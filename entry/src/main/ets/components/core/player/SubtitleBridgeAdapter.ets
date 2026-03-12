import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import util from '@ohos.util';
import { CommonConstants } from '../../../common/constants/CommonConstants';
import { VideoData } from './VideoData';
import { VideoDataType } from './Constants';
import { IPlayer, SubtitleInfo, TrackInfo } from './IPlayer';
import { AssFileParser, SrtEntry, SrtParser } from './SubtitleRenderer';

const TAG = '[SubtitleBridgeAdapter]';

/**
 * 将字幕文件的原始字节解码为字符串，自动识别 UTF-8（含 BOM）与 GBK 编码。
 * 判断依据：
 *   1. 有 UTF-8 BOM（EF BB BF）→ UTF-8
 *   2. 检测第一个高字节序列是否符合 UTF-8 多字节规则 → UTF-8
 *   3. 否则视为 GBK（兼容 GB2312 / GB18030）
 */
function decodeSubtitleBytes(arrayBuffer: ArrayBuffer): string {
  const bytes = new Uint8Array(arrayBuffer);

  // 检测 UTF-8 BOM
  if (bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) {
    const decoder = new util.TextDecoder('utf-8', { ignoreBOM: true });
    return decoder.decodeWithStream(new Uint8Array(arrayBuffer));
  }

  // 启发式检测：扫描前4KB，看是否存在合法的 UTF-8 多字节序列
  // 若发现非法 UTF-8 序列则判定为 GBK
  const sampleLen = Math.min(bytes.length, 4096);
  let isUtf8 = true;
  let i = 0;
  while (i < sampleLen) {
    const b = bytes[i];
    if (b < 0x80) {
      i++;
      continue;
    }
    let extraBytes = 0;
    if ((b & 0xE0) === 0xC0) { extraBytes = 1; }
    else if ((b & 0xF0) === 0xE0) { extraBytes = 2; }
    else if ((b & 0xF8) === 0xF0) { extraBytes = 3; }
    else {
      // 0x80-0xBF 开头 或 0xF8+ 开头，UTF-8 非法
      isUtf8 = false;
      break;
    }
    for (let j = 1; j <= extraBytes; j++) {
      if (i + j >= sampleLen || (bytes[i + j] & 0xC0) !== 0x80) {
        isUtf8 = false;
        break;
      }
    }
    if (!isUtf8) { break; }
    i += 1 + extraBytes;
  }

  const encoding = isUtf8 ? 'utf-8' : 'gbk';
  hilog.info(0x0000, TAG, `[decodeSubtitleBytes] 检测编码=${encoding} sampleLen=${sampleLen}`);
  const decoder = new util.TextDecoder(encoding);
  return decoder.decodeWithStream(new Uint8Array(arrayBuffer));
}

export interface SubtitleTrackItem {
  kind: 'internal' | 'external';
  displayName: string;
  internalIndex?: number;
  srtEntries?: SrtEntry[];
  url?: string;
}

export interface SubtitleBridgeState {
  subtitleTracks: TrackInfo[];
  allSubtitleTracks: SubtitleTrackItem[];
  activeSubtitleIndex: number;
  currentSubtitleTrack: number;
  currentSubtitleText: string;
  subtitleDelayMs: number;
  hasExternalActive: boolean;
}

export interface ISubtitleBridgeAdapter {
  init(player: IPlayer, videoData?: VideoData): Promise<void>;
  onTimeUpdate(currentTimeMs: number): void;
  onSubtitleUpdate(info: SubtitleInfo): void;
  switchTrack(allIndex: number): Promise<void>;
  adjustDelay(deltaMs: number): void;
  onSeekSync(): void;
  getState(): SubtitleBridgeState;
  release(): void;
}

class BaseSubtitleBridgeAdapter implements ISubtitleBridgeAdapter {
  protected player?: IPlayer;
  protected videoData?: VideoData;
  protected subtitleTracks: TrackInfo[] = [];
  protected allSubtitleTracks: SubtitleTrackItem[] = [];
  protected activeSubtitleIndex: number = -1;
  protected currentSubtitleTrack: number = -1;
  protected currentSubtitleText: string = '';
  protected subtitleDelayMs: number = 0;
  protected srtEntries: SrtEntry[] = [];
  protected lastSrtText: string = '';

