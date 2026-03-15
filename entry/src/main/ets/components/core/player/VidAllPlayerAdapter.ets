import { IPlayer, SubtitleInfo, TrackInfo } from './IPlayer';
import { VideoData } from './VideoData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CommonConstants } from '../../../common/constants/CommonConstants';
import * as VidAllCorePlayerNapiModule from 'libvidall_core_player_napi.so';

const TAG = '[VidAllPlayerAdapter]';
const METRICS_TAG = 'VidAll_Metrics';
const TIME_UPDATE_INTERVAL_MS = 500;

interface NativeXComponentFallbackContext {
}

interface VidAllCorePlayerNapiBridge {
  createPlayer: () => number;
  setSource: (handle: number, url: string) => void;
  setDurationHint: (handle: number, durationMs: number) => void;
  setHeaders: (handle: number, headersJson: string) => void;
  setXComponent: (handle: number, context: Object, xComponentId: string) => void;
  prepare: (handle: number) => void;
  play: (handle: number) => void;
  pause: (handle: number) => void;
  seek: (handle: number, positionMs: number) => void;
  selectTrack: (handle: number, trackIndex: number) => void;
  release: (handle: number) => void;
  getCurrentTime: (handle: number) => number;
  getDuration: (handle: number) => number;
  setCallbacks: (
    handle: number,
    onPrepared: () => void,
    onError: (code: number, msg: string) => void,
    onTimeUpdate: (posMs: number) => void,
    onCompleted: () => void,
    onBufferingChange: (isBuffering: boolean) => void,
    onSeekDone: () => void
  ) => void;
}

interface VidAllCorePlayerNapiBridgeModule {
  default?: VidAllCorePlayerNapiBridge;
}

