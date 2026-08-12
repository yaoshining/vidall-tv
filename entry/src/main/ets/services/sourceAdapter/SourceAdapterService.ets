// filepath: entry/src/main/ets/services/sourceAdapter/SourceAdapterService.ets
//
// SourceAdapterService - 统一播放源解析与稳定 identity 收口服务。
//
// 目标：把原本散落在 PlayerPage、MovieDetailPage、SeasonDetailPage、
// PlayHistoryPage、FileExplorerPage 中的 WebDAV / SMB / local 协议拼装逻辑，
// 统一收敛到一个 service。
//
// 约束：
// 1. 不修改 `PlayerPageParam` 字段，保持现有播放入口契约。
// 2. 不重写 AVPlayer / IJK / Native adapter；只负责"播放前一刻"的源解析。
// 3. 不在本 service 内做 ffprobe 回填；只读取 DB 中已落库的轨道元数据。
//
// 与 ServiceLocator 的关系：
// - 默认通过 ServiceLocator.get<SourceAdapterService>('source-adapter') 获取。
// - 测试可通过 ServiceLocator.register('source-adapter', mock) 替换。
//
// 设计取舍：
// - 不引入新依赖（继续使用 WebDAVClient / FileSourceDatabase）。
// - 协议拼装结果与既有各入口保持字节级一致（端口兜底、rootPath 前导 `/`、
//   httpHeader 是否为空对象等）。

import { FileSourceDatabase } from "../../db/files/FileSourceDatabase";
import {
  FileSource,
  FileSourceType,
  SMBSourceConfig,
  WebDAVSourceConfig
} from "../../db/models/FileSourceEntity";
import { FfprobeTrack, FfprobeUtil } from "../../utils/FfprobeUtil";
import { buildWebDavHttpHeader, WebDAVClient, WebDAVConfig } from "../../lib/WebDAVClient";
import buffer from '@ohos.buffer';
import { PresetAudioTrack, PresetSubtitleTrack } from "../../components/core/player/VideoData";
import {
  PlaybackSourceIdentity,
  PlaybackSourceType,
  ResolvePlaybackSourceRequest,
  ResolvedPlaybackSource,
  fileSourceIdFromIdentity,
  fileSourceTypeFromIdentity
} from "./PlaybackSource";

/**
 * 已知协议类型集合。
 * 用于判断 `fileSource.type` 是否需要走 service 的协议拼装路径，
 * 其它类型（如 'aliyun'、'baidu' 等云盘）由后续 adapter 接入，本期不支持。
 */
const KNOWN_SOURCE_TYPES: ReadonlyArray<PlaybackSourceType> = ['webdav', 'smb', 'local'];

/**
 * `loadSourceMetadata` 的返回结构。
 * 显式 interface 避免 ArkTS `arkts-no-obj-literals-as-types` 与
 * `arkts-no-untyped-obj-literals` 报错。
 */
interface SourceMetadata {
  durationHintMs: number;
  presetAudioTracks: PresetAudioTrack[] | undefined;
  presetSubtitleTracks: PresetSubtitleTrack[] | undefined;
  startPositionMs: number;
}

/**
 * `assembleWebDavSource` / `assembleSmbSource` 的返回结构。
 */
interface AssembledSource {
  url: string;
  httpHeader: Record<string, string>;
}

/**
 * watch 判定阈值，与 `PlayerPage.resolveEpisodePlaybackSource` 现有行为保持一致。
 * >=95% 视为已完播，不返回 startPositionMs。
 */
const WATCHED_THRESHOLD = 0.95;

/**
 * 路径段编码工具，对齐原 `PlayHistoryPage.buildPlayUrl` 中 SMB 路径段处理逻辑：
 * 1. 先 `decodeURIComponent`，避免对已编码段再次编码。
 * 2. 再 `encodeURIComponent`，确保空格/中文被正确处理。
 */
function encodeSmbPathSegments(rawPath: string): string {
  return rawPath.split('/').map((seg: string): string => {
    if (seg.length === 0) {
      return '';
    }
    let decoded: string = seg;
    try {
      decoded = decodeURIComponent(seg);
    } catch {
      decoded = seg;
    }
    return encodeURIComponent(decoded);
  }).join('/');
}

/**
 * 判定 `fileSource.type` 是否在 service 支持范围内。
 */
export function isSupportedSourceType(type: string): boolean {
  return KNOWN_SOURCE_TYPES.indexOf(type) >= 0;
}

/**
 * 构造稳定的 source identity。
 * 规则：永远使用 `${sourceType}:${sourceId}`，并把 sourceId 转成字符串以避免 number→string 隐式转换带来的不稳定。
 */
export function buildSourceIdentity(
  sourceType: PlaybackSourceType,
  sourceId: number
): PlaybackSourceIdentity {
  return {
    sourceType,
    sourceId: sourceId > 0 ? sourceId.toString() : ''
  };
}

