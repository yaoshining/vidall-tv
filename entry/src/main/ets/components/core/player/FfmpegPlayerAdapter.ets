import { IPlayer, SubtitleInfo, TrackInfo } from './IPlayer';
import { VideoData } from './VideoData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CommonConstants } from '../../../common/constants/CommonConstants';
import { FfmpegAudioDecodeResult, FfmpegAudioDecodeUtil } from '../../../utils/FfmpegAudioDecodeUtil';
import { FfmpegAudioRendererSink } from './FfmpegAudioRendererSink';
import { FfprobeUtil } from '../../../utils/FfprobeUtil';

const TAG = '[FfmpegPlayerAdapter]';
const DECODE_SEGMENT_SECONDS = 12;
const DECODE_TIMEOUT_MS = 90000;
const BUFFER_LOW_WATER_MS = 7000;
const BUFFER_HIGH_WATER_MS = 22000;
const TIME_UPDATE_INTERVAL_MS = 200;
const ENABLE_FFMPEG_DIAG_LOG = false;

export class FfmpegPlayerAdapter implements IPlayer {
  private _duration: number = 0;
  private _currentTime: number = 0;
  private _isPlaying: boolean = false;

  private _videoData?: VideoData;
  private _surfaceId: string = '';

  private _audioSink: FfmpegAudioRendererSink = new FfmpegAudioRendererSink();
  private _sinkReady: boolean = false;
  private _inputCompleted: boolean = false;
  private _decodeCursorMs: number = 0;
  private _playbackBaseMs: number = 0;
  private _decodeChannels: number = 2;

  private _decodePromise?: Promise<void>;
  private _fillingWater: boolean = false;
  private _isSeeking: boolean = false;

  private _timeUpdateTimer?: number;

  private _onReadyCb?: () => void;
  private _onPlayCb?: () => void;
  private _onPausedCb?: () => void;
  private _onCompletedCb?: () => void;
  private _onStoppedCb?: () => void;
  private _onTimeUpdateCb?: (currentTime: number) => void;
  private _onErrorCb?: (error: Error) => void;
  private _onUnsupportedFormatCb?: () => void;
  private _onSeekDoneCb?: () => void;
  private _onSubtitleUpdateCb?: (info: SubtitleInfo) => void;

  get duration(): number {
    return this._duration;
  }

  get currentTime(): number {
    return this._currentTime;
  }

