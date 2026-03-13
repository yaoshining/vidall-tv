import { IPlayer, SubtitleInfo, TrackInfo } from './IPlayer';
import { VideoData } from './VideoData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CommonConstants } from '../../../common/constants/CommonConstants';
import VidAllCorePlayerNapi from 'libvidall_core_player_napi.so';

const TAG = '[VidAllPlayerAdapter]';
const TIME_UPDATE_INTERVAL_MS = 500;

interface NativeXComponentFallbackContext {
}

/**
 * VidAll Player 原生骨架适配器。
 *
 * 当前阶段目标：
 * - 固化 IPlayer 对接点
 * - 固化 XComponent + native context 绑定时序
 * - 为后续 C++/NAPI 实现预留状态与事件桥接位置
 *
 * 注意：真实解码、渲染、A/V 同步尚未接入，当前仅为框架占位。
 */
export class VidAllPlayerAdapter implements IPlayer {
  private _duration: number = 0;
  private _currentTime: number = 0;
  private _isPlaying: boolean = false;
  private _isPrepared: boolean = false;
  private _videoData?: VideoData;
  private _surfaceId: string = '';
  private _pendingContext: object | null = null;
  private _pendingXComponentId: string = '';
  private _timeUpdateTimer?: number;
  private _playerHandle: number = 0;
  private _lastDurationUnknownSeekLogMs: number = 0;
  private _enableSeekDiagLog: boolean = false;

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
    private _onBufferingCb?: (isBuffering: boolean) => void;

  get duration(): number {
    return this._duration;
  }

  get currentTime(): number {
    return this._currentTime;
  }