/**
 * SourceAdapterService - 协议无关的播放源解析 service。
 *
 * 公共 API：
 * - `resolveEpisode(req)`：从 DB 取 FileSource → 解析协议 → 回填轨道/进度 → 输出 ResolvedPlaybackSource。
 * - `resolveFromFileSource(fileSource, filePath, videoId?)`：当调用方已拿到 FileSource 时复用本 service，
 *   避免重复查 DB（如详情页已经查过一次）。
 */
export class SourceAdapterService {
  /**
   * 完整解析入口：根据 sourceId 反查 FileSource，再走协议拼装。
   * 若 sourceId 缺失或 DB 中不存在，返回 `null`，由调用方决定如何处理。
   */
  async resolveEpisode(req: ResolvePlaybackSourceRequest): Promise<ResolvedPlaybackSource | null> {
    if (req.sourceId === undefined || req.sourceId <= 0) {
      return null;
    }
    const fileSource = await FileSourceDatabase.getInstance().getFileSourceById(req.sourceId);
    if (fileSource === null) {
      return null;
    }
    const videoId = req.videoId ?? 0;
    return this.resolveFromFileSource(fileSource, req.filePath, videoId);
  }

  /**
   * 从已查到的 FileSource 直接解析，避免重复查 DB。
   *
   * 调用方负责保证 `fileSource` 是当前生效的（type / configJson 与 DB 一致）。
   * 协议类型不在 service 支持范围内时返回 `null`。
   */
  async resolveFromFileSource(
    fileSource: FileSource,
    filePath: string,
    videoId: number = 0
  ): Promise<ResolvedPlaybackSource | null> {
    if (fileSource.id === undefined) {
      return null;
    }
    if (!isSupportedSourceType(fileSource.type)) {
      return null;
    }
    const sourceType = fileSource.type as PlaybackSourceType;
    let url = '';
    let httpHeader: Record<string, string> = {};
    if (sourceType === 'webdav') {
      const assembled = this.assembleWebDavSource(fileSource.configJson, filePath);
      if (assembled === null) {
        return null;
      }
      url = assembled.url;
      httpHeader = assembled.httpHeader;
    } else if (sourceType === 'smb') {
      const assembled = this.assembleSmbSource(fileSource.configJson, filePath);
      if (assembled === null) {
        return null;
      }
      url = assembled.url;
      httpHeader = assembled.httpHeader;
    } else {
      // local 暂保留为直接使用 filePath
      url = filePath;
    }
    const sourceIdentity = buildSourceIdentity(sourceType, fileSource.id);
    const meta = await this.loadSourceMetadata(filePath, videoId);
    const result: ResolvedPlaybackSource = {
      url,
      httpHeader,
      sourceIdentity
    };
    if (meta.durationHintMs > 0) {
      result.durationHintMs = meta.durationHintMs;
    }
    if (meta.presetAudioTracks !== undefined) {
      result.presetAudioTracks = meta.presetAudioTracks;
    }
    if (meta.presetSubtitleTracks !== undefined) {
      result.presetSubtitleTracks = meta.presetSubtitleTracks;
    }
    if (meta.startPositionMs > 0) {
      result.startPositionMs = meta.startPositionMs;
    }
    return result;
  }

  /**
   * WebDAV URL + Authorization 拼装。
   * 与原 `PlayerPage.resolveEpisodePlaybackSource` / `MovieDetailPage.play` /
   * `PlayHistoryPage.buildPlayUrl` 行为对齐：
   * - 端口兜底：https→443，http→80（与 player index 一致）。
   * - rootPath 不强制前导 `/`，对齐 player index 既有实现。
   * - authHeader 为空时不写入 Authorization 头（httpHeader 返回空对象）。
   */
  private assembleWebDavSource(
    configJson: string,
    filePath: string
  ): AssembledSource | null {
    let config: WebDAVSourceConfig;
    try {
      config = JSON.parse(configJson) as WebDAVSourceConfig;
    } catch {
      return null;
    }
    const protocol = config.protocol ?? 'http';
    const host = config.url ?? '';
    const port = config.port ?? (protocol === 'https' ? 443 : 80);
    const rootPath = (config.rootPath ?? '').replace(/\/$/, '');
    // 补齐前导斜杠：用户配置 `rootPath: "dav"` 时，必须变成 `/dav`，
    // 否则 baseUrl 会拼成 `http://host:portdav`，WebDAVClient.getFullUrl 会生成错误 URL。
    const normalizedRootPath = rootPath.length > 0 && !rootPath.startsWith('/')
      ? `/${rootPath}`
      : rootPath;
    const baseUrl = `${protocol}://${host}:${port}${normalizedRootPath}`;
    const webdavConfig: WebDAVConfig = {
      baseUrl,
      username: config.username ?? '',
      password: config.password ?? '',
      timeout: 30000
    };
    const client = new WebDAVClient(webdavConfig);
    const url = client.getFullUrl(filePath);
    const authHeader = client.getAuthHeaderPublic();
    const httpHeader = buildWebDavHttpHeader(authHeader);
    const result: AssembledSource = { url, httpHeader };
    return result;
  }

