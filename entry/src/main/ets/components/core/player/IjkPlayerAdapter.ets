import { IPlayer, SubtitleInfo, TrackInfo } from './IPlayer';
import { VideoData } from './VideoData';
import { VideoDataType } from './Constants';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CommonConstants } from '../../../common/constants/CommonConstants';
import { IjkMediaPlayer } from '@ohos/ijkplayer';
import type { OnPreparedListener } from '@ohos/ijkplayer';
import type { OnCompletionListener } from '@ohos/ijkplayer';
import type { OnErrorListener } from '@ohos/ijkplayer';
import type { OnSeekCompleteListener } from '@ohos/ijkplayer';
import type { OnInfoListener } from '@ohos/ijkplayer';
import type { OnBufferingUpdateListener } from '@ohos/ijkplayer';
import type { OnVideoSizeChangedListener } from '@ohos/ijkplayer';

const TAG = '[IjkPlayerAdapter]';

/**
 * IjkPlayer 播放内核适配器
 *
 * 实现 IPlayer 接口，封装 @ohos/ijkplayer 的所有操作。
 *
 * 与 AVPlayerAdapter 的关键差异：
 * 1. XComponent 必须使用 libraryname='ijkplayer_napi'，不能用 controller 模式
 *    —— surfaceId 在此处无效，context 由 VideoPlayer UI 层通过 setContext() 传入
 * 2. 没有原生 timeUpdate 事件，需用定时器轮询 getCurrentPosition()
 * 3. 没有原生字幕 API（getTrackInfos 返回空），字幕完全依赖外部文件
 * 4. seek 参数为 string 类型
 * 5. play/pause/stop/release 均为同步方法，包装为 Promise
 *
 * 使用方式（VideoPlayer.ets UI 层）：
 *   XComponent({ id: 'ijkXComponent', type: XComponentType.SURFACE, libraryname: 'ijkplayer_napi' })
 *     .onLoad((context) => {
 *       const adapter = controller.player as IjkPlayerAdapter;
 *       adapter.setContext(context, 'ijkXComponent');
 *     })
 */
export class IjkPlayerAdapter implements IPlayer {
  private ijk: IjkMediaPlayer;
  private readonly XCOMPONENT_ID = 'ijkPlayerXComponent';

  // ─── 状态 ───
  private _duration: number = 0;
  private _currentTime: number = 0;
  private _isPrepared: boolean = false;
  private _isPlaying: boolean = false;
  private _isReleased: boolean = false;

  // ─── XComponent context（必须在 native_setup 之前调用 setContext）───
  private _pendingContext: object | null = null;
  private _pendingXComponentId: string = '';

  // ─── 定时器（轮询 currentTime） ───
  private _timeUpdateTimer?: number;
  private readonly TIME_UPDATE_INTERVAL = 250; // ms

  // ─── 回调存储 ───
  private _onReadyCb?: () => void;
  private _onPlayCb?: () => void;
  private _onPausedCb?: () => void;
  private _onCompletedCb?: () => void;
  private _onStoppedCb?: () => void;
  private _onTimeUpdateCb?: (currentTime: number) => void;
  private _onErrorCb?: (error: Error) => void;
  private _onSeekDoneCb?: () => void;
  // IjkPlayer 无内嵌字幕，此回调永不触发，仅满足接口
  private _onSubtitleUpdateCb?: (info: SubtitleInfo) => void;

  constructor() {
    // 使用单例模式，与官方 README 示例一致
    // 注意：getInstance() 返回的实例在 setContext 时会设置 id = XCOMPONENT_ID
    this.ijk = IjkMediaPlayer.getInstance();
    hilog.info(CommonConstants.LOG_DOMAIN, TAG, '构造完成（单例模式，等待 setPendingContext）');
  }

  // ─── IPlayer 属性 ───

  get duration(): number {
    return this._duration;
  }

  get currentTime(): number {
    return this._currentTime;
  }

  /**
   * 暴露内部 IjkMediaPlayer 实例，供外部访问
   */
  getIjkMediaPlayer(): IjkMediaPlayer {
    return this.ijk;
  }

