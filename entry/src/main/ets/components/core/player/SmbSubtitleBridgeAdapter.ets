import { hilog } from '@kit.PerformanceAnalysisKit';
import { CommonConstants } from '../../../common/constants/CommonConstants';
import { SMBClient, SMBClientConfig } from '../../../lib/SMBClient';
import { AvSubtitleBridgeAdapter, BaseSubtitleBridgeAdapter, SubtitleTrackItem } from './SubtitleBridgeAdapter';
import { AssFileParser, SrtEntry, SrtParser } from './SubtitleRenderer';
import { PresetSubtitleTrack } from './VideoData';
import { FfprobeUtil, EmbeddedSubEntry } from '../../../utils/FfprobeUtil';
import { VidAllPlayerAdapter } from './VidAllPlayerAdapter';

const TAG = '[SmbSubtitleBridgeAdapter]';

const SUBTITLE_EXTENSIONS: string[] = ['.srt', '.ass', '.ssa', '.vtt'];

/** 候选字幕文件信息，供并发读取阶段使用 */
interface SubtitleCandidate {
  name: string;
  filePath: string;
  matchedExt: string;
}

/** SMB 视频 URL 解析结果 */
interface ParsedSmbVideoUrl {
  host: string;
  port: number;
  username: string;
  password: string;
  shareName: string;
  /** 用于 listDirectory 的路径，如 "/share/Movies" */
  listDirPath: string;
  /** 视频文件名（不含扩展名），用于过滤同名字幕文件 */
  baseName: string;
}

/**
 * 解析 SMB 视频 URL，提取连接参数与路径信息。
 * URL 格式：smb://user:pass@host:port/share/subdir/video.mkv
 * 凭据部分由 SMBClient.buildSmbUrl 通过 encodeURIComponent 生成，故 ':' 在凭据中会被编码为 %3A。
 */
function parseSmbVideoUrl(url: string): ParsedSmbVideoUrl | null {
  if (!url.startsWith('smb://')) {
    return null;
  }

  // 去掉 "smb://" 前缀
  const withoutScheme: string = url.substring(6);

  // 凭据分隔符 '@'：由于用户名和密码已 percent-encode，'@' 不会出现在凭据中
  const atIdx: number = withoutScheme.indexOf('@');

  let authPart: string = '';
  let hostAndPath: string = '';
  if (atIdx >= 0) {
    authPart = withoutScheme.substring(0, atIdx);
    hostAndPath = withoutScheme.substring(atIdx + 1);
  } else {
    hostAndPath = withoutScheme;
  }

  // 解析 username:password
  let username: string = '';
  let password: string = '';
  if (authPart.length > 0) {
    const colonIdx: number = authPart.indexOf(':');
    if (colonIdx >= 0) {
      try {
        username = decodeURIComponent(authPart.substring(0, colonIdx));
      } catch (e) {
        username = authPart.substring(0, colonIdx);
      }
      try {
        password = decodeURIComponent(authPart.substring(colonIdx + 1));
      } catch (e) {
        password = authPart.substring(colonIdx + 1);
      }
    } else {
      try {
        username = decodeURIComponent(authPart);
      } catch (e) {
        username = authPart;
      }
    }
  }

  // 解析 host:port/fullPath
  const firstSlash: number = hostAndPath.indexOf('/');
  const hostPortStr: string = firstSlash >= 0 ? hostAndPath.substring(0, firstSlash) : hostAndPath;
  const fullPath: string = firstSlash >= 0 ? hostAndPath.substring(firstSlash) : '/';

  let host: string = hostPortStr;
  let port: number = 445;
  const portColon: number = hostPortStr.lastIndexOf(':');
  if (portColon >= 0) {
    host = hostPortStr.substring(0, portColon);
    const portStr: string = hostPortStr.substring(portColon + 1);
    const portNum: number = parseInt(portStr);
    if (!isNaN(portNum) && portNum > 0) {
      port = portNum;
    }
  }

  // 解析完整路径 "/share/subdir1/.../filename.mkv"
  // 去掉前导斜杠后按 '/' 分割
  let cleanPath: string = fullPath;
  while (cleanPath.startsWith('/')) {
    cleanPath = cleanPath.substring(1);
  }

  const segments: string[] = cleanPath.split('/');
  if (segments.length < 2) {
    // share 内无文件路径，无法定位字幕目录
    return null;
  }

  // 第一段是 share 名称
  let shareName: string = segments[0];
  try {
    shareName = decodeURIComponent(shareName);
  } catch (e) {
    // 保留原始值
  }

  // 最后一段是文件名
  let fileSegment: string = segments[segments.length - 1];
  try {
    fileSegment = decodeURIComponent(fileSegment);
  } catch (e) {
    // 保留原始值
  }

  // 中间段是目录路径（share 内部）
  const dirSegments: string[] = [];
  for (let i = 1; i < segments.length - 1; i++) {
    let seg: string = segments[i];
    try {
      seg = decodeURIComponent(seg);
    } catch (e) {
      // 保留原始值
    }
    dirSegments.push(seg);
  }

  // listDirPath: "/<shareName>/<dirSegments...>"
  let subDirPart: string = '';
  if (dirSegments.length > 0) {
    subDirPart = '/' + dirSegments.join('/');
  }
  const listDirPath: string = '/' + shareName + subDirPart;

  // baseName: 文件名去掉扩展名
  const dotIdx: number = fileSegment.lastIndexOf('.');
  const baseName: string = dotIdx > 0 ? fileSegment.substring(0, dotIdx) : fileSegment;

  const result: ParsedSmbVideoUrl = {
    host,
    port,
    username,
    password,
    shareName,
    listDirPath,
    baseName
  };
  return result;
}

