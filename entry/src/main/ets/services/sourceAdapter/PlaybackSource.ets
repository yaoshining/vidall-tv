// filepath: entry/src/main/ets/services/sourceAdapter/PlaybackSource.ets
//
// 统一的播放源描述模型。
//
// 背景：原 `PlayerPage.resolveEpisodePlaybackSource()`、`MovieDetailPage.play()`、
// `SeasonDetailPage`、`PlayHistoryPage.buildPlayUrl()`、`FileExplorerPage.playVideo()`
// 各处都各自 `JSON.parse(fileSource.configJson)` 后拼装 SMB / WebDAV URL 与
// Authorization header。规则分散且边界不一致（端口兜底、rootPath 前导 `/`、
// httpHeader 是否设置空对象等）。
//
// 本文件定义的类型，是 `SourceAdapterService` 与调用方之间的稳定契约，
// 用于：
// 1. 调用方不再关心协议拼装细节，只描述"我要播哪个文件源下的哪个文件"。
// 2. service 统一输出 URL / headers / source identity，供字幕缓存、最近使用字幕、
//    后续 runtime service（PlaybackBackendService、AudioTrackRoutingService 等）消费。
//
// 与现有 `ResolvedEpisodePlaybackSource` 的差异：
// - 增加 `sourceType` / `sourceId` / `sourceIdentity` 字段，确保稳定缓存 key 不再依赖
//   调用方自行透传。
// - 字段名改用更通用的 `filePath`，与现有 `videoPath` 同义但更直观。
// - `httpHeader` 始终为 `Record<string, string>`（无 token 时为空对象，不再 undefined）。
//
// 兼容性：
// - `PlayerPageParam` 不变；现有字段照旧透传到 `VideoData`。
// - `ResolvedEpisodePlaybackSource` 由 `PlayerPage` 内逐步替换，本 service 输出优先。

import { PresetAudioTrack, PresetSubtitleTrack } from "../../components/core/player/VideoData";

/** 协议类型，对齐 FileSourceEntity.FileSourceType 的字符串值。 */
export type PlaybackSourceType = 'webdav' | 'smb' | 'local' | string;

/**
 * 稳定的 source identity。
 *
 * 用途：作为字幕缓存与最近使用字幕记录的稳定 key，
 * 不应因 SMB 代理 URL 临时变化或 WebDAV host 重写而改变。
 *
 * 组成规则（service 内部强制）：
 * - `${sourceType}:${sourceId}`，例 `webdav:3`、`smb:7`、`local:42`
 * - 永久稳定，由 FileSource.id 在 DB 中保证不变。
 */
export interface PlaybackSourceIdentity {
  /** 协议类型字符串 */
  sourceType: PlaybackSourceType;
  /** 文件源 DB id 的字符串形式 */
  sourceId: string;
}

/**
 * 统一的播放源解析请求。
 *
 * 调用方只需描述"要播哪个文件源下的哪个文件"，
 * service 负责装配 URL / headers / identity / 已落库的轨道与时长。
 */
export interface ResolvePlaybackSourceRequest {
  /** DB 中的文件源 id；缺失时表示 local / 已构造好 URL 的直接透传场景 */
  sourceId?: number;
  /**
   * 协议类型（可选）。当 service 内部从 DB 读到 sourceId 时会自动推断；
   * 直接透传场景（如 FileExplorerPage 已拿到 client）由调用方显式传入。
   */
  sourceType?: PlaybackSourceType;
  /** 文件相对路径（含前导 /），用于 SMB / WebDAV URL 拼装 */
  filePath: string;
  /** 视频 DB id（可选），用于回查 play_progress 与 ffprobe 落库轨道 */
  videoId?: number;
}

/**
 * 统一的播放源解析结果。
 *
 * 调用方拿到后可直接映射到 `PlayerPageParam` 的 url / httpHeader / durationHintMs /
 * presetAudioTracks / presetSubtitleTracks / startPositionMs / fileSourceType /
 * fileSourceId 等字段。
 */
export interface ResolvedPlaybackSource {
  /** 已编码的播放 URL（直接喂给 AVPlayer / MPV / native backend） */
  url: string;
  /**
   * HTTP 请求头。空时返回空对象（而非 undefined），便于调用方直接赋值。
   * 当前仅 WebDAV 场景会附带 Authorization；SMB 走 player 内部 NAPI，不依赖此 header。
   */
  httpHeader: Record<string, string>;
  /** 时长提示（毫秒），从 `videos` 表读取 */
  durationHintMs?: number;
  /** ffprobe 落库后的预置音轨 */
  presetAudioTracks?: PresetAudioTrack[];
  /** ffprobe 落库后的预置字幕轨 */
  presetSubtitleTracks?: PresetSubtitleTrack[];
  /**
   * 集内起播位置（毫秒），由 service 从 `play_progress` 按 videoId 读取，
   * 已应用 watched 判定（>=95% 不返回）。
   *
   * 调用方拿到后透传到 `PlayerPageParam.startPositionMs`。
   */
  startPositionMs?: number;
  /**
   * 稳定的 source identity，供字幕缓存 / 最近使用字幕记录使用。
   * service 内部保证存在；调用方可直接赋值到 `PlayerPageParam.fileSourceType` 与
   * `fileSourceId`，二者在现有实现中已被用于字幕缓存分桶。
   */
  sourceIdentity: PlaybackSourceIdentity;
}

/**
 * `toResolveRequest` 的输入项。
 * 显式 interface 避免 ArkTS `arkts-no-obj-literals-as-types` 报错。
 */
export interface ToResolveRequestItem {
  sourceId?: number;
  videoPath: string;
  videoId?: number;
}

/**
 * `PlaybackContextItem` → `ResolvePlaybackSourceRequest` 的桥接函数。
 *
 * 调用方（媒体库剧集切源、文件浏览器上下集切换）在拿到 `PlaybackContextItem` 后
 * 只需把字段映射到 `ResolvePlaybackSourceRequest`，由 service 负责拼装。
 *
 * 本函数不读 DB、不依赖 service 实例，便于在测试或 mock 场景中复用。
 */
export function toResolveRequest(item: ToResolveRequestItem): ResolvePlaybackSourceRequest {
  const req: ResolvePlaybackSourceRequest = { filePath: item.videoPath };
  if (item.sourceId !== undefined) {
    req.sourceId = item.sourceId;
  }
  if (item.videoId !== undefined) {
    req.videoId = item.videoId;
  }
  return req;
}

/**
 * 从 `ResolvedPlaybackSource` 派生 `PlayerPageParam` 所需的 identity 字符串。
 *
 * 与现有 `PlayerPageParam.fileSourceType` / `fileSourceId` 字段语义保持一致，
 * 调用方只需 `nextParam.fileSourceType = identity.sourceType`。
 */
export function fileSourceTypeFromIdentity(identity: PlaybackSourceIdentity): string {
  return identity.sourceType;
}

export function fileSourceIdFromIdentity(identity: PlaybackSourceIdentity): string {
  return identity.sourceId;
}
