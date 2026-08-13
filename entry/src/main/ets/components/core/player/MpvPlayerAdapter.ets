import { IPlayer, SubtitleInfo, TrackInfo } from './IPlayer';
import { VideoData } from './VideoData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CommonConstants } from '../../../common/constants/CommonConstants';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  createPlayer,
  VidAllPlayer,
  XComponentSurfaceAdapter,
  VidAllPlayerSurfaceTarget,
  PlayerEvent,
  PlayerTrack,
  PlayerTrackKind,
  MediaSource,
  PlayerOptions
} from '@vidall/player';

const TAG = '[MpvPlayerAdapter]';

/** PGS / VobSub 编解码器名称 — 图形字幕需 mpv 内嵌合成。 */
const MPV_GRAPHIC_SUBTITLE_CODECS: string[] = [
  'hdmv_pgs_subtitle',
  'vobsub',
  'dvd_subtitle'
];

/** MediaSource.kind 的合法值联合类型 */
type MediaSourceKind = 'localFile' | 'http' | 'https' | 'hls' | 'dash' | 'localhostProxy' | 'smb';

/**
 * MPV 播放内核适配器
 *
 * 实现 IPlayer 接口，封装 @vidall/player (libmpv) 的所有操作。
 *
 * MPV surface 接入的关键点：
 * 1. XComponent 使用 XComponentController 模式拿 surfaceId（非 libraryname），
 *    通过 XComponentSurfaceAdapter 管理 attachSurface/resizeSurface/detachSurface 生命周期。
 * 2. 无需定时器轮询 currentTime — position 事件由 mpv time-pos 属性驱动。
 * 3. 字幕默认不选中（由 TV 端 SubtitleBridgeAdapter 绘制），
 *    仅 PGS/VobSub 图形字幕自动选中让 mpv 内嵌合成。
 * 4. 轨道 ID 使用 SDK 内部 PlayerTrack.id，绕过 ffprobe preset 体系。
 * 5. seek 使用 seekPercent 或 seekRelative，无绝对毫秒 seek。
 */
export class MpvPlayerAdapter implements IPlayer {
  // ─── 内部实例 ───
  private player: VidAllPlayer;
  private surfaceAdapter: XComponentSurfaceAdapter;
  private unsubscribe?: () => void;

  // ─── 状态 ───
  private _duration: number = 0;
  private _durationHintMs: number = 0;
  private _currentTime: number = 0;
  private _isPrepared: boolean = false;
  private _isPlaying: boolean = false;
  private _isReleased: boolean = false;
  /** play() 因内部状态未就绪被拒绝时置 true，等 state 变为 paused 后自动重试 */
  private _pendingPlay: boolean = false;

  // ─── 轨道缓存 ───
  private _cachedTracks: PlayerTrack[] = [];
  /**
   * 字幕轨道 id 偏移量。VidAll_Player HAR 中 NATIVE_TRACK_ID_OFFSET=100000，
   * 且不同 kind（video/audio/subtitle）的 native id 独立从 1 开始编号，
   * 导致 etsId = offset + nativeId 可能冲突（如 video id=1, audio id=1, subtitle id=1
   * 均映射到 etsId=100001）。
   * 为避免 selectTrack 时 id 冲突，在 getTrackInfos 输出时给字幕轨道加上此偏移，
   * 在 selectTrack 收到带偏移的 id 时还原为原始 etsId 并限定 kind='subtitle'。
   */
  private static readonly SUBTITLE_ID_OFFSET: number = 500000;

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
  private _onSubtitleUpdateCb?: (info: SubtitleInfo) => void;
  private _onBufferingCb?: (isBuffering: boolean) => void;

  // ─── 内嵌字幕回调（由 VideoPlayerController 注入）───
  private _onEmbeddedSubtitleCb: ((text: string) => void) | null = null;

  // ─── seek Promise 追踪 ───
  private _pendingSeekCount: number = 0;

  // ─── seek 完成确认追踪 ───
  // mpv_command_async 的 Promise 只表示命令入队成功，不代表 seek 完成。
  // 需要 position 事件确认到达目标位置后才触发 onSeekCompleted。
  private _seekTargetMs: number = -1;
  private _waitingForSeekCompletion: boolean = false;
  private _seekStartTime: number = 0;
  /** seek 超时阈值（ms），超时后强制触发 onSeekCompleted 防卡死 */
  private static readonly SEEK_CONFIRM_TIMEOUT_MS: number = 3000;
  /** seek 位置确认容差（ms），position 在目标 ± 容差内视为 seek 完成 */
  private static readonly SEEK_POSITION_TOLERANCE_MS: number = 2000;

