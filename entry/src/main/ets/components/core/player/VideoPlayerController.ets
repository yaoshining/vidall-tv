import { PlayerEvents, VideoDataType } from "./Constants";
import { VideoData } from "./VideoData";
import { BusinessError, emitter } from "@kit.BasicServicesKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { display } from '@kit.ArkUI';
import { CommonConstants } from "../../../common/constants/CommonConstants";
import { millisecondsToTime } from "../../../utils/TimeUtil";
import { IPlayer, TrackInfo } from "./IPlayer";
import { AVPlayerAdapter } from "./AVPlayerAdapter";
import { MpvPlayerAdapter } from "./MpvPlayerAdapter";
import { VidAllPlayerAdapter } from "./VidAllPlayerAdapter";
import { FileSourceDatabase } from "../../../db/files/FileSourceDatabase";
import { PlayProgressEntity } from "../../../db/models/MediaEntity";
import { FfprobeUtil } from "../../../utils/FfprobeUtil";
import {
  AvSubtitleBridgeAdapter,
  BaseSubtitleBridgeAdapter,
  ISubtitleBridgeAdapter,
  MpvSubtitleBridgeAdapter,
  NoSubtitleBridgeAdapter,
  SubtitleBridgeState,
  SubtitleTrackItem
} from "./SubtitleBridgeAdapter";
import { VpeEnhancerUtil, VpeQualityLevel } from "../../../utils/VpeEnhancerUtil";
import { ParsedSubtitle } from "./SubtitleRenderer";
import { PlaybackContext } from "./PlaybackContext";
import {
  DEFAULT_EPISODE_AUTOPLAY_COUNTDOWN_SECONDS,
  DEFAULT_EPISODE_AUTOPLAY_ENABLED
} from "./EpisodeAutoplayPreferences";
import { MetricsService } from "../../../services/metrics/MetricsService";
import { MediaIdentity } from "../../../services/metrics/MetricsReporter";
import { SubtitleDispatcher, SubtitleCacheContext } from "../../../subtitle/SubtitleDispatcher";
import { AudioDispatcher } from "../../../audio/AudioDispatcher";
// ─── Runtime session services (Module 4: refactor-player-runtime-session-services) ───
import { playbackBackendService, PlaybackBackendService } from
  "../../../services/playback/PlaybackBackendService";
import type { PlaybackBackendDecision } from
  "../../../services/playback/PlaybackBackendTypes";
import { SubtitleSessionService } from
  "../../../services/subtitleSession/SubtitleSessionService";
import {
  audioTrackRoutingService,
  AudioTrackRoutingService,
  findInitialAudioTrackIndex as serviceFindInitialAudioTrackIndex
} from "../../../services/audioRouting/AudioTrackRoutingService";
import type { AudioRoutingDecision } from "../../../services/audioRouting/AudioRoutingTypes";
import { audioDecoderCapabilityService } from "../../../services/audioCapability/AudioDecoderCapabilityService";
import { PlaybackState } from "./PlaybackState";
import { ReloadSession } from "./ReloadSession";
import {
  ResumeSession,
  PendingResumeState,
  ResumeAutoplayDecision,
  PendingResumeAutoplayResultState
} from "./ResumeSession";

export type { SubtitleTrackItem } from "./SubtitleBridgeAdapter";

/** 播放内核类型 */
export type PlayerBackend = 'avplayer' | 'mpv';

export function resolveAiEnhanceEnabledByRuntime(runtimeSupported: boolean, requestedEnabled: boolean): boolean {
  return runtimeSupported && requestedEnabled;
}

/** 判断视频 HDR 类型是否属于 HDR（HDR10/HLG/Dolby Vision）。undefined/''/'SDR' 均为 false。 */
export function isHdrVideo(hdrType: string | undefined): boolean {
  return hdrType === 'HDR10' || hdrType === 'HLG' || hdrType === 'DOLBY_VISION';
}

export function shouldShowAiEnhanceSettingsByRuntime(
  runtimeSupported: boolean,
  backend: PlayerBackend,
  isHdr: boolean = false
): boolean {
  return runtimeSupported && backend === 'avplayer' && !isHdr;
}

export function resolveEffectivePlaybackSurfaceId(displaySurfaceId: string, vpeSurfaceId: string): string {
  if (vpeSurfaceId.length > 0) {
    return vpeSurfaceId;
  }
  return displaySurfaceId;
}

// ─── VPE 画质增强：按缩放比例自动选档 ──────────────────────────

/** Detail Enhancer 输入分辨率硬约束（来自官方《视频缩放》文档）：宽高上限。 */
export const VPE_SOURCE_MAX_DIMENSION = 2000;
/** Detail Enhancer 输入分辨率硬约束：宽高下限。 */
export const VPE_SOURCE_MIN_DIMENSION = 32;
/** 缩放比例阈值：达到该值前使用 LOW 档，之后使用 MEDIUM 档（最高档，保留鸿鹄动画）。 */
export const VPE_SCALE_MEDIUM_THRESHOLD = 1.5;

/** 显示目标尺寸（物理像素）。 */
export interface DisplaySize {
  width: number;
  height: number;
}

/**
 * 按缩放比例解析 VPE 画质增强档位。
 *
 * 返回 null 仅表示「无法启用」（源分辨率超出 Detail Enhancer 输入硬约束）；
 * 其余情况都返回一个档位，最低为 low（用户开启即生效）。
 * 缩放比例 = max(显示宽/源宽, 显示高/源高)。
 *
 * 最高档为 medium：high 档无鸿鹄画质芯片启动动画且肉眼增益难辨，用户感受优先。
 */
export function resolveVpeQualityByScaling(
  srcW: number | undefined,
  srcH: number | undefined,
  dispW: number | undefined,
  dispH: number | undefined
): VpeQualityLevel | null {
  // 源宽高都已知（有效正数）时，检查 Detail Enhancer 输入硬约束
  if (typeof srcW === 'number' && typeof srcH === 'number' && srcW > 0 && srcH > 0) {
    if (srcW > VPE_SOURCE_MAX_DIMENSION || srcH > VPE_SOURCE_MAX_DIMENSION) {
      return null;
    }
    if (srcW < VPE_SOURCE_MIN_DIMENSION || srcH < VPE_SOURCE_MIN_DIMENSION) {
      return null;
    }
  }
  // 数据缺失（源宽高或显示尺寸任一缺失/≤0）→ low（最低档保证「开启即生效」）
  if (!srcW || !srcH || !dispW || !dispH || srcW <= 0 || srcH <= 0 || dispW <= 0 || dispH <= 0) {
    return 'low';
  }
  const scale = Math.max(dispW / srcW, dispH / srcH);
  if (scale < VPE_SCALE_MEDIUM_THRESHOLD) {
    return 'low';
  }
  return 'medium';
}

/** 画面比例模式 */
export enum AspectRatioMode {
  /** 适应：等比缩放保留黑边（RenderFit.RESIZE_CONTAIN 语义，默认） */
  FIT = 0,
  /** 填充：等比裁剪铺满（RenderFit.RESIZE_COVER 语义） */
  FILL = 1,
  /** 拉伸：不等比铺满（RenderFit.RESIZE_FILL 语义） */
  STRETCH = 2
}

const TAG = '[VideoPlayerController]';
const METRICS_TAG = 'VidAll_Metrics';
const GENERIC_SYSTEM_ERROR = 'system error';
const RESUME_SEEK_AUTOPLAY_FALLBACK_MS = 1500;
const ENABLE_SESSION_DIAG_LOG = false;
/** 支持的播放速率白名单；控制器层对外输入做归一化，避免后端静默降级导致 UI 显示不一致 */
const SUPPORTED_SPEEDS: number[] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

// AudioRoutingDecision 与 PresetAudioHint 已迁移到 AudioTrackRoutingService：
//   import type { AudioRoutingDecision, PresetAudioHint } from
//     "../../../services/audioRouting/AudioRoutingTypes"
// controller 仅作为 façade 引用 service 类型，不再保留本地重复声明。

interface FallbackLogRecord {
  fallbackReason: string;
  fallbackFrom: PlayerBackend;
  fallbackTo: PlayerBackend;
  videoId: number;
  filePath: string;
  detailMessage: string;
}

interface ResumeDiagnosticLogRecord {
  event: string;
  sessionId: number;
  backend: PlayerBackend;
  videoId: number;
  seriesProviderId: string;
  seasonNumber: number;
  episodeNumber: number;
  resumeSource: string;
  captureBackend: PlayerBackend;
  pendingResumeMs: number;
  effectiveResumeMs: number;
  autoResumePlay: boolean;
  autoplayDecision: string;
  autoplayDecisionSource: string;
  autoplayDecisionOrigin: string;
  autoplayExecutionResult: string;
  queuedSeekMs: number;
  isSeeking: boolean;
  currentTimeMs: number;
  durationMs: number;
  filePath: string;
}

const SYSTEM_HARD_PREFERRED_CODECS: string[] = [
  'aac', 'mp3', 'opus', 'flac', 'pcm', 'vorbis'
];

// 这些格式在当前 TV 机型上更容易触发 AVPlayer 不支持，先走软解兜底更稳。
const SYSTEM_SOFT_FALLBACK_CODECS: string[] = [
  'ac3(dolby digital)',
  'eac3(dolby digital plus/atmos)',
  'truehd(dolby truehd/atmos)',
  'dts/dts-hd',
  'mlp',
  'audio vivid'
];

// 声道能力提示用于日志和后续 UI 展示，不代表设备一定能成功输出该布局。
const SUPPORTED_CHANNEL_LAYOUT_HINTS: string[] = [
  'mono(1.0)',
  'stereo(2.0)',
  '5.1(6ch, best effort)',
  '7.1(8ch, best effort)'
];

// ─────────────────────────────────────────────
// 音轨条目
// ─────────────────────────────────────────────

/**
 * 音轨信息条目，用于音轨菜单显示和切换
 */
export interface AudioTrackItem {
  /** 轨道索引（用于 selectTrack） */
  trackIndex: number;
  /** 显示名称，如 "中文 (AAC)"、"英语 (AC-3)" */
  displayName: string;
  /** 语言代码 */
  language?: string;
  /** MIME 类型 */
  mimeType?: string;
  /** 编解码器名称，如 "aac"、"eac3"、"ac3"，供 codec-aware 选轨使用 */
  codecName?: string;
  /** 声道数（预置/ffprobe 注入；运行时轨道可能缺失） */
  channels?: number;
}

export type UnsupportedFormatFallback = 'mpv';

@ObservedV2
export class VideoPlayerController {
  /** 运行时播放后端：AVPlayer 主路径，MPV 唯一回退路径。 */
  @Trace backend: PlayerBackend = 'avplayer';

  /**
   * 显式播放状态（D1 镜像迁移）。
   * 与旧字段 isReady/isPlaying/isSeeking/isLoading/hasPrepared 并存，
   * 后续逐步把读取方迁移到本字段后再删除旧字段。
   */
  private state: PlaybackState = PlaybackState.IDLE;

  /** AI 画质增强开关（仅 avplayer 路径有效） */
  @Trace aiEnhanceEnabled: boolean = true;
  @Trace aiEnhanceRuntimeSupported: boolean = false;
  /** 当前已解析档位（按缩放比例自动计算，仅用于展示/日志，不再由用户设置）。 */
  @Trace aiEnhanceQuality: VpeQualityLevel = 'low';
  /** 显示区域宽度（物理像素，由 XComponent onAreaChange 上报缓存；0 表示尚未上报）。 */
  private displayWidth: number = 0;
  /** 显示区域高度（物理像素，由 XComponent onAreaChange 上报缓存；0 表示尚未上报）。 */
  private displayHeight: number = 0;

  private player?: IPlayer;
  readonly unsupportedFormatFallback: UnsupportedFormatFallback = 'mpv';
  @Trace name: ResourceStr = ''
  @Trace surfaceId: string = ''
  private mpvSurfaceBound: boolean = false
  get isMpvSurfaceBound(): boolean { return this.mpvSurfaceBound }
  private pendingMpvSurfaceId: string = ''
  private pendingMpvSurfaceWidth: number = 0
  private pendingMpvSurfaceHeight: number = 0
  private mpvSurfaceWidth: number = 0
  private mpvSurfaceHeight: number = 0
  @Trace duration = 0
  @Trace isPlaying = false
  @Trace isReady = false
  @Trace isSeeking = false
  @Trace currentTime = 0
  @Trace currentBufferTime = 0
  @Trace isLoading = false
  @Trace lastErrorMessage: string = ''
  @Trace audioCapabilityText: string = ''
  @Trace progress = 0
  @Trace subtitleTracks: TrackInfo[] = []
  @Trace currentSubtitleTrack: number = -1
  @Trace currentSubtitleText: string = ''
  @Trace subtitleUpdateCounter: number = 0
  @Trace allSubtitleTracks: SubtitleTrackItem[] = [];
  @Trace activeSubtitleIndex: number = -1;
  @Trace subtitleDelayMs: number = 0;
  @Trace parsedSubtitle: ParsedSubtitle | null = null;
  @Trace audioTracks: AudioTrackItem[] = [];
  @Trace activeAudioIndex: number = -1;
  @Trace sourceProtocol: string = '';
  @Trace aspectRatioMode: AspectRatioMode = AspectRatioMode.FIT;
  @Trace playbackSpeed: number = 1.0;
  /** 源重载事务（收敛原 pendingReloadToken/activeReloadToken/reloadTimeoutId/pendingReloadResolve/pendingReloadReject） */
  private readonly reloadSession: ReloadSession = new ReloadSession();
  private subtitleAdapter: ISubtitleBridgeAdapter = new NoSubtitleBridgeAdapter();
  private readonly subtitleDispatcher: SubtitleDispatcher = new SubtitleDispatcher();
  /** 字幕缓存上下文，由外部（player page）注入后用于步骤 4 缓存查询 */
  private subtitleCacheContext?: SubtitleCacheContext;
  private currentVideoData?: VideoData;
  private currentOriginalVideoSrc: string = '';
  private forceMpvForNextInit: boolean = false;
  private timeToSeek = -1
  private subtitleClearTimer?: number
  private subtitleRemainingTime: number = 0
  private subtitlePauseTime: number = 0
  /** 字幕时间轴诊断日志节流：每 1s 打印一次 */
  private lastSubtitleTimelineLogMs: number = -1000;
  /** 上一次内嵌字幕的 startTime，用于判断是否是同一字幕的重复回调 */
  private lastSubtitleStartTime: number = -1;
  private readonly SUBTITLE_TIMELINE_LOG_INTERVAL = 1000;