  /**
   * 保存 XComponent context，在下次 init() 调用时于 native_setup 后绑定。
   * 由 VideoPlayerController.setIjkContext() 调用。
   *
   * 正确时序：setContext 必须在 native_setup 之后、prepareAsync 之前调用。
   */
  setPendingContext(context: object, xComponentId: string): void {
    this._pendingContext = context;
    this._pendingXComponentId = xComponentId;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `setPendingContext: xComponentId=${xComponentId}，等待 init() 中 native_setup 后绑定`);
  }

  // ─── 生命周期 ───

  async init(videoData: VideoData, surfaceId: string): Promise<void> {
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `init 开始 — type=${videoData.type} src=${videoData.videoSrc.substring(0, 80)}`);

    this._isPrepared = false;
    this._isPlaying = false;
    this._duration = 0;
    this._currentTime = 0;

    try {
      // 官方标准初始化顺序（参照 README_zh.md）：
      // 1. setContext（必须最先！在 native_setup 之前）
      // 2. setDebug
      // 3. native_setup
      // 4. setDataSource / setDataSourceHeader
      // 5. setOption
      // 6. setOnXxxListener
      // 7. setMessageListener
      // 8. prepareAsync
      // 9. start（可在 prepareAsync 后直接调，或在 onPrepared 里调）

      // ── Step 1：setContext（必须最先，在 native_setup 之前）──
      if (this._pendingContext && this._pendingXComponentId) {
        this.ijk.setContext(this._pendingContext, this._pendingXComponentId);
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[1/8] setContext 完成，xComponentId=${this._pendingXComponentId}`);
        this._pendingContext = null;
        this._pendingXComponentId = '';
      } else {
        hilog.error(CommonConstants.LOG_DOMAIN, TAG,
          '[1/8] ❌ pendingContext 为空！必须在 init() 前调用 setPendingContext()，视频将黑屏');
      }

      // ── Step 2：setDebug ──
      this.ijk.setDebug(true);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '[2/8] setDebug 完成');

      // ── Step 3：native_setup ──
      this.ijk.native_setup();
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '[3/8] native_setup 完成');

      // ── Step 4：setDataSource ──
      if (videoData.type === VideoDataType.URL) {
        this.ijk.setDataSource(videoData.videoSrc);
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[4/8] setDataSource(URL): ${videoData.videoSrc.substring(0, 120)}`);
        if (videoData.httpHeader) {
          const headerMap = new Map<string, string>();
          const keys = Object.keys(videoData.httpHeader);
          for (const k of keys) {
            headerMap.set(k, videoData.httpHeader[k]);
          }
          if (headerMap.size > 0) {
            this.ijk.setDataSourceHeader(headerMap);
            hilog.info(CommonConstants.LOG_DOMAIN, TAG,
              `[4/8] setDataSourceHeader: ${keys.join(', ')}`);
          }
        }
      } else {
        this.ijk.setDataSource(videoData.videoSrc);
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[4/8] setDataSource(FILE): ${videoData.videoSrc}`);
      }

      // ── Step 5：setOption ──
      this.applyDefaultOptions();
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '[5/8] setOption 完成');

      // ── Step 6：setOnXxxListener ──
      this.bindListeners();
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '[6/8] 所有 Listener 注册完成');

      // ── Step 7：setMessageListener ──
      this.ijk.setMessageListener();
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '[7/8] setMessageListener 完成');

      // ── Step 8：prepareAsync ──
      this.ijk.prepareAsync();
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '[8/8] prepareAsync 已调用，等待 onPrepared 回调...');

    } catch (e) {
      const msg = JSON.stringify(e);
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `init 异常: ${msg}`);
      throw new Error(`IjkPlayerAdapter init failed: ${msg}`);
    }
  }

  play(): Promise<void> {
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `play() 调用 — isPrepared=${this._isPrepared} isPlaying=${this._isPlaying}`);
    if (!this._isPrepared) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, 'play() 忽略：尚未 prepared');
      return Promise.resolve();
    }
    try {
      this.ijk.start();
      this._isPlaying = true;
      this.startTimeUpdateTimer();
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'start() 调用成功');
      if (this._onPlayCb) { this._onPlayCb(); }
    } catch (e) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `start() 异常: ${JSON.stringify(e)}`);
    }
    return Promise.resolve();
  }

  pause(): Promise<void> {
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `pause() 调用 — isPlaying=${this._isPlaying}`);
    if (!this._isPrepared || !this._isPlaying) {
      return Promise.resolve();
    }
    try {
      this.ijk.pause();
      this._isPlaying = false;
      this.stopTimeUpdateTimer();
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'pause() 调用成功');
      if (this._onPausedCb) { this._onPausedCb(); }
    } catch (e) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `pause() 异常: ${JSON.stringify(e)}`);
    }
    return Promise.resolve();
  }

  async toggle(): Promise<void> {
    if (this._isPlaying) {
      await this.pause();
    } else {
      await this.play();
    }
  }

  async release(): Promise<void> {
    if (this._isReleased) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, 'release() 重复调用，忽略');
      return;
    }
    hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'release() 开始');
    this.stopTimeUpdateTimer();
    try {
      this.ijk.stop();
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'stop() 完成');
    } catch (e) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, `stop() 异常（忽略）: ${JSON.stringify(e)}`);
    }
    try {
      this.ijk.release();
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'release() 完成');
    } catch (e) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, `release() 异常（忽略）: ${JSON.stringify(e)}`);
    }
    this._isReleased = true;
    this._isPrepared = false;
    this._isPlaying = false;
  }

  seek(timeMs: number): void {
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `seek(${timeMs}ms) 调用 — isPrepared=${this._isPrepared}`);
    if (!this._isPrepared) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, 'seek() 忽略：尚未 prepared');
      return;
    }
    try {
      // seekTo 参数为 string
      this.ijk.seekTo(timeMs.toString());
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, `seekTo(${timeMs}) 已调用`);
    } catch (e) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `seekTo 异常: ${JSON.stringify(e)}`);
    }
  }

  async forward(milliseconds: number): Promise<void> {
    this.seek(this._currentTime + milliseconds);
  }

  async backward(milliseconds: number): Promise<void> {
    this.seek(Math.max(0, this._currentTime - milliseconds));
  }

  // ─── 轨道 ───

  async getTrackInfos(): Promise<TrackInfo[]> {
    // IjkPlayer 没有原生轨道查询 API，返回空数组
    // 字幕完全由外部文件驱动（VideoPlayerController 的 findExternalSubtitles 负责）
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      'getTrackInfos() 返回空（IjkPlayer 无原生轨道 API，字幕走外部文件）');
    return Promise.resolve([]);
  }

  async selectTrack(trackIndex: number): Promise<void> {
    if (trackIndex < 0) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'selectTrack(-1) 关闭字幕（外部字幕由 Controller 处理）');
      return;
    }
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `selectTrack(${trackIndex}) — IjkPlayer 字幕轨道切换`);
    try {
      this.ijk.selectTrack(trackIndex.toString());
    } catch (e) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `selectTrack 异常: ${JSON.stringify(e)}`);
    }
  }

  // ─── 事件回调注册 ───

  onReady(callback: () => void): void { this._onReadyCb = callback; }
  onPlay(callback: () => void): void { this._onPlayCb = callback; }
  onPaused(callback: () => void): void { this._onPausedCb = callback; }
  onCompleted(callback: () => void): void { this._onCompletedCb = callback; }
  onStopped(callback: () => void): void { this._onStoppedCb = callback; }
  onTimeUpdate(callback: (currentTime: number) => void): void { this._onTimeUpdateCb = callback; }
  onError(callback: (error: Error) => void): void { this._onErrorCb = callback; }
  /** IjkPlayer 不会触发格式不支持回调（ijkplayer 基于 FFmpeg，格式支持广泛） */
  onUnsupportedFormat(_callback: () => void): void { /* no-op */ }
  onSeekDone(callback: () => void): void { this._onSeekDoneCb = callback; }
  onSubtitleUpdate(callback: (info: SubtitleInfo) => void): void {
    this._onSubtitleUpdateCb = callback;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      'onSubtitleUpdate 已注册（IjkPlayer 无内嵌字幕，此回调不会被主动触发）');
  }

  // ─── 内部实现 ───

  /**
   * 应用播放参数
   *
   * 注意：鸿蒙版 ijkplayer 不支持 overlay-format 参数（Android 专用），
   * 强行设置会导致 SDL_VoutFFmpeg_CreateOverlay 失败，视频黑屏只有声音。
   * 鸿蒙版底层使用 XComponent Surface，overlay format 由框架自动管理。
   */
  private applyDefaultOptions(): void {
    // ── 精确寻帧 ──
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'enable-accurate-seek', '1');

    // ── 缓冲控制 ──
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'max_cached_duration', '3000');
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'infbuf', '1');
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'min-frames', '100');

    // ⚠️ start-on-prepared=0：onPrepared 后不自动 start，由 onReady 回调驱动
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'start-on-prepared', '0');

    // 有数据就播，不缓冲等待
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'packet-buffering', '0');

    // 跳帧（CPU 跟不上时保持音画同步，TV 端建议 1~5）
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'framedrop', '5');

    // ── 解码方式 ──
    // 软解码（兜底方案，兼容性最好，避免硬解绿点/黑屏问题）
    // 如需开启硬解码，取消下面两行注释，但鸿蒙某些设备/格式硬解可能出现绿点
    // this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'mediacodec-all-videos', '1');
    // this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'mediacodec-hevc', '1');
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'mediacodec-all-videos', '0');
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'mediacodec-hevc', '0');

    // ── 网络超时（HTTP/WebDAV，单位 μs）──
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, 'timeout', '10000000');
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, 'connect_timeout', '10000000');
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, 'listen_timeout', '10000000');
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, 'addrinfo_timeout', '10000000');
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, 'dns_cache_timeout', '10000000');

    // ── 屏幕常亮 ──
    this.ijk.setScreenOnWhilePlaying(true);

    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      '播放参数已应用：硬解(H264+H265)，精确寻帧，10s超时，start-on-prepared=0');
  }

  /**
   * 绑定所有 IjkMediaPlayer 回调监听器，桥接到 IPlayer 回调
   * 必须在 setMessageListener() 前调用
   */
  private bindListeners(): void {
    // onPrepared
    const onPreparedListener: OnPreparedListener = {
      onPrepared: () => {
        this._isPrepared = true;
        this._duration = this.ijk.getDuration();
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `onPrepared — duration=${this._duration}ms videoSize=${this.ijk.getVideoWidth()}x${this.ijk.getVideoHeight()}`);
        if (this._onReadyCb) { this._onReadyCb(); }
      }
    };
    this.ijk.setOnPreparedListener(onPreparedListener);

    // onCompletion
    const onCompletionListener: OnCompletionListener = {
      onCompletion: () => {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'onCompletion');
        this._isPlaying = false;
        this.stopTimeUpdateTimer();
        if (this._onCompletedCb) { this._onCompletedCb(); }
      }
    };
    this.ijk.setOnCompletionListener(onCompletionListener);

    // onError
    const onErrorListener: OnErrorListener = {
      onError: (what: number, extra: number) => {
        hilog.error(CommonConstants.LOG_DOMAIN, TAG,
          `onError — what=${what} extra=${extra} (what=100:MEDIA_ERROR_UNKNOWN, extra=-10004:IO_ERROR)`);
        this._isPlaying = false;
        this.stopTimeUpdateTimer();
        if (this._onErrorCb) {
          this._onErrorCb(new Error(`IjkPlayer error: what=${what} extra=${extra}`));
        }
      }
    };
    this.ijk.setOnErrorListener(onErrorListener);

    // onSeekComplete
    const onSeekCompleteListener: OnSeekCompleteListener = {
      onSeekComplete: () => {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `onSeekComplete — currentPosition=${this.ijk.getCurrentPosition()}ms`);
        if (this._onSeekDoneCb) { this._onSeekDoneCb(); }
      }
    };
    this.ijk.setOnSeekCompleteListener(onSeekCompleteListener);

    // onInfo
    const onInfoListener: OnInfoListener = {
      onInfo: (what: number, extra: number) => {
        // 常见 what 值：
        // 700 = MEDIA_INFO_BUFFERING_START
        // 701 = MEDIA_INFO_BUFFERING_END
        // 703 = MEDIA_INFO_NETWORK_BANDWIDTH
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `onInfo — what=${what} extra=${extra}`);
      }
    };
    this.ijk.setOnInfoListener(onInfoListener);

    // onBufferingUpdate
    const onBufferingUpdateListener: OnBufferingUpdateListener = {
      onBufferingUpdate: (percent: number) => {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `onBufferingUpdate — ${percent}%`);
      }
    };
    this.ijk.setOnBufferingUpdateListener(onBufferingUpdateListener);

    // onVideoSizeChanged
    const onVideoSizeChangedListener: OnVideoSizeChangedListener = {
      onVideoSizeChanged: (width: number, height: number, sarNum: number, sarDen: number) => {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `onVideoSizeChanged — ${width}x${height} sar=${sarNum}/${sarDen}`);
      }
    };
    this.ijk.setOnVideoSizeChangedListener(onVideoSizeChangedListener);

    hilog.info(CommonConstants.LOG_DOMAIN, TAG, '所有监听器已注册');
  }

  /**
   * 启动定时器，每 250ms 轮询 getCurrentPosition()
   * IjkPlayer 没有 timeUpdate 事件，必须用轮询实现
   */
  private startTimeUpdateTimer(): void {
    if (this._timeUpdateTimer !== undefined) {
      return; // 已在运行
    }
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `启动 timeUpdate 定时器，间隔=${this.TIME_UPDATE_INTERVAL}ms`);
    this._timeUpdateTimer = setInterval(() => {
      if (!this._isPrepared || this._isReleased) {
        this.stopTimeUpdateTimer();
        return;
      }
      const pos = this.ijk.getCurrentPosition();
      if (pos !== this._currentTime) {
        this._currentTime = pos;
        if (this._onTimeUpdateCb) {
          this._onTimeUpdateCb(pos);
        }
      }
    }, this.TIME_UPDATE_INTERVAL);
  }

  /**
   * 停止定时器
   */
  private stopTimeUpdateTimer(): void {
    if (this._timeUpdateTimer !== undefined) {
      clearInterval(this._timeUpdateTimer);
      this._timeUpdateTimer = undefined;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'timeUpdate 定时器已停止');
    }
  }
}









