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
import { DeviceCapabilityUtil, type IjkHwDecodeSupport } from '../../../utils/DeviceCapabilityUtil';
import { AppPreferences, PrefKey } from '../../../utils/AppPreferences';
import { FfprobeUtil } from '../../../utils/FfprobeUtil';

const TAG = '[IjkPlayerAdapter]';
const ENABLE_IJK_INFO_CALLBACK = false;

/** ijk 内嵌字幕流（从 getMediaInfo().meta 解析） */
interface IjkSubtitleStreamInfo {
  streamIndex: number;
  language: string;
  codecName: string;
}

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
  private _sessionId: string = '';
  private _seekRenderingInfoCount: number = 0;
  private _lastHeartbeatWriteAt: number = 0;

  // ─── 状态 ───
  private _duration: number = 0;
  private _currentTime: number = 0;
  private _isPrepared: boolean = false;
  private _isPlaying: boolean = false;
  private _isReleased: boolean = false;
  /** 当前视频的编码类型（由 VideoData.videoCodec 传入，如 'hevc', 'h264'） */
  private _videoCodec: string = '';
  /** 当前视频 URL（用于 native 字幕提取） */
  private _currentUrl: string = '';
  /** 当前视频 HTTP 鉴权头（用于 native 字幕提取，格式: "Authorization: Basic xxx\r\n"） */
  private _currentHeaderLines: string = '';

  // ─── XComponent context（必须在 native_setup 之前调用 setContext）───
  private _pendingContext: object | null = null;
  private _pendingXComponentId: string = '';

  // ─── 定时器（轮询 currentTime） ───
  private _timeUpdateTimer?: number;
  // 100ms 轮询确保外置字幕显示偏差 P95 ≤ 120ms（#17）
  private readonly TIME_UPDATE_INTERVAL = 100; // ms

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
    // 使用多实例模式，避免单例跨页面状态残留导致的偶发异常。
    this.ijk = new IjkMediaPlayer();
    this._sessionId = `ijk-${Date.now()}`;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `构造完成（多实例模式）session=${this._sessionId}，等待 setPendingContext`);
    this.writeBreadcrumb('constructed');
  }

  private writeBreadcrumb(stage: string, extra: string = ''): void {
    const safeExtra = this.sanitizeBreadcrumbExtra(extra);
    const payload = `${Date.now()}|${this._sessionId}|${stage}|` +
      `prepared=${this._isPrepared}|playing=${this._isPlaying}|time=${this._currentTime}|${safeExtra}`;
    AppPreferences.set(PrefKey.PLAYER_LAST_BREADCRUMB, payload).catch(() => {});
  }

  private sanitizeBreadcrumbExtra(extra: string): string {
    if (extra.length === 0) {
      return '';
    }
    // 统一为单行并避免与分隔符冲突。
    let normalized = extra
      .replace(/\r\n|\r|\n/g, ' ')
      .replace(/\|/g, '/');
    const MAX_LEN = 180;
    if (normalized.length > MAX_LEN) {
      normalized = normalized.substring(0, MAX_LEN) + '...';
    }
    return normalized;
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
  * 保存 XComponent context，在下次 init() 调用时于 native_setup 前绑定。
   * 由 VideoPlayerController.setIjkContext() 调用。
   *
  * 正确时序：setContext 必须在 native_setup 之前调用。
   */
  setPendingContext(context: object, xComponentId: string): void {
    this._pendingContext = context;
    this._pendingXComponentId = xComponentId;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
    `setPendingContext: xComponentId=${xComponentId} session=${this._sessionId}`);
  }

  // ─── 生命周期 ───

  async init(videoData: VideoData, surfaceId: string): Promise<void> {
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `init 开始 — type=${videoData.type} src=${videoData.videoSrc.substring(0, 80)}`);

    this._isPrepared = false;
    this._isPlaying = false;
    this._duration = 0;
    this._currentTime = 0;
    this._isReleased = false;
    this._seekRenderingInfoCount = 0;
    this._lastHeartbeatWriteAt = 0;
    this._videoCodec = (videoData.videoCodec ?? '').toLowerCase();
    this._currentUrl = videoData.videoSrc;
    // 将 httpHeader 转为 FFmpeg headers 格式（"Key: Value\r\n" 拼接）供 native 字幕提取使用
    this._currentHeaderLines = '';
    if (videoData.httpHeader) {
      const headerKeys = Object.keys(videoData.httpHeader);
      for (const k of headerKeys) {
        this._currentHeaderLines += k + ': ' + videoData.httpHeader[k] + '\r\n';
      }
    }
    this.writeBreadcrumb('init-start', `type=${videoData.type}`);

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
          `[1/8] setContext 完成，xComponentId=${this._pendingXComponentId} session=${this._sessionId}`);
        this._pendingContext = null;
        this._pendingXComponentId = '';
      } else {
        const msg = '[1/8] pendingContext 为空，取消 init 以避免 native 异常';
        hilog.error(CommonConstants.LOG_DOMAIN, TAG, `${msg} session=${this._sessionId}`);
        throw new Error(msg);
      }

      // ── Step 2：setDebug ──
      // 高频 native debug 日志会明显增加 IO 压力，稳定性优先默认关闭。
      this.ijk.setDebug(false);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '[2/8] setDebug(false) 完成');

      // ── Step 3：native_setup ──
      this.ijk.native_setup();
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '[3/8] native_setup 完成');
      this.writeBreadcrumb('native-setup-done');

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
      await this.applyDefaultOptions();
      if (this._isReleased) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `[5/8] init 已在 release 后中止 session=${this._sessionId}`);
        return;
      }
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '[5/8] setOption 完成');

      // ── Step 6：setOnXxxListener ──
      this.bindListeners();
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '[6/8] 所有 Listener 注册完成');

      // ── Step 7：setMessageListener ──
      this.ijk.setMessageListener();
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '[7/8] setMessageListener 完成');

      // ── Step 8：prepareAsync ──
      this.ijk.prepareAsync();
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[8/8] prepareAsync 已调用，等待 onPrepared 回调... session=${this._sessionId}`);
      this.writeBreadcrumb('prepare-async-called');

    } catch (e) {
      const msg = JSON.stringify(e);
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `init 异常: ${msg}`);
      this.writeBreadcrumb('init-error', msg);
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
      this.writeBreadcrumb('play-started');
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
      this.writeBreadcrumb('paused');
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
    hilog.info(CommonConstants.LOG_DOMAIN, TAG, `release() 开始 session=${this._sessionId}`);
    this.writeBreadcrumb('release-start');
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
    this._pendingContext = null;
    this._pendingXComponentId = '';
    this.writeBreadcrumb('release-done');
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
    // 此方法作为 fallback，在 FfprobeUtil 探测失败时被调用。
    // IjkPlayer 的 getMediaInfo().audioDecoder 只描述当前激活的一条音轨，
    // 因此此方法最多返回单条音轨，仅用于兜底显示。
    if (!this._isPrepared) {
      const def: TrackInfo = { trackIndex: 0, trackType: 'audio', mimeType: 'audio/mp4a-latm', language: '' };
      return Promise.resolve([def]);
    }

    const codecMimeMap: Record<string, string> = {
      'aac': 'audio/mp4a-latm',
      'mp3': 'audio/mpeg',
      'ac3': 'audio/ac-3',
      'eac3': 'audio/eac3',
      'dts': 'audio/dts',
      'flac': 'audio/flac',
      'opus': 'audio/opus',
      'vorbis': 'audio/vorbis',
      'truehd': 'audio/truehd',
      'pcm_s16le': 'audio/raw',
    };

    try {
      const info: object = this.ijk.getMediaInfo();
      const infoStr: string = JSON.stringify(info);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, `[getTrackInfos] getMediaInfo: ${infoStr}`);

      const adMatch = infoStr.match(/"audioDecoder"\s*:\s*"([^"]+)"/);
      const metaMatch = infoStr.match(/"meta"\s*:\s*"([^"]+)"/);
      const audioDecoderStr = adMatch ? adMatch[1] : '';
      const metaStr = metaMatch ? metaMatch[1] : '';
      const langFromMeta = this.extractMetaValue(metaStr, 'language');

      // 解析 audioDecoder："avcodec, eac3" → ["eac3"]
      const decoderList: string[] = [];
      if (audioDecoderStr.length > 0) {
        const rawTokens = audioDecoderStr.split(',').map((s: string) => s.trim()).filter((s: string) => s.length > 0);
        let idx = 0;
        while (idx < rawTokens.length) {
          if (rawTokens[idx] === 'avcodec' && idx + 1 < rawTokens.length) {
            decoderList.push(rawTokens[idx + 1]);
            idx += 2;
          } else {
            decoderList.push(rawTokens[idx]);
            idx += 1;
          }
        }
      }

      const tracks: TrackInfo[] = [];
      for (let i = 0; i < decoderList.length; i++) {
        const codec = decoderList[i].toLowerCase();
        const item: TrackInfo = {
          trackIndex: i,
          trackType: 'audio',
          mimeType: codecMimeMap[codec] ?? `audio/${codec}`,
          language: i === 0 ? langFromMeta : ''
        };
        tracks.push(item);
      }

      if (tracks.length > 0) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG, `getTrackInfos() fallback 返回 ${tracks.length} 个音轨`);
        return Promise.resolve(tracks);
      }
    } catch (e) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `getMediaInfo() 异常: ${JSON.stringify(e)}`);
    }

    const def: TrackInfo = { trackIndex: 0, trackType: 'audio', mimeType: 'audio/mp4a-latm', language: '' };
    return Promise.resolve([def]);
  }

  /**
   * 从 meta 字符串中提取指定 key 的 value
   * meta 格式: "key:language,value:chi;key:sample_rate,value:48000;"
   */
  private extractMetaValue(meta: string, key: string): string {
    // 匹配 "key:XXX,value:YYY;"
    const pattern = new RegExp(`key:${key},value:([^;]+)`);
    const m = meta.match(pattern);
    return m ? m[1] : '';
  }

  async selectTrack(trackIndex: number): Promise<void> {
    if (trackIndex < 0) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'selectTrack(-1) 关闭字幕（外部字幕由 Controller 处理）');
      return;
    }
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `selectTrack(${trackIndex}) — 切换到 ijkplayer 流索引 ${trackIndex}`);
    try {
      this.ijk.selectTrack(trackIndex.toString());
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `selectTrack(${trackIndex}) 调用成功，等待 Controller seek flush 后恢复播放`);
    } catch (e) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `selectTrack 异常: ${JSON.stringify(e)}`);
      throw new Error(`selectTrack failed: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 设置字幕延迟偏移。
   *
   * IjkPlayerAdapter 中此方法是空实现：字幕延迟由 VideoPlayerController
   * 在 SRT 时间轴查找时应用（currentTime - subtitleDelayMs），无需底层支持。
   */
  setSubtitleDelay(_delayMs: number): void {
    // no-op: 延迟偏移由上层 SRT 查找逻辑处理
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `setSubtitleDelay: 延迟已由 VideoPlayerController 层处理`);
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
  onBuffering(_callback: (isBuffering: boolean) => void): void { /* no-op */ }

  // ─── 内部实现 ───

  /**
   * 应用播放参数
   *
   * 注意：鸿蒙版 ijkplayer 不支持 overlay-format 参数（Android 专用），
   * 强行设置会导致 SDL_VoutFFmpeg_CreateOverlay 失败，视频黑屏只有声音。
   * 鸿蒙版底层使用 XComponent Surface，overlay format 由框架自动管理。
   */
  private async applyDefaultOptions(): Promise<void> {
    // ── seek 策略（稳定性优先）──
    // 精确 seek 会增加 HEVC 片源的回退解码压力，先关闭以降低崩溃概率。
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'enable-accurate-seek', '0');

    // ── 缓冲控制 ──
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'max_cached_duration', '1500');
    // infbuf=1 可能导致长播时缓冲无上限增长，增加系统回收/强杀风险。
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'infbuf', '0');
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'min-frames', '30');

    // ⚠️ start-on-prepared=0：onPrepared 后不自动 start，由 onReady 回调驱动
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'start-on-prepared', '0');

    // 有数据就播，不缓冲等待
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'packet-buffering', '0');

    // 跳帧（CPU 跟不上时保持音画同步，TV 端建议 1~5）
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'framedrop', '5');

    // 不强制覆盖 codec 线程与 loop filter，避免在高码率 HEVC 下出现视频解码跟不上
    // （表现为画面卡顿、音频继续播放导致音画不同步）。

    // ── 硬件解码策略（稳定性优先）──
    // 线上出现 HEVC/HDR（含 Mastering Display Metadata）播放时偶发强退，
    // 崩溃点集中在 EGL 渲染链路。先统一关闭 mediacodec，优先保证稳定。
    // 后续可在确认设备/片源组合稳定后再灰度恢复硬解。
    const defaultHwSupport: IjkHwDecodeSupport = { h264: false, h265: false };
    let hwSupport: IjkHwDecodeSupport = defaultHwSupport;
    try {
      hwSupport = await DeviceCapabilityUtil.checkIjkHardwareDecodeSupport();
    } catch (e) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `获取硬解能力失败，继续按软解策略运行: ${JSON.stringify(e)}`);
    }

    // 判断是否是 HEVC 内容
    // HEVC 硬解在 HDR/Dolby Vision 内容（如 4K DV MKV）下会导致花屏（白点/绿色块），强制软解。
    // mediacodec-all-videos=1 会同时开启 H264+H265 硬解，无法单独关闭 HEVC，
    // 因此 HEVC 内容必须把 all-videos 也设为 0。
    const isHevc = this._videoCodec.includes('hevc') ||
      this._videoCodec.includes('h265') ||
      this._videoCodec.includes('265');

    const useH264Hw = !isHevc && hwSupport.h264;
    // HEVC 硬解始终关闭（花屏根因），H265 能力留着但不使用
    const useH265Hw = false;

    // all-videos=1 会把 H264+H265 一起开：只有明确 H264 内容时才开；HEVC 内容两个都关。
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER,
      'mediacodec-all-videos', useH264Hw ? '1' : '0');
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER,
      'mediacodec-hevc', useH265Hw ? '1' : '0');
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `硬件解码决策: videoCodec=${this._videoCodec || '未知'} isHevc=${isHevc} ` +
      `H264=${useH264Hw ? '硬解✅' : '软解⚠️'} H265=${useH265Hw ? '硬解✅' : '软解⚠️'} ` +
      `设备能力(H264=${hwSupport.h264}, H265=${hwSupport.h265})`);

    // ── 网络超时（HTTP/WebDAV，单位 μs）──
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, 'timeout', '10000000');
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, 'connect_timeout', '10000000');
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, 'listen_timeout', '10000000');
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, 'addrinfo_timeout', '10000000');
    this.ijk.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, 'dns_cache_timeout', '10000000');

    // ── 屏幕常亮 ──
    this.ijk.setScreenOnWhilePlaying(true);

    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      '播放参数已应用：非精确seek，10s超时，start-on-prepared=0');
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
          `onPrepared — duration=${this._duration}ms videoSize=${this.ijk.getVideoWidth()}x${this.ijk.getVideoHeight()} session=${this._sessionId}`);
        this.writeBreadcrumb('on-prepared', `duration=${this._duration}`);

        // ── [调研] native 字幕提取端到端验证 ──
        // 若当前视频含内嵌字幕流（通过 getMediaInfo().meta 解析），则触发 native 提取，
        // 打印提取耗时和前 200 字符，验证 FFmpeg Range 请求方案可行性。
        try {
          const rawInfo = this.ijk.getMediaInfo() as Record<string, string>;
          const meta: string = rawInfo['meta'] ?? '';
          const streams = this.parseIjkSubtitleMeta(meta);
          if (streams.length > 0) {
            const s = streams[0];
            hilog.info(CommonConstants.LOG_DOMAIN, TAG,
              `[调研·NativeExtract] 发现字幕流 s:${s.streamIndex} codec=${s.codecName} lang=${s.language}，开始 native 提取...`);
            const extractStart = Date.now();
            FfprobeUtil.extractSubtitleTrackAsync(
              this._currentUrl, this._currentHeaderLines, s.streamIndex, 30000
            ).then((srtText: string) => {
              const elapsed = Date.now() - extractStart;
              hilog.info(CommonConstants.LOG_DOMAIN, TAG,
                `[调研·NativeExtract] 完成！耗时=${elapsed}ms 总长度=${srtText.length} 前200字符:\n${srtText.substring(0, 200)}`);
            }).catch(() => {
              const elapsed = Date.now() - extractStart;
              hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
                `[调研·NativeExtract] 提取失败，耗时=${elapsed}ms`);
            });
          } else {
            hilog.info(CommonConstants.LOG_DOMAIN, TAG, '[调研·NativeExtract] 无内嵌字幕流，跳过');
          }
        } catch (e) {
          hilog.warn(CommonConstants.LOG_DOMAIN, TAG, '[调研·NativeExtract] meta 解析异常');
        }

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
        this.writeBreadcrumb('on-error', `what=${what},extra=${extra}`);
        if (this._onErrorCb) {
          this._onErrorCb(new Error(`IjkPlayer error: what=${what} extra=${extra}`));
        }
      }
    };
    this.ijk.setOnErrorListener(onErrorListener);

    // onSeekComplete
    const onSeekCompleteListener: OnSeekCompleteListener = {
      onSeekComplete: () => {
        const pos = this.ijk.getCurrentPosition();
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `onSeekComplete — currentPosition=${pos}ms`);
        // seek 完成后立即触发一次 onTimeUpdate，使外置字幕无需等待下个 tick 就能重定位
        // 最差恢复时延从 ~500ms 降到 seek 完成延迟（通常 <100ms）—— #17
        this._currentTime = pos;
        if (this._onTimeUpdateCb) { this._onTimeUpdateCb(pos); }
        if (this._onSeekDoneCb) { this._onSeekDoneCb(); }
      }
    };
    this.ijk.setOnSeekCompleteListener(onSeekCompleteListener);

    // onInfo: 10008 在部分 HEVC 片源会形成高频事件风暴，默认不桥接到 JS 层。
    if (ENABLE_IJK_INFO_CALLBACK) {
      const onInfoListener: OnInfoListener = {
        onInfo: (what: number, extra: number) => {
          // 700=BUFFERING_START, 701=BUFFERING_END, 703=NETWORK_BANDWIDTH
          // 10008(FFP_MSG_VIDEO_SEEK_RENDERING_START)在部分片源会高频出现，按次数抽样打印。
          if (what === 10008) {
            this._seekRenderingInfoCount++;
            if (this._seekRenderingInfoCount % 30 === 0) {
              hilog.info(CommonConstants.LOG_DOMAIN, TAG,
                `onInfo(抽样) — what=${what} extra=${extra} count=${this._seekRenderingInfoCount}`);
            }
            return;
          }
          hilog.info(CommonConstants.LOG_DOMAIN, TAG, `onInfo — what=${what} extra=${extra}`);
        }
      };
      this.ijk.setOnInfoListener(onInfoListener);
    } else {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        '已禁用 onInfo 回调桥接（诊断模式）');
    }

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
   * 启动定时器，每 100ms 轮询 getCurrentPosition()
   * IjkPlayer 没有 timeUpdate 事件，必须用轮询实现。
   * 100ms 间隔满足字幕偏差 P95 ≤ 120ms 目标（#17）；
   * seek 后 onSeekComplete 会额外触发一次立即刷新，保证恢复时延 ≤ 200ms。
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
      try {
        // 修复: onPrepared 时 getDuration() 可能返回 0（部分流媒体格式 duration 延迟就绪），
        // 在每次轮询 tick 中补偿获取，确保 VideoPlayerController.onTimeUpdate 能读到有效值。
        if (this._duration <= 0) {
          const lateDuration = this.ijk.getDuration();
          if (lateDuration > 0) {
            this._duration = lateDuration;
            hilog.info(CommonConstants.LOG_DOMAIN, TAG,
              `[timeUpdate] duration 延迟就绪: ${this._duration}ms session=${this._sessionId}`);
          }
        }
        const pos = this.ijk.getCurrentPosition();
        if (pos !== this._currentTime) {
          this._currentTime = pos;
          const now = Date.now();
          if (now - this._lastHeartbeatWriteAt >= 30000) {
            this._lastHeartbeatWriteAt = now;
            this.writeBreadcrumb('play-heartbeat', `pos=${pos}`);
          }
          if (this._onTimeUpdateCb) {
            this._onTimeUpdateCb(pos);
          }
        }
      } catch (e) {
        hilog.error(CommonConstants.LOG_DOMAIN, TAG,
          `timeUpdate 轮询异常，停止定时器: ${JSON.stringify(e)} session=${this._sessionId}`);
        this.writeBreadcrumb('timeupdate-error', JSON.stringify(e));
        this.stopTimeUpdateTimer();
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

  /** 解析 getMediaInfo().meta，提取内嵌字幕流列表（仅供调研探针使用） */
  private parseIjkSubtitleMeta(meta: string): IjkSubtitleStreamInfo[] {
    const streams: IjkSubtitleStreamInfo[] = [];
    if (!meta || meta.length === 0) {
      return streams;
    }
    const parts = meta.split(';');
    const keys: string[] = [];
    const vals: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i].trim();
      const commaIdx = part.indexOf(',value:');
      if (commaIdx < 0) {
        continue;
      }
      const keyPart = part.substring(0, commaIdx);
      const valPart = part.substring(commaIdx + 7);
      if (keyPart.startsWith('key:')) {
        keys.push(keyPart.substring(4));
        vals.push(valPart);
      }
    }
    let streamIdx = 0;
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] === 'type' && vals[i] === 'timedtext') {
        const ws = Math.max(0, i - 5);
        const we = Math.min(keys.length - 1, i + 15);
        let codecName = 'subrip';
        let language = '';
        for (let j = ws; j <= we; j++) {
          if (keys[j] === 'codec_name') { codecName = vals[j]; }
          else if (keys[j] === 'language') { language = vals[j]; }
        }
        const stream: IjkSubtitleStreamInfo = { streamIndex: streamIdx, language, codecName };
        streams.push(stream);
        streamIdx++;
      }
    }
    return streams;
  }
}









