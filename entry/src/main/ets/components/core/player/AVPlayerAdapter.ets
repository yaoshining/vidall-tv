import { IPlayer, SubtitleInfo, TrackInfo } from './IPlayer';
import { VideoData } from './VideoData';
import { media } from '@kit.MediaKit';
import fs from '@ohos.file.fs';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AVPlayerState, VideoDataType } from './Constants';
import { CommonConstants } from '../../../common/constants/CommonConstants';

const TAG = '[AVPlayerAdapter]';

/**
 * AVPlayer 播放内核适配器
 *
 * 封装 HarmonyOS media.AVPlayer 的所有操作，实现 IPlayer 接口。
 * VideoPlayerController 通过 IPlayer 接口调用，不直接依赖此类。
 *
 * 扩展其他内核时（如 IjkPlayer），新建对应 Adapter 实现 IPlayer 即可，
 * VideoPlayerController 无需任何改动。
 */
export class AVPlayerAdapter implements IPlayer {
  private avPlayer?: media.AVPlayer;
  private _surfaceId: string = '';

  // ─── 回调存储 ───
  private _onReadyCb?: () => void;
  private _onPlayCb?: () => void;
  private _onPausedCb?: () => void;
  private _onCompletedCb?: () => void;
  private _onStoppedCb?: () => void;
  private _onTimeUpdateCb?: (currentTime: number) => void;
  private _onErrorCb?: (error: Error) => void;
  private _onUnsupportedFormatCb?: () => void;
  private _onSeekDoneCb?: () => void;
  /** 最近一次 AVPlayer error 事件的错误码，用于在 stateChange(ERROR) 时区分错误类型 */
  private _lastErrorCode: number = 0;
  private _onSubtitleUpdateCb?: (info: SubtitleInfo) => void;

  // ─── IPlayer 属性 ───
  get duration(): number {
    return this.avPlayer?.duration ?? 0;
  }

  get currentTime(): number {
    return this.avPlayer?.currentTime ?? 0;
  }

  // ─── 生命周期 ───

  async init(videoData: VideoData, surfaceId: string): Promise<void> {
    this._surfaceId = surfaceId;
    try {
      const player = await media.createAVPlayer();
      this.avPlayer = player;
      player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;

      // 注册所有 AVPlayer 内部事件，桥接到 IPlayer 回调
      this.bindAVPlayerEvents(player);

      // 设置媒体源
      if (videoData.type === VideoDataType.URL) {
        const playbackStrategy: media.PlaybackStrategy = {
          preferredWidth: 1,
          preferredHeight: 2,
          preferredBufferDuration: 3,
          preferredHdr: true
        };
        const mediaSource = media.createMediaSourceWithUrl(
          videoData.videoSrc,
          videoData.httpHeader
        );
        player.setMediaSource(mediaSource, playbackStrategy);
      } else if (videoData.type === VideoDataType.FILE_URI) {
        const file = fs.openSync(videoData.videoSrc, fs.OpenMode.READ_ONLY);
        player.fdSrc = { fd: file.fd };
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `init 失败: code=${err.code} msg=${err.message}`);
      throw new Error(`AVPlayerAdapter init failed: ${err.message}`);
    }
  }

  play(): Promise<void> {
    if (!this.avPlayer) {
      return Promise.reject(new Error('AVPlayer not initialized') as BusinessError);
    }
    return this.avPlayer.play();
  }

  pause(): Promise<void> {
    if (!this.avPlayer) {
      return Promise.reject(new Error('AVPlayer not initialized') as BusinessError);
    }
    if (this.avPlayer.state !== AVPlayerState.PLAYING) {
      return Promise.resolve();
    }
    return this.avPlayer.pause();
  }

  async toggle(): Promise<void> {
    if (!this.avPlayer) { return; }
    if (this.avPlayer.state === AVPlayerState.PLAYING) {
      await this.pause();
    } else {
      await this.play();
    }
  }