  /**
   * SMB URL 拼装。
   * 与原 `PlayerPage.resolveEpisodePlaybackSource` / `MovieDetailPage.play` /
   * `SeasonDetailPage` / `PlayHistoryPage.buildPlayUrl` 行为对齐：
   * - 端口兜底 445。
   * - 路径段 `decode → encode` 二次处理。
   * - MPV 直连采用无 userinfo URI，并通过 Basic Authorization 交由 VidAll_Player
   *   的内部 native bridge 注入 Samba；AVPlayer/IJK 仍由后端服务使用原始 URI 建立代理。
   */
  private assembleSmbSource(
    configJson: string,
    filePath: string
  ): AssembledSource | null {
    let config: SMBSourceConfig;
    try {
      config = JSON.parse(configJson) as SMBSourceConfig;
    } catch {
      return null;
    }
    const port = config.port ?? 445;
    const encodedPath = encodeSmbPathSegments(filePath);
    const url = `smb://${config.host}:${port}${encodedPath}`;
    const username = config.username ?? '';
    const password = config.password ?? '';
    const credentials = buffer.from(`${username}:${password}`).toString('base64');
    const httpHeader: Record<string, string> = username.length > 0 || password.length > 0
      ? { 'Authorization': `Basic ${credentials}` }
      : {};
    const result: AssembledSource = { url, httpHeader };
    return result;
  }

  /**
   * 从 DB 读取时长、预置轨道、play_progress，并应用 watched 判定。
   *
   * 返回类型 SourceMetadata 为显式 interface，避免在 ArkTS 严格模式下
   * 使用 `Record<string, Object>` 等绕过类型检查的写法。
   */
  private async loadSourceMetadata(
    filePath: string,
    videoId: number
  ): Promise<SourceMetadata> {
    const db = FileSourceDatabase.getInstance();
    const videoEntity = await db.getVideoByPath(filePath);
    const meta: SourceMetadata = {
      durationHintMs: 0,
      presetAudioTracks: undefined,
      presetSubtitleTracks: undefined,
      startPositionMs: 0
    };
    if (videoEntity !== null) {
      if (videoEntity.durationMs !== undefined && videoEntity.durationMs !== null && videoEntity.durationMs > 0) {
        meta.durationHintMs = videoEntity.durationMs;
      }
      if (videoEntity.audioTracksJson !== undefined && videoEntity.audioTracksJson !== null &&
          videoEntity.audioTracksJson.length > 0) {
        const audioTracks = JSON.parse(videoEntity.audioTracksJson) as FfprobeTrack[];
        const mapped = FfprobeUtil.toPresetAudioTracks(audioTracks);
        if (mapped.length > 0) {
          meta.presetAudioTracks = mapped;
        }
      }
      if (videoEntity.subtitleTracksJson !== undefined && videoEntity.subtitleTracksJson !== null &&
          videoEntity.subtitleTracksJson.length > 0) {
        const subtitleTracks = JSON.parse(videoEntity.subtitleTracksJson) as FfprobeTrack[];
        const mapped = FfprobeUtil.toPresetSubtitleTracks(subtitleTracks);
        if (mapped.length > 0) {
          meta.presetSubtitleTracks = mapped;
        }
      }
    }
    if (videoId > 0) {
      const savedProgress = await db.getPlayProgress(videoId);
      if (savedProgress !== null && savedProgress.positionMs > 0) {
        const isWatched = savedProgress.durationMs > 0
          && savedProgress.positionMs >= savedProgress.durationMs * WATCHED_THRESHOLD;
        if (!isWatched) {
          meta.startPositionMs = savedProgress.positionMs;
        }
      }
    }
    return meta;
  }
}

/**
 * 默认 service 实例，便于 EntryAbility.onCreate 中一次性注册。
 */
export const defaultSourceAdapterService = new SourceAdapterService();

/**
 * `identityToPlayerPageParams` 的返回结构。
 */
export interface PlayerPageIdentityParams {
  fileSourceType: string;
  fileSourceId: string;
}

/**
 * 便捷桥接函数：直接消费 `ResolvedPlaybackSource` 输出与现有字段命名兼容的元组，
 * 减少调用方代码量。
 *
 * 用法：
 * ```typescript
 * const resolved = await SourceAdapterService.resolveEpisode(...);
 * if (resolved !== null) {
 *   const params = identityToPlayerPageParams(resolved.sourceIdentity);
 *   const fileSourceType = params.fileSourceType;
 *   const fileSourceId = params.fileSourceId;
 * }
 * ```
 *
 * 不使用对象解构（`const { fileSourceType, fileSourceId } = ...`），因为 ArkTS
 * 严格模式禁止解构声明。
 */
export function identityToPlayerPageParams(identity: PlaybackSourceIdentity): PlayerPageIdentityParams {
  return {
    fileSourceType: fileSourceTypeFromIdentity(identity),
    fileSourceId: fileSourceIdFromIdentity(identity)
  };
}

// 显式 re-export 方便 mock 测试。
export { FileSourceType };
