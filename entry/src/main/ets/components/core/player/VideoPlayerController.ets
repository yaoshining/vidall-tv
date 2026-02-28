import { PlayerEvents, VideoDataType } from "./Constants";
import { VideoData } from "./VideoData";
import { BusinessError, emitter } from "@kit.BasicServicesKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { CommonConstants } from "../../../common/constants/CommonConstants";
import { millisecondsToTime } from "../../../utils/TimeUtil";
import { SrtEntry, SrtParser, AssFileParser } from "./SubtitleRenderer";
import { http } from "@kit.NetworkKit";
import { IPlayer, TrackInfo } from "./IPlayer";
import { AVPlayerAdapter } from "./AVPlayerAdapter";
import { AnalyticsManager } from '../../../analytics/AnalyticsManager';
import { EventType, SubtitleFormatType } from '../../../analytics/AnalyticsTypes';

const TAG = '[VideoPlayerController]';

// ─────────────────────────────────────────────
// 统一字幕轨道描述
// ─────────────────────────────────────────────

/**
 * 统一字幕轨道条目，用于字幕菜单显示和切换
 * kind='internal'：AVPlayer 内嵌轨道（API 19 实际无回调，保留结构）
 * kind='external'：外部 SRT 文件（本实现的主要方式）
 */
export interface SubtitleTrackItem {
  kind: 'internal' | 'external';
  /** 显示名称，如 "英语"、"简体中文 [外部]" */
  displayName: string;
  /** kind='internal' 时：subtitleTracks 数组里的 index */
  internalIndex?: number;
  /** kind='external' 时：已解析的 SRT 条目 */
  srtEntries?: SrtEntry[];
  /** kind='external' 时：字幕文件 URL */
  url?: string;
}

@ObservedV2
export class VideoPlayerController {
  /** 当前使用的播放内核，默认为 AVPlayerAdapter */
  private player?: IPlayer;
  private analyticsManager: AnalyticsManager = AnalyticsManager.getInstance();
  @Trace name: ResourceStr = ''
  @Trace surfaceId: string = ''
  @Trace duration = 0
  @Trace isPlaying = false
  @Trace isReady = false
  @Trace isSeeking = false
  @Trace currentTime = 0
  @Trace currentBufferTime = 0
  @Trace isLoading = false
  @Trace progress = 0
  /** 内嵌字幕轨道列表（来自 getTrackInfos） */
  @Trace subtitleTracks: TrackInfo[] = []
  @Trace currentSubtitleTrack: number = -1
  @Trace currentSubtitleText: string = ''
  @Trace subtitleUpdateCounter: number = 0
  @Trace allSubtitleTracks: SubtitleTrackItem[] = [];
  @Trace activeSubtitleIndex: number = -1;
  private srtEntries: SrtEntry[] = [];
  private lastSrtText: string = '';
  private currentVideoData?: VideoData;
  private timeToSeek = -1
  private subtitleClearTimer?: number
  private subtitleRemainingTime: number = 0
  private subtitlePauseTime: number = 0