  /** 标记 preparing 时是否已设置 sid=no + sub-visibility=no，避免重复调用 */
  private _subtitleVisibilityDisabled: boolean = false;

  constructor() {
    const options: PlayerOptions = {
      hardwareDecoding: 'auto'
    };
    this.player = createPlayer(options);
    const surfaceTarget: VidAllPlayerSurfaceTarget = new VidAllPlayerSurfaceTarget(this.player);
    this.surfaceAdapter = new XComponentSurfaceAdapter(surfaceTarget);
    hilog.info(CommonConstants.LOG_DOMAIN, TAG, '构造完成，等待 XComponent onLoad 绑定 surface');
  }

  // ─── 公开方法（供 VideoPlayerController 调用）───

  /**
   * 获取 XComponentSurfaceAdapter，供 VideoPlayer.ets 的 XComponent 生命周期回调使用。
   */
  getSurfaceAdapter(): XComponentSurfaceAdapter {
    return this.surfaceAdapter;
  }

  /** 注册内嵌字幕回调（subtitleText → SubtitleBridgeAdapter.onEmbeddedTimedText） */
  setOnEmbeddedSubtitleCallback(cb: (text: string) => void): void {
    this._onEmbeddedSubtitleCb = cb;
  }

  // ─── IPlayer 属性 ───

  get duration(): number {
    return this._duration;
  }

  get currentTime(): number {
    return this._currentTime;
  }

  // ─── 生命周期 ───

  async init(videoData: VideoData, surfaceId: string): Promise<void> {
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `init 开始 — type=${videoData.type} src=${videoData.videoSrc.substring(0, 80)}`);

    this._isPrepared = false;
    this._isPlaying = false;
    this._pendingPlay = false;
    this._duration = 0;
    this._durationHintMs = videoData.durationHintMs ?? 0;
    this._currentTime = 0;
    this._isReleased = false;
    this._cachedTracks = [];
    this._pendingSeekCount = 0;
    this._seekTargetMs = -1;
    this._waitingForSeekCompletion = false;
    this._seekStartTime = 0;
    this._subtitleVisibilityDisabled = false;

    // 注册事件监听（在 attachSurface 之前，确保不遗漏事件）
    this.registerEventListeners();

