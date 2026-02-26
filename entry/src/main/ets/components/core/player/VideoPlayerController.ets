import { media } from "@kit.MediaKit";
import fs from "@ohos.file.fs";
import { AVPlayerState, PlayerEvents, VideoDataType } from "./Constants";
import { VideoData } from "./VideoData";
import { BusinessError, emitter } from "@kit.BasicServicesKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { CommonConstants } from "../../../common/constants/CommonConstants";
import { millisecondsToTime } from "../../../utils/TimeUtil";
import { SrtEntry, SrtParser, AssFileParser } from "./SubtitleRenderer";
import { http } from "@kit.NetworkKit";

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
  private avPlayer?: media.AVPlayer
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
  @Trace subtitleTracks: media.MediaDescription[] = []
  @Trace currentSubtitleTrack: number = -1
  @Trace currentSubtitleText: string = ''
  @Trace subtitleUpdateCounter: number = 0
  /** 统一字幕轨道列表（内嵌 + 外部，供菜单展示） */
  @Trace allSubtitleTracks: SubtitleTrackItem[] = [];
  /** 当前激活的字幕轨道在 allSubtitleTracks 中的索引，-1 表示关闭 */
  @Trace activeSubtitleIndex: number = -1;
  /** 解析后的外部 SRT 字幕条目（时间轴驱动） */
  private srtEntries: SrtEntry[] = [];
  /** 当前通过 timeUpdate 显示的字幕文本（避免每帧重复赋值） */
  private lastSrtText: string = '';
  /** 当前播放的 VideoData（供 prepared 后自动查找字幕使用） */
  private currentVideoData?: VideoData;
  private timeToSeek = -1
  private subtitleClearTimer?: number  // 字幕清空定时器
  private subtitleRemainingTime: number = 0  // 字幕剩余显示时间（毫秒）
  private subtitlePauseTime: number = 0  // 字幕暂停时的时间戳

  async initAVPlayer(videoData: VideoData, surfaceId: string, player?: media.AVPlayer): Promise<void> {
    this.name = videoData.name || ''
    this.currentVideoData = videoData;
    try {
      let avPlayer = player || await media.createAVPlayer()
      this.avPlayer = avPlayer
      this.surfaceId = surfaceId

      avPlayer.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT

      this.setAVPlayerCallbacks(avPlayer)

      if (videoData.type === VideoDataType.URL) {
        // avPlayer.url = videoData.videoSrc

        // {
        //   'Authorization': 'Basic eWFvOnlzMTk4NzU2',
        // // 'Authorization': 'Basic Y2RrZDpkYXJ0dmpoeA==',
        // "User-Agent": "VidALL/1.0.0",
        // }

        // 设置播放策略，设置缓冲区数据量为3s。
        let playbackStrategy : media.PlaybackStrategy =
          {preferredWidth: 1, preferredHeight: 2, preferredBufferDuration: 3, preferredHdr: true};
        const mediaSource =
          media.createMediaSourceWithUrl(videoData.videoSrc, videoData.httpHeader)
        avPlayer.setMediaSource(mediaSource, playbackStrategy)
      }

      if (videoData.type === VideoDataType.FILE_URI) {
        let file = fs.openSync(videoData.videoSrc, fs.OpenMode.READ_ONLY)
        avPlayer.fdSrc = {
          fd: file.fd
        }
      }

      this.setAVPlayerStateChangeCallback(avPlayer)

      // 重置字幕状态
      this.srtEntries = [];
      this.lastSrtText = '';
      this.currentSubtitleText = '';
      this.subtitleUpdateCounter = 0;
      this.allSubtitleTracks = [];
      this.activeSubtitleIndex = -1;

      // 如果提供了外部 SRT 字幕 URL，异步下载并解析
      if (videoData.subtitleUrl) {
        this.loadExternalSrt(videoData.subtitleUrl, videoData.subtitleHeaders)
          .catch((e: BusinessError) => {
            hilog.warn(CommonConstants.LOG_DOMAIN, TAG, `外部字幕加载失败: ${e.message}`);
          });
      }
    } catch (error) {
      if (error) {
        console.error(`Video Player creation error: ${error}`)
        return
      }
    }
  }

  async play(): Promise<void> {
    // if (this.isSeeking) {
    //   return
    // }
    await this.avPlayer?.play().catch((err: BusinessError) => {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `play failed, code is ${err.code}, message is ${err.message}`);
    })
  }

  async pause(): Promise<void> {
    if (this.avPlayer?.state === AVPlayerState.PLAYING) {
      await this.avPlayer?.pause().catch((err: BusinessError) => {
        hilog.error(CommonConstants.LOG_DOMAIN, TAG,
          `play failed, code is ${err.code}, message is ${err.message}`);
      })
    }
  }

  async toggle(): Promise<void> {
    if (this.avPlayer) {
      if (this.avPlayer.state === AVPlayerState.PLAYING) {
        await this.pause()
      } else {
        await this.play()
      }
    }
  }

  async release(): Promise<void> {
    if (this.avPlayer) {
      try {
        if (this.subtitleClearTimer) {
          clearTimeout(this.subtitleClearTimer)
          this.subtitleClearTimer = undefined
        }
        // 清理 SRT 状态
        this.srtEntries = [];
        this.lastSrtText = '';
        this.currentSubtitleText = '';
        await this.avPlayer.release()
      } catch (error) {
        // TODO: Implement error handling.
      }
    }
  }

  async seek(time: number): Promise<void> {
    if (this.avPlayer) {
      await this.pause()
      this.currentTime = time
      if (!this.isSeeking) {
        this.isSeeking = true
        this.avPlayer.seek(time)
      } else {
        this.timeToSeek = time
      }
    }
  }

  async forward(milliseconds: number): Promise<void> {
    this.seek(this.currentTime + milliseconds)
  }

  async backward(milliseconds: number): Promise<void> {
    this.seek(this.currentTime - milliseconds)
  }

  private setAVPlayerStateChangeCallback(avPlayer: media.AVPlayer): void {
    avPlayer.on('stateChange', (state: string) => {
      switch (state) {
        case AVPlayerState.IDLE:
          break
        case AVPlayerState.INITIALIZED:
          avPlayer.surfaceId = this.surfaceId
          avPlayer.prepare().catch((err: BusinessError) => {
            hilog.error(CommonConstants.LOG_DOMAIN, TAG,
              `prepare failed, code is ${err.code}, message is ${err.message}`);
          })
          break
        case AVPlayerState.PREPARED:
          this.duration = avPlayer.duration
          this.currentTime = avPlayer.currentTime
          this.isReady = true
          this.loadSubtitleTracks(avPlayer)
          emitter.emit(PlayerEvents.PREPARED)
          break
        case AVPlayerState.PLAYING:
          this.isPlaying = true
          // 恢复字幕定时器
          this.resumeSubtitleTimer()
          emitter.emit(PlayerEvents.PLAYING)
          break
        case AVPlayerState.PAUSED:
          this.isPlaying = false
          // 暂停字幕定时器
          this.pauseSubtitleTimer()
          break
        case AVPlayerState.COMPLETED:
          this.isPlaying = false
          break
        case AVPlayerState.STOPPED:
          this.isPlaying = false
          break
        case AVPlayerState.ERROR:
          this.isPlaying = false
          break
        default:
          break
      }
    })
  }

  private setAVPlayerCallbacks(avPlayer: media.AVPlayer): void {
    avPlayer.on("timeUpdate", () => {
      this.currentTime = avPlayer.currentTime
      this.progress = this.currentTime / this.duration

      // SRT 时间轴驱动字幕
      if (this.srtEntries.length > 0) {
        const text = SrtParser.findAt(this.srtEntries, this.currentTime);
        if (text !== this.lastSrtText) {
          this.lastSrtText = text;
          this.currentSubtitleText = text;
          this.subtitleUpdateCounter++;
        }
      }
    })

    avPlayer.on('error', (error: Error) => {
      console.error('AVPlayer error:', JSON.stringify(error));
      this.isLoading = false;
    });

    avPlayer.on('seekDone', async () => {
      console.log(`time to seek is: ` + this.timeToSeek);
      if (!this.isSeeking) {
        avPlayer.seek(this.timeToSeek)
        this.timeToSeek = -1
      } else {
        await avPlayer.play()
      }

      this.isSeeking = false
    })

    try {
      avPlayer.on('subtitleUpdate', (info: media.SubtitleInfo) => {
        // 若已激活外部字幕（SRT/ASS 时间轴驱动），忽略内嵌字幕回调，避免覆盖
        if (this.srtEntries.length > 0) {
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `内嵌字幕回调被屏蔽（外部字幕已激活），text="${info.text?.substring(0, 50)}"`);
          return;
        }

        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `内嵌字幕回调: text="${info.text?.substring(0, 80)}" startTime=${info.startTime}ms duration=${info.duration}ms`);

        if (this.subtitleClearTimer) {
          clearTimeout(this.subtitleClearTimer)
          this.subtitleClearTimer = undefined
        }

        if (info && info.text) {
          this.currentSubtitleText = info.text

          let displayDuration = 0
          if (info.duration !== undefined && info.duration > 0) {
            displayDuration = info.duration
          } else {
            displayDuration = 3000
          }

          this.subtitleRemainingTime = displayDuration

          if (this.isPlaying) {
            this.startSubtitleTimer()
          }
        } else {
          this.currentSubtitleText = ''
          this.subtitleRemainingTime = 0
        }

        this.subtitleUpdateCounter++
      })
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '内嵌字幕监听已注册');
    } catch (error) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `注册内嵌字幕监听失败: ${JSON.stringify(error)}`);
    }
  }

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

  /**
   * 加载字幕轨道列表
   */
  private async loadSubtitleTracks(avPlayer: media.AVPlayer): Promise<void> {
    try {
      const trackDescription = await avPlayer.getTrackDescription();
      if (trackDescription && trackDescription.length > 0) {
        this.subtitleTracks = trackDescription.filter((track: media.MediaDescription) => {
          return track[media.MediaDescriptionKey.MD_KEY_TRACK_TYPE] === media.MediaType.MEDIA_TYPE_SUBTITLE;
        });
        hilog.info(CommonConstants.LOG_DOMAIN, TAG, `内嵌字幕轨道数: ${this.subtitleTracks.length}`);
        this.subtitleTracks.forEach((track: media.MediaDescription, index: number) => {
          hilog.info(CommonConstants.LOG_DOMAIN, TAG, `内嵌字幕[${index}]: ${JSON.stringify(track)}`);
        });
      }
    } catch (error) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `getTrackDescription 失败: ${JSON.stringify(error)}`);
    }

    // 构建内嵌轨道列表
    const tracks: SubtitleTrackItem[] = [];
    for (let i = 0; i < this.subtitleTracks.length; i++) {
      const item: SubtitleTrackItem = {
        kind: 'internal',
        displayName: this.getSubtitleTrackName(i),
        internalIndex: i
      };
      tracks.push(item);
    }
    this.allSubtitleTracks = tracks;

    // 查找外部字幕（异步，完成后追加到列表）
    if (this.currentVideoData && this.currentVideoData.type === VideoDataType.URL) {
      const externalItems = await this.findExternalSubtitles(
        this.currentVideoData.videoSrc,
        this.currentVideoData.httpHeader
      );
      if (externalItems.length > 0) {
        const updated: SubtitleTrackItem[] = [];
        for (const t of this.allSubtitleTracks) {
          updated.push(t);
        }
        for (const ext of externalItems) {
          updated.push(ext);
        }
        this.allSubtitleTracks = updated;
        // 默认激活第一个外部字幕
        const firstExtIdx = updated.findIndex((t: SubtitleTrackItem) => t.kind === 'external');
        if (firstExtIdx >= 0) {
          await this.switchSubtitleTrack(firstExtIdx);
          return;
        }
      }
    }

    // 无外部字幕时，若有内嵌轨道默认激活第一条
    if (this.allSubtitleTracks.length > 0) {
      await this.switchSubtitleTrack(0);
    }
  }

  /**
   * 选择字幕轨道
   * @param trackIndex 字幕轨道索引，-1表示关闭字幕
   */
  async selectSubtitleTrack(trackIndex: number): Promise<void> {
    if (!this.avPlayer) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, 'AVPlayer not initialized');
      return
    }

    // 记录切换前的播放状态
    const wasPlaying = this.isPlaying

    try {
      // 根据官方文档：播放过程中动态切换需先 pause()
      if (wasPlaying) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'Pausing playback before subtitle track switch');
        await this.pause()
      }

      if (trackIndex === -1) {
        // 关闭字幕：只更新状态，不调用 deselectTrack
        this.currentSubtitleTrack = -1
        this.currentSubtitleText = ''  // 清空字幕
        hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'Subtitle disabled');
      } else if (trackIndex >= 0 && trackIndex < this.subtitleTracks.length) {
        // 选择新的字幕轨道
        const track = this.subtitleTracks[trackIndex]
        const trackIndexInPlayer = track[media.MediaDescriptionKey.MD_KEY_TRACK_INDEX] as number
        const language = track[media.MediaDescriptionKey.MD_KEY_LANGUAGE] as string || 'unknown'

        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `Selecting subtitle track ${trackIndex}: trackIndex=${trackIndexInPlayer}, language=${language}`);

        // 清空当前字幕文本，等待新字幕更新
        this.currentSubtitleText = ''

        // 选择字幕轨道
        await this.avPlayer.selectTrack(trackIndexInPlayer)
        this.currentSubtitleTrack = trackIndex

        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `Successfully selected subtitle track ${trackIndex}. Waiting for subtitleUpdate callbacks...`);
      }

      // 根据官方文档：切换后重新 play()
      if (wasPlaying) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'Resuming playback after subtitle track switch');
        await this.play()
      }
    } catch (error) {
      const err = error as BusinessError
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `Failed to select subtitle track: code=${err.code}, message=${err.message}`);

      // 即使出错也尝试恢复播放
      if (wasPlaying) {
        try {
          await this.play()
        } catch (playError) {
          hilog.error(CommonConstants.LOG_DOMAIN, TAG,
            `Failed to resume playback: ${JSON.stringify(playError)}`);
        }
      }
    }
  }

  /**
   * 获取字幕轨道的显示名称
   */
  getSubtitleTrackName(trackIndex: number): string {
    if (trackIndex === -1) {
      return '关闭字幕'
    }

    if (trackIndex >= 0 && trackIndex < this.subtitleTracks.length) {
      const track = this.subtitleTracks[trackIndex]

      // 尝试获取字幕的各种信息
      const language = track[media.MediaDescriptionKey.MD_KEY_LANGUAGE] as string
      const mimeType = track[media.MediaDescriptionKey.MD_KEY_CODEC_MIME] as string

      // 构建显示名称
      let displayName = ''

      if (language) {
        // 将语言代码转换为更友好的名称
        displayName = this.getLanguageName(language)
      } else if (mimeType) {
        // 从MIME类型提取格式信息
        const format = mimeType.split('/').pop() || ''
        displayName = `字幕 ${trackIndex + 1} (${format})`
      } else {
        displayName = `字幕 ${trackIndex + 1}`
      }

      return displayName
    }

    return '字幕'
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
    this.activeSubtitleIndex = allIndex;
    this.currentSubtitleText = '';
    this.subtitleUpdateCounter++;

    if (allIndex < 0) {
      // 关闭字幕：清空 SRT，关闭内嵌
      this.srtEntries = [];
      this.lastSrtText = '';
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '关闭字幕，将调用 selectSubtitleTrack(-1)');
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
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `切换到内嵌字幕轨道 ${internalIdx}，将调用 selectSubtitleTrack 激活`);
      // 调用旧方法激活内嵌轨道（会触发 AVPlayer 的 selectTrack）
      await this.selectSubtitleTrack(internalIdx);
    }
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

  /**
   * 下载并解析外部 SRT 字幕文件
   * 解析成功后写入 srtEntries，timeUpdate 会自动驱动显示
   */
  private async loadExternalSrt(url: string, headers?: Record<string, string>): Promise<void> {
    hilog.info(CommonConstants.LOG_DOMAIN, TAG, `开始加载外部字幕: ${url}`);

    const reqHeaders: Record<string, string> = {
      'User-Agent': 'VidALL/1.0.0',
      'Accept': 'text/plain,*/*'
    };
    if (headers) {
      const keys = Object.keys(headers);
      for (const k of keys) {
        reqHeaders[k] = headers[k];
      }
    }

    return new Promise<void>((resolve, reject) => {
      const req = http.createHttp();
      req.request(url, {
        method: http.RequestMethod.GET,
        header: reqHeaders,
        connectTimeout: 10000,
        readTimeout: 15000
      }, (err: BusinessError, resp: http.HttpResponse) => {
        req.destroy();
        if (err) {
          hilog.error(CommonConstants.LOG_DOMAIN, TAG,
            `字幕下载失败: code=${err.code} msg=${err.message}`);
          reject(err);
          return;
        }
        if (resp.responseCode !== 200) {
          const e = new Error(`字幕服务器返回 ${resp.responseCode}`);
          hilog.warn(CommonConstants.LOG_DOMAIN, TAG, e.message);
          reject(e as BusinessError);
          return;
        }
        try {
          const body = resp.result as string;
          const entries = SrtParser.parse(body);
          this.srtEntries = entries;
          this.lastSrtText = '';
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `外部字幕加载成功，共 ${entries.length} 条`);
          resolve();
        } catch (parseErr) {
          const e = parseErr as BusinessError;
          hilog.error(CommonConstants.LOG_DOMAIN, TAG, `字幕解析失败: ${e.message}`);
          reject(e);
        }
      });
    });
  }
}