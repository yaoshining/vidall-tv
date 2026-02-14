import { media } from "@kit.MediaKit";
import fs from "@ohos.file.fs";
import { AVPlayerState, PlayerEvents, VideoDataType } from "./Constants";
import { VideoData } from "./VideoData";
import { BusinessError, emitter } from "@kit.BasicServicesKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { CommonConstants } from "../../../common/constants/CommonConstants";
import { millisecondsToTime } from "../../../utils/TimeUtil";

const TAG = '[VideoPlayerController]';

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
  @Trace currentSubtitleTrack: number = -1  // -1表示关闭字幕
  @Trace currentSubtitleText: string = ''  // 当前显示的字幕文本
  private timeToSeek = -1  // -1表示没有要seek的时间，大于-1表示正在seek还没来的及处理的时间

  async initAVPlayer(videoData: VideoData, surfaceId: string, player?: media.AVPlayer): Promise<void> {
    this.name = videoData.name || ''
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
    } catch (error) {
      if (error) {
        console.error(`Video Player creation error: ${error}`)
        return
      }
    }
  }

  async play(): Promise<void> {
    if (this.isSeeking) {
      return
    }
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
          emitter.emit(PlayerEvents.PLAYING)
          break
        case AVPlayerState.PAUSED:
          this.isPlaying = false
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
    })

    avPlayer.on('error', (error: Error) => {
      console.error('AVPlayer error:', JSON.stringify(error));
      this.isLoading = false;
    });

    avPlayer.on('seekDone', async () => {
      if (this.timeToSeek > -1) {
        avPlayer.seek(this.timeToSeek)
        this.timeToSeek = -1
        this.isSeeking = false
      } else {
        await avPlayer.play()
      }
    })

    // 监听字幕更新事件
    // 根据官方文档，内置字幕会通过 subtitleUpdate 回调实时推送
    try {
      avPlayer.on('subtitleUpdate', (info: media.SubtitleInfo) => {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `Subtitle update: text="${info.text}", startTime=${info.startTime}ms`);

        if (info && info.text) {
          this.currentSubtitleText = info.text
        } else {
          this.currentSubtitleText = ''
        }
      })
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'Subtitle update listener registered successfully');
    } catch (error) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `Failed to register subtitle listener: ${JSON.stringify(error)}`);
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

  /**
   * 加载字幕轨道列表
   */
  private async loadSubtitleTracks(avPlayer: media.AVPlayer): Promise<void> {
    try {
      const trackDescription = await avPlayer.getTrackDescription()
      if (trackDescription && trackDescription.length > 0) {
        // 筛选出字幕轨道
        this.subtitleTracks = trackDescription.filter((track: media.MediaDescription) => {
          return track[media.MediaDescriptionKey.MD_KEY_TRACK_TYPE] === media.MediaType.MEDIA_TYPE_SUBTITLE
        })

        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `Found ${this.subtitleTracks.length} subtitle tracks`);

        // 打印所有字幕轨道的详细信息用于调试
        this.subtitleTracks.forEach((track: media.MediaDescription, index: number) => {
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `Subtitle ${index}: ${JSON.stringify(track)}`);
        })

        // 如果有字幕轨道，默认选择第一个
        if (this.subtitleTracks.length > 0) {
          await this.selectSubtitleTrack(0)
        }
      }
    } catch (error) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `Failed to load subtitle tracks: ${JSON.stringify(error)}`);
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
      'zh': '中文',
      'zh-CN': '简体中文',
      'zh-TW': '繁体中文',
      'zh-HK': '繁体中文(香港)',
      'en': '英语',
      'en-US': '英语(美国)',
      'en-GB': '英语(英国)',
      'ja': '日语',
      'ko': '韩语',
      'fr': '法语',
      'de': '德语',
      'es': '西班牙语',
      'ru': '俄语',
      'it': '意大利语',
      'pt': '葡萄牙语',
      'ar': '阿拉伯语',
      'th': '泰语',
      'vi': '越南语',
      'und': '未定义'
    }

    return languageMap[languageCode] || languageCode || '字幕'
  }
}