    try {
      // Step 1: XComponent onLoad 时已由 VideoPlayer.ets 调用 surfaceAdapter.onLoad()
      // 此处 surfaceId 由 XComponentController.getXComponentSurfaceId() 获得。
      // attachSurface 由 surfaceAdapter.onLoad 内部完成，无需手动调用。

      // Step 2: 构造 MediaSource 并 load
      const source: MediaSource = this.buildMediaSource(videoData);
      await this.player.load(source);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'load() 已调用，等待 prepared 事件...');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `init 异常: ${err.message ?? String(e)}`);
      throw new Error(`MpvPlayerAdapter init failed: ${err.message ?? 'unknown'}`);
    }
  }

  async play(): Promise<void> {
    if (this._isReleased) {
      return;
    }
    this._pendingPlay = false;
    try {
      await this.player.play();
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'play() 已调用');
    } catch (e) {
      const err = e as BusinessError;
      const msg = err.message ?? '';
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `play() 异常: ${msg}`);
      // VidAll_Player 在 seek 后内部状态未稳定时会拒绝 play()，
      // 设置 _pendingPlay 标志，等 state 变为 paused/playing 后自动重试
      if (msg.includes('prepared') || msg.includes('paused') || msg.includes('buffering') ||
          msg.includes('media') || msg.includes('state')) {
        this._pendingPlay = true;
        hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'play() 已标记 _pendingPlay，等待 state 事件后自动重试');
      }
    }
  }

  async pause(): Promise<void> {
    if (this._isReleased) {
      return;
    }
    // 主动暂停时清除 _pendingPlay，避免 pause 触发 paused 事件后自动重试 play
    this._pendingPlay = false;
    try {
      await this.player.pause();
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'pause() 已调用');
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `pause() 异常: ${err.message ?? 'unknown'}`);
    }
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
    // 取消事件订阅
    if (this.unsubscribe !== undefined) {
      this.unsubscribe();
      this.unsubscribe = undefined;
    }
    // 释放 surface
    try {
      await this.surfaceAdapter.onDestroy();
    } catch (e) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `surfaceAdapter.onDestroy 异常: ${String(e)}`);
    }
    try {
      await this.player.release();
    } catch (e) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `player.release() 异常: ${String(e)}`);
    }
    this._isReleased = true;
    this._isPrepared = false;
    this._isPlaying = false;
    this._pendingPlay = false;
    this._waitingForSeekCompletion = false;
    this._seekTargetMs = -1;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'release() 完成');
  }

  // ─── 播放控制 ───

  seek(timeMs: number): void {
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `seek() 入口: timeMs=${timeMs} currentTime=${this._currentTime} isPrepared=${this._isPrepared} isReleased=${this._isReleased} duration=${this._duration} hint=${this._durationHintMs} isPlaying=${this._isPlaying}`);
    if (this._isReleased) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, 'seek() 忽略：已 release');
      this.onSeekCompleted();
      return;
    }
    if (!this._isPrepared) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, 'seek() 忽略：尚未 prepared，触发 onSeekCompleted 防止 isSeeking 卡死');
      this.onSeekCompleted();
      return;
    }
    // seek 时清除 _pendingPlay，避免 seek 过程中 state 变化触发意外 play
    this._pendingPlay = false;

    // seekPercent 为绝对定位（基于 duration），不依赖 _currentTime，
    // 且原生参数范围是 0~100（百分比数值），适配器内部完成 0~1 → 0~100 换算。
    this.seekPercentImpl(timeMs);
  }

  /**
   * 基于百分比的 seek 实现（主路径）
   * 注意：MPV HAR 的 seekPercent 原生参数单位为 0~100（百分比数值），
   * 代码内部用 0~1 的小数表示比例，调用前必须乘以 100。
   * 传入 0~1 的小数会被原生层当作 0.X% 处理，导致 seek 目标缩小 100 倍
   * （如 seekPercent(0.123154) 实际只 seek 到 0.12% 对应的位置）。
   */
  private seekPercentImpl(timeMs: number): void {
    let effectiveDuration = this._duration;
    if (effectiveDuration <= 0 && this._durationHintMs > 0) {
      effectiveDuration = this._durationHintMs;
    }
    if (effectiveDuration <= 0) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `seekPercent: 无法获取 duration(${this._duration})，hint=${this._durationHintMs}，fallback 到 seekRelative`);
      this.seekRelativeFallback(timeMs);
      return;
    }
    let percent = timeMs / effectiveDuration;
    if (percent < 0) {
      percent = 0;
    }
    if (percent > 1) {
      percent = 1;
    }
    // 原生 seekPercent 参数为 0~100，必须在内部换算
    const percentScale = percent * 100;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `seek(${timeMs}ms) → seekPercent(${percentScale.toFixed(4)} → 0-100) [duration=${effectiveDuration} currentTime=${this._currentTime}]`);
    this._pendingSeekCount += 1;
    // 记录 seek 目标，等待 position 事件确认后再触发 onSeekCompleted
    this._seekTargetMs = timeMs;
    this._waitingForSeekCompletion = true;
    this._seekStartTime = Date.now();
    this.player.seekPercent(percentScale).then(() => {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `seekPercent(${percentScale.toFixed(4)}) 命令已提交，等待 position 确认 seek 完成`);
      // 不立即触发 onSeekCompleted，由 handlePositionEvent 或超时兜底触发
      this.checkSeekCompletionOrTimeout();
    }).catch((seekErr: BusinessError) => {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `seekPercent(${percentScale.toFixed(4)}) 异常: ${seekErr.message ?? 'unknown'}，fallback 到 seekRelative`);
      // seek 失败时清除等待状态，fallback 路径自己管理
      this._waitingForSeekCompletion = false;
      this._seekTargetMs = -1;
      this.onSeekCompleted();
      this.seekRelativeFallback(timeMs);
    });
  }

  /**
   * seekPercent 失败或 duration 不可用时的 fallback：使用 seekRelative(相对偏移)
   */
  private seekRelativeFallback(timeMs: number): void {
    const relativeMs = timeMs - this._currentTime;
    const relativeSeconds = relativeMs / 1000;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `seekRelative fallback: seek(${timeMs}ms) → seekRelative(${relativeSeconds.toFixed(3)}s) [currentTime=${this._currentTime}]`);
    this._pendingSeekCount += 1;
    // 记录 seek 目标，等待 position 确认
    this._seekTargetMs = timeMs;
    this._waitingForSeekCompletion = true;
    this._seekStartTime = Date.now();
    this.player.seekRelative(relativeSeconds).then(() => {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `seekRelative(${relativeSeconds.toFixed(3)}s) 命令已提交，等待 position 确认 seek 完成`);
      this.checkSeekCompletionOrTimeout();
    }).catch(() => {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `seekRelative fallback 也失败，放弃本次 seek`);
      this._waitingForSeekCompletion = false;
      this._seekTargetMs = -1;
      this.onSeekCompleted();
    });
  }

  async forward(milliseconds: number): Promise<void> {
    if (!this._isPrepared || this._isReleased) {
      return;
    }
    // seekRelative 前清除 _pendingPlay，避免竞态
    this._pendingPlay = false;
    const seconds = milliseconds / 1000;
    this._pendingSeekCount += 1;
    // 估算 seek 目标位置
    this._seekTargetMs = this._currentTime + milliseconds;
    this._waitingForSeekCompletion = true;
    this._seekStartTime = Date.now();
    try {
      await this.player.seekRelative(seconds);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `forward(${milliseconds}ms) 命令已提交，等待 position 确认`);
      this.checkSeekCompletionOrTimeout();
    } catch (e) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `forward seekRelative 异常: ${String(e)}`);
      this._waitingForSeekCompletion = false;
      this._seekTargetMs = -1;
      this.onSeekCompleted();
    }
  }

  async backward(milliseconds: number): Promise<void> {
    if (!this._isPrepared || this._isReleased) {
      return;
    }
    // seekRelative 前清除 _pendingPlay，避免竞态
    this._pendingPlay = false;
    const seconds = -(milliseconds / 1000);
    this._pendingSeekCount += 1;
    // 估算 seek 目标位置
    this._seekTargetMs = this._currentTime - milliseconds;
    if (this._seekTargetMs < 0) {
      this._seekTargetMs = 0;
    }
    this._waitingForSeekCompletion = true;
    this._seekStartTime = Date.now();
    try {
      await this.player.seekRelative(seconds);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `backward(${milliseconds}ms) 命令已提交，等待 position 确认`);
      this.checkSeekCompletionOrTimeout();
    } catch (e) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `backward seekRelative 异常: ${String(e)}`);
      this._waitingForSeekCompletion = false;
      this._seekTargetMs = -1;
      this.onSeekCompleted();
    }
  }

  // ─── 轨道 ───

  async getTrackInfos(): Promise<TrackInfo[]> {
    const result: TrackInfo[] = [];
    for (let i = 0; i < this._cachedTracks.length; i++) {
      const t = this._cachedTracks[i];
      // video 轨道不暴露：VidAll_TV 不需要视频轨选择，且 video/audio/subtitle 的 etsId 冲突
      if (t.kind === 'video') {
        continue;
      }
      const codec = t.codec ?? '';
      const mimeType = this.trackCodecToMimeType(codec, t.kind);
      // 字幕轨道加偏移，避免与 audio 轨道 etsId 冲突
      const trackIndex = t.kind === 'subtitle'
        ? t.id + MpvPlayerAdapter.SUBTITLE_ID_OFFSET
        : t.id;
      const item: TrackInfo = {
        trackIndex: trackIndex,
        trackType: t.kind as 'video' | 'audio' | 'subtitle',
        mimeType: mimeType,
        language: t.language ?? '',
        codec: codec
      };
      // 调试：字幕轨道的 codec→mimeType 映射
      if (t.kind === 'subtitle') {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `getTrackInfos: subtitle etsId=${t.id} → trackIndex=${trackIndex} codec="${codec}" → mimeType="${mimeType}" lang="${t.language ?? ''}"`);
      }
      result.push(item);
    }
    return result;
  }

  async selectTrack(trackIndex: number): Promise<void> {
    // trackIndex 对应 PlayerTrack.id（SDK 内部 ID）
    // -1 表示关闭该类轨道
    if (trackIndex < 0) {
      // 找到当前选中的字幕轨道并取消选中
      const subTrack = this.findTrackByKindAndSelected('subtitle');
      if (subTrack !== null) {
        try {
          await this.player.selectTrack('subtitle', null);
          hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'selectTrack: 关闭字幕轨');
        } catch (e) {
          hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
            `selectTrack(null) 异常: ${String(e)}`);
        }
      }
      // 关闭字幕时恢复 sub-visibility，为下次选中图形字幕做准备
      try {
        await this.player.setPropertyString('sub-visibility', 'yes');
      } catch (e) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `setPropertyString('sub-visibility', 'yes') 异常: ${String(e)}`);
      }
      return;
    }
    // 检测是否为字幕轨道（带 SUBTITLE_ID_OFFSET 偏移）
    const isSubtitleTrack = trackIndex >= MpvPlayerAdapter.SUBTITLE_ID_OFFSET;
    const actualId = isSubtitleTrack ? trackIndex - MpvPlayerAdapter.SUBTITLE_ID_OFFSET : trackIndex;
    const targetKind: PlayerTrackKind = isSubtitleTrack ? 'subtitle' : 'audio';
    // VidAll_TV 仅对外暴露音频和字幕轨；非字幕 ID 始终按音频查找。
    // VidAll_Player 不同 kind 的 ID 可重叠，必须指定 kind 才能稳定命中。
    const track = this.findTrackById(actualId, targetKind);
    if (track === null) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `selectTrack(${trackIndex}): 未找到对应轨道 (actualId=${actualId} kind=${targetKind})`);
      return;
    }
    try {
      await this.player.selectTrack(track.kind, track.id);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `selectTrack: kind=${track.kind} id=${track.id} (input=${trackIndex})`);
      // 选中字幕轨时，判断是否为文本字幕：
      // 文本字幕 → 设置 sub-visibility=no，禁止 mpv 内嵌渲染，由 TV 端 SubtitleRenderer 统一渲染
      // 图形字幕 → 保持 sub-visibility=yes，让 mpv 内嵌合成到视频帧
      if (track.kind === 'subtitle') {
        const codec = (track.codec ?? '').toLowerCase();
        const isGraphic = this.isGraphicSubtitleCodec(codec);
        try {
          const visibility = isGraphic ? 'yes' : 'no';
          await this.player.setPropertyString('sub-visibility', visibility);
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `selectTrack: 字幕类型=${isGraphic ? '图形' : '文本'} codec=${codec} → sub-visibility=${visibility}`);
        } catch (e) {
          hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
            `setPropertyString('sub-visibility') 异常: ${String(e)}`);
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `selectTrack 异常: ${err.message ?? String(e)}`);
    }
  }

  setSubtitleDelay(delayMs: number): void {
    try {
      this.player.setSubtitleDelay(delayMs);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `setSubtitleDelay: ${delayMs}ms`);
    } catch (e) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `setSubtitleDelay 异常: ${String(e)}`);
    }
  }

  setPlaybackSpeed(speed: number): void {
    try {
      this.player.setRate(speed);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `setPlaybackSpeed: speed=${speed}`);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `setPlaybackSpeed(${speed}) 失败: ${err.message ?? 'unknown'}`);
    }
  }

  setPropertyString(property: string, value: string): void {
    try {
      this.player.setPropertyString(property, value);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `setPropertyString: ${property}=${value}`);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `setPropertyString(${property}=${value}) 失败: ${err.message ?? 'unknown'}`);
    }
  }

  /**
   * 禁止 mpv 自动选字幕轨并关闭内嵌渲染。
   * 在 preparing 状态时调用一次，防止 mpv 默认 sid=auto 选中首个字幕轨
   * 导致 mpv 内嵌渲染与 SubtitleAdapter 双层显示。
   */
  private disableSubtitleVisibility(): void {
    if (this._subtitleVisibilityDisabled) {
      return;
    }
    this._subtitleVisibilityDisabled = true;
    // 设置 sid=no 禁止 mpv 自动选中字幕轨
    this.player.setPropertyString('sid', 'no').then(() => {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'disableSubtitleVisibility: sid=no 设置成功');
    }).catch((e: BusinessError) => {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `disableSubtitleVisibility: sid=no 失败: ${e.message ?? 'unknown'}`);
    });
    // 同时关闭 sub-visibility，双重保险
    this.player.setPropertyString('sub-visibility', 'no').then(() => {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'disableSubtitleVisibility: sub-visibility=no 设置成功');
    }).catch((e: BusinessError) => {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `disableSubtitleVisibility: sub-visibility=no 失败: ${e.message ?? 'unknown'}`);
    });
  }

  // ─── 事件回调注册 ───

  onReady(callback: () => void): void { this._onReadyCb = callback; }
  onPlay(callback: () => void): void { this._onPlayCb = callback; }
  onPaused(callback: () => void): void { this._onPausedCb = callback; }
  onCompleted(callback: () => void): void { this._onCompletedCb = callback; }
  onStopped(callback: () => void): void { this._onStoppedCb = callback; }
  onTimeUpdate(callback: (currentTime: number) => void): void { this._onTimeUpdateCb = callback; }
  onError(callback: (error: Error) => void): void { this._onErrorCb = callback; }
  onUnsupportedFormat(callback: () => void): void { this._onUnsupportedFormatCb = callback; }
  onSeekDone(callback: () => void): void { this._onSeekDoneCb = callback; }
  onSubtitleUpdate(callback: (info: SubtitleInfo) => void): void { this._onSubtitleUpdateCb = callback; }
  onBuffering(callback: (isBuffering: boolean) => void): void { this._onBufferingCb = callback; }

  // ─── 内部实现 ───

  private onSeekCompleted(): void {
    if (this._pendingSeekCount > 0) {
      this._pendingSeekCount -= 1;
    }
    if (this._pendingSeekCount === 0 && this._onSeekDoneCb) {
      this._onSeekDoneCb();
    }
  }

  /**
   * seek 命令提交后，检查当前 position 是否已满足 seek 完成条件；
   * 若不满足，启动超时兜底定时器。
   * 由于 mpv_command_async 的 Promise 在命令入队时就 resolve，
   * 此时 position 可能还没更新，需要等待下一个 position 事件。
   */
  private checkSeekCompletionOrTimeout(): void {
    if (!this._waitingForSeekCompletion) {
      return;
    }
    // 如果当前位置已满足条件，立即触发
    if (this._seekTargetMs >= 0) {
      const diff = Math.abs(this._currentTime - this._seekTargetMs);
      if (diff <= MpvPlayerAdapter.SEEK_POSITION_TOLERANCE_MS) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `seek 立即确认: position=${this._currentTime}ms 目标=${this._seekTargetMs}ms 差值=${diff}ms`);
        this._waitingForSeekCompletion = false;
        this._seekTargetMs = -1;
        this.onSeekCompleted();
        return;
      }
    }
    // position 还没更新到目标，启动超时兜底
    const elapsed = Date.now() - this._seekStartTime;
    const remaining = MpvPlayerAdapter.SEEK_CONFIRM_TIMEOUT_MS - elapsed;
    if (remaining <= 0) {
      // 已超时，强制触发
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `seek 超时(${elapsed}ms)，强制触发 onSeekCompleted，目标=${this._seekTargetMs}ms 当前=${this._currentTime}ms`);
      this._waitingForSeekCompletion = false;
      this._seekTargetMs = -1;
      this.onSeekCompleted();
      return;
    }
    // 延迟超时检查：用 setTimeout 模拟超时兜底
    setTimeout(() => {
      if (this._waitingForSeekCompletion) {
        const elapsed2 = Date.now() - this._seekStartTime;
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `seek 超时兜底(${elapsed2}ms)，强制触发 onSeekCompleted，目标=${this._seekTargetMs}ms 当前=${this._currentTime}ms`);
        this._waitingForSeekCompletion = false;
        this._seekTargetMs = -1;
        this.onSeekCompleted();
      }
    }, remaining);
  }

  private registerEventListeners(): void {
    if (this.unsubscribe !== undefined) {
      this.unsubscribe();
    }
    this.unsubscribe = this.player.subscribe((event: PlayerEvent) => {
      this.handlePlayerEvent(event);
    });
  }

  private handlePlayerEvent(event: PlayerEvent): void {
    if (this._isReleased) {
      return;
    }
    const eventType = event.type;
    switch (eventType) {
      case 'state':
        this.handleStateEvent(event);
        break;
      case 'position':
        this.handlePositionEvent(event);
        break;
      case 'buffering':
        this.handleBufferingEvent(event);
        break;
      case 'tracks':
        this.handleTracksEvent(event);
        break;
      case 'subtitleText':
        this.handleSubtitleTextEvent(event);
        break;
      case 'error':
        this.handleErrorEvent(event);
        break;
      case 'videoParams':
        // 可用于后续 DAR / 硬解状态上报
        break;
      default:
        break;
    }
  }

  private handleStateEvent(event: PlayerEvent): void {
    const state = event.state;
    if (state === undefined) {
      return;
    }
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `state 事件: ${state}`);
    switch (state) {
      case 'preparing':
        // mpv 正在准备，还未 prepared
        // 立即禁止自动选字幕轨 + 关闭内嵌渲染，避免 mpv 默认 sid=auto 选中首个字幕轨
        // 导致 mpv 内嵌渲染 + SubtitleAdapter 双层显示
        this.disableSubtitleVisibility();
        break;
      case 'playing':
        this._isPlaying = true;
        if (this._pendingPlay) {
          // play() 之前被拒绝，但 libmpv 已自动进入 playing，清除标志
          this._pendingPlay = false;
          hilog.info(CommonConstants.LOG_DOMAIN, TAG, '_pendingPlay 清除: libmpv 已自动进入 playing');
        }
        if (!this._isPrepared) {
          this._isPrepared = true;
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `onReady 触发: duration=${this._duration} hint=${this._durationHintMs}`);
          if (this._onReadyCb) { this._onReadyCb(); }
        }
        if (this._onPlayCb) { this._onPlayCb(); }
        break;
      case 'paused':
        this._isPlaying = false;
        if (this._pendingPlay) {
          // play() 之前被拒绝（seek 后内部状态未就绪），现在状态已稳定，自动重试
          this._pendingPlay = false;
          hilog.info(CommonConstants.LOG_DOMAIN, TAG, '_pendingPlay 触发: state=paused，自动重试 play()');
          this.player.play().catch((retryErr: BusinessError) => {
            hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
              `play() 自动重试失败: ${retryErr.message ?? 'unknown'}`);
          });
        }
        if (!this._isPrepared) {
          this._isPrepared = true;
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `onReady 触发(paused): duration=${this._duration} hint=${this._durationHintMs}`);
          if (this._onReadyCb) { this._onReadyCb(); }
        }
        if (this._onPausedCb) { this._onPausedCb(); }
        break;
      case 'completed':
        this._isPlaying = false;
        if (this._onCompletedCb) { this._onCompletedCb(); }
        break;
      case 'idle':
        // stop 后或初始状态
        if (this._isPrepared) {
          if (this._onStoppedCb) { this._onStoppedCb(); }
        }
        break;
      case 'error':
        // error 事件单独处理（PlayerEventType.error）
        break;
      default:
        break;
    }
  }

  private handlePositionEvent(event: PlayerEvent): void {
    const positionMs = event.positionMs ?? 0;
    const durationMs = event.durationMs ?? 0;
    this._currentTime = positionMs;
    if (durationMs > 0) {
      if (this._duration <= 0) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `position 事件首次设置 duration: ${durationMs}`);
      }
      this._duration = durationMs;
    }
    // 检查 seek 是否完成：position 接近目标位置时触发 onSeekCompleted
    if (this._waitingForSeekCompletion && this._seekTargetMs >= 0) {
      const diff = Math.abs(positionMs - this._seekTargetMs);
      if (diff <= MpvPlayerAdapter.SEEK_POSITION_TOLERANCE_MS) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `seek 完成确认: position=${positionMs}ms 目标=${this._seekTargetMs}ms 差值=${diff}ms → onSeekCompleted`);
        this._waitingForSeekCompletion = false;
        this._seekTargetMs = -1;
        this.onSeekCompleted();
      }
    }
    if (this._onTimeUpdateCb) {
      this._onTimeUpdateCb(positionMs);
    }
  }

  private handleBufferingEvent(_event: PlayerEvent): void {
    if (this._onBufferingCb) {
      // @vidall/player 的 buffering 事件：有 event 意味着正在缓冲
      this._onBufferingCb(true);
    }
  }

  private handleTracksEvent(event: PlayerEvent): void {
    const tracks = event.tracks;
    if (tracks === undefined) {
      return;
    }
    this._cachedTracks = tracks;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `tracks 事件: ${tracks.length} 条轨道`);
    // 字幕选轨统一由 SubtitleBridgeAdapter 管理
    // 不再在此处 autoSelectFirstGraphicSubtitle，避免与 SubtitleBridgeAdapter 冲突
  }

  private handleSubtitleTextEvent(event: PlayerEvent): void {
    const text = event.subtitleText ?? '';
    // 透传到 VideoPlayerController → SubtitleBridgeAdapter.onEmbeddedTimedText
    if (this._onEmbeddedSubtitleCb) {
      this._onEmbeddedSubtitleCb(text);
    }
    // 同时触发 IPlayer.onSubtitleUpdate（兼容接口）
    if (this._onSubtitleUpdateCb) {
      const info: SubtitleInfo = {
        text: text,
        startTime: this._currentTime,
        duration: 0
      };
      this._onSubtitleUpdateCb(info);
    }
  }

  private handleErrorEvent(event: PlayerEvent): void {
    const playerError = event.error;
    if (playerError === undefined) {
      return;
    }
    hilog.error(CommonConstants.LOG_DOMAIN, TAG,
      `error 事件: domain=${playerError.domain} code=${playerError.code} msg=${playerError.message}`);
    // 格式不支持时触发 onUnsupportedFormat
    // 仅当 domain='media' 且错误码指向解码/格式问题时触发，避免将网络/IO错误误判为格式不支持
    if (playerError.domain === 'media' && this.isUnsupportedFormatCode(playerError.code)) {
      if (this._onUnsupportedFormatCb) {
        this._onUnsupportedFormatCb();
        return;
      }
    }
    if (this._onErrorCb) {
      this._onErrorCb(new Error(playerError.message));
    }
  }

  /** 判断错误码是否指向格式不支持/解码失败 */
  private isUnsupportedFormatCode(code: string): boolean {
    // @vidall/player PlayerError.code 为字符串类型
    // 常见格式不支持错误码：'FORMAT_UNSUPPORTED'、'CODEC_NOT_FOUND' 等
    // 数值型错误码：> 0 且 < 200 视为格式/解码问题
    const upperCode = code.toUpperCase();
    if (upperCode.includes('UNSUPPORTED') || upperCode.includes('CODEC') ||
      upperCode.includes('FORMAT') || upperCode.includes('DECODE')) {
      return true;
    }
    const numVal = Number.parseInt(upperCode, 10);
    if (!Number.isNaN(numVal) && numVal > 0 && numVal < 200) {
      return true;
    }
    return false;
  }

  private isGraphicSubtitleCodec(codec: string): boolean {
    for (let i = 0; i < MPV_GRAPHIC_SUBTITLE_CODECS.length; i++) {
      if (codec.includes(MPV_GRAPHIC_SUBTITLE_CODECS[i])) {
        return true;
      }
    }
    return false;
  }

  private buildMediaSource(videoData: VideoData): MediaSource {
    const src = videoData.videoSrc;
    const headers = videoData.httpHeader;
    let kind: MediaSourceKind = 'http';
    if (src.startsWith('smb://')) {
      kind = 'smb';
    } else if (src.startsWith('https://')) {
      kind = 'https';
    } else if (src.startsWith('http://')) {
      // 区分本地代理和普通 HTTP
      if (src.includes('127.0.0.1') || src.includes('localhost')) {
        kind = 'localhostProxy';
      } else {
        kind = 'http';
      }
    } else if (src.startsWith('file://')) {
      kind = 'localFile';
    }

    const source: MediaSource = {
      kind: kind,
      uri: src
    };
    // 添加 HTTP headers（WebDAV 认证等）
    if (headers !== undefined && headers !== null) {
      const headerKeys = Object.keys(headers);
      if (headerKeys.length > 0) {
        source.headers = headers as Record<string, string>;
      }
    }
    return source;
  }

  /**
   * 按 id 查找缓存轨道。可选指定 kind 以避免 etsId 冲突：
   * VidAll_Player HAR 中 NATIVE_TRACK_ID_OFFSET=100000，不同 kind 的 native id
   * 可能重复（如 video native id=1 → etsId=100001，audio native id=1 → etsId=100001），
   * 指定 kind 可精确匹配目标轨道。
   */
  private findTrackById(id: number, kind?: PlayerTrackKind): PlayerTrack | null {
    for (let i = 0; i < this._cachedTracks.length; i++) {
      const t = this._cachedTracks[i];
      if (t.id === id && (kind === undefined || t.kind === kind)) {
        return t;
      }
    }
    // kind 精确匹配未找到时，降级到仅 id 匹配
    if (kind !== undefined) {
      for (let i = 0; i < this._cachedTracks.length; i++) {
        if (this._cachedTracks[i].id === id) {
          return this._cachedTracks[i];
        }
      }
    }
    return null;
  }

  private findTrackByKindAndSelected(kind: PlayerTrackKind): PlayerTrack | null {
    for (let i = 0; i < this._cachedTracks.length; i++) {
      const t = this._cachedTracks[i];
      if (t.kind === kind && t.selected) {
        return this._cachedTracks[i];
      }
    }
    return null;
  }

  private trackCodecToMimeType(codec: string, kind: PlayerTrackKind): string {
    if (kind === 'audio') {
      const audioMap: Record<string, string> = {
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
        'pcm_s24le': 'audio/raw',
        'pcm_s32le': 'audio/raw'
      };
      const lower = codec.toLowerCase();
      for (const key of Object.keys(audioMap)) {
        if (lower.includes(key)) {
          return audioMap[key];
        }
      }
      return `audio/${codec}`;
    }
    if (kind === 'subtitle') {
      const subMap: Record<string, string> = {
        'subrip': 'application/x-subrip',
        'srt': 'application/x-subrip',
        'ass': 'text/x-ssa',
        'ssa': 'text/x-ssa',
        'sub': 'text/vtt',
        'hdmv_pgs_subtitle': 'image/pgs',
        'dvd_subtitle': 'image/vobsub',
        'vobsub': 'image/vobsub'
      };
      const lower = codec.toLowerCase();
      for (const key of Object.keys(subMap)) {
        if (lower.includes(key)) {
          return subMap[key];
        }
      }
      return `application/x-subtitle-${codec}`;
    }
    if (kind === 'video') {
      const videoMap: Record<string, string> = {
        'h264': 'video/avc',
        'hevc': 'video/hevc',
        'vp8': 'video/vp8',
        'vp9': 'video/vp9',
        'av1': 'video/av1',
        'mpeg4': 'video/mp4v-es'
      };
      const lower = codec.toLowerCase();
      for (const key of Object.keys(videoMap)) {
        if (lower.includes(key)) {
          return videoMap[key];
        }
      }
      return `video/${codec}`;
    }
    return '';
  }
}