  /**
   * 初始化播放器，默认使用 AVPlayerAdapter。
   * 未来切换内核时，只需传入不同的 IPlayer 实现即可。
   */
  async initPlayer(videoData: VideoData, surfaceId: string): Promise<void> {
    this.name = videoData.name || ''
    this.currentVideoData = videoData;
    this.surfaceId = surfaceId;

    // 释放旧 player
    if (this.player) {
      await this.player.release().catch(() => {});
      this.player = undefined;
    }

    // 重置状态
    this.isReady = false;
    this.isPlaying = false;
    this.duration = 0;
    this.currentTime = 0;
    this.progress = 0;
    this.srtEntries = [];
    this.lastSrtText = '';
    this.currentSubtitleText = '';
    this.subtitleUpdateCounter = 0;
    this.allSubtitleTracks = [];
    this.activeSubtitleIndex = -1;

    // 创建 AVPlayerAdapter（后续可换成其他 IPlayer 实现）
    const adapter = new AVPlayerAdapter();

    // 注册所有 IPlayer 事件回调
    adapter.onReady(() => this.onPlayerReady());
    adapter.onPlay(() => {
      this.isPlaying = true;
      this.isLoading = false;
      this.resumeSubtitleTimer();
      emitter.emit(PlayerEvents.PLAYING);
    });
    adapter.onPaused(() => {
      this.isPlaying = false;
      this.pauseSubtitleTimer();
    });
    adapter.onCompleted(() => {
      this.isPlaying = false;
    });
    adapter.onStopped(() => {
      this.isPlaying = false;
    });
    adapter.onTimeUpdate((currentTime: number) => {
      this.currentTime = currentTime;
      this.progress = this.duration > 0 ? currentTime / this.duration : 0;
      // SRT 时间轴驱动字幕
      if (this.srtEntries.length > 0) {
        const text = SrtParser.findAt(this.srtEntries, currentTime);
        if (text !== this.lastSrtText) {
          this.lastSrtText = text;
          this.currentSubtitleText = text;
          this.subtitleUpdateCounter++;
        }
      }
    });
    adapter.onError((error: Error) => {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `播放器错误: ${error.message}`);
      this.isLoading = false;
    });
    adapter.onSeekDone(() => {
      if (this.timeToSeek >= 0) {
        adapter.seek(this.timeToSeek);
        this.timeToSeek = -1;
      } else {
        this.player?.play().catch(() => {});
      }
      this.isSeeking = false;
    });
    adapter.onSubtitleUpdate((info) => {
      // 外部字幕激活时屏蔽内嵌回调
      if (this.srtEntries.length > 0) {
        return;
      }
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `内嵌字幕回调: text="${info.text?.substring(0, 80)}" duration=${info.duration}ms`);
      if (this.subtitleClearTimer) {
        clearTimeout(this.subtitleClearTimer);
        this.subtitleClearTimer = undefined;
      }
      if (info.text) {
        this.currentSubtitleText = info.text;
        const displayDuration = (info.duration && info.duration > 0) ? info.duration : 3000;
        this.subtitleRemainingTime = displayDuration;
        if (this.isPlaying) { this.startSubtitleTimer(); }
      } else {
        this.currentSubtitleText = '';
        this.subtitleRemainingTime = 0;
      }
      this.subtitleUpdateCounter++;
    });

    this.player = adapter;

    try {
      await adapter.init(videoData, surfaceId);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `init 失败: code=${err.code} msg=${err.message}`);
    }
  }

  /** prepared 后回调：读取 duration、加载字幕轨道 */
  private async onPlayerReady(): Promise<void> {
    this.duration = this.player?.duration ?? 0;
    this.currentTime = this.player?.currentTime ?? 0;
    this.isReady = true;
    emitter.emit(PlayerEvents.PREPARED);
    await this.loadSubtitleTracks();
  }

  async play(): Promise<void> {
    await this.player?.play().catch((err: BusinessError) => {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `play 失败: code=${err.code} msg=${err.message}`);
    });
  }

  async pause(): Promise<void> {
    await this.player?.pause().catch((err: BusinessError) => {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `pause 失败: code=${err.code} msg=${err.message}`);
    });
  }

  async toggle(): Promise<void> {
    await this.player?.toggle();
  }

  async release(): Promise<void> {
    if (this.subtitleClearTimer) {
      clearTimeout(this.subtitleClearTimer);
      this.subtitleClearTimer = undefined;
    }
    this.srtEntries = [];
    this.lastSrtText = '';
    this.currentSubtitleText = '';
    if (this.player) {
      await this.player.release().catch(() => {});
      this.player = undefined;
    }
  }

  async seek(time: number): Promise<void> {
    if (!this.player) { return; }
    await this.pause();
    this.currentTime = time;
    if (!this.isSeeking) {
      this.isSeeking = true;
      this.player.seek(time);
    } else {
      this.timeToSeek = time;
    }
  }

  async forward(milliseconds: number): Promise<void> {
    this.seek(this.currentTime + milliseconds);
  }

  async backward(milliseconds: number): Promise<void> {
    this.seek(this.currentTime - milliseconds);
  }

  // ─── 字幕定时器 ───

  /**
   * 启动字幕清空定时器
   */
  private startSubtitleTimer(): void {
    if (this.subtitleRemainingTime <= 0) {
      return
    }

    this.subtitlePauseTime = Date.now()
    console.log(`[VideoPlayerController] Starting subtitle timer: ${this.subtitleRemainingTime}ms`)

    this.subtitleClearTimer = setTimeout(() => {
      console.log(`[VideoPlayerController] Clearing subtitle`)
      this.currentSubtitleText = ''
      this.subtitleUpdateCounter++
      this.subtitleClearTimer = undefined
      this.subtitleRemainingTime = 0
    }, this.subtitleRemainingTime)
  }

  /**
   * 暂停字幕清空定时器
   */
  private pauseSubtitleTimer(): void {
    if (this.subtitleClearTimer) {
      clearTimeout(this.subtitleClearTimer)
      this.subtitleClearTimer = undefined

      // 计算剩余时间
      const elapsed = Date.now() - this.subtitlePauseTime
      this.subtitleRemainingTime = Math.max(0, this.subtitleRemainingTime - elapsed)
      console.log(`[VideoPlayerController] Subtitle timer paused, remaining: ${this.subtitleRemainingTime}ms`)
    }
  }

  /**
   * 恢复字幕清空定时器
   */
  private resumeSubtitleTimer(): void {
    if (this.subtitleRemainingTime > 0 && this.currentSubtitleText.length > 0) {
      console.log(`[VideoPlayerController] Resuming subtitle timer: ${this.subtitleRemainingTime}ms`)
      this.startSubtitleTimer()
    }
  }

  @Computed
  get durationDisplay(): string {
    return millisecondsToTime(this.duration)
  }

  @Computed
  get currentTimeDisplay(): string {
    return millisecondsToTime(this.currentTime)
  }

  /** 是否正在使用外部 SRT 字幕（用于 UI 判断是否需要 ASS 逗号提取） */
  get hasSrtSubtitle(): boolean {
    return this.srtEntries.length > 0;
  }

  private async loadSubtitleTracks(): Promise<void> {
    if (!this.player) { return; }

    try {
      const allTracks = await this.player.getTrackInfos();
      this.subtitleTracks = allTracks.filter((t: TrackInfo) => t.trackType === 'subtitle');
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `内嵌字幕轨道数: ${this.subtitleTracks.length}`);
      this.subtitleTracks.forEach((t: TrackInfo, i: number) => {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `内嵌字幕[${i}]: trackIndex=${t.trackIndex} mime=${t.mimeType} lang=${t.language}`);
      });
    } catch (e) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `getTrackInfos 失败: ${JSON.stringify(e)}`);
    }

    // 构建内嵌轨道条目
    const tracks: SubtitleTrackItem[] = [];
    for (let i = 0; i < this.subtitleTracks.length; i++) {
      const t = this.subtitleTracks[i];
      const item: SubtitleTrackItem = {
        kind: 'internal',
        displayName: this.getSubtitleTrackName(i),
        internalIndex: t.trackIndex
      };
      tracks.push(item);
    }
    this.allSubtitleTracks = tracks;

    // 探测外部字幕
    if (this.currentVideoData && this.currentVideoData.type === VideoDataType.URL) {
      const externalItems = await this.findExternalSubtitles(
        this.currentVideoData.videoSrc,
        this.currentVideoData.httpHeader
      );
      if (externalItems.length > 0) {
        const updated: SubtitleTrackItem[] = [];
        for (const t of this.allSubtitleTracks) { updated.push(t); }
        for (const ext of externalItems) { updated.push(ext); }
        this.allSubtitleTracks = updated;
        const firstExtIdx = updated.findIndex((t: SubtitleTrackItem) => t.kind === 'external');
        if (firstExtIdx >= 0) {
          await this.switchSubtitleTrack(firstExtIdx);
          return;
        }
      }
    }

    if (this.allSubtitleTracks.length > 0) {
      await this.switchSubtitleTrack(0);
    }
  }

  async selectSubtitleTrack(trackIndex: number): Promise<void> {
    if (!this.player) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, 'player not initialized');
      return;
    }
    try {
      await this.player.selectTrack(trackIndex);
      this.currentSubtitleTrack = trackIndex;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        trackIndex < 0 ? '字幕已关闭' : `内嵌字幕轨道 ${trackIndex} 已激活`);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `selectSubtitleTrack 失败: code=${err.code} msg=${err.message}`);
    }
  }

  getSubtitleTrackName(trackIndex: number): string {
    if (trackIndex === -1) {
      return '关闭字幕';
    }
    if (trackIndex >= 0 && trackIndex < this.subtitleTracks.length) {
      const track = this.subtitleTracks[trackIndex];
      if (track.language) {
        return this.getLanguageName(track.language);
      }
      if (track.mimeType) {
        const format = track.mimeType.split('/').pop() ?? '';
        return `字幕 ${trackIndex + 1} (${format})`;
      }
      return `字幕 ${trackIndex + 1}`;
    }
    return '字幕';
  }

  /**
   * 将语言代码转换为友好的显示名称
   */
  private getLanguageName(languageCode: string): string {
    const languageMap: Record<string, string> = {
      // ISO 639-1
      'zh': '中文', 'zh-CN': '简体中文', 'zh-TW': '繁体中文', 'zh-HK': '繁体中文(香港)',
      'en': '英语', 'en-US': '英语(美国)', 'en-GB': '英语(英国)',
      'ja': '日语', 'ko': '韩语', 'fr': '法语', 'de': '德语',
      'es': '西班牙语', 'ru': '俄语', 'it': '意大利语', 'pt': '葡萄牙语',
      'ar': '阿拉伯语', 'th': '泰语', 'vi': '越南语',
      // ISO 639-2（字幕文件常用）
      'chi': '中文', 'zho': '中文',
      'chs': '简体中文', 'cht': '繁体中文',
      'eng': '英语', 'jpn': '日语', 'kor': '韩语',
      'fra': '法语', 'fre': '法语', 'deu': '德语', 'ger': '德语',
      'spa': '西班牙语', 'rus': '俄语', 'ita': '意大利语',
      'por': '葡萄牙语', 'ara': '阿拉伯语', 'tha': '泰语', 'vie': '越南语',
      'und': '未定义'
    };
    return languageMap[languageCode] || languageCode || '字幕';
  }

  // ─────────────────────────────────────────────
  // 统一字幕切换（供 UI 调用）
  // ─────────────────────────────────────────────

  /**
   * 通过 allSubtitleTracks 索引切换字幕
   * allIndex = -1 表示关闭字幕
   */
  async switchSubtitleTrack(allIndex: number): Promise<void> {
    const fromIndex = this.activeSubtitleIndex;
    this.activeSubtitleIndex = allIndex;
    this.currentSubtitleText = '';
    this.subtitleUpdateCounter++;

    // 记录字幕切换埋点
    const mediaId = this.currentVideoData?.videoSrc || '';
    let subtitleFormat: SubtitleFormatType = SubtitleFormatType.UNKNOWN;

    if (allIndex < 0) {
      // 关闭字幕：清空 SRT，关闭内嵌
      this.srtEntries = [];
      this.lastSrtText = '';
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '关闭字幕，将调用 selectSubtitleTrack(-1)');

      this.analyticsManager.track({
        eventType: EventType.SUBTITLE_SWITCH,
        mediaId: mediaId,
        fromTrackIndex: fromIndex,
        toTrackIndex: -1,
        subtitleFormat: SubtitleFormatType.UNKNOWN
      });

      await this.selectSubtitleTrack(-1);
      return;
    }

    if (allIndex >= this.allSubtitleTracks.length) {
      return;
    }

    const item = this.allSubtitleTracks[allIndex];

    if (item.kind === 'external') {
      // 切换到外部 SRT/ASS
      const entries = item.srtEntries ?? [];
      this.srtEntries = entries;
      this.lastSrtText = '';
      this.currentSubtitleTrack = -1;

      // 判断外部字幕格式
      if (item.url) {
        const urlLower = item.url.toLowerCase();
        if (urlLower.endsWith('.srt')) {
          subtitleFormat = SubtitleFormatType.SRT;
        } else if (urlLower.endsWith('.ass') || urlLower.endsWith('.ssa')) {
          subtitleFormat = SubtitleFormatType.ASS;
        } else if (urlLower.endsWith('.vtt')) {
          subtitleFormat = SubtitleFormatType.VTT;
        }
      }

      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `切换到外部字幕: ${item.displayName}，共 ${entries.length} 条，url=${item.url ?? ''}`);
      if (entries.length === 0) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `⚠️ 外部字幕条目为空，字幕将不显示。请检查文件下载和解析日志。`);
      }
    } else {
      // 切换到内嵌字幕：清空外部字幕，调用 selectSubtitleTrack 激活 AVPlayer 内嵌轨道
      this.srtEntries = [];
      this.lastSrtText = '';
      const internalIdx = item.internalIndex ?? 0;
      subtitleFormat = SubtitleFormatType.EMBEDDED;

      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `切换到内嵌字幕轨道 ${internalIdx}，将调用 selectSubtitleTrack 激活`);
      // 调用旧方法激活内嵌轨道（会触发 AVPlayer 的 selectTrack）
      await this.selectSubtitleTrack(internalIdx);
    }

    // 记录字幕切换埋点
    this.analyticsManager.track({
      eventType: EventType.SUBTITLE_SWITCH,
      mediaId: mediaId,
      fromTrackIndex: fromIndex,
      toTrackIndex: allIndex,
      subtitleFormat: subtitleFormat
    });
  }

  // ─────────────────────────────────────────────
  // 外部字幕自动探测
  // ─────────────────────────────────────────────

  /**
   * 根据视频 URL 自动探测同名字幕文件
   *
   * 候选文件名规则（视频名为 movie.mkv）：
   *   movie.srt / movie.ass / movie.ssa / movie.vtt
   *   movie.chi.srt / movie.chs.srt / movie.cht.srt / movie.eng.srt ...
   *   movie.zh.srt / movie.zh-CN.srt / movie.en.srt ...
   *
   * 每个候选发 HEAD 请求，200/206 视为存在，然后 GET 下载解析。
   */
  private async findExternalSubtitles(
    videoUrl: string,
    headers?: Record<string, string>
  ): Promise<SubtitleTrackItem[]> {
    // 提取视频文件名（不含扩展名）和目录 URL
    const lastSlash = videoUrl.lastIndexOf('/');
    const dirUrl = lastSlash >= 0 ? videoUrl.substring(0, lastSlash + 1) : videoUrl + '/';
    const fileName = lastSlash >= 0 ? videoUrl.substring(lastSlash + 1) : videoUrl;
    // 去掉查询参数
    const cleanFileName = fileName.split('?')[0];
    const dotIdx = cleanFileName.lastIndexOf('.');
    const baseName = dotIdx >= 0 ? cleanFileName.substring(0, dotIdx) : cleanFileName;

    // 字幕扩展名
    const subtitleExts: string[] = ['srt', 'ass', 'ssa', 'vtt'];
    // 常见语言标签（用于 movie.lang.srt 格式）
    const langTags: string[] = [
      'chi', 'chs', 'cht', 'zho',
      'eng',
      'jpn', 'kor', 'fra', 'deu', 'spa', 'rus',
      'zh', 'zh-CN', 'zh-TW', 'en', 'ja', 'ko'
    ];

    // 构建候选列表（先无语言标签，再带语言标签）
    const candidates: string[] = [];
    for (const ext of subtitleExts) {
      candidates.push(`${baseName}.${ext}`);
    }
    for (const lang of langTags) {
      for (const ext of subtitleExts) {
        candidates.push(`${baseName}.${lang}.${ext}`);
      }
    }

    const reqHeaders: Record<string, string> = { 'User-Agent': 'VidALL/1.0.0' };
    if (headers) {
      const keys = Object.keys(headers);
      for (const k of keys) {
        reqHeaders[k] = headers[k];
      }
    }

    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `开始探测外部字幕，基础名: ${baseName}，候选数: ${candidates.length}`);

    const found: SubtitleTrackItem[] = [];

    for (const candidate of candidates) {
      const url = dirUrl + encodeURIComponent(candidate);
      const exists = await this.probeUrl(url, reqHeaders);
      if (!exists) {
        continue;
      }
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, `发现外部字幕: ${candidate}`);
      // 判断字幕格式
      const lowerCand = candidate.toLowerCase();
      const isSrt = lowerCand.endsWith('.srt');
      const isAss = lowerCand.endsWith('.ass') || lowerCand.endsWith('.ssa');
      const isVtt = lowerCand.endsWith('.vtt');

      if (!isSrt && !isAss && !isVtt) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG, `暂不支持的字幕格式，跳过: ${candidate}`);
        continue;
      }

      // 下载并解析
      try {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG, `开始下载字幕: ${url}`);
        let entries: SrtEntry[] = [];
        if (isSrt || isVtt) {
          entries = await this.fetchSrt(url, reqHeaders);
        } else {
          // .ass / .ssa
          entries = await this.fetchAss(url, reqHeaders);
        }

        const langLabel = this.extractLangLabel(candidate, baseName);
        const formatLabel = isAss ? 'ASS' : (isVtt ? 'VTT' : 'SRT');
        const displayName = langLabel.length > 0
          ? `${langLabel} [外部·${formatLabel}]`
          : `字幕 [外部·${formatLabel}]`;
        const item: SubtitleTrackItem = {
          kind: 'external',
          displayName,
          url,
          srtEntries: entries
        };
        found.push(item);
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `外部字幕解析完成: ${displayName}，共 ${entries.length} 条`);
      } catch (e) {
        const err = e as BusinessError;
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `外部字幕下载/解析失败: ${candidate} — code=${err.code} msg=${err.message}`);
      }
    }

    hilog.info(CommonConstants.LOG_DOMAIN, TAG, `外部字幕探测完毕，找到 ${found.length} 个`);
    return found;
  }

  /** HEAD 请求探测 URL 是否存在，200/206/301/302 视为存在 */
  private probeUrl(url: string, headers: Record<string, string>): Promise<boolean> {
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

  /** GET 下载并解析 SRT/VTT 文件 */
  private fetchSrt(url: string, headers: Record<string, string>): Promise<SrtEntry[]> {
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
          hilog.error(CommonConstants.LOG_DOMAIN, TAG,
            `SRT 下载失败: code=${err.code} msg=${err.message} url=${url}`);
          reject(err);
          return;
        }
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `SRT HTTP 响应: ${resp.responseCode}, resultType=${typeof resp.result}`);
        if (resp.responseCode !== 200) {
          reject(new Error(`HTTP ${resp.responseCode}`) as BusinessError);
          return;
        }
        const body = resp.result as string;
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `SRT 下载完成，内容大小: ${body.length} 字节，前50字符: ${body.substring(0, 50)}`);
        if (body.length === 0) {
          hilog.warn(CommonConstants.LOG_DOMAIN, TAG, 'SRT 文件内容为空');
          resolve([]);
          return;
        }
        const entries = SrtParser.parse(body);
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `SRT 解析完成，共 ${entries.length} 条`);
        if (entries.length > 0) {
          const e0 = entries[0];
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `SRT 第1条: ${e0.startMs}ms→${e0.endMs}ms: ${e0.text.substring(0, 40)}`);
        }
        resolve(entries);
      });
    });
  }

  /** GET 下载并解析 ASS/SSA 文件 */
  private fetchAss(url: string, headers: Record<string, string>): Promise<SrtEntry[]> {
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
          hilog.error(CommonConstants.LOG_DOMAIN, TAG,
            `ASS 下载失败: code=${err.code} msg=${err.message} url=${url}`);
          reject(err);
          return;
        }
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `ASS HTTP 响应: ${resp.responseCode}, resultType=${typeof resp.result}`);
        if (resp.responseCode !== 200) {
          hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
            `ASS 下载 HTTP 状态异常: ${resp.responseCode}`);
          reject(new Error(`HTTP ${resp.responseCode}`) as BusinessError);
          return;
        }
        const body = resp.result as string;
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `ASS 下载完成，内容大小: ${body.length} 字节，前50字符: ${body.substring(0, 50)}`);
        if (body.length === 0) {
          hilog.warn(CommonConstants.LOG_DOMAIN, TAG, 'ASS 文件内容为空');
          resolve([]);
          return;
        }
        const entries = AssFileParser.parse(body);
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `ASS 解析完成，共 ${entries.length} 条`);
        if (entries.length > 0) {
          const e0 = entries[0];
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `ASS 第1条: ${e0.startMs}ms→${e0.endMs}ms: ${e0.text.substring(0, 40)}`);
        }
        resolve(entries);
      });
    });
  }

  /**
   * 从候选文件名中提取语言标签，用于显示名
   * movie.chi.srt → "chi"  →  getLanguageName("chi")
   * movie.srt     → ""
   */
  private extractLangLabel(candidate: string, baseName: string): string {
    // 去扩展名
    const dotIdx = candidate.lastIndexOf('.');
    const withoutExt = dotIdx >= 0 ? candidate.substring(0, dotIdx) : candidate;
    // 如果和 baseName 一样，说明没有语言标签
    if (withoutExt === baseName) {
      return '';
    }
    // 去掉 baseName. 前缀，剩下的就是语言标签
    const prefix = baseName + '.';
    if (withoutExt.startsWith(prefix)) {
      const lang = withoutExt.substring(prefix.length);
      return this.getLanguageName(lang);
    }
    return withoutExt;
  }
}