  /** 播放进度上下文（由调用方在 initPlayer 前设置） */
  progressContext: PlayProgressEntity | null = null;
  /** 播放上下文（当季集列表 + 当前集索引），供连播/上下集跳转使用；文件浏览器入口不传时为 undefined */
  playbackContext: PlaybackContext | undefined = undefined;
  /** 是否自动播放下一集 */
  @Trace episodeAutoplayEnabled: boolean = DEFAULT_EPISODE_AUTOPLAY_ENABLED;
  /** 自动播放下一集前的倒计时秒数 */
  @Trace episodeAutoplayCountdownSeconds: number = DEFAULT_EPISODE_AUTOPLAY_COUNTDOWN_SECONDS;
  // ─── Runtime session services (Module 4 wiring) ───
  /** 后端编排 service（adapter 生命周期 + fallback 编排 + XComponent 时序）。 */
  private readonly backendService: PlaybackBackendService = playbackBackendService;
  /**
   * 字幕会话 service（会话内字幕状态 + 优先级裁决）。
   * 每个 controller 各自 `new` 一个实例，service 内部 mutable state 与 controller 生命周期一一对应。
   * 这样避免多 controller / 多播放会话状态串扰（Module 4 fix #2）。
   */
  private readonly subtitleSessionSvc: SubtitleSessionService = new SubtitleSessionService();
  /** 音轨路由 service（codec 探测 + 初始选轨 + 用户绑定恢复）。 */
  private readonly audioRoutingService: AudioTrackRoutingService = audioTrackRoutingService;
  /** 最近一次路由决策（供初始选轨与纠偏记录使用）。 */
  private lastRoutingDecision?: AudioRoutingDecision;
  /** 10s 防抖进度写入定时器 */
  private progressTimer?: number;
  /** 播放会话编号：每次 initPlayer 自增，用于忽略旧实例回调 */
  private playbackSessionId: number = 0;
  /** 指标埋点：initPlayer 开始时间（用于计算首帧耗时） */
  private metricsLoadStartMs: number = 0;
  /** 指标埋点：seek 开始时间（用于计算 seek 完成耗时） */
  private metricsSeekStartMs: number = 0;
  /** 指标埋点：当前播放会话的媒体标识（在 initPlayer 中异步构造，供回调同步使用） */
  private metricsMedia: MediaIdentity | null = null;
  /** 时间回退诊断：记录最近一次 timeUpdate 值 */
  private lastTimeUpdateMs: number = -1;
  /** duration 未就绪时 seek 的诊断日志节流 */
  private lastSeekDurationUnknownLogMs: number = 0;
  /** prepare 成功标志：首次 onPlayerReady 后置 true，每次 initPlayer 重置 */
  private hasPrepared: boolean = false;
  /** 已完成 ready 恢复消费的会话+后端标识，避免同一后端重复 ready 再次消费 pending resume */
  private consumedReadyResumeToken: string = '';
  /** 续播会话（收敛原三层续播字段：pending/decision/seek/result） */
  private readonly resumeSession: ResumeSession = new ResumeSession();

  private get pendingBackendResumeTimeMs(): number {
    return this.resumeSession.pending?.positionMs ?? -1;
  }

  private set pendingBackendResumeTimeMs(value: number) {
    const pendingState = this.resumeSession.ensurePending(this.backend, this.buildPendingResumeSourceKey(this.currentVideoData));
    pendingState.positionMs = value;
    this.resumeSession.prunePending();
  }

  private get pendingBackendResumePlay(): boolean {
    return this.resumeSession.pending?.shouldResumePlay ?? false;
  }

  private set pendingBackendResumePlay(value: boolean) {
    const pendingState = this.resumeSession.ensurePending(this.backend, this.buildPendingResumeSourceKey(this.currentVideoData));
    const autoplayDecision = this.resumeSession.resolve(value, 'compat_override');
    pendingState.shouldResumePlay = value;
    pendingState.autoplayDecisionSource = autoplayDecision.source;
    pendingState.autoplayDecisionOrigin = autoplayDecision.origin;
    this.resumeSession.prunePending();
  }

  /**
   * 状态转移（D1 镜像迁移）。
   * 仅同步 `state` 字段用于日志/诊断与后续收敛，不改动旧字段的写入逻辑。
   */
  private transitionTo(nextState: PlaybackState): void {
    if (this.state !== nextState) {
      if (ENABLE_SESSION_DIAG_LOG) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[session=${this.playbackSessionId}] state ${this.state} → ${nextState}`);
      }
      this.state = nextState;
    }
  }

  private clearPendingResumeState(): void {
    this.resumeSession.pending = null;
  }

  private buildPendingResumeSourceKey(videoData: VideoData | undefined): string {
    if (videoData === undefined) {
      return '';
    }
    if (videoData === this.currentVideoData && this.currentOriginalVideoSrc.length > 0) {
      return this.currentOriginalVideoSrc;
    }
    return videoData.videoSrc;
  }

  /**
   * 缓存 key 用的稳定视频路径：SMB 源用原始 smb:// URL（端口稳定），其他源用 videoSrc。
   * 下载字幕写缓存与读缓存必须使用同一路径，否则 SHA-256 hash 不同导致缓存永远无法命中。
   */
  get stableVideoSrcForCache(): string {
    return this.currentOriginalVideoSrc.length > 0
      ? this.currentOriginalVideoSrc
      : (this.currentVideoData?.videoSrc ?? '');
  }

  /**
   * 字幕缓存用的文件源类型（公开 getter）。
   *
   * 与 `loadSubtitleTracks` 步骤 4 构建 cacheCtx 的推算逻辑保持一致：
   * - 优先用 `VideoData.fileSourceType`（WebDAV/SMB 等远程源）
   * - 否则 FILE_URI 退化为 'local'（本地文件）
   * - 其它情况退化为 'network'（直链）
   *
   * 暴露给 UI（如 SubtitleSelectorDrawerDialog）以正确访问缓存目录。
   */
  get subtitleSourceType(): string {
    const raw = this.currentVideoData?.fileSourceType;
    if (raw !== undefined && raw.length > 0) {
      return raw;
    }
    if (this.currentVideoData?.type === VideoDataType.FILE_URI) {
      return 'local';
    }
    return 'network';
  }

  /**
   * 字幕缓存用的文件源 ID（公开 getter）。
   * 与 `subtitleSourceType` 配对使用。
   */
  get subtitleSourceId(): string {
    return this.currentVideoData?.fileSourceId ?? '0';
  }

  private shouldPreservePendingResume(videoData: VideoData): boolean {
    return this.resumeSession.shouldPreserve(this.buildPendingResumeSourceKey(videoData));
  }

  private consumePendingResumeState(): PendingResumeState | null {
    return this.resumeSession.consumePending();
  }

  private normalizePendingResumePosition(positionMs: number): number {
    return this.resumeSession.normalizePosition(positionMs, this.duration);
  }

  private savePendingResumeState(
    positionMs: number,
    shouldResumePlay: boolean,
    autoplayDecisionSource: string,
    autoplayDecisionOrigin: string,
    reason: string,
    captureBackend: PlayerBackend
  ): void {
    const safePosition = this.normalizePendingResumePosition(positionMs);
    const pendingState: PendingResumeState = {
      positionMs: safePosition,
      shouldResumePlay,
      autoplayDecisionSource,
      autoplayDecisionOrigin,
      sourceKey: this.buildPendingResumeSourceKey(this.currentVideoData),
      reason,
      captureBackend
    };
    this.resumeSession.pending = pendingState;
    this.currentTime = safePosition;
    this.progress = this.duration > 0 ? safePosition / this.duration : 0;
    this.logResumeDiagnostic('resume_pending_capture', reason, captureBackend, safePosition,
      safePosition, shouldResumePlay, 'pending', -1, autoplayDecisionSource, autoplayDecisionOrigin);
  }

  private logResumeDecisionEstablished(
    stage: string,
    shouldResumePlay: boolean,
    source: string,
    origin: string
  ): void {
    this.logResumeDiagnostic('resume_decision_established', source, this.backend, -1,
      this.currentTime > 0 ? this.currentTime : 0, shouldResumePlay, stage, this.timeToSeek, source, origin);
  }

  private rememberPendingResumeAutoplayDecision(shouldResumePlay: boolean, source: string): void {
    this.resumeSession.decisionExplicit = shouldResumePlay;
    this.resumeSession.hasDecisionExplicit = true;
    this.resumeSession.decisionSource = source.length > 0 ? source : 'explicit';
    this.logResumeDecisionEstablished('active', shouldResumePlay, this.resumeSession.decisionSource, 'explicit');
  }

  prepareResumeAutoplayDecision(shouldResumePlay: boolean, source: string): void {
    this.resumeSession.preparedExplicit = shouldResumePlay;
    this.resumeSession.hasPreparedExplicit = true;
    this.resumeSession.preparedSource = source.length > 0 ? source : 'prepared';
    this.logResumeDecisionEstablished('prepared', shouldResumePlay, this.resumeSession.preparedSource, 'explicit');
  }

  discardPreparedResumeAutoplayDecision(): void {
    this.clearPreparedResumeAutoplayDecision();
  }

  rememberResumeAutoplayDecision(shouldResumePlay: boolean, source: string): void {
    this.rememberPendingResumeAutoplayDecision(shouldResumePlay, source);
  }

  private clearPreparedResumeAutoplayDecision(): void {
    this.resumeSession.clearPrepared();
  }

  private applyPreparedResumeAutoplayDecision(): void {
    if (!this.resumeSession.hasPreparedExplicit) {
      return;
    }
    this.rememberPendingResumeAutoplayDecision(
      this.resumeSession.preparedExplicit,
      this.resumeSession.preparedSource
    );
    this.clearPreparedResumeAutoplayDecision();
  }

  private clearPendingResumeAutoplayDecision(): void {
    this.resumeSession.clearPendingDecision();
  }

  private clearResumeAutoplayDecisionLifecycle(): void {
    this.resumeSession.clearDecisionLifecycle();
  }

  protected scheduleResumeSeekAutoplayFallbackTimeout(callback: () => void): number {
    return setTimeout(callback, RESUME_SEEK_AUTOPLAY_FALLBACK_MS);
  }

  protected clearResumeSeekAutoplayFallbackTimeout(timerId: number): void {
    clearTimeout(timerId);
  }

  private clearResumeSeekAutoplayFallbackState(): void {
    if (this.resumeSession.fallbackTimer !== undefined) {
      this.clearResumeSeekAutoplayFallbackTimeout(this.resumeSession.fallbackTimer);
      this.resumeSession.fallbackTimer = undefined;
    }
    this.resumeSession.fallbackSessionId = 0;
    this.resumeSession.fallbackTriggered = false;
  }

  private armResumeSeekAutoplayFallback(sessionId: number): void {
    this.clearResumeSeekAutoplayFallbackState();
    this.resumeSession.fallbackSessionId = sessionId;
    this.resumeSession.fallbackTimer = this.scheduleResumeSeekAutoplayFallbackTimeout(() => {
      this.resumeSession.fallbackTimer = undefined;
      this.handleResumeSeekAutoplayTimeout(sessionId);
    });
  }

  private handleResumeSeekAutoplayTimeout(sessionId: number): void {
    if (sessionId !== this.playbackSessionId) {
      return;
    }
    if (sessionId !== this.resumeSession.fallbackSessionId || !this.isSeeking) {
      return;
    }
    if (!this.resumeSession.hasDecisionExplicit || !this.resumeSession.decisionExplicit) {
      return;
    }
    if (this.resumeSession.decisionSource.length === 0) {
      return;
    }
    this.resumeSession.fallbackTriggered = true;
    this.isSeeking = false;
    this.play().catch(() => {});
  }

  private handlePlayerPaused(): void {
    if (!this.resumeSession.preserveOnPaused) {
      this.clearPendingResumeAutoplayDecision();
    }
    this.isPlaying = false;
    this.transitionTo(PlaybackState.PAUSED);
    this.pauseSubtitleTimer();
    this.stopProgressTimer();
    this.saveProgressNow();
  }

  private resolvePendingResumeAutoplayDecision(
    inferredShouldResumePlay: boolean,
    inferredSource: string
  ): ResumeAutoplayDecision {
    return this.resumeSession.resolve(inferredShouldResumePlay, inferredSource);
  }

  /**
   * XComponent 重建时使用控制器当前播放源，避免组件旧实例以过期 @Param 抢占切集会话。
   * 首次挂载尚无控制器播放源时，才使用组件传入的初始数据。
   */
  async initPlayerForSurface(initialVideoData: VideoData, surfaceId: string): Promise<void> {
    const activeVideoData = this.currentVideoData;
    if (activeVideoData === undefined) {
      await this.initPlayer(initialVideoData, surfaceId);
      return;
    }
    if (this.currentOriginalVideoSrc.length > 0) {
      activeVideoData.videoSrc = this.currentOriginalVideoSrc;
    }
    if (activeVideoData !== initialVideoData) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        '[initPlayerForSurface] 忽略 XComponent 过期播放源，沿用控制器当前播放源');
    }
    // Issue #243 修复：当路由在首次 initPlayer 即选定 mpv 时，backend 变更会触发 UI
    // 从 avplayer XComponent 切到 mpv XComponent，mpv 的 onLoad 会再次走到这里。
    // 此时 MPV adapter 已在上一次 initPlayer 创建完成，重复重建会导致新实例
    // 再也拿不到 surface（黑屏 + 无音轨）。源未变化时直接复用已就绪的 MPV。
    if (this.backend === 'mpv' && this.player !== undefined) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        '[initPlayerForSurface] MPV 已创建且源未变化，跳过冗余重建');
      return;
    }
    await this.initPlayer(activeVideoData, surfaceId);
  }

  /** 初始化 AVPlayer 主路径或 MPV 回退路径。 */
  async initPlayer(videoData: VideoData, surfaceId: string): Promise<void> {
    this.playbackSessionId += 1;
    const currentSessionId = this.playbackSessionId;
    this.metricsLoadStartMs = Date.now();
    this.metricsMedia = null;
    const previousSourceKey = this.buildPendingResumeSourceKey(this.currentVideoData);
    const nextSourceKey = this.buildPendingResumeSourceKey(videoData);
    // 切集后异步探测完成前也不能继续暴露上一集的尾部进度。
    if (previousSourceKey.length > 0 && previousSourceKey !== nextSourceKey) {
      this.duration = 0;
      this.currentTime = 0;
      this.currentBufferTime = 0;
      this.progress = 0;
    }
    // 先重置可展示状态，避免在异步预处理期间继续暴露上次播放残留。
    this.resetDisplayState();
    // 在适配器注册回调前提前查询媒体标识，回调内同步使用，避免异步改造回调签名
    const metricsVideoId = this.progressContext?.videoId;
    if (metricsVideoId !== undefined && metricsVideoId > 0) {
      this.metricsMedia = await this.buildMediaIdentity(metricsVideoId);
    }
    this.hasPrepared = false;
    this.name = videoData.name || ''
    this.currentVideoData = videoData;
    if (!this.forceMpvForNextInit) {
      this.currentOriginalVideoSrc = videoData.videoSrc;
    }
    this.surfaceId = surfaceId;
    this.lastTimeUpdateMs = -1;
    const shouldPreservePendingResume = this.shouldPreservePendingResume(videoData);
    if (!shouldPreservePendingResume) {
      this.clearPendingResumeState();
    }
    this.clearPendingResumeAutoplayDecision();
    this.applyPreparedResumeAutoplayDecision();
    this.resumeSession.resetSeek();
    this.resumeSession.clearResult();
    this.clearResumeSeekAutoplayFallbackState();
    if (ENABLE_SESSION_DIAG_LOG) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[session=${currentSessionId}] initPlayer start backend=${this.backend}`);
    }