  async init(videoData: VideoData, surfaceId: string): Promise<void> {
    await this.releaseInternal(false);

    this._videoData = videoData;
    this._surfaceId = surfaceId;
    this._duration = 0;
    this._currentTime = 0;
    this._isPlaying = false;
    this._sinkReady = false;
    this._inputCompleted = false;
    this._decodeCursorMs = 0;
    this._playbackBaseMs = 0;
    this._decodeChannels = this.normalizeDecodeChannels(videoData.ffmpegDecodeChannels);
    this._decodePromise = undefined;
    this._fillingWater = false;
    this._isSeeking = false;

    this._audioSink.markInputCompleted(false);

    this.probeDurationInBackground();

    if (ENABLE_FFMPEG_DIAG_LOG) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `init 连续缓冲模式: src=${videoData.videoSrc.substring(0, 80)} surface=${surfaceId} decodeChannels=${this._decodeChannels}`);
    }

    this._onReadyCb?.();
  }

  async play(): Promise<void> {
    if (!this._videoData) {
      const err = new Error('ffmpeg backend 未初始化视频源');
      this._onErrorCb?.(err);
      throw err;
    }

    if (this._isPlaying) {
      return;
    }

    await this.ensurePrimed();

    await this._audioSink.play();
    this._isPlaying = true;
    this.startTimeUpdateTimer();
    this.fillToHighWater().catch(() => {
      // 水位补段失败会在内部上报错误，这里避免未处理 promise。
    });

    if (ENABLE_FFMPEG_DIAG_LOG) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `play 连续缓冲模式启动: buffer=${this._audioSink.getBufferedDurationMs()}ms`);
    }
    this._onPlayCb?.();
  }

  async pause(): Promise<void> {
    await this._audioSink.pause();
    this._isPlaying = false;
    this._currentTime = this._playbackBaseMs + this._audioSink.getCurrentPositionMs();
    this._onPausedCb?.();
  }

  async toggle(): Promise<void> {
    if (this._isPlaying) {
      await this.pause();
    } else {
      await this.play();
    }
  }

  async release(): Promise<void> {
    await this.releaseInternal(true);
  }

  seek(timeMs: number): void {
    const target = timeMs < 0 ? 0 : timeMs;
    this.seekInternal(target).catch((e: Error) => {
      this._onErrorCb?.(e);
    });
  }

  async forward(milliseconds: number): Promise<void> {
    this.seek(this._currentTime + milliseconds);
  }

  async backward(milliseconds: number): Promise<void> {
    this.seek(this._currentTime - milliseconds);
  }

  async getTrackInfos(): Promise<TrackInfo[]> {
    return [];
  }

  async selectTrack(trackIndex: number): Promise<void> {
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `selectTrack(${trackIndex}) 当前阶段未实现`);
  }

  setSubtitleDelay(_delayMs: number): void {
  }

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

  private async releaseInternal(emitStopped: boolean): Promise<void> {
    this._isPlaying = false;
    this._videoData = undefined;

    if (this._timeUpdateTimer !== undefined) {
      clearInterval(this._timeUpdateTimer);
      this._timeUpdateTimer = undefined;
    }

    await this._audioSink.release();

    this._sinkReady = false;
    this._inputCompleted = false;
    this._decodeCursorMs = 0;
    this._playbackBaseMs = 0;
    this._decodePromise = undefined;
    this._fillingWater = false;
    this._isSeeking = false;

    if (emitStopped) {
      this._onStoppedCb?.();
    }
  }

  private startTimeUpdateTimer(): void {
    if (this._timeUpdateTimer !== undefined) {
      return;
    }

    this._timeUpdateTimer = setInterval(() => {
      if (this._isSeeking) {
        return;
      }

      const localPos = this._audioSink.getCurrentPositionMs();
      this._currentTime = this._playbackBaseMs + localPos;
      this._onTimeUpdateCb?.(this._currentTime);

      if (this._audioSink.hasEnded()) {
        this._isPlaying = false;
        this._onCompletedCb?.();
        if (this._timeUpdateTimer !== undefined) {
          clearInterval(this._timeUpdateTimer);
          this._timeUpdateTimer = undefined;
        }
        return;
      }

      this.maybeTriggerWaterFill();
    }, TIME_UPDATE_INTERVAL_MS);
  }

  private async ensurePrimed(): Promise<void> {
    if (this._sinkReady) {
      return;
    }

    await this.decodeAndAppendOneSegment();

    if (!this._sinkReady) {
      throw new Error('首段音频预缓冲失败');
    }
  }

  private maybeTriggerWaterFill(): void {
    if (!this._isPlaying || this._inputCompleted || this._fillingWater) {
      return;
    }

    if (this._audioSink.getBufferedDurationMs() < BUFFER_LOW_WATER_MS) {
      this.fillToHighWater().catch(() => {
      });
    }
  }

  private async fillToHighWater(): Promise<void> {
    if (this._fillingWater || this._inputCompleted) {
      return;
    }

    this._fillingWater = true;
    try {
      while (!this._inputCompleted && this._audioSink.getBufferedDurationMs() < BUFFER_HIGH_WATER_MS) {
        await this.decodeAndAppendOneSegment();
      }
    } finally {
      this._fillingWater = false;
    }
  }

  private async decodeAndAppendOneSegment(): Promise<void> {
    if (!this._videoData) {
      throw new Error('ffmpeg backend 未初始化视频源');
    }

    if (this._decodePromise) {
      await this._decodePromise;
      return;
    }

    this._decodePromise = this.decodeOneSegmentInternal(this._decodeCursorMs);
    try {
      await this._decodePromise;
    } finally {
      this._decodePromise = undefined;
    }
  }

  private async decodeOneSegmentInternal(startMs: number): Promise<void> {
    if (ENABLE_FFMPEG_DIAG_LOG) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `开始补段: start=${startMs}ms, target=${DECODE_SEGMENT_SECONDS}s, ch=${this._decodeChannels}`);
    }

    let result = await this.decodeSegmentWithChannels(startMs, this._decodeChannels);

    // 多声道失败时自动回退到立体声，保证播放稳定性。
    if (!result.success && this._decodeChannels > 2) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `多声道软解失败，回退立体声: ${result.errorMessage ?? 'unknown'}`);
      this._decodeChannels = 2;
      result = await this.decodeSegmentWithChannels(startMs, this._decodeChannels);
    }

    if (!result.success) {
      const err = new Error(result.errorMessage ?? 'ffmpeg 音频软解失败');
      this._onErrorCb?.(err);
      throw err;
    }

    if (!this._sinkReady) {
      await this._audioSink.loadWav(result.outputPath);
      this._sinkReady = true;
      this._audioSink.markInputCompleted(false);
    } else {
      await this._audioSink.enqueueWav(result.outputPath);
    }

    const decodedMs = this._audioSink.durationMs;
    if (decodedMs <= 0) {
      this._inputCompleted = true;
      this._audioSink.markInputCompleted(true);
      return;
    }

    this._decodeCursorMs += decodedMs;

    const likelyEndByShortSegment = decodedMs < (DECODE_SEGMENT_SECONDS * 1000 - 800);
    const likelyEndByKnownDuration = this._duration > 0 && this._decodeCursorMs >= (this._duration - 300);
    if (likelyEndByShortSegment || likelyEndByKnownDuration) {
      this._inputCompleted = true;
      this._audioSink.markInputCompleted(true);
    }
  }

  private async decodeSegmentWithChannels(
    startMs: number,
    channels: number
  ): Promise<FfmpegAudioDecodeResult> {
    const outputPath = `/data/storage/el2/base/cache/vidall_ffmpeg_q_${Date.now()}_${Math.floor(startMs)}_c${channels}.wav`;
    return FfmpegAudioDecodeUtil.decodeFirstAudioTrackToWav(
      this._videoData!.videoSrc,
      outputPath,
      this._videoData!.httpHeader,
      DECODE_TIMEOUT_MS,
      DECODE_SEGMENT_SECONDS,
      Math.floor(startMs / 1000),
      channels
    );
  }

  private normalizeDecodeChannels(channels?: number): number {
    if (!channels) {
      return 2;
    }
    if (channels <= 1) {
      return 1;
    }
    if (channels >= 8) {
      return 8;
    }
    if (channels >= 6) {
      return 6;
    }
    return 2;
  }

  private async seekInternal(targetMs: number): Promise<void> {
    const hadPlaying = this._isPlaying;
    this._isSeeking = true;
    this._isPlaying = false;

    try {
      await this._audioSink.pause();
      await this._audioSink.release();

      this._sinkReady = false;
      this._inputCompleted = false;
      this._decodeCursorMs = targetMs;
      this._playbackBaseMs = targetMs;
      this._currentTime = targetMs;
      this._audioSink.markInputCompleted(false);

      await this.ensurePrimed();
      await this.fillToHighWater();

      if (hadPlaying) {
        await this._audioSink.play();
        this._isPlaying = true;
      }

      this._onTimeUpdateCb?.(this._currentTime);
      this._onSeekDoneCb?.();
    } finally {
      this._isSeeking = false;
    }
  }

  private probeDurationInBackground(): void {
    if (!this._videoData) {
      return;
    }

    const url = this._videoData.videoSrc;
    if (url.length === 0) {
      return;
    }

    FfprobeUtil.probe(url, this._videoData.httpHeader, 12000)
      .then((result) => {
        if (result.success && result.durationMs > 0) {
          this._duration = result.durationMs;
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `ffprobe 获取整片时长成功: ${result.durationMs}ms`);
        }
      })
      .catch(() => {
      });
  }
}