  async release(): Promise<void> {
    if (this.avPlayer) {
      try {
        await this.avPlayer.release();
      } catch (e) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG, `release 异常: ${JSON.stringify(e)}`);
      }
      this.avPlayer = undefined;
    }
  }

  seek(timeMs: number): void {
    this.avPlayer?.seek(timeMs);
  }

  async forward(milliseconds: number): Promise<void> {
    this.seek((this.avPlayer?.currentTime ?? 0) + milliseconds);
  }

  async backward(milliseconds: number): Promise<void> {
    this.seek((this.avPlayer?.currentTime ?? 0) - milliseconds);
  }

  // ─── 轨道 ───

  async getTrackInfos(): Promise<TrackInfo[]> {
    if (!this.avPlayer) { return []; }
    try {
      const descs = await this.avPlayer.getTrackDescription();
      const result: TrackInfo[] = [];
      for (const desc of descs) {
        const rawType = desc[media.MediaDescriptionKey.MD_KEY_TRACK_TYPE] as number;
        let trackType: 'video' | 'audio' | 'subtitle' = 'video';
        if (rawType === media.MediaType.MEDIA_TYPE_AUD) {
          trackType = 'audio';
        } else if (rawType === media.MediaType.MEDIA_TYPE_SUBTITLE) {
          trackType = 'subtitle';
        } else if (rawType === media.MediaType.MEDIA_TYPE_VID) {
          trackType = 'video';
        }
        const info: TrackInfo = {
          trackIndex: desc[media.MediaDescriptionKey.MD_KEY_TRACK_INDEX] as number,
          trackType,
          mimeType: desc[media.MediaDescriptionKey.MD_KEY_CODEC_MIME] as string | undefined,
          language: desc[media.MediaDescriptionKey.MD_KEY_LANGUAGE] as string | undefined
        };
        result.push(info);
      }
      return result;
    } catch (e) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `getTrackInfos 失败: ${JSON.stringify(e)}`);
      return [];
    }
  }

  async selectTrack(trackIndex: number): Promise<void> {
    if (!this.avPlayer) { return; }
    if (trackIndex < 0) {
      // 关闭字幕：AVPlayer 暂无 deselectTrack API，只重置状态
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '关闭字幕轨道（无 deselectTrack API）');
      return;
    }
    const wasPlaying = this.avPlayer.state === AVPlayerState.PLAYING;
    try {
      if (wasPlaying) { await this.avPlayer.pause(); }
      await this.avPlayer.selectTrack(trackIndex);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, `selectTrack(${trackIndex}) 成功`);
      if (wasPlaying) { await this.avPlayer.play(); }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `selectTrack(${trackIndex}) 失败: code=${err.code} msg=${err.message}`);
      if (wasPlaying) {
        try { await this.avPlayer?.play(); } catch (_) {}
      }
      throw new Error(`selectTrack(${trackIndex}) failed: ${err.message}`);
    }
  }

  // ─── 事件回调注册 ───

  onReady(callback: () => void): void {
    this._onReadyCb = callback;
  }

  onPlay(callback: () => void): void {
    this._onPlayCb = callback;
  }

  onPaused(callback: () => void): void {
    this._onPausedCb = callback;
  }

  onCompleted(callback: () => void): void {
    this._onCompletedCb = callback;
  }

  onStopped(callback: () => void): void {
    this._onStoppedCb = callback;
  }

  onTimeUpdate(callback: (currentTime: number) => void): void {
    this._onTimeUpdateCb = callback;
  }

  onError(callback: (error: Error) => void): void {
    this._onErrorCb = callback;
  }

  onUnsupportedFormat(callback: () => void): void {
    this._onUnsupportedFormatCb = callback;
  }

  onSeekDone(callback: () => void): void {
    this._onSeekDoneCb = callback;
  }

  onSubtitleUpdate(callback: (info: SubtitleInfo) => void): void {
    this._onSubtitleUpdateCb = callback;
  }

  // ─── 内部实现 ───

  /**
   * 绑定 AVPlayer 原生事件到 IPlayer 回调
   * 在 init() 里调用一次即可
   */
  private bindAVPlayerEvents(player: media.AVPlayer): void {
    // stateChange 统一分发
    player.on('stateChange', (state: string) => {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, `stateChange: ${state}`);
      switch (state) {
        case AVPlayerState.IDLE:
          break;
        case AVPlayerState.INITIALIZED:
          // 设置 Surface 并触发 prepare
          player.surfaceId = this._surfaceId;
          player.prepare().catch((err: BusinessError) => {
            hilog.error(CommonConstants.LOG_DOMAIN, TAG,
              `prepare 失败: code=${err.code} msg=${err.message}`);
          });
          break;
        case AVPlayerState.PREPARED:
          // 准备完成，通知 Controller
          if (this._onReadyCb) { this._onReadyCb(); }
          break;
        case AVPlayerState.PLAYING:
          if (this._onPlayCb) { this._onPlayCb(); }
          break;
        case AVPlayerState.PAUSED:
          if (this._onPausedCb) { this._onPausedCb(); }
          break;
        case AVPlayerState.COMPLETED:
          if (this._onCompletedCb) { this._onCompletedCb(); }
          break;
        case AVPlayerState.STOPPED:
          if (this._onStoppedCb) { this._onStoppedCb(); }
          break;
        case AVPlayerState.ERROR:
          // error 事件在 stateChange(ERROR) 之后才触发（实测顺序）
          // 因此这里不能直接用 _lastErrorCode，改为在 error 事件里统一分发
          // 仅做日志，实际回调由下方 error 事件处理
          hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
            `stateChange: error（等待 error 事件获取 code 后分发）`);
          break;
        default:
          break;
      }
    });

    // timeUpdate
    player.on('timeUpdate', () => {
      if (this._onTimeUpdateCb) {
        this._onTimeUpdateCb(player.currentTime);
      }
    });

    // error —— 实测在 stateChange('error') 之后触发，在此统一分发回调
    player.on('error', (error: Error) => {
      const bizErr = error as BusinessError;
      const code = bizErr.code ?? 0;
      this._lastErrorCode = code;
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `AVPlayer error: code=${code} msg=${bizErr.message}`);

      // 格式/流不支持 → 触发 fallback 切换 ijkplayer
      if (code === 5400106 || code === 5400103) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `格式不支持 (code=${code})，触发 onUnsupportedFormat`);
        if (this._onUnsupportedFormatCb) { this._onUnsupportedFormatCb(); }
      } else {
        // 其他错误（网络、文件缺失等）走普通 onError
        if (this._onErrorCb) { this._onErrorCb(error); }
      }
    });

    // seekDone
    player.on('seekDone', () => {
      if (this._onSeekDoneCb) { this._onSeekDoneCb(); }
    });

    // subtitleUpdate
    try {
      player.on('subtitleUpdate', (info: media.SubtitleInfo) => {
        if (this._onSubtitleUpdateCb) {
          const si: SubtitleInfo = {
            text: info.text,
            startTime: info.startTime,
            duration: info.duration
          };
          this._onSubtitleUpdateCb(si);
        }
      });
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '内嵌字幕监听已注册');
    } catch (e) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `subtitleUpdate 注册失败（可能当前 API 不支持）: ${JSON.stringify(e)}`);
    }
  }
}