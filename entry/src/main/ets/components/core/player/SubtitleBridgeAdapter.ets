import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CommonConstants } from '../../../common/constants/CommonConstants';
import { VideoData } from './VideoData';
import { VideoDataType } from './Constants';
import { IPlayer, SubtitleInfo, TrackInfo } from './IPlayer';
import { AssFileParser, SrtEntry, SrtParser } from './SubtitleRenderer';

const TAG = '[SubtitleBridgeAdapter]';

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
    const dotIdx = cleanFileName.lastIndexOf('.');
    const baseName = dotIdx >= 0 ? cleanFileName.substring(0, dotIdx) : cleanFileName;

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
        expectDataType: http.HttpDataType.STRING
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
        const body = resp.result as string;
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
        expectDataType: http.HttpDataType.STRING
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
        const body = resp.result as string;
        resolve(AssFileParser.parse(body));
      });
    });
  }
}

export class IjkSubtitleBridgeAdapter extends BaseSubtitleBridgeAdapter {
  protected async loadInternalTracks(): Promise<SubtitleTrackItem[]> {
    const items: SubtitleTrackItem[] = [];
    if (!this.videoData || !this.videoData.presetSubtitleTracks) {
      return items;
    }

    const presets = this.videoData.presetSubtitleTracks;
    for (let i = 0; i < presets.length; i++) {
      const p = presets[i];
      const item: SubtitleTrackItem = {
        kind: 'internal',
        displayName: p.displayName,
        internalIndex: p.trackIndex
      };
      items.push(item);
    }
    return items;
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