  setPendingContext(context: object, xComponentId: string): void {
    this._pendingContext = context;
    this._pendingXComponentId = xComponentId;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `setPendingContext: xComponentId=${xComponentId}, hasContext=${context ? 'Y' : 'N'}`);
  }

  setSeekDiagEnabled(enabled: boolean): void {
    this._enableSeekDiagLog = enabled;
  }

  async initWithContext(videoData: VideoData, surfaceId: string, context: object, xComponentId: string): Promise<void> {
    this._pendingContext = context;
    this._pendingXComponentId = xComponentId;
    await this.init(videoData, surfaceId);
  }

  async init(videoData: VideoData, surfaceId: string): Promise<void> {
    // setNativeContext() 会在调用 init() 前先写入 pending context。
    // 这里先缓存，避免 releaseInternal(false) 把它清空。
    const pendingContext = this._pendingContext;
    const pendingXComponentId = this._pendingXComponentId;

    await this.releaseInternal(false);

    this._pendingContext = pendingContext;
    this._pendingXComponentId = pendingXComponentId;
    this._videoData = videoData;
    this._surfaceId = surfaceId;
    this._duration = 0;
    this._currentTime = 0;
    this._isPlaying = false;
    this._isPrepared = false;

    if (this._pendingXComponentId.length === 0) {
      const hasContext = this._pendingContext ? 'Y' : 'N';
      throw new Error(`VidAll Player XComponent id 尚未绑定(hasContext=${hasContext}, xIdLen=${this._pendingXComponentId.length})`);
    }

    if (!this._pendingContext) {
      // 当前骨架 C++ setXComponent 只消费 xComponentId，不消费 context。
      // 为了先打通 native 主链，context 为空时使用空对象兜底。
      const fallbackContext: NativeXComponentFallbackContext = {};
      this._pendingContext = fallbackContext as object;
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        'init: XComponent context 为空，骨架阶段使用空对象兜底');
    }

    this._playerHandle = this.callNativeWithValue('createPlayer', () => VidAllCorePlayerNapi.createPlayer());
    this.callNativeVoid('setSource', () => {
      VidAllCorePlayerNapi.setSource(this._playerHandle, videoData.videoSrc);
    });
    const headersJson = this.buildHeadersJson(videoData.httpHeader);
    if (headersJson.length > 0) {
      this.callNativeVoid('setHeaders', () => {
        VidAllCorePlayerNapi.setHeaders(this._playerHandle, headersJson);
      });
    }
    if (videoData.durationHintMs !== undefined && videoData.durationHintMs > 0) {
      this._duration = videoData.durationHintMs;
      this.callNativeVoid('setDurationHint', () => {
        VidAllCorePlayerNapi.setDurationHint(this._playerHandle, videoData.durationHintMs as number);
      });
    }
    this.callNativeVoid('setXComponent', () => {
      VidAllCorePlayerNapi.setXComponent(this._playerHandle, this._pendingContext, this._pendingXComponentId);
    });

    // 注册三个 C++ 回调，必须在 prepare() 之前调用
    // onPrepared：骨架阶段由 C++ Prepare() 函数同步触发
    // onError：骨架阶段在状态校验失败（如未 prepared 就 play/selectTrack）时触发
    // onTimeUpdate：骨架阶段在 prepare/play/pause/seek 以及轮询路径触发
    const currentHandle = this._playerHandle;
    this.callNativeVoid('setCallbacks', () => {
      VidAllCorePlayerNapi.setCallbacks(
        currentHandle,
        () => {
          this._isPrepared = true;
          const nativeDuration = this.tryNativeWithFallback('getDuration', () =>
            VidAllCorePlayerNapi.getDuration(currentHandle), 0);
          if (nativeDuration > 0) {
            this._duration = nativeDuration;
          } else if (videoData.durationHintMs !== undefined && videoData.durationHintMs > 0) {
            this._duration = videoData.durationHintMs;
          }
          this._currentTime = this.tryNativeWithFallback('getCurrentTime', () =>
            VidAllCorePlayerNapi.getCurrentTime(currentHandle), 0);
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `VidAll Player onPrepared: handle=${currentHandle} duration=${this._duration}`);
          this._onReadyCb?.();
        },
        (code: number, msg: string) => {
          const hint = this.resolveNativeErrorHint(code);
          const errorMessage = `[${code}] ${msg} (hint=${hint})`;
          hilog.error(CommonConstants.LOG_DOMAIN, TAG, `VidAll Player onError: ${errorMessage}`);
          this._onErrorCb?.(new Error(errorMessage));
        },
        (posMs: number) => {
          this._currentTime = posMs;
          this._onTimeUpdateCb?.(posMs);
        },
        () => {
          this._isPlaying = false;
          if (this._timeUpdateTimer !== undefined) {
            clearInterval(this._timeUpdateTimer);
            this._timeUpdateTimer = undefined;
          }
          this._currentTime = this._duration > 0 ? this._duration : this._currentTime;
          this._onTimeUpdateCb?.(this._currentTime);
          this._onCompletedCb?.();
        },
        (isBuffering: boolean) => {
          this._onBufferingCb?.(isBuffering);
        }
      );
    });
    this.callNativeVoid('prepare', () => {
      VidAllCorePlayerNapi.prepare(currentHandle);
    });
    // onPrepared 由 C++ prepare() 同步触发，上方回调此时已执行完毕
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `VidAll Player init 完成: handle=${currentHandle} surface=${surfaceId} xComponent=${this._pendingXComponentId}`);
  }

  async play(): Promise<void> {
    if (this._playerHandle <= 0) {
      const err = new Error('VidAll Player 未完成初始化');
      this._onErrorCb?.(err);
      throw err;
    }
    if (!this._isPrepared) {
      // 骨架阶段兜底：若上层状态抖动导致 prepared 标记丢失，先尝试补一次 prepare。
      this.callNativeVoid('prepare', () => {
        VidAllCorePlayerNapi.prepare(this._playerHandle);
      });
      if (!this._isPrepared) {
        const err = new Error('VidAll Player 尚未准备完成');
        this._onErrorCb?.(err);
        throw err;
      }
    }
    this.callNativeVoid('play', () => {
      VidAllCorePlayerNapi.play(this._playerHandle);
    });
    this._isPlaying = true;
    this.startTimeUpdateTimer();
    this._onPlayCb?.();
  }

  async pause(): Promise<void> {
    if (this._playerHandle > 0) {
      this.callNativeVoid('pause', () => {
        VidAllCorePlayerNapi.pause(this._playerHandle);
      });
    }
    this._isPlaying = false;
    if (this._timeUpdateTimer !== undefined) {
      clearInterval(this._timeUpdateTimer);
      this._timeUpdateTimer = undefined;
    }
    if (this._playerHandle > 0) {
      this._currentTime = this.callNativeWithValue('getCurrentTime', () =>
        VidAllCorePlayerNapi.getCurrentTime(this._playerHandle));
    }
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
    let targetTimeMs = timeMs < 0 ? 0 : timeMs;
    if (this._duration > 0 && targetTimeMs > this._duration) {
      targetTimeMs = this._duration;
    } else if (this._enableSeekDiagLog && this._duration <= 0 && targetTimeMs > 0) {
      const now = Date.now();
      if (now - this._lastDurationUnknownSeekLogMs >= 3000) {
        this._lastDurationUnknownSeekLogMs = now;
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `seek: duration 未就绪，暂不做上限裁剪 target=${targetTimeMs}`);
      }
    }
    this._currentTime = targetTimeMs;
    if (this._playerHandle > 0) {
      this.callNativeVoid('seek', () => {
        VidAllCorePlayerNapi.seek(this._playerHandle, targetTimeMs);
      });
      this._currentTime = this.callNativeWithValue('getCurrentTime', () =>
        VidAllCorePlayerNapi.getCurrentTime(this._playerHandle));
    }
    this._onSeekDoneCb?.();
  }

  async forward(milliseconds: number): Promise<void> {
    this.seek(this._currentTime + milliseconds);
  }

  async backward(milliseconds: number): Promise<void> {
    this.seek(this._currentTime - milliseconds);
  }

  async getTrackInfos(): Promise<TrackInfo[]> {
    const tracks: TrackInfo[] = [];
    const videoData = this._videoData;
    if (!videoData) {
      return tracks;
    }

    if (videoData.presetAudioTracks && videoData.presetAudioTracks.length > 0) {
      for (let i = 0; i < videoData.presetAudioTracks.length; i++) {
        const preset = videoData.presetAudioTracks[i];
        const track: TrackInfo = {
          trackIndex: preset.trackIndex,
          trackType: 'audio',
          mimeType: preset.mimeType,
          language: preset.language
        };
        tracks.push(track);
      }
    }

    if (videoData.presetSubtitleTracks && videoData.presetSubtitleTracks.length > 0) {
      for (let i = 0; i < videoData.presetSubtitleTracks.length; i++) {
        const preset = videoData.presetSubtitleTracks[i];
        const track: TrackInfo = {
          trackIndex: preset.trackIndex,
          trackType: 'subtitle',
          mimeType: this.mapSubtitleCodecToMime(preset.codecName),
          language: preset.language
        };
        tracks.push(track);
      }
    }

    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `getTrackInfos 骨架返回预置轨道: total=${tracks.length}`);
    return tracks;
  }

  private mapSubtitleCodecToMime(codecName?: string): string | undefined {
    if (!codecName || codecName.length === 0) {
      return undefined;
    }
    const normalized = codecName.toLowerCase();
    if (normalized.includes('subrip') || normalized === 'srt') {
      return 'application/x-subrip';
    }
    if (normalized.includes('ass')) {
      return 'text/x-ssa';
    }
    if (normalized.includes('webvtt') || normalized === 'vtt') {
      return 'text/vtt';
    }
    if (normalized.includes('pgs')) {
      return 'application/x-pgs';
    }
    return undefined;
  }

  private buildHeadersJson(headers?: Record<string, string>): string {
    if (!headers) {
      return '';
    }
    const keys = Object.keys(headers);
    if (keys.length === 0) {
      return '';
    }
    const safeHeaders: Record<string, string> = {};
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      safeHeaders[key] = headers[key];
    }
    return JSON.stringify(safeHeaders);
  }

  async selectTrack(trackIndex: number): Promise<void> {
    if (this._playerHandle <= 0) {
      const err = new Error('VidAll Player 未完成初始化');
      this._onErrorCb?.(err);
      throw err;
    }
    if (trackIndex < -1) {
      const err = new Error(`轨道索引非法: ${trackIndex}`);
      this._onErrorCb?.(err);
      throw err;
    }
    this.callNativeVoid('selectTrack', () => {
      VidAllCorePlayerNapi.selectTrack(this._playerHandle, trackIndex);
    });
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `selectTrack 骨架调用完成: trackIndex=${trackIndex}`);
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

  onBuffering(callback: (isBuffering: boolean) => void): void {
    this._onBufferingCb = callback;
  }

  private async releaseInternal(emitStopped: boolean): Promise<void> {
    this._isPlaying = false;
    this._isPrepared = false;
    this._videoData = undefined;
    this._duration = 0;
    this._currentTime = 0;
    this._surfaceId = '';
    this._pendingContext = null;
    this._pendingXComponentId = '';
    if (this._timeUpdateTimer !== undefined) {
      clearInterval(this._timeUpdateTimer);
      this._timeUpdateTimer = undefined;
    }
    if (this._playerHandle > 0) {
      try {
        this.callNativeVoid('release', () => {
          VidAllCorePlayerNapi.release(this._playerHandle);
        });
      } catch (_) {
        // release 阶段以清理资源为主，native 释放失败不再向外抛出，避免打断收尾流程。
      }
      this._playerHandle = 0;
    }
    if (emitStopped) {
      this._onStoppedCb?.();
    }
  }

  private startTimeUpdateTimer(): void {
    if (this._timeUpdateTimer !== undefined) {
      return;
    }
    this._timeUpdateTimer = setInterval(() => {
      try {
        if (this._playerHandle > 0) {
          this._currentTime = this.callNativeWithValue('getCurrentTime', () =>
            VidAllCorePlayerNapi.getCurrentTime(this._playerHandle));
          const nativeDuration = this.callNativeWithValue('getDuration', () =>
            VidAllCorePlayerNapi.getDuration(this._playerHandle));
          if (nativeDuration > 0) {
            this._duration = nativeDuration;
          }
        }
        this._onTimeUpdateCb?.(this._currentTime);
        if (this._isPlaying && this._duration > 0 && this._currentTime >= this._duration) {
          this._isPlaying = false;
          if (this._timeUpdateTimer !== undefined) {
            clearInterval(this._timeUpdateTimer);
            this._timeUpdateTimer = undefined;
          }
          this._onCompletedCb?.();
        }
      } catch (_) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          'timeUpdate 轮询已停止：native getter 调用失败');
        if (this._timeUpdateTimer !== undefined) {
          clearInterval(this._timeUpdateTimer);
          this._timeUpdateTimer = undefined;
        }
        this._isPlaying = false;
      }
    }, TIME_UPDATE_INTERVAL_MS);
  }

  private callNativeVoid(action: string, fn: () => void): void {
    try {
      fn();
    } catch (e) {
      const err = this.wrapNativeError(action, e as BusinessError);
      this._onErrorCb?.(err);
      throw err;
    }
  }

  private callNativeWithValue<T>(action: string, fn: () => T): T {
    try {
      return fn();
    } catch (e) {
      const err = this.wrapNativeError(action, e as BusinessError);
      this._onErrorCb?.(err);
      throw err;
    }
  }

  private tryNativeWithFallback<T>(action: string, fn: () => T, fallback: T): T {
    try {
      return fn();
    } catch (e) {
      const err = this.wrapNativeError(action, e as BusinessError);
      this._onErrorCb?.(err);
      return fallback;
    }
  }

  private wrapNativeError(action: string, nativeError: BusinessError): Error {
    const code = nativeError.code;
    const message = nativeError.message ?? 'unknown native error';
    const hint = this.resolveNativeErrorHint(code);
    const error = new Error(`[NAPI/${action}] code=${code} msg=${message} hint=${hint}`);
    hilog.error(CommonConstants.LOG_DOMAIN, TAG, error.message);
    return error;
  }

  private resolveNativeErrorHint(code: number): string {
    if (code === 1001) {
      return 'prepare 前未设置 source url';
    }
    if (code === 1002) {
      return 'prepare 前未绑定 xComponentId';
    }
    if (code === 1003) {
      return '未 prepare 就调用 play';
    }
    if (code === 1004) {
      return '未 prepare 就调用 selectTrack';
    }
    if (code === 1005) {
      return '未 prepare 就调用 pause';
    }
    if (code === 1006) {
      return '未 prepare 就调用 seek';
    }
    if (code === 1007) {
      return 'selectTrack 传入了非法轨道索引';
    }
    return '请查看 NAPI TypeError/RangeError 与调用时序';
  }
}