  async init(player: IPlayer, videoData?: VideoData): Promise<void> {
    this.player = player;
    this.videoData = videoData;
    this.subtitleTracks = [];
    this.allSubtitleTracks = [];
    this.activeSubtitleIndex = -1;
    this.currentSubtitleTrack = -1;
    this.currentSubtitleText = '';
    this.subtitleDelayMs = 0;
    this.srtEntries = [];
    this.lastSrtText = '';

    const internalItems = await this.loadInternalTracks();
    const mergedItems: SubtitleTrackItem[] = [];
    for (let i = 0; i < internalItems.length; i++) {
      mergedItems.push(internalItems[i]);
    }

    const externalItems = await this.loadExternalTracks();
    for (let i = 0; i < externalItems.length; i++) {
      mergedItems.push(externalItems[i]);
    }

    this.allSubtitleTracks = mergedItems;

    if (this.allSubtitleTracks.length > 0) {
      const preferredIndex = this.findPreferredTrackIndex();
      await this.switchTrack(preferredIndex);
    }
  }

  /** 默认优先选择外置字幕，其次才是第一条内嵌字幕 */
  protected findPreferredTrackIndex(): number {
    for (let i = 0; i < this.allSubtitleTracks.length; i++) {
      if (this.allSubtitleTracks[i].kind === 'external') {
        return i;
      }
    }
    return 0;
  }

  onTimeUpdate(currentTimeMs: number): void {
    if (this.srtEntries.length === 0) {
      return;
    }
    const adjustedTime = currentTimeMs - this.subtitleDelayMs;
    const text = SrtParser.findAt(this.srtEntries, adjustedTime);
    if (text !== this.lastSrtText) {
      this.lastSrtText = text;
      this.currentSubtitleText = text;
    }
  }

  onSubtitleUpdate(info: SubtitleInfo): void {
    if (this.srtEntries.length > 0) {
      return;
    }
    this.currentSubtitleText = info.text ?? '';
  }

  async switchTrack(allIndex: number): Promise<void> {
    if (!this.player) {
      return;
    }

    this.activeSubtitleIndex = allIndex;
    this.currentSubtitleText = '';

    if (allIndex < 0) {
      this.srtEntries = [];
      this.lastSrtText = '';
      this.currentSubtitleTrack = -1;
      await this.player.selectTrack(-1);
      return;
    }

    if (allIndex >= this.allSubtitleTracks.length) {
      return;
    }

    const target = this.allSubtitleTracks[allIndex];
    if (target.kind === 'external') {
      const entries = target.srtEntries ?? [];
      this.srtEntries = entries;
      this.lastSrtText = '';
      this.currentSubtitleTrack = -1;
      await this.player.selectTrack(-1);
      return;
    }

    this.srtEntries = [];
    this.lastSrtText = '';
    const internalIndex = target.internalIndex ?? -1;
    this.currentSubtitleTrack = internalIndex;
    await this.player.selectTrack(internalIndex);
  }

  adjustDelay(deltaMs: number): void {
    this.subtitleDelayMs += deltaMs;
    this.lastSrtText = '';
  }

  onSeekSync(): void {
    this.lastSrtText = '';
  }

  getState(): SubtitleBridgeState {
    const state: SubtitleBridgeState = {
      subtitleTracks: this.subtitleTracks,
      allSubtitleTracks: this.allSubtitleTracks,
      activeSubtitleIndex: this.activeSubtitleIndex,
      currentSubtitleTrack: this.currentSubtitleTrack,
      currentSubtitleText: this.currentSubtitleText,
      subtitleDelayMs: this.subtitleDelayMs,
      hasExternalActive: this.srtEntries.length > 0
    };
    return state;
  }

  release(): void {
    this.subtitleTracks = [];
    this.allSubtitleTracks = [];
    this.activeSubtitleIndex = -1;
    this.currentSubtitleTrack = -1;
    this.currentSubtitleText = '';
    this.subtitleDelayMs = 0;
    this.srtEntries = [];
    this.lastSrtText = '';
    this.player = undefined;
    this.videoData = undefined;
  }