/**
 * 从文件名中提取语言标签。
 * 例："电影.chs.srt" + baseName "电影" → "chs"
 *     "电影.srt"     + baseName "电影" → ""（使用默认显示名）
 */
function extractSmbLangLabel(fileName: string, baseName: string): string {
  const dotIdx: number = fileName.lastIndexOf('.');
  const withoutExt: string = dotIdx >= 0 ? fileName.substring(0, dotIdx) : fileName;
  if (withoutExt === baseName) {
    return '';
  }
  const prefix: string = baseName + '.';
  if (withoutExt.startsWith(prefix)) {
    return withoutExt.substring(prefix.length);
  }
  return withoutExt;
}

/**
 * 通过 SMB 协议加载视频同名外置字幕文件（可被多个适配器复用）。
 * 任何步骤失败均静默处理（catch 后返回空数组），不向上抛出异常。
 */
async function loadSmbExternalSubtitles(smbVideoUrl: string): Promise<SubtitleTrackItem[]> {
  if (!smbVideoUrl.startsWith('smb://')) {
    return [];
  }
  try {
    const parsed: ParsedSmbVideoUrl | null = parseSmbVideoUrl(smbVideoUrl);
    if (!parsed) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        '[外置字幕] SMB URL 解析失败，跳过字幕加载');
      return [];
    }

    const clientConfig: SMBClientConfig = {
      host: parsed.host,
      port: parsed.port,
      username: parsed.username,
      password: parsed.password,
      shareName: parsed.shareName
    };
    const client: SMBClient = new SMBClient(clientConfig);

    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[外置字幕] 列举目录 host=${parsed.host} path=${parsed.listDirPath} baseName=${parsed.baseName}`);

    const dirResult = await client.listDirectory(parsed.listDirPath);
    if (dirResult.error && dirResult.files.length === 0) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `[外置字幕] 目录列举失败: ${dirResult.error}`);
      return [];
    }

    const sharePrefix: string = '/' + parsed.shareName;
    const lowerBaseName: string = parsed.baseName.toLowerCase();

    const candidates: SubtitleCandidate[] = [];
    for (let i = 0; i < dirResult.files.length; i++) {
      const file = dirResult.files[i];
      if (file.isDirectory) {
        continue;
      }
      const lowerName: string = file.name.toLowerCase();
      let isSubtitle: boolean = false;
      let matchedExt: string = '';
      for (let j = 0; j < SUBTITLE_EXTENSIONS.length; j++) {
        if (lowerName.endsWith(SUBTITLE_EXTENSIONS[j])) {
          isSubtitle = true;
          matchedExt = SUBTITLE_EXTENSIONS[j];
          break;
        }
      }
      if (!isSubtitle) {
        continue;
      }
      const nameWithoutExt: string = lowerName.substring(0, lowerName.length - matchedExt.length);
      const strictMatch: boolean = nameWithoutExt === lowerBaseName
        || nameWithoutExt.startsWith(`${lowerBaseName}.`);
      if (!strictMatch) {
        continue;
      }
      let filePath: string = file.path;
      if (filePath.startsWith(sharePrefix)) {
        filePath = filePath.substring(sharePrefix.length);
      }
      const candidate: SubtitleCandidate = { name: file.name, filePath, matchedExt };
      candidates.push(candidate);
    }

    if (candidates.length === 0) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '[外置字幕探测完成] 找到 0 个 SMB 外置字幕');
      return [];
    }

    const readWithTimeout = (p: Promise<string>, ms: number): Promise<string> => {
      const timeoutP: Promise<string> = new Promise<string>((resolve) => {
        setTimeout(() => resolve(''), ms);
      });
      return Promise.race([p, timeoutP]);
    };
    const contents: string[] = await Promise.all(
      candidates.map((candidate) =>
        readWithTimeout(client.readTextFile(candidate.filePath).catch(() => ''), 3000)
      )
    );

    const found: SubtitleTrackItem[] = [];
    for (let i = 0; i < candidates.length; i++) {
      const content: string = contents[i];
      if (content.length === 0) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `[外置字幕] 读取超时或失败: ${candidates[i].name}`);
        continue;
      }
      try {
        const matchedExt: string = candidates[i].matchedExt;
        let entries: SrtEntry[] = [];
        let formatLabel: string = 'SRT';
        if (matchedExt === '.ass' || matchedExt === '.ssa') {
          entries = AssFileParser.parse(content);
          formatLabel = 'ASS';
        } else if (matchedExt === '.vtt') {
          entries = SrtParser.parse(content);
          formatLabel = 'VTT';
        } else {
          entries = SrtParser.parse(content);
          formatLabel = 'SRT';
        }
        const langLabel: string = extractSmbLangLabel(candidates[i].name, parsed.baseName);
        const displayName: string = langLabel.length > 0
          ? `${langLabel} [外部·${formatLabel}]`
          : `字幕 [外部·${formatLabel}]`;
        if (entries.length === 0) {
          hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
            `[外置字幕] 解析结果为空，跳过: ${candidates[i].name}`);
          continue;
        }
        const item: SubtitleTrackItem = { kind: 'external', displayName, srtEntries: entries };
        found.push(item);
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[外置字幕] 加载成功: ${candidates[i].name} entries=${entries.length}`);
      } catch (e) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `[外置字幕] 解析失败: ${candidates[i].name}`);
      }
    }

    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[外置字幕探测完成] 找到 ${found.length} 个 SMB 外置字幕`);
    return found;
  } catch (e) {
    hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
      '[外置字幕] SMB 字幕加载异常，返回空数组');
    return [];
  }
}

/**
 * SMB 外置字幕适配器（配合 native FFmpeg 后端使用）。
 * 外置字幕通过 SMB 协议加载；内嵌字幕通过 FfprobeUtil.extractEmbeddedSubtitles 提取。
 */
export class SmbSubtitleBridgeAdapter extends BaseSubtitleBridgeAdapter {
  /** 防止异步提取竞态：每次发起新切轨请求时递增，过期结果不写入 srtEntries */
  private subtitleSwitchGeneration: number = 0;
  /** 缓存最新播放位置，用于提取完成后判断 entries 是否覆盖当前时间 */
  private lastKnownPositionMs: number = 0;

  override onTimeUpdate(currentTimeMs: number): void {
    this.lastKnownPositionMs = currentTimeMs;
    super.onTimeUpdate(currentTimeMs);
  }

  protected async loadExternalTracks(): Promise<SubtitleTrackItem[]> {
    return loadSmbExternalSubtitles(this.videoData?.videoSrc ?? '');
  }

  /**
   * 覆写内嵌轨道加载：从 videoData.presetSubtitleTracks 读取已由 ffprobe 探测到的字幕轨，
   * 过滤掉 PGS / DVD subtitle 等图形格式，只保留可文本渲染的格式。
   */
  protected override async loadInternalTracks(): Promise<SubtitleTrackItem[]> {
    const items: SubtitleTrackItem[] = [];
    const presets = this.videoData?.presetSubtitleTracks;
    if (!presets || presets.length === 0) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        '[SmbSub] 无 presetSubtitleTracks，跳过内嵌轨道加载');
      return items;
    }
    const TEXT_CODECS: string[] = ['subrip', 'srt', 'ass', 'ssa', 'webvtt', 'mov_text'];
    for (let i = 0; i < presets.length; i++) {
      const t: PresetSubtitleTrack = presets[i];
      if (t.codecName && !TEXT_CODECS.includes(t.codecName)) {
        continue;
      }
      const item: SubtitleTrackItem = {
        kind: 'internal',
        displayName: t.displayName,
        internalIndex: t.trackIndex
      };
      items.push(item);
    }
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[SmbSub] loadInternalTracks: preset=${presets.length} 可渲染文本字幕=${items.length}`);
    return items;
  }

  /**
   * 覆写轨道切换：内嵌字幕通过 FfprobeUtil.extractEmbeddedSubtitles 提取后走 SRT 渲染管线；
   * 外置字幕交由父类处理（srtEntries 已在 loadExternalTracks 解析完毕）。
   */
  override async switchTrack(allIndex: number): Promise<void> {
    if (!this.player) {
      return;
    }
    if (allIndex < 0) {
      await this.player?.selectTrack(-1);
      await super.switchTrack(allIndex);
      return;
    }
    const target = this.allSubtitleTracks[allIndex];
    if (!target) {
      return;
    }
    if (target.kind === 'external') {
      await super.switchTrack(allIndex);
      return;
    }
    const internalIndex = target.internalIndex ?? -1;
    if (internalIndex < 0) {
      return;
    }
    await this.player?.selectTrack(-1);
    this.subtitleSwitchGeneration += 1;
    const currentGen = this.subtitleSwitchGeneration;
    this.activeSubtitleIndex = allIndex;
    this.srtEntries = [];
    this.lastSrtText = '';
    this.currentSubtitleText = '';
    this.currentSubtitleTrack = internalIndex;

    let videoSrc: string = this.videoData?.videoSrc ?? '';
    const vidAllAdapter = this.player as VidAllPlayerAdapter;
    const proxyUrl: string = vidAllAdapter?.getProxyUrl?.() ?? '';
    if (proxyUrl.length > 0) {
      videoSrc = proxyUrl;
    }
    if (videoSrc.length === 0) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, '[SmbSub] 无可用视频 URL，降级无字幕');
      return;
    }

    try {
      const entries: EmbeddedSubEntry[] = await FfprobeUtil.extractEmbeddedSubtitles(
        videoSrc, undefined, internalIndex, 90000
      );
      if (currentGen !== this.subtitleSwitchGeneration) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          '[SmbSub] 字幕提取结果已过期，丢弃（generation 不匹配）');
        return;
      }
      this.srtEntries = entries as SrtEntry[];
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[SmbSub] 内嵌字幕提取完成 stream=${internalIndex} entries=${entries.length}`);

      let needFallback = entries.length === 0;
      if (!needFallback && entries.length > 0) {
        const maxEndMs: number = (entries as SrtEntry[]).reduce(
          (maxVal: number, e: SrtEntry) => e.endMs > maxVal ? e.endMs : maxVal,
          0
        );
        const curPos: number = this.lastKnownPositionMs;
        if (curPos > 0 && maxEndMs < curPos) {
          hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
            `[SmbSub] 内嵌字幕仅覆盖到 ${maxEndMs}ms，当前播放 ${curPos}ms，需 fallback`);
          needFallback = true;
        }
      }
      if (needFallback) {
        const externalIndex: number = this.allSubtitleTracks.findIndex(
          (t: SubtitleTrackItem) => t.kind === 'external'
        );
        if (externalIndex >= 0) {
          hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
            `[SmbSub] 内嵌字幕不足，fallback 到外置字幕 index=${externalIndex}`);
          await super.switchTrack(externalIndex);
        }
      }
    } catch {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        '[SmbSub] 内嵌字幕提取失败，尝试 fallback 到外置字幕');
      if (currentGen === this.subtitleSwitchGeneration) {
        const externalIdx: number = this.allSubtitleTracks.findIndex(
          (t: SubtitleTrackItem) => t.kind === 'external'
        );
        if (externalIdx >= 0) {
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `[SmbSub] catch fallback 到外置字幕 index=${externalIdx}`);
          await super.switchTrack(externalIdx);
        }
      }
    }
  }
}

/**
 * SMB + AVPlayer 字幕适配器。
 * 内嵌字幕通过 AVPlayer 原生 subtitleInfoUpdate 实时推送（继承 AvSubtitleBridgeAdapter）；
 * 外置字幕通过 SMBClient 从原始 SMB URL 目录加载（覆写 loadExternalTracks）。
 * 适用于 SMB 源切换到 AVPlayer 路径（通过 HTTP 代理拉流）的场景。
 */
export class SmbAvSubtitleBridgeAdapter extends AvSubtitleBridgeAdapter {
  private readonly smbVideoUrl: string;

  constructor(smbVideoUrl: string) {
    super();
    this.smbVideoUrl = smbVideoUrl;
  }

  protected override async loadExternalTracks(): Promise<SubtitleTrackItem[]> {
    return loadSmbExternalSubtitles(this.smbVideoUrl);
  }
}