    // Route selection always resolves to AVPlayer or MPV; MPV is the only fallback.
    this.transitionTo(PlaybackState.ROUTING);
    const backendBeforeAutoRouting = this.backend;
    const decision = await this.resolveAudioRoutingDecision(videoData);
    if (currentSessionId !== this.playbackSessionId) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `[initPlayer] sessionId 过期（${currentSessionId} ≠ ${this.playbackSessionId}），放弃本次初始化`);
      return;
    }
    videoData.ffmpegDecodeChannels = decision.preferredChannels;
    videoData.audioProbeSummary = decision.summary;
    videoData.videoCodec = decision.videoCodecName;
    videoData.videoHdrType = decision.videoHdrType;
    videoData.videoWidth = decision.videoWidth;
    videoData.videoHeight = decision.videoHeight;
    this.lastRoutingDecision = decision;
    if (this.forceMpvForNextInit) {
      this.backend = 'mpv';
      this.forceMpvForNextInit = false;
      if (this.currentOriginalVideoSrc.startsWith('smb://')) {
        videoData.videoSrc = this.currentOriginalVideoSrc;
      }
    } else {
      this.backend = decision.preferredBackend;
    }
    if (decision.precheckProbeFailed && backendBeforeAutoRouting !== this.backend) {
      this.logFallbackEvent('precheck_probe_failed', backendBeforeAutoRouting, this.backend,
        decision.precheckProbeError);
    }
    // 关键：详细打印整组音轨分析（用于 verify 真机回溯；不论是否锁定 fallback 都打印）
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[initPlayer.route-decision] backend=${this.backend}, fallback=${this.unsupportedFormatFallback}, ` +
      `anyHardSupported=${decision.anyHardSupported}, allSoftDecodeOnly=${decision.allSoftDecodeOnly}, ` +
      `detectedCodec=${decision.detectedCodec}, detectedChannels=${decision.detectedChannels}, ` +
      `recommendedTrack=${decision.recommendedInitialTrackIndex}(${decision.recommendedCodec || '无'}), ` +
      `videoHdrType=${decision.videoHdrType.length > 0 ? decision.videoHdrType : '未知'}, ` +
      `videoSize=${decision.videoWidth ?? '?'}x${decision.videoHeight ?? '?'}`);
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[initPlayer.route-decision] trackAnalyses=${decision.trackAnalyses.length} 条:`);
    for (let i = 0; i < decision.trackAnalyses.length; i++) {
      const t = decision.trackAnalyses[i];
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[initPlayer.route-decision]   [${i}] codec=${t.codec} channels=${t.channels} ` +
        `compatible=${t.compatible} capabilitySource=${t.capabilitySource} isHardware=${t.isHardware} ` +
        `hardSupported=${t.hardSupported} source=${t.source}`);
    }
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[initPlayer.route-decision] capabilitySummary=${decision.capabilitySummary}`);
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `自动音频路由: backend=${this.backend}, fallback=${this.unsupportedFormatFallback}, ` +
      `ffmpegChannels=${videoData.ffmpegDecodeChannels}, summary=${decision.summary}`);
    this.logAudioCapabilityReport(decision);

    // 指标埋点：play_start — backend 已最终确定，记录本次播放启动意图
    hilog.info(CommonConstants.LOG_DOMAIN, METRICS_TAG,
      `{"event":"play_start","backend":"${this.backend}","video_id":${this.progressContext?.videoId ?? -1},"file":"${this.extractFileName(videoData.videoSrc ?? '')}","ts":${this.metricsLoadStartMs}}`);

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
    this.isSeeking = false;
    this.timeToSeek = -1;
    this.lastErrorMessage = '';
    this.subtitleAdapter.release();
    this.subtitleAdapter = new NoSubtitleBridgeAdapter();
    this.currentSubtitleText = '';
    this.subtitleUpdateCounter = 0;
    this.allSubtitleTracks = [];
    this.activeSubtitleIndex = -1;
    this.currentSubtitleTrack = -1;
    this.subtitleTracks = [];
    this.subtitleDelayMs = 0;
    this.audioTracks = [];
    this.activeAudioIndex = -1;

    // ── 预置音轨：从数据库已读取，立即填充，无需等播放器 ready ──
    // MPV 的 PlayerTrack.id 是 VidAll_Player 的运行时 ID，不能复用 ffprobe 预置流索引。
    // 因此 MPV 必须等 getTrackInfos() 返回后再填充，确保回传 selectTrack 的 ID 可用。
    if (this.backend !== 'mpv' && videoData.presetAudioTracks && videoData.presetAudioTracks.length > 0) {
      const presets = videoData.presetAudioTracks;
      const tracks: AudioTrackItem[] = [];
      for (let i = 0; i < presets.length; i++) {
        const p = presets[i];
        const item: AudioTrackItem = {
          trackIndex: p.trackIndex,
          displayName: p.displayName,
          language: p.language,
          mimeType: p.mimeType,
          codecName: p.codecName,
          channels: p.channels
        };
        tracks.push(item);
      }
      this.audioTracks = tracks;
      this.activeAudioIndex = 0;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[initPlayer] 预置音轨已提前填充: ${tracks.length} 条`);
    } else if (this.backend === 'mpv') {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        '[initPlayer] MPV 忽略 ffprobe 预置音轨，等待 VidAll_Player 运行时轨道');
    }

    // 根据 backend 创建对应适配器（thin delegation to `PlaybackBackendService.prepareAdapter`）。
    //
    // 测试注入钩子：若子类覆写了 createAdapterForBackend() 并返回非 undefined，则跳过 service
    // 直接使用测试注入的 player（历史测试类依赖 createAvPlayerAdapter 注入 mock player）。
    const testAdapter = this.createAdapterForBackend(this.backend);
    if (testAdapter !== undefined) {
      this.player = testAdapter;
    } else {
      const adapterHandle = this.backendService.prepareAdapter(
        videoData,
        this.backend,
        {
          onReady: () => {},
          onPlay: () => {},
          onPaused: () => {},
          onCompleted: () => {},
          onStopped: () => {},
          onTimeUpdate: () => {},
          onError: () => {},
          onUnsupportedFormat: () => {},
          onSeekDone: () => {},
          onSubtitleUpdate: () => {},
          onBuffering: () => {},
          onEmbeddedTimedText: (text: string) => {
            const bridge = this.subtitleAdapter;
            if (currentSessionId !== this.playbackSessionId) {
              return;
            }
            // MPV 字幕桥继承 BaseSubtitleBridgeAdapter；AVPlayer 使用 onSubtitleUpdate 路径，
            // NoSubtitleBridgeAdapter 是空操作。只对有 onEmbeddedTimedText 实现的桥放行。
            if (!(bridge instanceof BaseSubtitleBridgeAdapter)) {
              return;
            }
            bridge.onEmbeddedTimedText(text);
            this.applySubtitleBridgeState(bridge.getState());
          }
        }
      );
      this.sourceProtocol = videoData.videoSrc.startsWith('smb://') ? 'SMB' : this.sourceProtocol;
      // SMB 代理启动后，将代理 URL 写回 videoData，确保后续 init/setSurface 使用代理 URL
      if (adapterHandle.effectiveVideoSrc.length > 0 &&
        adapterHandle.effectiveVideoSrc !== videoData.videoSrc) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `initPlayer: videoSrc 替换为代理 URL: ${videoData.videoSrc.substring(0, 60)} → ${adapterHandle.effectiveVideoSrc.substring(0, 60)}`);
        videoData.videoSrc = adapterHandle.effectiveVideoSrc;
      }
      if (adapterHandle.subtitleBridge !== undefined) {
        this.subtitleAdapter = adapterHandle.subtitleBridge;
      } else {
        this.subtitleAdapter = new NoSubtitleBridgeAdapter();
      }
      const adapter: IPlayer | undefined = adapterHandle.player;
      if (adapter === undefined) {
        const adapterError = 'PlaybackBackendService.prepareAdapter did not return a player';
        if (this.backend === 'avplayer') {
          this.fallbackAvPlayerToMpv('avplayer_init_failure', adapterError);
        } else {
          this.handleTerminalPlayerError(adapterError);
        }
        return;
      }
      this.player = adapter;
    }

    this.transitionTo(PlaybackState.PREPARING);

    // Register IPlayer event callbacks (shared path for both service and test adapter).
    const p = this.player as IPlayer;
    p.onReady(() => {
      if (currentSessionId !== this.playbackSessionId) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `[session=${currentSessionId}] 忽略过期 onReady`);
        return;
      }
      this.onPlayerReady();
      this.resolvePendingReload();
    });
    p.onPlay(() => {
      this.handlePlayerPlayEvent(currentSessionId);
    });
    p.onPaused(() => {
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
      this.handlePlayerPaused();
    });
    p.onCompleted(() => {
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
      this.clearPendingResumeAutoplayDecision();
      this.isPlaying = false;
      this.isLoading = false;
      this.transitionTo(PlaybackState.PAUSED);
      if (this.duration > 0) {
        this.currentTime = this.duration;
        this.progress = 1;
      }
      this.stopProgressTimer();
      this.saveProgressNow();
      emitter.emit(PlayerEvents.COMPLETED);
    });
    p.onStopped(() => {
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
      this.clearPendingResumeAutoplayDecision();
      this.isPlaying = false;
      this.transitionTo(PlaybackState.PAUSED);
      this.stopProgressTimer();
    });
    p.onTimeUpdate((currentTime: number) => {
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
      const backwardDelta = this.lastTimeUpdateMs - currentTime;
      const shouldWarnRollback = this.lastTimeUpdateMs >= 0 &&
        !this.isSeeking &&
        this.lastTimeUpdateMs > 1000 &&
        currentTime > 0 &&
        backwardDelta > 1000;
      if (shouldWarnRollback) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `[session=${currentSessionId}] timeUpdate 回退: prev=${this.lastTimeUpdateMs} now=${currentTime}`);
      }
      this.lastTimeUpdateMs = currentTime;
      this.currentTime = currentTime;
      if (this.lastErrorMessage.length > 0 && this.isPlaying) {
        this.lastErrorMessage = '';
      }
      const playerDuration = this.player?.duration ?? 0;
      if (playerDuration > 0) {
        this.duration = playerDuration;
      }
      this.progress = this.duration > 0 ? currentTime / this.duration : 0;
      this.subtitleAdapter.onTimeUpdate(currentTime);
      const subtitleState = this.subtitleAdapter.getState();
      if (subtitleState.hasExternalActive) {
        this.applySubtitleBridgeState(subtitleState);
      }
      this.logSubtitleTimeline(currentTime);
    });
    p.onError((error: Error) => {
      if (currentSessionId !== this.playbackSessionId || this.player !== p) {
        return;
      }
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `播放器错误: ${error.message}`);
      // 指标埋点：play_result=error
      const metricsElapsedOnError = Date.now() - this.metricsLoadStartMs;
      hilog.warn(CommonConstants.LOG_DOMAIN, METRICS_TAG,
        `{"event":"play_result","backend":"${this.backend}","video_id":${this.progressContext?.videoId ?? -1},"result":"error","error_code":"${error.message.substring(0, 80)}","elapsed_ms":${metricsElapsedOnError}}`);
      
      // Task 4.5: Record failed playback attempt
      if (MetricsService.isInitialized()) {
        // 升级为 MediaIdentity 对象，服务端可通过 provider/provider_id 唯一识别视频
        const sourceType = videoData.type === VideoDataType.FILE_URI ? 'local' : 'network';
        MetricsService.getInstance().recordPlaybackAttempt(false, 0, this.metricsMedia ?? undefined, sourceType);
      }
      
      // prepare 前的 IO 文件不存在错误：无论使用什么播放器，都应通知上层页面提示用户删除元数据
      // AVPlayer 在文件缺失时返回 code=20400007 / message="No such file or directory"，
            if (!this.hasPrepared) {
        const msg = error.message.toLowerCase();
        const isFileNotFound = msg.includes('io resource not found')
          || msg.includes('no such file')
          || msg.includes('not found')
          || msg.includes('404');
        if (isFileNotFound) {
          const videoId = this.progressContext?.videoId ?? -1;
          if (videoId > 0) {
            emitter.emit(PlayerEvents.FILE_INACCESSIBLE, { data: { videoId: videoId } });
          }
        }
      }

      if (this.backend === 'avplayer' && !this.hasPrepared) {
        this.fallbackAvPlayerToMpv('avplayer_init_failure', error.message);
        return;
      }
      this.handleTerminalPlayerError(error.message);
    });
    p.onBuffering((isBuffering: boolean) => {
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
      this.isLoading = isBuffering;
      if (!isBuffering && this.lastErrorMessage.length > 0) {
        this.lastErrorMessage = '';
      }
    });
    p.onUnsupportedFormat(() => {
      if (currentSessionId !== this.playbackSessionId || this.player !== p) {
        return;
      }
      const targetBackend: PlayerBackend = 'mpv';
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `AVPlayer 不支持当前格式，自动切换到 ${targetBackend}...`);
      // 不干预用户字幕绑定：fallback 是系统行为，不应覆盖用户的主动选择。
      // 若用户之前关闭过字幕（disabled），resolveSubtitle 步骤 1 会正确返回 none。
      // 若用户之前选中了某条字幕，binding 保留，步骤 1 会正确恢复。
      const fbVideoPath = this.stableVideoSrcForCache;
      if (fbVideoPath.length > 0) {
        this.subtitleDispatcher.getUserBinding(fbVideoPath).then((binding) => {
          if (binding !== null) {
            hilog.info(CommonConstants.LOG_DOMAIN, TAG,
              `fallback: 保留 binding (${binding.subtitleType})，resolveSubtitle 步骤 1 会按类型处理`);
          }
        }).catch(() => {});
      }
      // 记录设备/固件纠偏：系统宣称支持但 AVPlayer 实际不支持。
      this.recordCurrentCodecCorrection('avplayer_unsupported_format');
      this.fallbackAvPlayerToMpv('avplayer_unsupported_format');
    });
    p.onSeekDone(() => {
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
      // 指标埋点：seek_result
      const seekElapsed = Date.now() - this.metricsSeekStartMs;
      hilog.info(CommonConstants.LOG_DOMAIN, METRICS_TAG,
        `{"event":"seek_result","backend":"${this.backend}","result":"done","elapsed_ms":${seekElapsed}}`);
      const resumeSeekInFlight = this.resumeSession.seekInFlight;
      const resumeSeekSource = this.resumeSession.seekSource;
      const resumeSeekCaptureBackend = this.resumeSession.seekCaptureBackend;
      const resumeSeekTargetMs = this.resumeSession.seekTargetMs;
      const resumeSeekAutoPlay = this.resumeSession.seekAutoPlay;
      const resumeSeekAutoplayFallbackTriggered = this.resumeSession.fallbackTriggered;
      this.clearResumeSeekAutoplayFallbackState();
      const resumeAutoplayDecisionSource = this.resumeSession.result?.autoplayDecisionSource ?? '';
      const resumeAutoplayDecisionOrigin = this.resumeSession.result?.autoplayDecisionOrigin ?? '';
      if (resumeSeekInFlight) {
        this.logResumeDiagnostic('resume_seek_done', resumeSeekSource, resumeSeekCaptureBackend, resumeSeekTargetMs,
          resumeSeekTargetMs, resumeSeekAutoPlay, 'pending', this.timeToSeek,
          resumeAutoplayDecisionSource, resumeAutoplayDecisionOrigin);
      }
      if (this.timeToSeek >= 0) {
        if (resumeSeekInFlight) {
          this.logResumeDiagnostic('resume_autoplay_decision', resumeSeekSource, resumeSeekCaptureBackend,
            resumeSeekTargetMs, resumeSeekTargetMs, resumeSeekAutoPlay, 'queued_seek', this.timeToSeek,
            resumeAutoplayDecisionSource, resumeAutoplayDecisionOrigin);
          this.resumeSession.clearSeekDispatch();
        }
        this.player?.seek(this.timeToSeek);
        this.timeToSeek = -1;
        this.isSeeking = false;
        return;
      }
      const shouldContinuePendingReadyAfterSeek = this.resumeSession.trackInitAfterSeek;
      if (resumeSeekInFlight) {
        this.resumeSession.clearSeekDispatch();
      }
      this.isSeeking = false;
      if (shouldContinuePendingReadyAfterSeek) {
        this.resumeSession.suppressPlayAfterSeek = false;
        this.continuePendingReadyAfterSeek(currentSessionId).catch(() => {});
        return;
      }
      if (resumeSeekAutoplayFallbackTriggered) {
        return;
      }
      if (this.resumeSession.suppressPlayAfterSeek) {
        if (resumeSeekInFlight) {
          this.logResumeDiagnostic('resume_autoplay_decision', resumeSeekSource, resumeSeekCaptureBackend,
            resumeSeekTargetMs, resumeSeekTargetMs, resumeSeekAutoPlay, 'suppress', -1,
            resumeAutoplayDecisionSource, resumeAutoplayDecisionOrigin);
        }
        this.recordPendingResumeAutoplayResult('paused', true);
        this.transitionTo(PlaybackState.PAUSED);
        this.resumeSession.suppressPlayAfterSeek = false;
      } else {
        if (resumeSeekInFlight) {
          this.logResumeDiagnostic('resume_autoplay_decision', resumeSeekSource, resumeSeekCaptureBackend,
            resumeSeekTargetMs, resumeSeekTargetMs, resumeSeekAutoPlay, 'play', -1,
            resumeAutoplayDecisionSource, resumeAutoplayDecisionOrigin);
          this.primePendingResumeAutoplayResult(resumeSeekSource, resumeSeekCaptureBackend,
            resumeSeekTargetMs, resumeSeekTargetMs, resumeSeekAutoPlay, 'play',
            resumeAutoplayDecisionSource, resumeAutoplayDecisionOrigin);
        }
        this.play().catch(() => {});
      }
    });
    p.onSubtitleUpdate((info) => {
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
      // 外部字幕激活时屏蔽内嵌回调
      if (this.subtitleAdapter.getState().hasExternalActive) {
        return;
      }
      this.subtitleAdapter.onSubtitleUpdate(info);
      this.applySubtitleBridgeState(this.subtitleAdapter.getState());
      // 字幕已关闭（activeSubtitleIndex < 0），忽略后续定时器与文本更新
      if (this.activeSubtitleIndex < 0) {
        return;
      }
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `内嵌字幕回调: text="${info.text?.substring(0, 80)}" startTime=${info.startTime}ms duration=${info.duration}ms`);
      if (info.text) {
        // 只在字幕内容或 startTime 发生变化时重置定时器。
        // AVPlayer 对同一字幕可能在持续期间内多次重复回调，若每次都清除并重建定时器，
        // 定时器永远无法触发，字幕就不会被清除。
        const isNewSubtitle = info.text !== this.currentSubtitleText ||
          (info.startTime !== undefined && info.startTime !== this.lastSubtitleStartTime);
        if (isNewSubtitle) {
          if (this.subtitleClearTimer) {
            clearTimeout(this.subtitleClearTimer);
            this.subtitleClearTimer = undefined;
          }
          this.currentSubtitleText = info.text;
          this.lastSubtitleStartTime = info.startTime ?? -1;
          const displayDuration = (info.duration && info.duration > 0) ? info.duration : 3000;
          this.subtitleRemainingTime = displayDuration;
          if (this.isPlaying) { this.startSubtitleTimer(); }
        }
        // 同一字幕的重复回调：保持现有定时器继续运行，不重置
      } else {
        // 空文本（字幕区间结束）：立即清除
        if (this.subtitleClearTimer) {
          clearTimeout(this.subtitleClearTimer);
          this.subtitleClearTimer = undefined;
        }
        this.currentSubtitleText = '';
        this.subtitleRemainingTime = 0;
        this.lastSubtitleStartTime = -1;
      }
      this.subtitleUpdateCounter++;
    });

    // 注：this.player 已在上面 `this.player = adapter` 提前赋值（service 编排后立刻投影到 @Trace 字段）。

    if (this.backend === 'mpv') {
      this.mpvSurfaceBound = false;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        'MpvPlayerAdapter 已创建，等待 UI 层 setMpvSurface() 绑定 XComponent...');
      if (this.pendingMpvSurfaceId.length > 0 && this.pendingMpvSurfaceWidth > 0 &&
        this.pendingMpvSurfaceHeight > 0) {
        const sid = this.pendingMpvSurfaceId;
        const sw = this.pendingMpvSurfaceWidth;
        const sh = this.pendingMpvSurfaceHeight;
        this.pendingMpvSurfaceId = '';
        this.pendingMpvSurfaceWidth = 0;
        this.pendingMpvSurfaceHeight = 0;
        await this.setMpvSurface(sid, sw, sh);
      }
    } else {
      const effectiveSurfaceId = this.tryCreateVpeEnhancer(surfaceId);
      try {
        await this.player?.init(videoData, effectiveSurfaceId);
      } catch (e) {
        const err = e as BusinessError;
        this.fallbackAvPlayerToMpv('avplayer_init_failure', err.message ?? 'AVPlayer init failed');
      }
    }
  }

  protected createAvPlayerAdapter(): IPlayer {
    return new AVPlayerAdapter();
  }

  /**
   * 测试注入钩子：若返回非 undefined，initPlayer 将跳过 PlaybackBackendService 直接使用该 adapter。
   * 基类返回 undefined（正常走 service 路径）；测试子类覆写此方法注入 mock player。
   */
  protected createAdapterForBackend(_backend: PlayerBackend): IPlayer | undefined {
    return undefined;
  }

  /**
   * 重置上一次播放残留的可展示状态。
   * 在 initPlayer 的异步预处理前调用，确保切源时 UI 状态尽快清空。
   * 声明为 protected 以允许测试通过 spy override 验证调用合约（Task 2.2）。
   */
  protected resetDisplayState(): void {
    this.audioCapabilityText = '';
    this.sourceProtocol = '';
  }

  // ─── VPE AI 画质增强 ──────────────────────────────────────────

  /**
   * 开启 AI 画质增强（档位由系统按缩放比例自动选择，用户不指定）。
   * - VPE 已运行：重算档位并在变化时运行中换档（不重建管线）
   * - VPE 未运行：下次 initPlayer 时创建，档位由 resolveVpeQualityByScaling 决定
   */
  setAiEnhance(): void {
    const runtimeSupported = this.syncAiEnhanceAvailability();
    if (!runtimeSupported) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '[VPE] 运行时不可用，忽略启用请求');
      return;
    }
    this.aiEnhanceEnabled = true;
    if (VpeEnhancerUtil.isRunning) {
      // 强制切回自动档位：关闭时 VPE 已切到 NONE 透传，而 aiEnhanceQuality 仍停留在旧档位，
      // 若不强制则「档位未变化」判断会跳过 updateQuality，导致开启后画面仍无增强。
      this.applyAutoQuality(true);
    }
    // VPE 未运行时无需操作，下次播放时 initPlayer 会按自动档位创建
  }

  /**
   * 由 XComponent onAreaChange 上报显示区域物理像素，供 VPE 自动选档使用。
   * 显示尺寸后到（晚于 initPlayer）时重算档位，变化则运行中换档。
   */
  updateDisplaySize(width: number, height: number): void {
    if (width <= 0 || height <= 0) {
      return;
    }
    const changed = this.displayWidth !== width || this.displayHeight !== height;
    this.displayWidth = width;
    this.displayHeight = height;
    if (changed && VpeEnhancerUtil.isRunning) {
      this.applyAutoQuality();
    }
  }

  /** 计算当前应选档位并应用（运行中换档，不重建管线）。force 时无条件切回自动档位。 */
  private applyAutoQuality(force: boolean = false): void {
    const quality = this.resolveAutoQuality();
    if (quality !== null && (force || quality !== this.aiEnhanceQuality)) {
      this.aiEnhanceQuality = quality;
      VpeEnhancerUtil.updateQuality(quality);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[VPE] 自动档位更新: ${quality}${force ? ' (强制)' : ''}`);
    }
  }

  /** 按当前源视频分辨率与显示尺寸计算自动档位。 */
  private resolveAutoQuality(): VpeQualityLevel | null {
    const srcW = this.currentVideoData?.videoWidth;
    const srcH = this.currentVideoData?.videoHeight;
    const disp = this.resolveDisplaySizeForVpe();
    return resolveVpeQualityByScaling(srcW, srcH, disp?.width, disp?.height);
  }

  /** 解析显示目标尺寸：优先 XComponent 缓存，其次屏幕物理像素，都无则 undefined。 */
  private resolveDisplaySizeForVpe(): DisplaySize | undefined {
    if (this.displayWidth > 0 && this.displayHeight > 0) {
      const cached: DisplaySize = { width: this.displayWidth, height: this.displayHeight };
      return cached;
    }
    try {
      const d = display.getDefaultDisplaySync();
      if (d && d.width > 0 && d.height > 0) {
        const screen: DisplaySize = { width: d.width, height: d.height };
        return screen;
      }
    } catch (e) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, `[VPE] 读取屏幕尺寸失败: ${String(e)}`);
    }
    return undefined;
  }

  /**
   * 关闭 AI 画质增强。
   * 切换为透传模式（NONE 质量），保持 VPE 管线完整，不摧毁 Surface，不冻结画面。
   */
  disableAiEnhance(): void {
    this.aiEnhanceEnabled = false;
    if (VpeEnhancerUtil.isRunning) {
      VpeEnhancerUtil.setPassthrough();
    }
  }

  getResolvedAiEnhanceEnabled(): boolean {
    this.syncAiEnhanceAvailability();
    return this.aiEnhanceEnabled;
  }

  shouldShowAiEnhanceSettings(): boolean {
    return shouldShowAiEnhanceSettingsByRuntime(
      this.aiEnhanceRuntimeSupported,
      this.backend,
      isHdrVideo(this.currentVideoData?.videoHdrType)
    );
  }

  private syncAiEnhanceAvailability(): boolean {
    const runtimeSupported = this.isAiEnhanceRuntimeSupported();
    this.aiEnhanceRuntimeSupported = runtimeSupported;
    const resolvedEnabled = resolveAiEnhanceEnabledByRuntime(runtimeSupported, this.aiEnhanceEnabled);
    if (this.aiEnhanceEnabled && !resolvedEnabled) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        '[VPE] 运行时探测不可用，自动回退为关闭状态');
    }
    this.aiEnhanceEnabled = resolvedEnabled;
    return runtimeSupported;
  }

  private isAiEnhanceRuntimeSupported(): boolean {
    return VpeEnhancerUtil.isSupported();
  }

  /**
   * 设置画面比例模式。三路后端通过 XComponent.renderFit 统一生效：
   * - FIT → RenderFit.RESIZE_CONTAIN（等比保留黑边）
   * - FILL → RenderFit.RESIZE_COVER（等比裁剪铺满）
   * - STRETCH → RenderFit.RESIZE_FILL（不等比拉伸铺满）
   */
  setAspectRatioMode(mode: AspectRatioMode): void {
    this.aspectRatioMode = mode;
    const modeNames: string[] = ['FIT', 'FILL', 'STRETCH'];
    console.info(`[VideoPlayer] aspectRatioMode → ${modeNames[mode] ?? mode}`);
  }

  /**
   * 设置播放速率（倍速）。
   *
   * 支持档位：0.5 / 0.75 / 1.0 / 1.25 / 1.5 / 2.0。
   * 通过 IPlayer 接口向当前内核分发，各后端自行实现或降级。
   * 速率会在 onPlayerReady 后重新应用，确保后端切换后倍速设置不丢失。
   */
  setPlaybackSpeed(speed: number): void {
    // 白名单归一化：不在支持档位的值回退到 1.0x，避免后端静默降级与 UI 显示不一致
    const normalizedSpeed = SUPPORTED_SPEEDS.includes(speed) ? speed : 1.0;
    if (normalizedSpeed !== speed) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `setPlaybackSpeed: speed=${speed} 不在支持列表，归一化为 1.0`);
    }
    this.playbackSpeed = normalizedSpeed;
    if (this.player) {
      this.player.setPlaybackSpeed(normalizedSpeed);
    }
    hilog.info(CommonConstants.LOG_DOMAIN, TAG, `setPlaybackSpeed: speed=${normalizedSpeed} backend=${this.backend}`);
  }

  /**
   * 尝试创建 VPE 增强实例，返回有效的 surfaceId。
   * - 增强成功：返回 VPE 输入 surfaceId（替代 XComponent surfaceId 传给播放器）
   * - 增强失败或不支持：返回原始 displaySurfaceId（透明降级）
   */
  private tryCreateVpeEnhancer(displaySurfaceId: string): string {
    const runtimeSupported = this.syncAiEnhanceAvailability();
    const videoHdrType = this.currentVideoData?.videoHdrType;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[VPE] tryCreate: supported=${runtimeSupported} enabled=${this.aiEnhanceEnabled} backend=${this.backend} quality=${this.aiEnhanceQuality}`);
    if (!runtimeSupported || !this.aiEnhanceEnabled || this.backend !== 'avplayer') {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[VPE] 跳过创建: supported=${runtimeSupported} enabled=${this.aiEnhanceEnabled} backend=${this.backend}`);
      return displaySurfaceId;
    }
    if (isHdrVideo(videoHdrType)) {
      // SDR → HDR 切换时清理旧增强器，避免旧实例继续持有已释放的 surface。
      if (VpeEnhancerUtil.isRunning) {
        VpeEnhancerUtil.destroyEnhancer();
      }
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[VPE] 跳过创建: HDR 视频不启用 VPE (hdrType=${videoHdrType})`);
      return displaySurfaceId;
    }
    const resolvedQuality = this.resolveAutoQuality();
    if (resolvedQuality === null) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        '[VPE] 跳过创建: 源分辨率超出 Detail Enhancer 输入约束');
      return displaySurfaceId;
    }
    this.aiEnhanceQuality = resolvedQuality;
    const vpeSurfaceId = VpeEnhancerUtil.createEnhancer(displaySurfaceId, resolvedQuality);
    const effectiveSurfaceId = resolveEffectivePlaybackSurfaceId(displaySurfaceId, vpeSurfaceId);
    if (effectiveSurfaceId !== displaySurfaceId) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[VPE] 管线建立: vpeSurfaceId=${vpeSurfaceId} quality=${resolvedQuality}`);
      return effectiveSurfaceId;
    }
    hilog.warn(CommonConstants.LOG_DOMAIN, TAG, '[VPE] 创建失败，回退到原始 surfaceId');
    return displaySurfaceId;
  }

  /**
   * 注入字幕缓存上下文，用于步骤 4 本地缓存自动加载。
   * 由 player page 在持有 UIAbilityContext 后调用，注入 filesDir 等信息。
   */
  setSubtitleCacheContext(ctx: SubtitleCacheContext): void {
    this.subtitleCacheContext = ctx;
  }

  /**
   * 供 VideoPlayer UI 层在 MPV XComponent.onAreaChange 回调中调用。
   * 使用 XComponentController 模式获取 surfaceId，然后绑定 surface 并初始化播放。
   * 行为委托至 `PlaybackBackendService.bindMpvContext`。
   * @param surfaceId XComponent surfaceId
   * @param width XComponent 有效宽度（必须 > 0）
   * @param height XComponent 有效高度（必须 > 0）
   */
  /**
   * 绑定 MPV 播放器 XComponent surface。
   * width/height 必须为物理像素（由 VideoPlayer.ets 在 onAreaChange 中 vp2px 转换后传入）。
   */
  async setMpvSurface(surfaceId: string, width: number, height: number): Promise<void> {
    if (surfaceId.length === 0 || width <= 0 || height <= 0) {
      return;
    }
    // surface 生命周期独立于播放器异步创建；始终先保存最新参数，避免 fallback 期间丢失事件。
    this.pendingMpvSurfaceId = surfaceId;
    this.pendingMpvSurfaceWidth = width;
    this.pendingMpvSurfaceHeight = height;
    this.mpvSurfaceWidth = width;
    this.mpvSurfaceHeight = height;
    if (this.backend !== 'mpv' || !this.player) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `setMpvSurface() 等待 MPV player，缓存 surface 参数: id=${surfaceId.substring(0, 8)}... w=${width} h=${height}`);
      return;
    }
    if (this.mpvSurfaceBound) {
      this.notifyMpvSurfaceResize(width, height);
      return;
    }
    this.pendingMpvSurfaceId = '';
    this.pendingMpvSurfaceWidth = 0;
    this.pendingMpvSurfaceHeight = 0;
    if (this.currentVideoData) {
      try {
        await this.backendService.bindMpvContext(
          this.player,
          surfaceId,
          this.currentVideoData,
          width,
          height
        );
        this.mpvSurfaceBound = true;
      } catch (e) {
        const err = e as Error;
        hilog.error(CommonConstants.LOG_DOMAIN, TAG,
          `setMpvSurface init 失败: ${err.message}`);
        this.handleTerminalPlayerError(err.message);
      }
    }
  }

  /**
   * 通知 MPV 播放器 XComponent 尺寸变更（onAreaChange 回调）。
   * 由 VideoPlayer.ets 在 mpv 分支的 onAreaChange 中调用。
   */
  notifyMpvSurfaceResize(physicalWidth: number, physicalHeight: number): void {
    if (this.backend !== 'mpv' || !this.player) {
      return;
    }
    if (!(this.player instanceof MpvPlayerAdapter)) {
      return;
    }
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `notifyMpvSurfaceResize: w=${physicalWidth} h=${physicalHeight} bound=${this.mpvSurfaceBound}`);
    if (physicalWidth > 0 && physicalHeight > 0) {
      this.mpvSurfaceWidth = physicalWidth;
      this.mpvSurfaceHeight = physicalHeight;
      this.player.getSurfaceAdapter().onSizeChange(physicalWidth, physicalHeight).catch(() => {});
    }
  }

  async reloadSource(videoData: VideoData, autoPlay: boolean = true): Promise<void> {
    if (autoPlay) {
      this.clearPreparedResumeAutoplayDecision();
    }
    if (this.surfaceId.length === 0) {
      this.clearResumeAutoplayDecisionLifecycle();
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, 'reloadSource: surfaceId 为空，忽略切源请求');
      throw new Error('reloadSource requires surfaceId');
    }
    this.clearPendingResumeState();
    this.rejectPendingReload(new Error('reload superseded'));
    if (autoPlay) {
      this.prepareResumeAutoplayDecision(true, 'reload_source_autoplay');
    }
    const reloadPromise = new Promise<void>((resolve, reject) => {
      this.reloadSession.begin(resolve, reject);
    });
    try {
      await this.initPlayer(videoData, this.surfaceId);
      if (this.backend === 'mpv') {
        this.mpvSurfaceBound = false;
        await this.setMpvSurface(this.surfaceId, this.mpvSurfaceWidth, this.mpvSurfaceHeight);
      }
      await reloadPromise;
      if (autoPlay) {
        await this.play();
      }
    } catch (error) {
      const reloadError = error instanceof Error ? error : new Error(String(error));
      this.clearResumeAutoplayDecisionLifecycle();
      this.rejectPendingReload(reloadError);
      throw reloadError;
    }
  }

  private resolvePendingReload(): void {
    this.reloadSession.resolvePending();
  }

  private rejectPendingReload(error: Error): void {
    this.reloadSession.rejectPending(error);
  }

  /**
   * 计算后端路由决策（thin delegation to `PlaybackBackendService.chooseBackend`）。
   *
   * controller **不得**直接调用 `audioRoutingService.resolveRoutingDecision`。
   * backend route 决策的唯一入口是 `backendService.chooseBackend`，它内部委托
   * `AudioTrackRoutingService` 完成整组音轨分析，并把结果包装为 `PlaybackBackendDecision`。
   *
   * 历史背景：原 `VideoPlayerController.resolveAudioRoutingDecision` 直接做 ffprobe + 决策。
   * 为符合 OpenSpec stage 4 的 service 化要求，本方法现在只是 backend service 的 façade。
   * 整组音轨分析、preset 降级、route 决策、硬解判断全部由 service 链完成。
   */
  private async resolveAudioRoutingDecision(videoData: VideoData): Promise<AudioRoutingDecision> {
    const decision: PlaybackBackendDecision = await this.backendService.chooseBackend(videoData);
    // 字段在 PlaybackBackendDecision 与 AudioRoutingDecision 上完全对齐，直接 cast
    return decision as AudioRoutingDecision;
  }

  private logAudioCapabilityReport(decision: AudioRoutingDecision): void {
    // 结构化日志：后续可直接平移到 UI 能力面板，减少二次拼装成本。
    // 字段语义已升级为整组音轨分析（anyHardSupported / allSoftDecodeOnly），
    // 反映多音轨片源下"是否至少存在一条可硬解轨 / 是否全部应软解"。
    const channelTag = this.getChannelTag(decision.detectedChannels);
    const currentDecodePlan = decision.preferredBackend === 'avplayer'
      ? `system-harddecode-${channelTag}`
      : `${decision.preferredBackend}-fallback-${channelTag}`;

    const message =
      '[AudioCapability] ' +
      `trackCount=${decision.trackAnalyses.length}, ` +
      `firstCodec=${decision.detectedCodec}, firstChannels=${decision.detectedChannels}(${channelTag}), ` +
      `anyHardSupported=${decision.anyHardSupported}, allSoftDecodeOnly=${decision.allSoftDecodeOnly}, ` +
      `anyPlayable=${decision.anyPlayable}, anyUnplayable=${decision.anyUnplayable}, ` +
      `route=${decision.preferredBackend}, fallback=${decision.fallback}, ` +
      `recommendedTrack=${decision.recommendedInitialTrackIndex}, ` +
      `decodePlan=${currentDecodePlan}; ` +
      `capability=${decision.capabilitySummary}; ` +
      `systemHardPreferred=[${SYSTEM_HARD_PREFERRED_CODECS.join(', ')}]; ` +
      `systemSoftFallback=[${SYSTEM_SOFT_FALLBACK_CODECS.join(', ')}]; ` +
      `channelHints=[${SUPPORTED_CHANNEL_LAYOUT_HINTS.join(', ')}]`;

    this.audioCapabilityText =
      `音频能力: 共${decision.trackAnalyses.length}条 | ` +
      `首轨=${decision.detectedCodec} ${channelTag} | ` +
      `可硬解=${decision.anyHardSupported ? '是' : '否'} | ` +
      `当前路由=${decision.preferredBackend} | ` +
      `软解兜底=${decision.fallback}`;

    hilog.info(CommonConstants.LOG_DOMAIN, TAG, message);
  }

  private getChannelTag(channels: number): string {
    if (channels >= 8) {
      return '7.1';
    }
    if (channels >= 6) {
      return '5.1';
    }
    if (channels <= 1) {
      return '1.0';
    }
    return '2.0';
  }

  /**
   * codec-aware 初始音轨候选选择器（thin delegation to `AudioTrackRoutingService`）。
   *
   * 行为与原实现字节级一致：
   * 1. 偏好轨（audioTracks[0]）可播放 → 直接使用
   * 2. 偏好轨不可播放，存在同语言可播放轨 → 同语言降级
   * 3. 无同语言候选，存在任意可播放轨 → 任意可播放降级
   * 4. 全部不可播放 → 返回 0
   *
   * @returns 应传给 switchAudioTrack 的轨道在 audioTracks 数组中的索引
   */
  private findInitialAudioTrackIndex(): number {
    return serviceFindInitialAudioTrackIndex(this.audioTracks);
  }

  /** prepared 后回调：读取 duration、加载字幕轨道和音轨 */
  private async onPlayerReady(): Promise<void> {
    const readySessionId = this.playbackSessionId;
    const readyResumeToken = `${readySessionId}:${this.backend}`;
    if (this.consumedReadyResumeToken === readyResumeToken) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `忽略重复 onPlayerReady: session=${readySessionId} backend=${this.backend}`);
      return;
    }
    this.consumedReadyResumeToken = readyResumeToken;
    this.hasPrepared = true;
    const playerDuration = this.player?.duration ?? 0;
    this.duration = playerDuration > 0
      ? playerDuration
      : (this.currentVideoData?.durationHintMs ?? 0);
    this.currentTime = this.player?.currentTime ?? 0;
    this.isReady = true;
    this.isLoading = false;
    this.transitionTo(PlaybackState.PREPARED);
    const firstFrameElapsed = Date.now() - this.metricsLoadStartMs;
    hilog.info(CommonConstants.LOG_DOMAIN, METRICS_TAG,
      `{"event":"first_frame","backend":"${this.backend}","video_id":${this.progressContext?.videoId ?? -1},"elapsed_ms":${firstFrameElapsed}}`);
    hilog.info(CommonConstants.LOG_DOMAIN, METRICS_TAG,
      `{"event":"play_result","backend":"${this.backend}","video_id":${this.progressContext?.videoId ?? -1},"result":"success","elapsed_ms":${firstFrameElapsed}}`);
    if (MetricsService.isInitialized()) {
      const sourceType = this.currentVideoData?.type === VideoDataType.FILE_URI ? 'local' : 'network';
      MetricsService.getInstance().recordPlaybackAttempt(true, firstFrameElapsed, this.metricsMedia ?? undefined, sourceType);
    }

    const pendingResumeState = this.consumePendingResumeState();
    if (this.playbackSpeed !== 1.0 && this.player) {
      this.player.setPlaybackSpeed(this.playbackSpeed);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `onPlayerReady: 重新应用播放速率 speed=${this.playbackSpeed}`);
    }

    const resumeTimeMs = pendingResumeState?.positionMs ?? -1;
    // 服务器媒体续播（seekTime>0）也应 seek 后自动续播。
    const shouldResumePlay = (pendingResumeState?.shouldResumePlay ?? false) || (this.currentVideoData?.seekTime ?? 0) > 0;
    const resumeSource = pendingResumeState?.reason ?? '';
    const resumeCaptureBackend = pendingResumeState?.captureBackend ?? this.backend;
    const resumeAutoplayDecisionSource = pendingResumeState?.autoplayDecisionSource ?? '';
    const resumeAutoplayDecisionOrigin = pendingResumeState?.autoplayDecisionOrigin ?? '';
    const effectiveResumeTimeMs = resumeTimeMs > 0 && this.duration > 0 && resumeTimeMs > this.duration
      ? this.duration
      : (resumeTimeMs > 0 ? resumeTimeMs : 0);
    // 服务器媒体续播：起始位置通过 VideoData.seekTime 传入（回退 fallback 未捕获到的续播位置）。
    // 按当前媒体时长裁剪，避免服务器保存的越界进度直接传给 player.seek()。
    const rawSeekStartMs = this.currentVideoData?.seekTime ?? 0;
    const seekStartMs = this.duration > 0
      ? Math.min(Math.max(rawSeekStartMs, 0), this.duration)
      : Math.max(rawSeekStartMs, 0);
    const resumeTargetMs = effectiveResumeTimeMs > 0 ? effectiveResumeTimeMs : seekStartMs;
    if (pendingResumeState !== null) {
      this.logResumeDiagnostic('resume_pending_consume', resumeSource, resumeCaptureBackend, resumeTimeMs,
        effectiveResumeTimeMs, shouldResumePlay, 'pending', -1,
        resumeAutoplayDecisionSource, resumeAutoplayDecisionOrigin);
    }

    if (resumeTargetMs > 0 && this.player) {
      const safeResumeTimeMs = resumeTargetMs;
      // MPV 后端 load 后会自动进入 playing 状态，必须先暂停再 seek，
      // 否则 seekPercent 在播放中精度不足（尤其百分比很小时），
      // 且 position 事件会不断更新 currentTime 导致 seek 目标被覆盖。
      if (this.backend === 'mpv') {
        try {
          await this.player.pause();
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `onPlayerReady: MPV 自动播放已暂停，准备 seek 到 ${safeResumeTimeMs}ms`);
        } catch (e) {
          hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
            `onPlayerReady: MPV pause 异常: ${(e as BusinessError).message ?? 'unknown'}`);
        }
      }
      this.currentTime = safeResumeTimeMs;
      this.progress = this.duration > 0 ? safeResumeTimeMs / this.duration : 0;
      this.subtitleAdapter.onSeekSync();
      this.applySubtitleBridgeState(this.subtitleAdapter.getState());
      this.isSeeking = true;
      this.transitionTo(PlaybackState.SEEKING);
      this.resumeSession.beginResumeSeek(resumeSource, resumeCaptureBackend, safeResumeTimeMs, shouldResumePlay);
      this.primePendingResumeAutoplayResult(resumeSource, resumeCaptureBackend, resumeTimeMs,
        safeResumeTimeMs, shouldResumePlay, shouldResumePlay ? 'play_after_seek' : 'suppress_after_seek',
        resumeAutoplayDecisionSource, resumeAutoplayDecisionOrigin);
      this.logResumeDiagnostic('resume_seek_dispatch', resumeSource, resumeCaptureBackend, resumeTimeMs,
        safeResumeTimeMs, shouldResumePlay, shouldResumePlay ? 'play_after_seek' : 'suppress_after_seek', -1,
        resumeAutoplayDecisionSource, resumeAutoplayDecisionOrigin);
      this.player.seek(safeResumeTimeMs);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `后端切换续播定位: backend=${this.backend} time=${safeResumeTimeMs}`);
      // 先建立 isSeeking 再发 PREPARED，避免 VideoPlayer 监听器在续播 seek 进行中立即 play 导致「先从头播再跳」。
      emitter.emit(PlayerEvents.PREPARED);
      return;
    }

    emitter.emit(PlayerEvents.PREPARED);

    await this.finalizePlayerReadyTrackInitialization(readySessionId);
    if (pendingResumeState !== null && pendingResumeState.shouldResumePlay && !this.isPlaying) {
      this.primePendingResumeAutoplayResult(resumeSource, resumeCaptureBackend, resumeTimeMs,
        effectiveResumeTimeMs, shouldResumePlay, 'play_no_seek', resumeAutoplayDecisionSource,
        resumeAutoplayDecisionOrigin);
      this.logResumeDiagnostic('resume_autoplay_decision', resumeSource, resumeCaptureBackend, resumeTimeMs,
        effectiveResumeTimeMs, shouldResumePlay, 'play_no_seek', -1,
        resumeAutoplayDecisionSource, resumeAutoplayDecisionOrigin);
      await this.play();
    } else if (pendingResumeState !== null && shouldResumePlay) {
      this.primePendingResumeAutoplayResult(resumeSource, resumeCaptureBackend, resumeTimeMs,
        effectiveResumeTimeMs, shouldResumePlay, 'play_no_seek_already_playing', resumeAutoplayDecisionSource,
        resumeAutoplayDecisionOrigin);
      this.recordPendingResumeAutoplayResult('play_started', true);
    } else if (pendingResumeState !== null) {
      this.primePendingResumeAutoplayResult(resumeSource, resumeCaptureBackend, resumeTimeMs,
        effectiveResumeTimeMs, shouldResumePlay, 'paused_no_seek', resumeAutoplayDecisionSource,
        resumeAutoplayDecisionOrigin);
      this.recordPendingResumeAutoplayResult('paused', true);
    }
  }

  private async finalizePlayerReadyTrackInitialization(sessionId: number = this.playbackSessionId): Promise<void> {
    if (sessionId !== this.playbackSessionId) {
      return;
    }
    await this.loadSubtitleTracks();
    if (sessionId !== this.playbackSessionId) {
      return;
    }
    await this.loadAudioTracks();
    if (sessionId !== this.playbackSessionId) {
      return;
    }
    this.recordSubtitleUsageAtPlaybackStart();
  }

  private primePendingResumeAutoplayResult(
    resumeSource: string,
    captureBackend: PlayerBackend,
    pendingResumeMs: number,
    effectiveResumeMs: number,
    shouldResumePlay: boolean,
    autoplayDecision: string,
    autoplayDecisionSource: string,
    autoplayDecisionOrigin: string
  ): void {
    this.resumeSession.result = {
      resumeSource,
      captureBackend,
      pendingResumeMs,
      effectiveResumeMs,
      shouldResumePlay,
      autoplayDecision,
      autoplayDecisionSource,
      autoplayDecisionOrigin
    };
  }

  private recordPendingResumeAutoplayResult(result: string, shouldClear: boolean): void {
    const pendingState = this.resumeSession.result;
    if (pendingState === null) {
      return;
    }
    this.logResumeDiagnostic('resume_autoplay_result', pendingState.resumeSource, pendingState.captureBackend,
      pendingState.pendingResumeMs, pendingState.effectiveResumeMs, pendingState.shouldResumePlay,
      pendingState.autoplayDecision, -1, pendingState.autoplayDecisionSource, pendingState.autoplayDecisionOrigin, result);
    if (shouldClear) {
      this.resumeSession.result = null;
    }
  }

  private recordSubtitleUsageAtPlaybackStart(): void {
    // Task 5.5: Record subtitle usage at playback start (once per session, avoid double-counting)
    // 缺陷 2 修复：移除 activeSubtitleIndex < 0 的条件判断，始终记录一次，
    //   并取当前激活轨道的语言（auto-select 已在 loadSubtitleTracks 内完成）。
    // switchSubtitleTrack 中不再调用 recordSubtitleUsage，防止同一播放会话重复计数。
    if (MetricsService.isInitialized()) {
      let startSubtitleLang: string | null = null;
      if (this.activeSubtitleIndex >= 0 && this.activeSubtitleIndex < this.allSubtitleTracks.length) {
        startSubtitleLang = this.allSubtitleTracks[this.activeSubtitleIndex].language ?? null;
      }
      MetricsService.getInstance().recordSubtitleUsage(startSubtitleLang);
    }
  }

  private async continuePendingReadyAfterSeek(sessionId: number = this.playbackSessionId): Promise<void> {
    if (sessionId !== this.playbackSessionId || !this.resumeSession.trackInitAfterSeek) {
      return;
    }
    const shouldResumePlay = this.resumeSession.trackInitResumePlay;
    this.resumeSession.trackInitAfterSeek = false;
    this.resumeSession.trackInitResumePlay = false;
    await this.finalizePlayerReadyTrackInitialization(sessionId);
    if (sessionId !== this.playbackSessionId) {
      return;
    }
    if (shouldResumePlay && !this.isPlaying) {
      await this.play();
    } else {
      this.recordPendingResumeAutoplayResult('paused', true);
    }
  }

  /**
   * 记录当前失败 codec 的设备/固件纠偏结果。
   * 优先取当前激活音轨的 codec，其次取路由决策的 detectedCodec。
   */
  private recordCurrentCodecCorrection(reason: string): void {
    let codec = '';
    if (this.activeAudioIndex >= 0 && this.activeAudioIndex < this.audioTracks.length) {
      const track = this.audioTracks[this.activeAudioIndex];
      codec = (track.codecName ?? track.mimeType) ?? '';
    }
    if (codec.length === 0 && this.lastRoutingDecision !== undefined) {
      codec = this.lastRoutingDecision.detectedCodec;
    }
    if (codec.length > 0 && codec !== 'unknown') {
      audioDecoderCapabilityService.recordCorrection(codec, reason);
    }
  }

  private fallbackAvPlayerToMpv(reason: string, detailMessage: string = ''): void {
    if (this.backend !== 'avplayer') {
      return;
    }
    this.capturePendingResumeForFallback(reason);
    this.logFallbackEvent(reason, 'avplayer', 'mpv', detailMessage);
    this.isLoading = true;
    this.transitionTo(PlaybackState.PREPARING);
    this.forceMpvForNextInit = true;
    if (this.currentVideoData !== undefined && this.currentOriginalVideoSrc.startsWith('smb://')) {
      this.currentVideoData.videoSrc = this.currentOriginalVideoSrc;
    }
    const oldPlayer = this.player;
    this.player = undefined;
    VidAllPlayerAdapter.releaseSmbProxy();
    this.backend = 'mpv';
    oldPlayer?.release().catch(() => {});
  }

  private handleTerminalPlayerError(message: string): void {
    this.isLoading = false;
    this.isPlaying = false;
    this.transitionTo(PlaybackState.ERROR);
    this.lastErrorMessage = this.normalizePlayerError(message);
    this.rejectPendingReload(new Error(message));
  }

  private capturePendingResumeForFallback(source: string): void {
    const playerPosition = this.player?.currentTime ?? 0;
    const controllerPosition = this.currentTime > 0 ? this.currentTime : 0;
    const latestPosition = playerPosition > controllerPosition ? playerPosition : controllerPosition;
    const autoplayDecision = this.resolvePendingResumeAutoplayDecision(
      this.isPlaying || this.isSeeking,
      'transient_player_state'
    );
    this.savePendingResumeState(latestPosition, autoplayDecision.shouldResumePlay,
      autoplayDecision.source, autoplayDecision.origin, source, this.backend);
  }

  private logFallbackEvent(
    fallbackReason: string,
    fallbackFrom: PlayerBackend,
    fallbackTo: PlayerBackend,
    detailMessage: string = ''
  ): void {
    const structured: FallbackLogRecord = {
      fallbackReason,
      fallbackFrom,
      fallbackTo,
      videoId: this.progressContext?.videoId ?? -1,
      filePath: this.sanitizeLogFilePath(this.currentVideoData?.videoSrc ?? ''),
      detailMessage
    };
    hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
      `[fallback] ${JSON.stringify(structured)}`);
    // 指标埋点：play_result=fallback（便于 VidAll_Metrics 过滤统计兜底触发率）
    hilog.warn(CommonConstants.LOG_DOMAIN, METRICS_TAG,
      `{"event":"play_result","backend":"${fallbackFrom}","video_id":${structured.videoId},"result":"fallback","fallback_from":"${fallbackFrom}","fallback_to":"${fallbackTo}","reason":"${fallbackReason}"}`);
  }

  private logResumeDiagnostic(
    event: string,
    resumeSource: string,
    captureBackend: PlayerBackend,
    pendingResumeMs: number,
    effectiveResumeMs: number,
    autoResumePlay: boolean,
    autoplayDecision: string,
    queuedSeekMs: number,
    autoplayDecisionSource: string = '',
    autoplayDecisionOrigin: string = '',
    autoplayExecutionResult: string = ''
  ): void {
    const record: ResumeDiagnosticLogRecord = {
      event,
      sessionId: this.playbackSessionId,
      backend: this.backend,
      videoId: this.progressContext?.videoId ?? -1,
      seriesProviderId: this.progressContext?.seriesProviderId ?? '',
      seasonNumber: this.progressContext?.seasonNumber ?? 0,
      episodeNumber: this.progressContext?.episodeNumber ?? 0,
      resumeSource,
      captureBackend,
      pendingResumeMs,
      effectiveResumeMs,
      autoResumePlay,
      autoplayDecision,
      autoplayDecisionSource,
      autoplayDecisionOrigin,
      autoplayExecutionResult,
      queuedSeekMs,
      isSeeking: this.isSeeking,
      currentTimeMs: this.currentTime,
      durationMs: this.duration,
      filePath: this.sanitizeLogFilePath(this.currentVideoData?.videoSrc ?? '')
    };
    this.emitResumeDiagnosticRecord(`[resume] ${JSON.stringify(record)}`);
  }

  protected emitResumeDiagnosticRecord(recordText: string): void {
    hilog.info(CommonConstants.LOG_DOMAIN, TAG, recordText);
  }

  private handlePlayerPlayEvent(currentSessionId: number): void {
    if (currentSessionId !== this.playbackSessionId) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `[session=${currentSessionId}] 忽略过期 onPlay`);
      return;
    }
    this.recordPendingResumeAutoplayResult('play_started', true);
    this.clearPendingResumeAutoplayDecision();
    this.isPlaying = true;
    this.isLoading = false;
    this.transitionTo(PlaybackState.PLAYING);
    // 成功播放后清理历史错误，避免底部长期显示旧报错。
    this.lastErrorMessage = '';
    if (ENABLE_SESSION_DIAG_LOG) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[session=${currentSessionId}] onPlay`);
    }
    this.resumeSubtitleTimer();
    this.startProgressTimer();
    emitter.emit(PlayerEvents.PLAYING);
  }

  private extractFileName(filePath: string): string {
    if (filePath.length === 0) {
      return '';
    }
    const clean = filePath.replace(/\?.*$/, '');
    const lastSlash = clean.lastIndexOf('/');
    return lastSlash >= 0 ? clean.substring(lastSlash + 1) : clean;
  }

  /**
   * 构造播放会话的媒体标识对象，供 metrics 上报使用。
   * 在 initPlayer 开始时（适配器回调注册前）异步调用，结果缓存到 metricsMedia 字段。
   * 异常时降级返回仅含 local_id 的最小标识，不影响播放主流程。
   */
  private async buildMediaIdentity(videoId: number): Promise<MediaIdentity> {
    try {
      const db = FileSourceDatabase.getInstance();
      const scrapeInfo = await db.getScrapeInfoByVideoId(videoId);
      const videoEntity = await db.getVideoById(videoId);
      const media: MediaIdentity = {
        local_id: videoId,
        provider: scrapeInfo?.provider ?? null,
        provider_id: scrapeInfo?.providerId ?? null,
        title: scrapeInfo?.title ?? null,
        year: null,
        file_name: videoEntity?.fileName ?? ''
      };
      return media;
    } catch (e) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, `buildMediaIdentity 失败 videoId=${videoId}: ${e}`);
      const fallback: MediaIdentity = {
        local_id: videoId,
        provider: null,
        provider_id: null,
        title: null,
        year: null,
        file_name: ''
      };
      return fallback;
    }
  }

  private sanitizeLogFilePath(filePath: string): string {
    if (filePath.length === 0) {
      return '';
    }
    const schemeMatch = filePath.match(/^([a-zA-Z][a-zA-Z0-9+\-.]*):/);
    if (schemeMatch !== null && schemeMatch[1].length > 0) {
      return `${schemeMatch[1].toLowerCase()}://***`;
    }
    return '***';
  }

  async play(): Promise<void> {
    if (!this.player) {
      this.recordPendingResumeAutoplayResult('play_no_player', true);
      return;
    }
    try {
      await this.player.play();
      this.duration = this.player.duration;
      this.recordPendingResumeAutoplayResult('play_requested', false);
    } catch (err) {
      const playError = err as BusinessError;
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `play 失败: code=${playError.code} msg=${playError.message}`);
      this.lastErrorMessage = this.normalizePlayerError(playError.message);
      this.recordPendingResumeAutoplayResult('play_failed', true);
    }
  }

  private normalizePlayerError(message: string): string {
    const msg = (message ?? '').trim();
    if (msg.length === 0) {
      return '播放器内部错误，请重试';
    }
    if (msg.toLowerCase() === GENERIC_SYSTEM_ERROR) {
      return '播放器内部错误，请重试';
    }
    return msg;
  }

  async pause(): Promise<void> {
    if (this.resumeSession.fallbackTimer !== undefined) {
      this.clearResumeSeekAutoplayFallbackState();
      this.clearPendingResumeAutoplayDecision();
      this.resumeSession.suppressPlayAfterSeek = true;
    }
    try {
      await this.player?.pause();
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `pause 失败: code=${err.code} msg=${err.message}`);
    }
  }

  async toggle(): Promise<void> {
    await this.player?.toggle();
  }

  async release(): Promise<void> {
    this.transitionTo(PlaybackState.RELEASING);
    this.rejectPendingReload(new Error('player released'));
    this.resumeSession.result = null;
    this.clearResumeSeekAutoplayFallbackState();
    this.stopProgressTimer();
    this.saveProgressNow();
    // 重置 MPV surface 绑定状态，避免后续绑定被误判为重复调用。
    this.mpvSurfaceBound = false;
    if (this.subtitleClearTimer) {
      clearTimeout(this.subtitleClearTimer);
      this.subtitleClearTimer = undefined;
    }
    this.subtitleAdapter.release();
    this.currentSubtitleText = '';
    if (this.player) {
      await this.player.release().catch(() => {});
      this.player = undefined;
    }
    VidAllPlayerAdapter.releaseSmbProxy();
    // 释放 VPE 实例（播放器已销毁后再销毁 VPE，避免 Surface 竞争）
    VpeEnhancerUtil.destroyEnhancer();
    this.transitionTo(PlaybackState.IDLE);
  }

  async seek(time: number, autoplayDecisionSource: string = ''): Promise<void> {
    if (!this.player) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, `[seek] player 为 null，跳过 target=${time}`);
      return;
    }
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[seek] 入口: target=${time}ms isSeeking=${this.isSeeking} backend=${this.backend} duration=${this.duration}`);
    this.metricsSeekStartMs = Date.now();
    this.clearResumeSeekAutoplayFallbackState();
    let safeTime = time < 0 ? 0 : time;
    if (this.duration > 0 && safeTime > this.duration) {
      safeTime = this.duration;
    } else if (this.duration <= 0 && safeTime > 0) {
      const now = Date.now();
      if (now - this.lastSeekDurationUnknownLogMs >= 3000) {
        this.lastSeekDurationUnknownLogMs = now;
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `[seek] duration 未就绪，暂不做上限裁剪 target=${safeTime}`);
      }
    }
    if (autoplayDecisionSource.length > 0) {
      this.rememberPendingResumeAutoplayDecision(true, autoplayDecisionSource);
      this.resumeSession.preserveOnPaused = true;
    } else {
      this.resumeSession.preserveOnPaused = false;
    }
    // 在 await pause() 前先占用 seek 状态。PREPARED 的监听器会同步启动音轨初始化，
    // 延后标记会让自动选轨把刚恢复的进度又 flush 回初始 position。
    const canDispatchSeek = !this.isSeeking;
    if (canDispatchSeek) {
      this.isSeeking = true;
      this.transitionTo(PlaybackState.SEEKING);
    }
    await this.pause();
    this.currentTime = safeTime;
    this.subtitleAdapter.onSeekSync();
    this.applySubtitleBridgeState(this.subtitleAdapter.getState());
    if (canDispatchSeek) {
      try {
        this.player.seek(safeTime);
        if (autoplayDecisionSource.length > 0) {
          this.armResumeSeekAutoplayFallback(this.playbackSessionId);
        }
      } catch (seekErr) {
        // 同步 seek 失败时重置状态，避免后续 seek 永久排队。
        this.isSeeking = false;
        this.transitionTo(PlaybackState.PAUSED);
        this.clearResumeSeekAutoplayFallbackState();
        this.clearPendingResumeAutoplayDecision();
        hilog.error(CommonConstants.LOG_DOMAIN, TAG,
          `seek 调用异常: ${(seekErr as BusinessError).message ?? 'unknown'}`);
      }
    } else {
      this.timeToSeek = safeTime;
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
      // 同步清空 adapter 内部状态，防止后续 applySubtitleBridgeState 还原过期字幕
      this.subtitleAdapter.onSubtitleUpdate({ text: '' });
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

  // ─────────────────────────────────────────────
  // 播放进度持久化（10s 防抖写入）
  // ─────────────────────────────────────────────

  /**
   * 启动 10s 防抖进度写入定时器，播放状态下每 10s 写一次进度。
   */
  private startProgressTimer(): void {
    this.stopProgressTimer();
    if (this.progressContext === null) { return; }
    this.progressTimer = setInterval(() => {
      this.saveProgressNow();
    }, 10000);
  }

  /** 停止进度写入定时器 */
  private stopProgressTimer(): void {
    if (this.progressTimer !== undefined) {
      clearInterval(this.progressTimer);
      this.progressTimer = undefined;
    }
  }

  /**
   * 立即写入当前进度（用于暂停/退出/切后台时强制落盘）。
   * 写入失败仅打 warn，不阻塞。
   */
  saveProgressNow(): void {
    if (this.progressContext === null) { return; }
    if (this.currentTime <= 0 && this.duration <= 0) { return; }
    const ctx = this.progressContext;
    const progress: PlayProgressEntity = {
      videoId: ctx.videoId,
      seriesProviderId: ctx.seriesProviderId,
      seasonNumber: ctx.seasonNumber,
      episodeNumber: ctx.episodeNumber,
      positionMs: this.currentTime,
      durationMs: this.duration > 0 ? this.duration : ctx.durationMs,
      updatedAt: Date.now()
    };
    FileSourceDatabase.getInstance().upsertPlayProgress(progress).catch(() => {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, '进度写入失败');
    });
  }

  @Computed
  get durationDisplay(): string {
    return millisecondsToTime(this.duration)
  }

  @Computed
  get currentTimeDisplay(): string {
    return millisecondsToTime(this.currentTime)
  }

  private applySubtitleBridgeState(state: SubtitleBridgeState): void {
    const prevText = this.currentSubtitleText;
    this.subtitleTracks = state.subtitleTracks;
    this.allSubtitleTracks = state.allSubtitleTracks;
    this.activeSubtitleIndex = state.activeSubtitleIndex;
    this.currentSubtitleTrack = state.currentSubtitleTrack;
    this.currentSubtitleText = state.currentSubtitleText;
    this.subtitleDelayMs = state.subtitleDelayMs;
    if (prevText !== this.currentSubtitleText) {
      this.subtitleUpdateCounter++;
    }
  }

  /**
   * 按视频播放时间输出当前字幕轨与字幕内容，便于排查“有轨道但无显示”问题。
   */
  private logSubtitleTimeline(currentTimeMs: number): void {
    if (currentTimeMs - this.lastSubtitleTimelineLogMs < this.SUBTITLE_TIMELINE_LOG_INTERVAL) {
      return;
    }
    this.lastSubtitleTimelineLogMs = currentTimeMs;

    const activeIndex = this.activeSubtitleIndex;
    let trackLabel = '关闭字幕';
    let trackKind = 'none';
    if (activeIndex >= 0 && activeIndex < this.allSubtitleTracks.length) {
      const item = this.allSubtitleTracks[activeIndex];
      trackLabel = item.displayName;
      trackKind = item.kind;
    }

    const subtitleTextRaw = this.currentSubtitleText.length > 0
      ? this.currentSubtitleText
      : '(空)';
    const subtitleText = subtitleTextRaw.replace(/\r?\n/g, ' ');
    const logText = subtitleText.length > 100
      ? subtitleText.substring(0, 100) + '...'
      : subtitleText;

    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[字幕时间轴] t=${currentTimeMs}ms (${millisecondsToTime(currentTimeMs)})` +
      ` activeIndex=${activeIndex} kind=${trackKind}` +
      ` track="${trackLabel}" delay=${this.subtitleDelayMs}ms text="${logText}"`);
  }

  /** 是否正在使用外部 SRT 字幕（用于 UI 判断是否需要 ASS 逗号提取） */
  get hasSrtSubtitle(): boolean {
    return this.subtitleAdapter.getState().hasExternalActive;
  }

  /**
   * 字幕会话初始化（thin delegation to `SubtitleSessionService.initialize`）。
   *
   * 行为与原 `loadSubtitleTracks` 字节级一致：
   * - subtitleAdapter.init
   * - 应用 bridge state 到 @Trace 字段
   * - 调度器步骤 1（用户绑定）/ 步骤 4（本地缓存）覆盖
   * - 失败回退到 NoSubtitleBridgeAdapter
   */
  private async loadSubtitleTracks(): Promise<void> {
    if (!this.player) {
      return;
    }
    // 构建缓存上下文（filesDir 由外部注入，sourceType/sourceId 来自 VideoData）
    let cacheCtx: SubtitleCacheContext | undefined = undefined;
    const cachedFilesDir = this.subtitleCacheContext?.filesDir;
    if (cachedFilesDir !== undefined) {
      const rawSourceType = this.currentVideoData?.fileSourceType;
      const resolvedSourceType = rawSourceType !== undefined ? rawSourceType :
        (this.currentVideoData?.type === VideoDataType.FILE_URI ? 'local' : 'network');
      const resolvedSourceId = this.currentVideoData?.fileSourceId ?? '0';
      const ctx: SubtitleCacheContext = {
        filesDir: cachedFilesDir,
        sourceType: resolvedSourceType,
        sourceId: resolvedSourceId
      };
      cacheCtx = ctx;
    }

    // 委托给 SubtitleSessionService
    await this.subtitleSessionSvc.initialize(
      this.subtitleAdapter,
      this.player,
      this.currentVideoData,
      this.currentOriginalVideoSrc,
      cacheCtx
    );
    // 同步 service session state 到 controller 的 @Trace 字段
    this.applySubtitleBridgeState(this.subtitleAdapter.getState());

    // 容错：若 service 报 fallback-no-bridge，自身适配器已被 service 重置为 NoSubtitleBridgeAdapter
    // 保留原 catch 行为（service 已内部处理，但 controller 兜底）
  }

  /**
   * 加载音轨列表 + 选择初始轨。
   *
   * 初始轨选择已委托给 `AudioTrackRoutingService.resolveInitialTrackIndex`（含用户绑定恢复与
   * codec-aware 默认选轨）。两条入口路径：
   * - presetAudioTracks 已在 initPlayer 提前填充 → 直接调 service 选轨
   * - player.getTrackInfos() 运行时枚举 → 构造列表后再调 service 选轨
   */
  private async loadAudioTracks(): Promise<void> {
    if (!this.player) { return; }

    try {
      // ── 已在 initPlayer 提前填充（presetAudioTracks 路径）──
      if (this.audioTracks.length > 0) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[loadAudioTracks] 已提前填充 ${this.audioTracks.length} 条音轨，直接选择默认轨道`);
        // 详细打印（用于 verify 真机回溯）
        for (let i = 0; i < this.audioTracks.length; i++) {
          const t = this.audioTracks[i];
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `[loadAudioTracks] 预置音轨[${i}]: trackIndex=${t.trackIndex} ` +
            `displayName=${t.displayName} mime=${t.mimeType ?? ''} ` +
            `codecName=${t.codecName ?? ''} lang=${t.language ?? ''}`);
        }
            await this.selectInitialAudioTrackByService();
        return;
      }

      // ── player.getTrackInfos()（AVPlayer / MPV 运行时轨道）──
      const allTracks = await this.player.getTrackInfos();
      const audioTracksInfo = allTracks.filter((t: TrackInfo) => t.trackType === 'audio');
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[loadAudioTracks] getTrackInfos() 返回音轨数: ${audioTracksInfo.length}`);
      audioTracksInfo.forEach((t: TrackInfo, i: number) => {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `音轨[${i}]: trackIndex=${t.trackIndex} mime=${t.mimeType} lang=${t.language}`);
      });

      const tracks: AudioTrackItem[] = [];
      for (let i = 0; i < audioTracksInfo.length; i++) {
        const t = audioTracksInfo[i];
        const item: AudioTrackItem = {
          trackIndex: t.trackIndex,
          displayName: this.getAudioTrackName(i, t),
          language: t.language,
          mimeType: t.mimeType
        };
        tracks.push(item);
      }
      this.audioTracks = tracks;

      if (this.audioTracks.length > 0) {
        await this.selectInitialAudioTrackByService();
      }
    } catch (e) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `加载音轨失败: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 内部辅助：调 `AudioTrackRoutingService.resolveInitialTrackIndex` 决定初始轨。
   * - 命中用户绑定 → 应用该轨
   * - 命中用户绑定但 displayName 已失效 → service 自动清除绑定，回退默认
   * - 无用户绑定 → codec-aware 默认选轨
   */
  private async selectInitialAudioTrackByService(): Promise<void> {
    const videoPath = this.currentOriginalVideoSrc.length > 0
      ? this.currentOriginalVideoSrc
      : (this.currentVideoData?.videoSrc ?? '');
    if (videoPath.length === 0) {
      await this.switchAudioTrack(serviceFindInitialAudioTrackIndex(this.audioTracks));
      return;
    }
    const result = await this.audioRoutingService.resolveInitialTrackIndex(videoPath, this.audioTracks);
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[loadAudioTracks] AudioTrackRoutingService 选轨: source=${result.source} trackIndex=${result.trackIndex} shouldClearUserBinding=${result.shouldClearUserBinding}`);
    await this.switchAudioTrack(result.trackIndex);
  }

  /** 获取音轨显示名称 */
  private getAudioTrackName(trackIndex: number, trackInfo: TrackInfo): string {
    let name = '';
    if (trackInfo.language) {
      name = this.getLanguageName(trackInfo.language);
    } else {
      name = `音轨 ${trackIndex + 1}`;
    }

    // 如果有 MIME 类型，添加格式信息
    if (trackInfo.mimeType) {
      const format = this.extractAudioFormat(trackInfo.mimeType);
      if (format) {
        name = `${name} (${format})`;
      }
    }

    return name;
  }

  /** 从 MIME 类型提取音频格式 */
  private extractAudioFormat(mimeType: string): string {
    const audioFormats: Record<string, string> = {
      'audio/mp4a-latm': 'AAC',
      'audio/mp4a': 'AAC',
      'audio/aac': 'AAC',
      'audio/ac-3': 'AC-3',
      'audio/eac3': 'E-AC-3',
      'audio/mpeg': 'MP3',
      'audio/flac': 'FLAC',
      'audio/opus': 'Opus',
      'audio/vorbis': 'Vorbis',
      'audio/pcm': 'PCM',
      'audio/dts': 'DTS'
    };

    for (const key of Object.keys(audioFormats)) {
      if (mimeType.includes(key)) {
        return audioFormats[key];
      }
    }

    return '';
  }

  async selectSubtitleTrack(trackIndex: number): Promise<void> {
    if (!this.player) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `[selectSubtitleTrack] player 未初始化，无法切换到轨道 ${trackIndex}`);
      return;
    }
    if (trackIndex < -1) {
      const errorMessage = `字幕轨道索引非法: ${trackIndex}`;
      this.lastErrorMessage = errorMessage;
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `[selectSubtitleTrack] ${errorMessage}`);
      return;
    }
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[selectSubtitleTrack] 调用 player.selectTrack(${trackIndex})，backend=${this.backend}`);
    try {
      await this.player.selectTrack(trackIndex);
      this.currentSubtitleTrack = trackIndex;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        trackIndex < 0
          ? `[selectSubtitleTrack] ✓ 字幕已关闭 (trackIndex=${trackIndex})`
          : `[selectSubtitleTrack] ✓ 内嵌字幕轨道 ${trackIndex} 已激活 (currentSubtitleTrack=${this.currentSubtitleTrack})`);
    } catch (e) {
      const err = e as BusinessError;
      this.lastErrorMessage = this.normalizePlayerError(err.message ?? '字幕切换失败');
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `[selectSubtitleTrack] ✗ 失败: trackIndex=${trackIndex} code=${err.code} msg=${err.message}`);
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
    const displayName = FfprobeUtil.getLanguageDisplayName(languageCode);
    return displayName.length > 0 ? displayName : (languageCode || '字幕');
  }

  // ─────────────────────────────────────────────
  // 统一字幕切换（供 UI 调用）
  // ─────────────────────────────────────────────

  /**
   * 通过 allSubtitleTracks 索引切换字幕（thin delegation to `SubtitleSessionService.switchToTrack`）。
   * allIndex = -1 表示关闭字幕。
   *
   * 行为与原实现字节级一致：
   * - 清除字幕定时器
   * - subtitleAdapter.switchTrack
   * - 应用 binding directive（disabled / external-local-file / internal）
   * - SMB 源使用初始化前的原始 URL 作为稳定绑定 key
   */
  async switchSubtitleTrack(allIndex: number): Promise<void> {
    if (this.subtitleClearTimer !== undefined) {
      clearTimeout(this.subtitleClearTimer);
      this.subtitleClearTimer = undefined;
    }
    this.subtitleRemainingTime = 0;

    // 委托给 SubtitleSessionService 计算 bridge state 变化 + binding directive
    const directive = await this.subtitleSessionSvc.switchToTrack(
      this.subtitleAdapter,
      this.currentVideoData,
      this.currentOriginalVideoSrc,
      allIndex
    );
    this.applySubtitleBridgeState(this.subtitleAdapter.getState());

    // 应用 binding directive 持久化
    const rawVideoSrc = this.currentVideoData?.videoSrc ?? '';
    const videoPath = this.currentOriginalVideoSrc.length > 0 ? this.currentOriginalVideoSrc : rawVideoSrc;
    if (videoPath.length > 0) {
      if (directive.type === 'disabled') {
        this.subtitleDispatcher.clearUserBinding(videoPath).catch(() => {});
      } else if (directive.type === 'external-local-file' && directive.url !== undefined) {
        this.subtitleDispatcher.saveUserBinding(videoPath, directive.url, 'local-file').catch(() => {});
      } else if (directive.type === 'internal' && directive.bindingKey !== undefined) {
        this.subtitleDispatcher.saveUserBinding(videoPath, directive.bindingKey, 'internal').catch(() => {});
      }
    }
  }

  // ─────────────────────────────────────────────
  // 音轨切换（供 UI 调用）
  // ─────────────────────────────────────────────

  /**
   * 通过 audioTracks 索引切换音轨
   */
  async switchAudioTrack(trackIndex: number, userInitiated: boolean = false): Promise<void> {
    if (trackIndex < 0 || trackIndex >= this.audioTracks.length) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `切换音轨失败: 索引越界 ${trackIndex}`);
      return;
    }

    if (!this.player) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, '播放器未初始化');
      return;
    }


    // 初始化加载时（isReady 刚触发，尚未真正播放）直接切换，不需要暂停/恢复
    const wasPlaying = this.isPlaying;
    const seekBack = this.currentTime;
    // prepared 续播可能已在同一事件周期内发起。此时切轨仍可生效，但不能再 pause/seek，
    // 否则会用初始 position 覆盖续播目标。
    const shouldFlushAfterSwitch = wasPlaying && !this.isSeeking;

    try {
      // 1. 暂停视频（避免音轨切换期间画面继续走而音轨还在旧轨）
      if (shouldFlushAfterSwitch) {
        await this.player.pause();
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[switchAudioTrack] 暂停播放，当前时间=${seekBack}ms`);
      }

      // 2. 切换音轨
      const audioTrack = this.audioTracks[trackIndex];
      if (audioTrack.trackIndex < -1) {
        const errorMessage = `音轨参数非法: uiIndex=${trackIndex}, trackIndex=${audioTrack.trackIndex}`;
        this.lastErrorMessage = errorMessage;
        hilog.error(CommonConstants.LOG_DOMAIN, TAG, errorMessage);
        return;
      }
      await this.player.selectTrack(audioTrack.trackIndex);
      this.activeAudioIndex = trackIndex;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[switchAudioTrack] ✓ 音轨已切换: uiIndex=${trackIndex} ` +
        `displayName=${audioTrack.displayName} trackIndex=${audioTrack.trackIndex} ` +
        `mime=${audioTrack.mimeType ?? ''} codecName=${audioTrack.codecName ?? ''} ` +
        `lang=${audioTrack.language ?? ''} userInitiated=${userInitiated} backend=${this.backend}`);

      // 用户主动切换时持久化绑定
      if (userInitiated) {
        const videoPath = this.currentVideoData?.videoSrc ?? '';
        if (videoPath.length > 0) {
          const dispatcher = new AudioDispatcher();
          dispatcher.saveAudioBinding(videoPath, audioTrack.displayName).catch(() => {});
        }
      }

      // 3. seek 到当前位置，强制音频解码器 flush 并从正确位置开始解码
      //    这样恢复播放时新音轨与视频帧完全对齐
      //    如果 resume seek 正在进行中，使用 resume 目标时间而不是 currentTime
      //    （currentTime 可能还没更新到 seek 目标位置）
      const seekTarget = this.resumeSession.seekInFlight
        ? this.resumeSession.seekTargetMs
        : seekBack;
      if (shouldFlushAfterSwitch && seekTarget > 0) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[switchAudioTrack] seek flush 到 ${seekTarget}ms${this.resumeSession.seekInFlight ? ' (resume seek 目标)' : ''}`);
        // 借用 seek() 的暂停-seek-恢复流程：isSeeking=true，seekDone 后自动 play()
        this.isSeeking = true;
        this.transitionTo(PlaybackState.SEEKING);
        this.player.seek(seekTarget);
        // seekDone 回调里会调 play()，不需要在这里手动恢复
      } else if (shouldFlushAfterSwitch) {
        // 时间为 0（片头），直接恢复播放
        await this.player.play();
      }
    } catch (e) {
      const err = e as BusinessError;
      this.lastErrorMessage = this.normalizePlayerError(err.message ?? '音轨切换失败');
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `切换音轨失败: code=${err.code} msg=${err.message}`);
      // 切换失败时尝试恢复播放
      if (wasPlaying) {
        await this.player.play().catch(() => {});
      }
    }
  }

  // ─────────────────────────────────────────────
  // 字幕延迟调整（供 UI 调用）
  // ─────────────────────────────────────────────

  /**
   * 调整字幕延迟偏移量（thin delegation to `SubtitleSessionService.adjustDelay`）。
   *
   * @param deltaMs 增量（单位 ms）。
   *   正值 → 字幕偏慢（画面已出但字幕还没出），增大 subtitleDelayMs，使字幕显示时刻后移
   *   负值 → 字幕偏快（字幕出早了），减小 subtitleDelayMs，使字幕显示时刻前移
   */
  adjustSubtitleDelay(deltaMs: number): void {
    this.subtitleSessionSvc.adjustDelay(this.subtitleAdapter, deltaMs);
    this.applySubtitleBridgeState(this.subtitleAdapter.getState());
  }

  /** 将已下载到本地的字幕文件追加到轨道列表并刷新 UI。 */
  async addExternalSubtitle(localPath: string): Promise<void> {
    await this.subtitleSessionSvc.addLocalSubtitle(this.subtitleAdapter, localPath);
    this.applySubtitleBridgeState(this.subtitleAdapter.getState());
  }

}