  protected async loadInternalTracks(): Promise<SubtitleTrackItem[]> {
    return [];
  }

  protected async loadExternalTracks(): Promise<SubtitleTrackItem[]> {
    if (!this.videoData || this.videoData.type !== VideoDataType.URL) {
      return [];
    }

    const videoUrl = this.videoData.videoSrc;
    const lastSlash = videoUrl.lastIndexOf('/');
    const dirUrl = lastSlash >= 0 ? videoUrl.substring(0, lastSlash + 1) : videoUrl + '/';
    const fileName = lastSlash >= 0 ? videoUrl.substring(lastSlash + 1) : videoUrl;
    const cleanFileName = fileName.split('?')[0];
    // 视频URL中的文件名可能已经是URL编码形式（如 %E6%9D%83...）
    // 必须先解码还原为真实文件名，再重新 encodeURIComponent 拼接候选路径
    // 否则 encodeURIComponent 会对 % 再次编码，产生双重编码（%25E6%259D%2583...）
    let decodedFileName = cleanFileName;
    try {
      decodedFileName = decodeURIComponent(cleanFileName);
    } catch (e) {
      decodedFileName = cleanFileName;
    }
    const dotIdx = decodedFileName.lastIndexOf('.');
    const baseName = dotIdx >= 0 ? decodedFileName.substring(0, dotIdx) : decodedFileName;

    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[外置字幕探测] videoUrl=${videoUrl}`);
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[外置字幕探测] dirUrl=${dirUrl} fileName=${fileName} baseName=${baseName}`);

    const subtitleExts: string[] = ['srt', 'ass', 'ssa', 'vtt'];
    const langTags: string[] = [
      'chi', 'chs', 'cht', 'zho', 'eng',
      'jpn', 'kor', 'fra', 'deu', 'spa', 'rus',
      'zh', 'zh-CN', 'zh-TW', 'en', 'ja', 'ko'
    ];