const playerBridgeModule = VidAllCorePlayerNapiModule as VidAllCorePlayerNapiBridgeModule | VidAllCorePlayerNapiBridge | undefined;
const VidAllCorePlayerNapi: VidAllCorePlayerNapiBridge =
  playerBridgeModule !== undefined && (playerBridgeModule as VidAllCorePlayerNapiBridgeModule).default !== undefined
    ? ((playerBridgeModule as VidAllCorePlayerNapiBridgeModule).default as VidAllCorePlayerNapiBridge)
    : (playerBridgeModule as VidAllCorePlayerNapiBridge);

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
  /** onReady 幂等门禁：防止 C++ setCallbacks 重注册等场景下重复触发控制层 onReady */
  private _readyFired: boolean = false;
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
  /** seek 完成确认门禁：true 表示有一次 seek 正在等待原生 seekDone 确认 */
  private _seekPending: boolean = false;
  /** seek 完成超时兜底：原生未在 600ms 内回调时自动触发 onSeekDone */
  private _seekDoneTimeoutTimer?: number;  /** 指标埋点：seek 调用时刻（用于计算 seek 完成耗时） */
  private _metricsSeekStartMs: number = 0;
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
      VidAllCorePlayerNapi.setXComponent(this._playerHandle, this._pendingContext as Object, this._pendingXComponentId);
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
          // 幂等门禁：C++ setCallbacks 重注册后会补发一次 onPrepared，确保控制层 onReady 只触发一次。
          if (this._readyFired) {
            hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
              `onPrepared: 重复触发已忽略 handle=${currentHandle}`);
            return;
          }
          this._readyFired = true;
          this._isPrepared = true;
          // getDuration/getCurrentTime 失败属非致命情况，使用 silentNativeFallback：
          // 不触发 _onErrorCb，避免上层误判为播放错误而进行后端切换。
          const nativeDuration = this.silentNativeFallback('getDuration', () =>
            VidAllCorePlayerNapi.getDuration(currentHandle), 0);
          if (nativeDuration > 0) {
            this._duration = nativeDuration;
          } else if (videoData.durationHintMs !== undefined && videoData.durationHintMs > 0) {
            this._duration = videoData.durationHintMs;
          }
          this._currentTime = this.silentNativeFallback('getCurrentTime', () =>
            VidAllCorePlayerNapi.getCurrentTime(currentHandle), 0);
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `onPrepared: handle=${currentHandle} duration=${this._duration} position=${this._currentTime}`);
          this._onReadyCb?.();
        },
        (code: number, msg: string) => {
          // 状态门禁：_playerHandle <= 0 表示已 release，忽略延迟到达的旧实例回调，
          // 防止新会话状态被旧错误污染。
          if (this._playerHandle <= 0) {
            return;
          }
          const hint = this.resolveNativeErrorHint(code);
          const errorMessage = `[${code}] ${msg} (hint=${hint})`;
          hilog.error(CommonConstants.LOG_DOMAIN, TAG,
            `onError: handle=${currentHandle} code=${code} hint=${hint}`);
          this._onErrorCb?.(new Error(errorMessage));
        },
        (posMs: number) => {
          // 状态门禁：同 onError。
          if (this._playerHandle <= 0) {
            return;
          }
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
        },
        () => {
          // 原生 seekDone 确认回调：seek 定位完成后由 C++ EmitSeekDone 触发。
          // 使用 _seekPending 门禁防止重复触发（sync + timeout 双路同时存在时最多触发一次）。
          if (!this._seekPending) {
            return;
          }
          this._seekPending = false;
          if (this._seekDoneTimeoutTimer !== undefined) {
            clearTimeout(this._seekDoneTimeoutTimer);
            this._seekDoneTimeoutTimer = undefined;
          }
          const seekDoneElapsed = Date.now() - this._metricsSeekStartMs;
          hilog.info(CommonConstants.LOG_DOMAIN, METRICS_TAG,
            `{"event":"seek_result","backend":"native","result":"done","elapsed_ms":${seekDoneElapsed}}`);
          this._onSeekDoneCb?.();
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
    this._metricsSeekStartMs = Date.now();
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
      // 清理上一次未完成的 seek 超时兜底，设置新的等待
      if (this._seekDoneTimeoutTimer !== undefined) {
        clearTimeout(this._seekDoneTimeoutTimer);
        this._seekDoneTimeoutTimer = undefined;
      }
      this._seekPending = true;
      this.callNativeVoid('seek', () => {
        // C++ Seek 执行完毕后会同步调用 EmitSeekDone，
        // 其触发的 JS seekDone 回调会清除 _seekPending 并火 _onSeekDoneCb。
        VidAllCorePlayerNapi.seek(this._playerHandle, targetTimeMs);
      });
      // 若 C++ 在骨架阶段已同步触发 seekDone，_seekPending 此时为 false，无需超时兜底。
      // 若未触发（未来异步解码器场景），以 600ms 超时作为保底。
      if (this._seekPending) {
        this._seekDoneTimeoutTimer = setTimeout(() => {
          this._seekDoneTimeoutTimer = undefined;
          if (this._seekPending) {
            this._seekPending = false;
            const seekTimeoutElapsed = Date.now() - this._metricsSeekStartMs;
            hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
              `seek 超时底底触发 target=${targetTimeMs}`);
            hilog.warn(CommonConstants.LOG_DOMAIN, METRICS_TAG,
              `{"event":"seek_result","backend":"native","result":"timeout","elapsed_ms":${seekTimeoutElapsed}}`);
            this._onSeekDoneCb?.();
          }
        }, 600);
      }
      // 读取 seek 后的确认位置（非致命读，失败时保留乐观值）
      this._currentTime = this.silentNativeFallback('getCurrentTimeAfterSeek', () =>
        VidAllCorePlayerNapi.getCurrentTime(this._playerHandle), targetTimeMs);
    } else {
      // 无 native handle：直接同步触发完成（兜底路径）
      this._onSeekDoneCb?.();
    }
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
    this._readyFired = false;
    this._videoData = undefined;
    this._duration = 0;
    this._currentTime = 0;
    this._surfaceId = '';
    this._pendingContext = null;
    this._pendingXComponentId = '';
    this._seekPending = false;
    if (this._seekDoneTimeoutTimer !== undefined) {
      clearTimeout(this._seekDoneTimeoutTimer);
      this._seekDoneTimeoutTimer = undefined;
    }
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
          // 定时轮询中 getCurrentTime/getDuration 的瞬时失败属非致命，
          // 使用内联 try/catch 代替 callNativeWithValue：不触发 _onErrorCb，
          // 避免瞬时读取失败造成播放器意外回退。
          try {
            this._currentTime = VidAllCorePlayerNapi.getCurrentTime(this._playerHandle);
          } catch (readErr) {
            hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
              `timeUpdate: getCurrentTime 失败，保持上次值 pos=${this._currentTime}`);
          }
          try {
            const nativeDuration = VidAllCorePlayerNapi.getDuration(this._playerHandle);
            if (nativeDuration > 0) {
              this._duration = nativeDuration;
            }
          } catch (durErr) {
            hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
              `timeUpdate: getDuration 失败，保持上次值 dur=${this._duration}`);
          }
        }
        // 仅当定时器仍然有效时才触发 timeUpdate：
        // C++ GetCurrentTime 内部调用 AdvancePlaybackClockIfNeeded，若达到 duration 会
        // 同步触发 EmitTimeUpdate + EmitCompleted，完成回调中会 clearInterval 并置 undefined。
        // 此检查防止同一轮 tick 内 onTimeUpdate 和 onCompleted 各被双重触发。
        if (this._timeUpdateTimer !== undefined) {
          this._onTimeUpdateCb?.(this._currentTime);
        }
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
          'timeUpdate 轮询已停止：意外异常');
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

  /**
   * 非致命路径专用：native 调用失败时只记录日志，不触发 _onErrorCb。
   * 适用于 ready 流程中 getDuration/getCurrentTime 等读取操作——
   * 这类失败不代表播放器进入错误态，不应触发上层后端切换。
   */
  private silentNativeFallback<T>(action: string, fn: () => T, fallback: T): T {
    try {
      return fn();
    } catch (e) {
      const err = this.wrapNativeError(action, e as BusinessError);
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `[silent] ${action} 非致命失败: ${err.message}`);
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