    const candidates: string[] = [];
    for (let i = 0; i < subtitleExts.length; i++) {
      const ext = subtitleExts[i];
      candidates.push(`${baseName}.${ext}`);
    }
    for (let i = 0; i < langTags.length; i++) {
      const lang = langTags[i];
      for (let j = 0; j < subtitleExts.length; j++) {
        const ext = subtitleExts[j];
        candidates.push(`${baseName}.${lang}.${ext}`);
      }
    }

    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[外置字幕探测] 生成 ${candidates.length} 个候选字幕文件`);

    const headers: Record<string, string> = { 'User-Agent': 'VidALL/1.0.0' };
    if (this.videoData.httpHeader) {
      const keys = Object.keys(this.videoData.httpHeader);
      for (let i = 0; i < keys.length; i++) {
        const k = keys[i];
        headers[k] = this.videoData.httpHeader[k];
      }
    }

    const found: SubtitleTrackItem[] = [];
    for (let i = 0; i < candidates.length; i++) {
      const candidate = candidates[i];
      const url = dirUrl + encodeURIComponent(candidate);
      const exists = await this.probeUrl(url, headers);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[外置字幕探测] candidate=${candidate} url=${url} exists=${exists}`);
      if (!exists) {
        continue;
      }

      const lower = candidate.toLowerCase();
      const isSrt = lower.endsWith('.srt');
      const isAss = lower.endsWith('.ass') || lower.endsWith('.ssa');
      const isVtt = lower.endsWith('.vtt');
      if (!isSrt && !isAss && !isVtt) {
        continue;
      }

      try {
        let entries: SrtEntry[] = [];
        if (isAss) {
          entries = await this.fetchAss(url, headers);
        } else {
          entries = await this.fetchSrt(url, headers);
        }
        const formatLabel = isAss ? 'ASS' : (isVtt ? 'VTT' : 'SRT');
        const item: SubtitleTrackItem = {
          kind: 'external',
          displayName: `字幕 [外部·${formatLabel}]`,
          url,
          srtEntries: entries
        };
        found.push(item);
      } catch (e) {
        const err = e as BusinessError;
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `外部字幕处理失败: code=${err.code} msg=${err.message}`);
      }
    }

    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[外置字幕探测完成] 找到 ${found.length} 个外置字幕`);
    return found;
  }

  protected probeUrl(url: string, headers: Record<string, string>): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      const req = http.createHttp();
      req.request(url, {
        method: http.RequestMethod.HEAD,
        header: headers,
        connectTimeout: 5000,
        readTimeout: 5000
      }, (err: BusinessError, resp: http.HttpResponse) => {
        req.destroy();
        if (err) {
          resolve(false);
          return;
        }
        const code = resp.responseCode;
        resolve(code === 200 || code === 206 || code === 301 || code === 302);
      });
    });
  }

  protected fetchSrt(url: string, headers: Record<string, string>): Promise<SrtEntry[]> {
    return new Promise<SrtEntry[]>((resolve, reject) => {
      const req = http.createHttp();
      req.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 10000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      }, (err: BusinessError, resp: http.HttpResponse) => {
        req.destroy();
        if (err) {
          reject(err);
          return;
        }
        if (resp.responseCode !== 200) {
          reject(new Error(`HTTP ${resp.responseCode}`));
          return;
        }
        const body = decodeSubtitleBytes(resp.result as ArrayBuffer);
        resolve(SrtParser.parse(body));
      });
    });
  }

  protected fetchAss(url: string, headers: Record<string, string>): Promise<SrtEntry[]> {
    return new Promise<SrtEntry[]>((resolve, reject) => {
      const req = http.createHttp();
      req.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 10000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      }, (err: BusinessError, resp: http.HttpResponse) => {
        req.destroy();
        if (err) {
          reject(err);
          return;
        }
        if (resp.responseCode !== 200) {
          reject(new Error(`HTTP ${resp.responseCode}`));
          return;
        }
        const body = decodeSubtitleBytes(resp.result as ArrayBuffer);
        resolve(AssFileParser.parse(body));
      });
    });
  }
}

export class IjkSubtitleBridgeAdapter extends BaseSubtitleBridgeAdapter {
  protected async loadInternalTracks(): Promise<SubtitleTrackItem[]> {
    // 隐藏内嵌字幕以避免长时间的字幕提取等待
    // 扫描时仍然会保存所有轨道信息到数据库（供未来优化使用）
    // 运行时只通过 loadExternalTracks() 加载外置字幕
    return [];
  }
}

export class AvSubtitleBridgeAdapter extends BaseSubtitleBridgeAdapter {
  protected async loadInternalTracks(): Promise<SubtitleTrackItem[]> {
    const items: SubtitleTrackItem[] = [];
    if (!this.player) {
      return items;
    }

    const allTracks = await this.player.getTrackInfos();
    const subtitleTracks: TrackInfo[] = allTracks.filter((t: TrackInfo) => t.trackType === 'subtitle');
    this.subtitleTracks = subtitleTracks;
    for (let i = 0; i < subtitleTracks.length; i++) {
      const track = subtitleTracks[i];
      const displayName = track.language && track.language.length > 0
        ? `字幕 ${i + 1} (${track.language})`
        : `字幕 ${i + 1}`;
      const item: SubtitleTrackItem = {
        kind: 'internal',
        displayName,
        internalIndex: track.trackIndex
      };
      items.push(item);
    }
    return items;
  }
}

export class NoSubtitleBridgeAdapter implements ISubtitleBridgeAdapter {
  private state: SubtitleBridgeState = {
    subtitleTracks: [],
    allSubtitleTracks: [],
    activeSubtitleIndex: -1,
    currentSubtitleTrack: -1,
    currentSubtitleText: '',
    subtitleDelayMs: 0,
    hasExternalActive: false
  };

  async init(_player: IPlayer, _videoData?: VideoData): Promise<void> {
    return Promise.resolve();
  }

  onTimeUpdate(_currentTimeMs: number): void {}

  onSubtitleUpdate(_info: SubtitleInfo): void {}

  async switchTrack(_allIndex: number): Promise<void> {
    return Promise.resolve();
  }

  adjustDelay(_deltaMs: number): void {}

  onSeekSync(): void {}

  getState(): SubtitleBridgeState {
    return this.state;
  }

  release(): void {}
}
