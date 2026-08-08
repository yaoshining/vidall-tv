import { PlayerEvents, VideoDataType } from "./Constants";
import { VideoData, PresetAudioTrack } from "./VideoData";
import { BusinessError, emitter } from "@kit.BasicServicesKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { CommonConstants } from "../../../common/constants/CommonConstants";
import { millisecondsToTime } from "../../../utils/TimeUtil";
import { IPlayer, TrackInfo } from "./IPlayer";
import { AVPlayerAdapter } from "./AVPlayerAdapter";
import { IjkPlayerAdapter } from "./IjkPlayerAdapter";
import { VidAllPlayerAdapter } from "./VidAllPlayerAdapter";
import { MpvPlayerAdapter } from "./MpvPlayerAdapter";
import { FileSourceDatabase } from "../../../db/files/FileSourceDatabase";
import { PlayProgressEntity } from "../../../db/models/MediaEntity";
import { FfprobeUtil } from "../../../utils/FfprobeUtil";
import { FfmpegVideoFrameUtil } from "../../../utils/FfmpegVideoFrameUtil";
import {
  AvSubtitleBridgeAdapter,
  IjkSubtitleBridgeAdapter,
  ISubtitleBridgeAdapter,
  NoSubtitleBridgeAdapter,
  SubtitleBridgeState,
  SubtitleTrackItem
} from "./SubtitleBridgeAdapter";
import { SmbAvSubtitleBridgeAdapter } from "./SmbSubtitleBridgeAdapter";
import { VpeEnhancerUtil, VpeQualityLevel } from "../../../utils/VpeEnhancerUtil";
import { ParsedSubtitle } from "./SubtitleRenderer";
import { PlaybackContext } from "./PlaybackContext";
import { AppPreferences, PrefKey } from "../../../utils/AppPreferences";
import {
  DEFAULT_EPISODE_AUTOPLAY_COUNTDOWN_SECONDS,
  DEFAULT_EPISODE_AUTOPLAY_ENABLED
} from "./EpisodeAutoplayPreferences";
import { MetricsService } from "../../../services/metrics/MetricsService";
import { MediaIdentity } from "../../../services/metrics/MetricsReporter";
import { SubtitleDispatcher, SubtitleCacheContext } from "../../../subtitle/SubtitleDispatcher";
import { AudioDispatcher } from "../../../audio/AudioDispatcher";
// ─── Runtime session services (Module 4: refactor-player-runtime-session-services) ───
import { playbackBackendService, PlaybackBackendService, PlaybackAdapterCallbacks } from
  "../../../services/playback/PlaybackBackendService";
import type { PlaybackBackendDecision } from
  "../../../services/playback/PlaybackBackendTypes";
import { SubtitleSessionService } from
  "../../../services/subtitleSession/SubtitleSessionService";
import {
  audioTrackRoutingService,
  AudioTrackRoutingService,
  PresetAudioHint,
  readPresetAudioHint,
  findInitialAudioTrackIndex as serviceFindInitialAudioTrackIndex
} from "../../../services/audioRouting/AudioTrackRoutingService";
import type { AudioRoutingDecision } from "../../../services/audioRouting/AudioRoutingTypes";

export type { SubtitleTrackItem } from "./SubtitleBridgeAdapter";

/** 播放内核类型 */
export type PlayerBackend = 'avplayer' | 'ijkplayer' | 'mpv' | 'ffmpeg' | 'native';

export function resolveAiEnhanceEnabledByRuntime(runtimeSupported: boolean, requestedEnabled: boolean): boolean {
  return runtimeSupported && requestedEnabled;
}

export function shouldShowAiEnhanceSettingsByRuntime(runtimeSupported: boolean, backend: PlayerBackend): boolean {
  return runtimeSupported && backend === 'avplayer';
}

export function resolveEffectivePlaybackSurfaceId(displaySurfaceId: string, vpeSurfaceId: string): string {
  if (vpeSurfaceId.length > 0) {
    return vpeSurfaceId;
  }
  return displaySurfaceId;
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
const DEFAULT_NATIVE_SEEK_DIAG_LOG_ENABLED = false;
const NATIVE_READY_GUARD_MS = 3500;
const RESUME_SEEK_AUTOPLAY_FALLBACK_MS = 1500;
const ENABLE_SESSION_DIAG_LOG = false;
const FFMPEG_PREVIEW_RENDER_FPS = 8;
const FFMPEG_PREVIEW_CHUNK_SECONDS = 0.8;
const FFMPEG_PREVIEW_LOW_WATERMARK_FRAMES = 5;
const FFMPEG_PREVIEW_MAX_QUEUE_FRAMES = 18;
const FFMPEG_PREVIEW_DECODE_TIMEOUT_MS = 4000;
const FFMPEG_PREVIEW_MAX_WIDTH = 640;
const FFMPEG_PREVIEW_JPEG_QUALITY = 8;
const FFMPEG_PREVIEW_LEAD_SECONDS = 0.1;
const FFMPEG_PREVIEW_SYNC_OFFSET_MS = 80;
const FFMPEG_PREVIEW_MAX_LAG_DROP_MS = 240;
const FFMPEG_PREVIEW_STALL_STEP_MAX_MS = 1200;
const FFMPEG_PREVIEW_DECODE_RETRY_DELAY_MS = 400;
const FFMPEG_PREVIEW_EXTRACT_STUCK_MS = 1500;
const FFMPEG_PREVIEW_EXTRACT_HARD_TIMEOUT_MS = 6500;
/** 支持的播放速率白名单；控制器层对外输入做归一化，避免后端静默降级导致 UI 显示不一致 */
const SUPPORTED_SPEEDS: number[] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
const FFMPEG_PREVIEW_SINGLE_FRAME_INTERVAL_MS = 180;
const FFMPEG_PREVIEW_FORCE_RESTART_INTERVAL_MS = 2200;
const FFMPEG_PREVIEW_FORCE_RESTART_LAG_MS = 1800;
const FFMPEG_PREVIEW_FORCE_RESTART_SAME_TICKS = 10;
const FFMPEG_PREVIEW_EMPTY_QUEUE_CATCHUP_INTERVAL_MS = 600;
const ENABLE_FFMPEG_PREVIEW_DIAG_LOG = true;
const FFMPEG_PREVIEW_DIAG_LOG_INTERVAL_MS = 1000;

interface FfmpegQueuedFrame {
  uri: string;
  ptsMs: number;
}

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

interface ResumeAutoplayDecision {
  shouldResumePlay: boolean;
  source: string;
  origin: string;
}

interface PendingResumeState {
  positionMs: number;
  shouldResumePlay: boolean;
  autoplayDecisionSource: string;
  autoplayDecisionOrigin: string;
  sourceKey: string;
  reason: string;
  captureBackend: PlayerBackend;
}

interface PendingResumeAutoplayResultState {
  resumeSource: string;
  captureBackend: PlayerBackend;
  pendingResumeMs: number;
  effectiveResumeMs: number;
  shouldResumePlay: boolean;
  autoplayDecision: string;
  autoplayDecisionSource: string;
  autoplayDecisionOrigin: string;
}

interface NativeXComponentFallbackContext {
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
}

export type UnsupportedFormatFallback = 'ijkplayer' | 'mpv' | 'native';

@ObservedV2
export class VideoPlayerController {
  /**
   * 播放内核选择，默认 'avplayer'。
   * 切换为 'ijkplayer' 后，VideoPlayer UI 层需要使用 libraryname='ijkplayer_napi'
   * 的 XComponent，并在 onLoad 回调中调用 controller.setIjkContext(context, id)。
   * 'native'/'ffmpeg' 后端已停止主路径接入，仅保留代码供参考；正常播放不应出现这两个值。
   */
  @Trace backend: PlayerBackend = 'avplayer';

  /** AI 画质增强开关（仅 avplayer 路径有效；ijkplayer 路径因渲染方式不同暂不支持） */
  @Trace aiEnhanceEnabled: boolean = true;
  /** 当前运行环境的 VPE 运行时探测结果 */
  @Trace aiEnhanceRuntimeSupported: boolean = false;
  /** AI 画质增强质量档位 */
  @Trace aiEnhanceQuality: VpeQualityLevel = 'medium';

  /** 当前使用的播放内核实例 */
  private player?: IPlayer;
  /** AVPlayer 遇到不支持格式时，自动回退的后端类型 */
  @Trace unsupportedFormatFallback: UnsupportedFormatFallback = 'ijkplayer';
  /** 是否已由外部显式设置回退策略（为 true 时不再自动覆盖） */
  private unsupportedFallbackLockedByUser: boolean = false;
  @Trace name: ResourceStr = ''
  @Trace surfaceId: string = ''
  /** MPV surface 是否已完成绑定（onLoad + 有效宽高） */
  private mpvSurfaceBound: boolean = false
  get isMpvSurfaceBound(): boolean { return this.mpvSurfaceBound }
  // 缓存 onAreaChange 提前到达时的 surface 参数，等 initPlayer 完成后自动绑定
  private pendingMpvSurfaceId: string = ''
  private pendingMpvSurfaceWidth: number = 0
  private pendingMpvSurfaceHeight: number = 0
  /** 缓存最近一次 MPV XComponent 的有效宽高，供 reloadSource 使用 */
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
  /** 音频能力探测文案（用于 UI 展示） */
  @Trace audioCapabilityText: string = ''
  /** ffmpeg 模式首帧预览图（file:// URI） */
  @Trace ffmpegPreviewUri: string = ''
  @Trace progress = 0
  /** 内嵌字幕轨道列表（来自 getTrackInfos） */
  @Trace subtitleTracks: TrackInfo[] = []
  @Trace currentSubtitleTrack: number = -1
  @Trace currentSubtitleText: string = ''
  @Trace subtitleUpdateCounter: number = 0
  @Trace allSubtitleTracks: SubtitleTrackItem[] = [];
  @Trace activeSubtitleIndex: number = -1;
  /**
   * 字幕延迟偏移（单位 ms）。
   * 正值表示字幕延迟显示（字幕偏慢，向后调），负值表示提前显示（字幕偏快，向前调）。
   * 作用于外部 SRT/ASS/VTT 字幕时间轴查找，见 onTimeUpdate 回调。
   */
  @Trace subtitleDelayMs: number = 0;
  /** 当前帧解析后的字幕数据，由 VideoPlayer @Monitor 写入，供播放器页独立渲染层直接读取 */
  @Trace parsedSubtitle: ParsedSubtitle | null = null;
  /** 音轨列表 */
  @Trace audioTracks: AudioTrackItem[] = [];
  @Trace activeAudioIndex: number = -1;
  /** 当前播放源的协议类型标识（如 'SMB'），用于 UI 展示与路由决策 */
  @Trace sourceProtocol: string = '';
  /** 画面比例模式，默认为适应（等比保留黑边） */
  @Trace aspectRatioMode: AspectRatioMode = AspectRatioMode.FIT;
  /**
   * ijkplayer 上报的视频原始宽高比（width / height）。
   * 0 表示尚未收到比例信息（初始态或切换视频时重置）。
   * 由 adapter 回调写入（Task 2.3/2.4），供 UI 层计算实际渲染尺寸使用。
   */
  @Trace ijkVideoRatio: number = 0;
  /** 当前播放速率，默认 1.0（正常速度）。支持档位：0.5/0.75/1.0/1.25/1.5/2.0 */
  @Trace playbackSpeed: number = 1.0;
  /** 复用同一 XComponent 切源时缓存的 IJK context */
  private cachedIjkContext?: object;
  private cachedIjkComponentId: string = '';
  /** 复用同一 XComponent 切源时缓存的 native context */
  private cachedNativeContext?: object;
  private cachedNativeComponentId: string = '';
  private pendingReloadToken: number = 0;
  private activeReloadToken: number = 0;
  private reloadTimeoutId?: number;
  private pendingReloadResolve?: () => void;
  private pendingReloadReject?: (error: Error) => void;
  private subtitleAdapter: ISubtitleBridgeAdapter = new NoSubtitleBridgeAdapter();
  private readonly subtitleDispatcher: SubtitleDispatcher = new SubtitleDispatcher();
  /** 字幕缓存上下文，由外部（player page）注入后用于步骤 4 缓存查询 */
  private subtitleCacheContext?: SubtitleCacheContext;
  private currentVideoData?: VideoData;
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
  /** native seek 诊断开关（默认关闭） */
  private nativeSeekDiagLogEnabled: boolean = DEFAULT_NATIVE_SEEK_DIAG_LOG_ENABLED;
  /** native 初始化就绪保护定时器：超时后自动回退到 ijkplayer */
  private nativeReadyGuardTimer?: number;
  /** 后端自动 fallback / 实例重建时待恢复的续播状态（一次性消费） */
  private pendingResumeState: PendingResumeState | null = null;
  /** 当前播放会话显式记录的“恢复后是否自动播放”决策 */
  private pendingResumeAutoplayDecisionExplicit: boolean = false;
  /** 当前播放会话是否已写入显式自动播放决策 */
  private hasPendingResumeAutoplayDecisionExplicit: boolean = false;
  /** 当前播放会话显式自动播放决策来源 */
  private pendingResumeAutoplayDecisionSource: string = '';
  /** 新媒体初始化链路预置的自动播放决策；在 initPlayer 启动新会话时转正为当前会话决策 */
  private preparedResumeAutoplayDecisionExplicit: boolean = false;
  /** 新媒体初始化链路是否已预置自动播放决策 */
  private hasPreparedResumeAutoplayDecisionExplicit: boolean = false;
  /** 新媒体初始化链路预置自动播放决策来源 */
  private preparedResumeAutoplayDecisionSource: string = '';
  /** seek 临时 pause 窗口内，onPaused 不应清理显式自动播放决策 */
  private preservePendingResumeAutoplayDecisionOnPaused: boolean = false;
  /** 待恢复续播 seek 是否进行中 */
  private pendingResumeSeekInFlight: boolean = false;
  /** 当前待恢复续播 seek 的来源 */
  private pendingResumeSeekSource: string = '';
  /** 当前待恢复续播 seek 的捕获后端 */
  private pendingResumeSeekCaptureBackend: PlayerBackend = 'avplayer';
  /** 当前待恢复续播 seek 的目标时间 */
  private pendingResumeSeekTargetMs: number = -1;
  /** 当前待恢复续播 seek 完成后是否自动恢复播放 */
  private pendingResumeSeekAutoPlay: boolean = false;
  /** fallback resume seek 完成后，是否需要补做 ready 阶段的轨道初始化 */
  private pendingReadyTrackInitAfterSeek: boolean = false;
  /** fallback resume seek 完成后，轨道初始化结束是否需要恢复播放 */
  private pendingReadyTrackInitResumePlay: boolean = false;
  /** 当前续播自动播放执行结果观察上下文 */
  private pendingResumeAutoplayResultState: PendingResumeAutoplayResultState | null = null;
  /** resume seek 自动恢复播放超时兜底定时器 */
  private resumeSeekAutoplayFallbackTimer?: number;
  /** resume seek 自动恢复播放超时兜底所属会话 */
  private resumeSeekAutoplayFallbackSessionId: number = 0;
  /** resume seek 自动恢复播放是否已由超时兜底触发 */
  private resumeSeekAutoplayFallbackTriggered: boolean = false;
  /** SMB 源当前是否通过 HTTP 代理运行（用于 release 时触发 cleanupOrphanedProxies） */
  private smbProxyActive: boolean = false;
  /** 保存原始 smb:// URL，供 avplayer→ijkplayer fallback 时重新启动代理 */
  private smbOriginalSrc: string = '';
  /** 一次性控制：本次 seek 完成后不自动恢复播放 */
  private suppressPlayAfterSeekOnce: boolean = false;
  /** ffmpeg 动态预览：当前是否正在抽帧 */
  private ffmpegPreviewExtracting: boolean = false;
  /** ffmpeg 连续预览：渲染定时器 */
  private ffmpegRenderTimer?: number;
  /** ffmpeg 连续预览：待渲染帧队列 */
  private ffmpegFrameQueue: FfmpegQueuedFrame[] = [];
  /** ffmpeg 连续预览：当前解码到的媒体时间（毫秒） */
  private ffmpegDecodedUntilMs: number = 0;
  /** ffmpeg 连续预览：流水号，用于隔离旧解码回调 */
  private ffmpegPipelineToken: number = 0;
  /** ffmpeg 连续预览：上一帧渲染时刻（系统时间） */
  private ffmpegLastRenderTickAtMs: number = 0;
  /** ffmpeg 连续预览：最近一次观测到的播放时间 */
  private ffmpegLastObservedPlaybackMs: number = -1;
  /** ffmpeg 连续预览：播放时钟停滞时的兜底推进量 */
  private ffmpegStallAdvanceMs: number = 0;
  /** ffmpeg 连续预览：下次允许解码的最早时间（系统时间） */
  private ffmpegNextDecodeAllowedAtMs: number = 0;
  /** ffmpeg 连续预览：诊断日志节流 */
  private ffmpegLastDiagLogAtMs: number = 0;
  /** ffmpeg 连续预览：最近一次渲染到 UI 的帧 URI */
  private ffmpegLastRenderedUri: string = '';
  /** ffmpeg 连续预览：最近一次渲染帧的 pts */
  private ffmpegLastRenderedPtsMs: number = -1;
  /** ffmpeg 连续预览：同一帧连续命中次数 */
  private ffmpegSameFrameTicks: number = 0;
  /** ffmpeg 连续预览：当前 chunk 解码启动时刻 */
  private ffmpegExtractStartAtMs: number = 0;
  /** ffmpeg 连续预览：解码卡住时的单帧追帧是否进行中 */
  private ffmpegCatchupExtracting: boolean = false;
  /** ffmpeg 连续预览：上次强制重启解码时间（系统时间） */
  private ffmpegLastForceRestartAtMs: number = 0;
  /** ffmpeg 连续预览：空队列追帧节流时间（系统时间） */
  private ffmpegLastEmptyQueueCatchupAtMs: number = 0;
  /** ffmpeg 连续预览：远程 chunk 不稳定时切到单帧模式 */
  private ffmpegSingleFrameMode: boolean = false;

  private get pendingBackendResumeTimeMs(): number {
    return this.pendingResumeState?.positionMs ?? -1;
  }

  private set pendingBackendResumeTimeMs(value: number) {
    const pendingState = this.ensurePendingResumeState();
    pendingState.positionMs = value;
    this.prunePendingResumeState();
  }

  private get pendingBackendResumePlay(): boolean {
    return this.pendingResumeState?.shouldResumePlay ?? false;
  }

  private set pendingBackendResumePlay(value: boolean) {
    const pendingState = this.ensurePendingResumeState();
    const autoplayDecision = this.resolvePendingResumeAutoplayDecision(value, 'compat_override');
    pendingState.shouldResumePlay = value;
    pendingState.autoplayDecisionSource = autoplayDecision.source;
    pendingState.autoplayDecisionOrigin = autoplayDecision.origin;
    this.prunePendingResumeState();
  }

  private ensurePendingResumeState(): PendingResumeState {
    if (this.pendingResumeState === null) {
      const pendingState: PendingResumeState = {
        positionMs: -1,
        shouldResumePlay: false,
        autoplayDecisionSource: 'compat_override',
        autoplayDecisionOrigin: 'compat',
        sourceKey: this.buildPendingResumeSourceKey(this.currentVideoData),
        reason: 'compat_override',
        captureBackend: this.backend
      };
      this.pendingResumeState = pendingState;
    }
    return this.pendingResumeState;
  }

  private prunePendingResumeState(): void {
    if (this.pendingResumeState === null) {
      return;
    }
    if (this.pendingResumeState.positionMs < 0 && !this.pendingResumeState.shouldResumePlay) {
      this.pendingResumeState = null;
    }
  }

  private clearPendingResumeState(): void {
    this.pendingResumeState = null;
  }

  private buildPendingResumeSourceKey(videoData: VideoData | undefined): string {
    if (videoData === undefined) {
      return '';
    }
    if (this.smbOriginalSrc.length > 0 && videoData.videoSrc.startsWith('http://127.0.0.1')) {
      return this.smbOriginalSrc;
    }
    return videoData.videoSrc;
  }

  /**
   * 缓存 key 用的稳定视频路径：SMB 源用原始 smb:// URL（端口稳定），其他源用 videoSrc。
   * 下载字幕写缓存与读缓存必须使用同一路径，否则 SHA-256 hash 不同导致缓存永远无法命中。
   */
  get stableVideoSrcForCache(): string {
    const raw = this.currentVideoData?.videoSrc ?? '';
    return this.smbOriginalSrc.length > 0 ? this.smbOriginalSrc : raw;
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
    if (this.pendingResumeState === null) {
      return false;
    }
    const nextSourceKey = this.buildPendingResumeSourceKey(videoData);
    if (nextSourceKey.length === 0) {
      return false;
    }
    return nextSourceKey === this.pendingResumeState.sourceKey;
  }

  private consumePendingResumeState(): PendingResumeState | null {
    const pendingState = this.pendingResumeState;
    this.pendingResumeState = null;
    return pendingState;
  }

  private normalizePendingResumePosition(positionMs: number): number {
    let safePosition = positionMs > 0 ? positionMs : 0;
    if (this.duration > 0 && safePosition > this.duration) {
      safePosition = this.duration;
    }
    return safePosition;
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
    this.pendingResumeState = pendingState;
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
    this.pendingResumeAutoplayDecisionExplicit = shouldResumePlay;
    this.hasPendingResumeAutoplayDecisionExplicit = true;
    this.pendingResumeAutoplayDecisionSource = source.length > 0 ? source : 'explicit';
    this.logResumeDecisionEstablished('active', shouldResumePlay, this.pendingResumeAutoplayDecisionSource, 'explicit');
  }

  prepareResumeAutoplayDecision(shouldResumePlay: boolean, source: string): void {
    this.preparedResumeAutoplayDecisionExplicit = shouldResumePlay;
    this.hasPreparedResumeAutoplayDecisionExplicit = true;
    this.preparedResumeAutoplayDecisionSource = source.length > 0 ? source : 'prepared';
    this.logResumeDecisionEstablished('prepared', shouldResumePlay, this.preparedResumeAutoplayDecisionSource, 'explicit');
  }

  discardPreparedResumeAutoplayDecision(): void {
    this.clearPreparedResumeAutoplayDecision();
  }

  rememberResumeAutoplayDecision(shouldResumePlay: boolean, source: string): void {
    this.rememberPendingResumeAutoplayDecision(shouldResumePlay, source);
  }

  private clearPreparedResumeAutoplayDecision(): void {
    this.preparedResumeAutoplayDecisionExplicit = false;
    this.hasPreparedResumeAutoplayDecisionExplicit = false;
    this.preparedResumeAutoplayDecisionSource = '';
  }

  private applyPreparedResumeAutoplayDecision(): void {
    if (!this.hasPreparedResumeAutoplayDecisionExplicit) {
      return;
    }
    this.rememberPendingResumeAutoplayDecision(
      this.preparedResumeAutoplayDecisionExplicit,
      this.preparedResumeAutoplayDecisionSource
    );
    this.clearPreparedResumeAutoplayDecision();
  }

  private clearPendingResumeAutoplayDecision(): void {
    this.pendingResumeAutoplayDecisionExplicit = false;
    this.hasPendingResumeAutoplayDecisionExplicit = false;
    this.pendingResumeAutoplayDecisionSource = '';
    this.preservePendingResumeAutoplayDecisionOnPaused = false;
  }

  private clearResumeAutoplayDecisionLifecycle(): void {
    this.clearPreparedResumeAutoplayDecision();
    this.clearPendingResumeAutoplayDecision();
  }

  protected scheduleResumeSeekAutoplayFallbackTimeout(callback: () => void): number {
    return setTimeout(callback, RESUME_SEEK_AUTOPLAY_FALLBACK_MS);
  }

  protected clearResumeSeekAutoplayFallbackTimeout(timerId: number): void {
    clearTimeout(timerId);
  }

  private clearResumeSeekAutoplayFallbackState(): void {
    if (this.resumeSeekAutoplayFallbackTimer !== undefined) {
      this.clearResumeSeekAutoplayFallbackTimeout(this.resumeSeekAutoplayFallbackTimer);
      this.resumeSeekAutoplayFallbackTimer = undefined;
    }
    this.resumeSeekAutoplayFallbackSessionId = 0;
    this.resumeSeekAutoplayFallbackTriggered = false;
  }

  private armResumeSeekAutoplayFallback(sessionId: number): void {
    this.clearResumeSeekAutoplayFallbackState();
    this.resumeSeekAutoplayFallbackSessionId = sessionId;
    this.resumeSeekAutoplayFallbackTimer = this.scheduleResumeSeekAutoplayFallbackTimeout(() => {
      this.resumeSeekAutoplayFallbackTimer = undefined;
      this.handleResumeSeekAutoplayTimeout(sessionId);
    });
  }

  private handleResumeSeekAutoplayTimeout(sessionId: number): void {
    if (sessionId !== this.playbackSessionId) {
      return;
    }
    if (sessionId !== this.resumeSeekAutoplayFallbackSessionId || !this.isSeeking) {
      return;
    }
    if (!this.hasPendingResumeAutoplayDecisionExplicit || !this.pendingResumeAutoplayDecisionExplicit) {
      return;
    }
    if (this.pendingResumeAutoplayDecisionSource.length === 0) {
      return;
    }
    this.resumeSeekAutoplayFallbackTriggered = true;
    this.isSeeking = false;
    this.play().catch(() => {});
  }

  private handlePlayerPaused(): void {
    if (!this.preservePendingResumeAutoplayDecisionOnPaused) {
      this.clearPendingResumeAutoplayDecision();
    }
    this.isPlaying = false;
    this.pauseSubtitleTimer();
    this.stopProgressTimer();
    this.saveProgressNow();
    if (this.backend === 'ffmpeg') {
      this.stopFfmpegRenderTimer();
    }
  }

  private resolvePendingResumeAutoplayDecision(
    inferredShouldResumePlay: boolean,
    inferredSource: string
  ): ResumeAutoplayDecision {
    if (this.hasPendingResumeAutoplayDecisionExplicit) {
      return {
        shouldResumePlay: this.pendingResumeAutoplayDecisionExplicit,
        source: this.pendingResumeAutoplayDecisionSource.length > 0
          ? this.pendingResumeAutoplayDecisionSource
          : 'explicit',
        origin: 'explicit'
      };
    }
    return {
      shouldResumePlay: inferredShouldResumePlay,
      source: inferredSource,
      origin: 'transient'
    };
  }

  /**
   * 初始化播放器。
   * - backend='avplayer'：直接用 surfaceId 初始化，与之前行为一致。
   * - backend='ijkplayer'：创建 IjkPlayerAdapter，surfaceId 暂时忽略，
   *   需要 VideoPlayer UI 层在 XComponent.onLoad 里调用 setIjkContext()。
    * - backend='native'：创建 VidAllPlayerAdapter，等待 UI 层在 XComponent.onLoad 里绑定 context。
    * - backend='ffmpeg'：已禁用主路径接入，收到后自动回退 ijkplayer。
   */
  async initPlayer(videoData: VideoData, surfaceId: string): Promise<void> {
    this.playbackSessionId += 1;
    const currentSessionId = this.playbackSessionId;
    this.metricsLoadStartMs = Date.now();
    this.metricsMedia = null;
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
    this.surfaceId = surfaceId;
    this.lastTimeUpdateMs = -1;
    this.ffmpegPreviewExtracting = false;
    this.stopFfmpegRenderTimer();
    this.ffmpegFrameQueue = [];
    this.ffmpegDecodedUntilMs = 0;
    this.ffmpegPipelineToken += 1;
    this.ffmpegLastRenderTickAtMs = 0;
    this.ffmpegLastObservedPlaybackMs = -1;
    this.ffmpegStallAdvanceMs = 0;
    this.ffmpegNextDecodeAllowedAtMs = 0;
    this.ffmpegLastDiagLogAtMs = 0;
    this.ffmpegLastRenderedUri = '';
    this.ffmpegLastRenderedPtsMs = -1;
    this.ffmpegSameFrameTicks = 0;
    this.ffmpegExtractStartAtMs = 0;
    this.ffmpegCatchupExtracting = false;
    this.ffmpegLastForceRestartAtMs = 0;
    this.ffmpegLastEmptyQueueCatchupAtMs = 0;
    this.ffmpegSingleFrameMode = false;
    this.clearNativeReadyGuardTimer();
    // 清理上一次 SMB 源遗留的孤立代理线程（keepProxy=true 释放后），防止线程泄漏
    // 委托给 PlaybackBackendService.cleanupOrphanedProxies（service 集中管理）
    if (this.smbProxyActive) {
      this.backendService.cleanupOrphanedProxies();
      this.smbProxyActive = false;
    }
    const shouldPreservePendingResume = this.shouldPreservePendingResume(videoData);
    if (!shouldPreservePendingResume) {
      this.clearPendingResumeState();
    }
    this.clearPendingResumeAutoplayDecision();
    this.applyPreparedResumeAutoplayDecision();
    this.pendingResumeSeekInFlight = false;
    this.pendingResumeSeekSource = '';
    this.pendingResumeSeekCaptureBackend = 'avplayer';
    this.pendingResumeSeekTargetMs = -1;
    this.pendingResumeSeekAutoPlay = false;
    this.pendingReadyTrackInitAfterSeek = false;
    this.pendingReadyTrackInitResumePlay = false;
    this.pendingResumeAutoplayResultState = null;
    this.clearResumeSeekAutoplayFallbackState();
    this.suppressPlayAfterSeekOnce = false;
    if (ENABLE_SESSION_DIAG_LOG) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[session=${currentSessionId}] initPlayer start backend=${this.backend}`);
    }

    // 若外部未显式锁定策略，则根据探测结果自动选择硬解/软解路由。
    // 决策通过 `backendService.chooseBackend` 计算（Fix #3：backend route 主路径必须经 backend service）。
    // 关键（Fix W3）：即使锁定 fallback 策略，也始终让 `backendService.chooseBackend` 跑一遍以刷新
    // `audioProbeSummary` / `trackAnalyses` 等诊断字段（不影响 `this.backend` / `this.unsupportedFormatFallback`）。
    const backendBeforeAutoRouting = this.backend;
    const decision = await this.resolveAudioRoutingDecision(videoData);
    // 并发防护：ffprobe 异步期间若有更新的 initPlayer 入口，则放弃本次
    if (currentSessionId !== this.playbackSessionId) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `[initPlayer] sessionId 过期（${currentSessionId} ≠ ${this.playbackSessionId}），放弃本次初始化`);
      return;
    }
    videoData.ffmpegDecodeChannels = decision.preferredChannels;
    videoData.audioProbeSummary = decision.summary;
    videoData.videoCodec = decision.videoCodecName;
    if (!this.unsupportedFallbackLockedByUser) {
      this.unsupportedFormatFallback = decision.fallback;
      // 用户偏好覆盖：从 AppPreferences 读取 PLAYER_FALLBACK，若有效则覆盖自动决策
      try {
        const prefFallback = await AppPreferences.get(PrefKey.PLAYER_FALLBACK, 'ijkplayer');
        if (prefFallback === 'ijkplayer' || prefFallback === 'mpv') {
          if (this.unsupportedFormatFallback !== prefFallback) {
            hilog.info(CommonConstants.LOG_DOMAIN, TAG,
              `用户偏好覆盖 fallback: ${this.unsupportedFormatFallback} → ${prefFallback}`);
            this.unsupportedFormatFallback = prefFallback;
          }
        }
      } catch {
        // 读取偏好失败，保持自动决策
      }
      if (this.backend === 'avplayer' || this.backend === 'ffmpeg' || this.backend === 'native') {
        this.backend = decision.preferredBackend;
      }
      if (decision.precheckProbeFailed && backendBeforeAutoRouting !== this.backend) {
        this.logFallbackEvent(
          'precheck_probe_failed',
          backendBeforeAutoRouting,
          this.backend,
          decision.precheckProbeError
        );
      }
    }
    // 关键：详细打印整组音轨分析（用于 verify 真机回溯；不论是否锁定 fallback 都打印）
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[initPlayer.route-decision] backend=${this.backend}, fallback=${this.unsupportedFormatFallback}, ` +
      `anyHardSupported=${decision.anyHardSupported}, allSoftDecodeOnly=${decision.allSoftDecodeOnly}, ` +
      `detectedCodec=${decision.detectedCodec}, detectedChannels=${decision.detectedChannels}`);
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[initPlayer.route-decision] trackAnalyses=${decision.trackAnalyses.length} 条:`);
    for (let i = 0; i < decision.trackAnalyses.length; i++) {
      const t = decision.trackAnalyses[i];
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[initPlayer.route-decision]   [${i}] codec=${t.codec} channels=${t.channels} ` +
        `hardSupported=${t.hardSupported} source=${t.source}`);
    }
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `自动音频路由: backend=${this.backend}, fallback=${this.unsupportedFormatFallback}, ` +
      `ffmpegChannels=${videoData.ffmpegDecodeChannels}, summary=${decision.summary}`);
    this.logAudioCapabilityReport(decision);

    if (this.backend === 'ffmpeg') {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        'ffmpeg 播放后端已从主路径下线，自动回退到 ijkplayer');
      this.backend = 'ijkplayer';
    }

    // native 后端已停止主路径接入（SMB 源现通过 HTTP 代理 + AVPlayer 播放），强制回退到 ijkplayer。
    // 注意：mpv 不在此列 — mpv 是活跃后端，不应被拒绝。
    if (this.backend === 'native') {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        'native 播放后端已从主路径下线，自动回退到 ijkplayer');
      this.backend = 'ijkplayer';
    }

    // SMB 源（smb://）的代理启动已由 `PlaybackBackendService.prepareAdapter` 统一处理。
    // controller 不再直接调用 `VidAllPlayerAdapter.startSmbProxy`，避免双启动。
    // controller 持有 service 写回的 smbOriginalSrc（已写在下面的 prepareAdapter 调用之后）。
    //
    // 旧的"非 SMB 源清空 smbOriginalSrc"逻辑仍然保留（用于 initPlayer 二次调用的 fallback 场景）：
    if (!videoData.videoSrc.startsWith('smb://') && !videoData.videoSrc.startsWith('http://127.0.0.1')) {
      // 非 SMB、非本地代理 URL（即真正的非 SMB 播放源），才清空缓存。
      // fallback 场景下第二次 initPlayer() 收到的是上一次代理的 http://127.0.0.1:PORT/... URL，
      // 不能清空 smbOriginalSrc，否则 setIjkContext() 无法重启代理。
      this.smbOriginalSrc = '';
    }

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
    // 这样用户打开播放页就能立即看到音轨列表，不必等待 ijkplayer prepareAsync 完成
    if (videoData.presetAudioTracks && videoData.presetAudioTracks.length > 0) {
      const presets = videoData.presetAudioTracks;
      const tracks: AudioTrackItem[] = [];
      for (let i = 0; i < presets.length; i++) {
        const p = presets[i];
        const item: AudioTrackItem = {
          trackIndex: p.trackIndex,
          displayName: p.displayName,
          language: p.language,
          mimeType: p.mimeType,
          codecName: p.codecName
        };
        tracks.push(item);
      }
      this.audioTracks = tracks;
      this.activeAudioIndex = 0;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[initPlayer] 预置音轨已提前填充: ${tracks.length} 条`);
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
            if (currentSessionId !== this.playbackSessionId || !(bridge instanceof IjkSubtitleBridgeAdapter)) {
              return;
            }
            bridge.onEmbeddedTimedText(text);
            this.applySubtitleBridgeState(bridge.getState());
          },
          onVideoRatio: (ratio: number) => {
            if (currentSessionId !== this.playbackSessionId) {
              return;
            }
            this.ijkVideoRatio = ratio;
          }
        }
      );
      if (adapterHandle.smbOriginalSrc.length > 0) {
        this.smbOriginalSrc = adapterHandle.smbOriginalSrc;
      }
      this.smbProxyActive = adapterHandle.smbProxyActive;
      this.sourceProtocol = adapterHandle.smbOriginalSrc.length > 0 ? 'SMB' : this.sourceProtocol;
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
        hilog.error(CommonConstants.LOG_DOMAIN, TAG,
          'initPlayer: PlaybackBackendService.prepareAdapter 未返回 player，降级到 AVPlayerAdapter');
        this.player = this.createAvPlayerAdapter();
        return;
      }
      this.player = adapter;
    }

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
      if (this.duration > 0) {
        this.currentTime = this.duration;
        this.progress = 1;
      }
      this.stopProgressTimer();
      this.saveProgressNow();
      if (this.backend === 'ffmpeg') {
        this.stopFfmpegRenderTimer();
      }
      emitter.emit(PlayerEvents.COMPLETED);
    });
    p.onStopped(() => {
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
      this.clearPendingResumeAutoplayDecision();
      this.isPlaying = false;
      this.stopProgressTimer();
      if (this.backend === 'ffmpeg') {
        this.stopFfmpegRenderTimer();
      }
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
      if (this.backend === 'ffmpeg' && this.isPlaying) {
        this.scheduleFfmpegDecodeIfNeeded(currentTime);
      }
      this.subtitleAdapter.onTimeUpdate(currentTime);
      if (this.backend === 'native' && this.isPlaying && currentTime > 0) {
        this.clearNativeReadyGuardTimer();
      }
      const subtitleState = this.subtitleAdapter.getState();
      if (subtitleState.hasExternalActive) {
        this.applySubtitleBridgeState(subtitleState);
      }
      this.logSubtitleTimeline(currentTime);
    });
    p.onError((error: Error) => {
      if (currentSessionId !== this.playbackSessionId) {
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
      // native 后端在文件缺失时返回 "io resource not found"。
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

      if (this.backend === 'native') {
        this.fallbackNativeToIjk('native_error_callback', 'native 错误回调触发，已自动回退到 IJK 播放', error.message);
        return;
      }
      // mpv 播放失败：提示用户尝试 ijkplayer
      if (this.backend === 'mpv') {
        this.isLoading = false;
        this.lastErrorMessage = this.normalizePlayerError(error.message);
        this.rejectPendingReload(new Error(error.message));
        // 发出 mpv 错误事件，由 VideoPlayer 页面展示切换对话框
        emitter.emit(PlayerEvents.MPV_ERROR_FALLBACK, {
          data: { errorMessage: this.lastErrorMessage }
        });
        return;
      }
      // ijkplayer 播放失败：提示用户尝试 mpv
      if (this.backend === 'ijkplayer') {
        this.isLoading = false;
        this.lastErrorMessage = this.normalizePlayerError(error.message);
        this.rejectPendingReload(new Error(error.message));
        // 发出 ijk 错误事件，由 VideoPlayer 页面展示切换对话框
        emitter.emit(PlayerEvents.IJK_ERROR_FALLBACK, {
          data: { errorMessage: this.lastErrorMessage }
        });
        return;
      }
      this.isLoading = false;
      this.lastErrorMessage = this.normalizePlayerError(error.message);
      this.rejectPendingReload(new Error(error.message));
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
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
      const targetBackend: PlayerBackend = this.unsupportedFormatFallback;
      this.logFallbackEvent('avplayer_unsupported_format', 'avplayer', targetBackend);
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `AVPlayer 不支持当前格式，自动切换到 ${targetBackend}...`);
      this.isLoading = true;
      this.capturePendingResumeForFallback('avplayer_unsupported_format');
      // 不干预用户字幕绑定：fallback 是系统行为，不应覆盖用户的主动选择。
      // 若用户之前关闭过字幕（disabled），resolveSubtitle 步骤 1 会正确返回 none。
      // 若用户之前选中了某条字幕，binding 保留，步骤 1 会正确恢复。
      const rawFbVideoSrc = this.currentVideoData?.videoSrc ?? '';
      const fbVideoPath = this.smbOriginalSrc.length > 0 ? this.smbOriginalSrc : rawFbVideoSrc;
      if (fbVideoPath.length > 0) {
        this.subtitleDispatcher.getUserBinding(fbVideoPath).then((binding) => {
          if (binding !== null) {
            hilog.info(CommonConstants.LOG_DOMAIN, TAG,
              `fallback: 保留 binding (${binding.subtitleType})，resolveSubtitle 步骤 1 会按类型处理`);
          }
        }).catch(() => {});
      }
      // 先把 player 引用清空，防止后续调用
      const oldPlayer = this.player;
      this.player = undefined;
      // 切换 backend（@Trace），触发 VideoPlayer UI 重建。
      this.backend = targetBackend;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `backend 已切换为 ${targetBackend}，等待 UI 层重建...`);
      // 异步释放旧 player（不等待，不影响切换流程）
      oldPlayer?.release().catch(() => {});
    });
    p.onSeekDone(() => {
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
      // 指标埋点：seek_result（非 native 后端在此记录；native 在 VidAllPlayerAdapter 内分别记录 done/timeout）
      if (this.backend !== 'native') {
        const seekElapsed = Date.now() - this.metricsSeekStartMs;
        hilog.info(CommonConstants.LOG_DOMAIN, METRICS_TAG,
          `{"event":"seek_result","backend":"${this.backend}","result":"done","elapsed_ms":${seekElapsed}}`);
      }
      const resumeSeekInFlight = this.pendingResumeSeekInFlight;
      const resumeSeekSource = this.pendingResumeSeekSource;
      const resumeSeekCaptureBackend = this.pendingResumeSeekCaptureBackend;
      const resumeSeekTargetMs = this.pendingResumeSeekTargetMs;
      const resumeSeekAutoPlay = this.pendingResumeSeekAutoPlay;
      const resumeSeekAutoplayFallbackTriggered = this.resumeSeekAutoplayFallbackTriggered;
      this.clearResumeSeekAutoplayFallbackState();
      const resumeAutoplayDecisionSource = this.pendingResumeAutoplayResultState?.autoplayDecisionSource ?? '';
      const resumeAutoplayDecisionOrigin = this.pendingResumeAutoplayResultState?.autoplayDecisionOrigin ?? '';
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
          this.pendingResumeSeekInFlight = false;
          this.pendingResumeSeekSource = '';
          this.pendingResumeSeekCaptureBackend = 'avplayer';
          this.pendingResumeSeekTargetMs = -1;
          this.pendingResumeSeekAutoPlay = false;
        }
        this.player?.seek(this.timeToSeek);
        this.timeToSeek = -1;
        this.isSeeking = false;
        return;
      }
      const shouldContinuePendingReadyAfterSeek = this.pendingReadyTrackInitAfterSeek;
      if (resumeSeekInFlight) {
        this.pendingResumeSeekInFlight = false;
        this.pendingResumeSeekSource = '';
        this.pendingResumeSeekCaptureBackend = 'avplayer';
        this.pendingResumeSeekTargetMs = -1;
        this.pendingResumeSeekAutoPlay = false;
      }
      this.isSeeking = false;
      if (shouldContinuePendingReadyAfterSeek) {
        this.suppressPlayAfterSeekOnce = false;
        this.continuePendingReadyAfterSeek(currentSessionId).catch(() => {});
        return;
      }
      if (resumeSeekAutoplayFallbackTriggered) {
        return;
      }
      if (this.suppressPlayAfterSeekOnce) {
        if (resumeSeekInFlight) {
          this.logResumeDiagnostic('resume_autoplay_decision', resumeSeekSource, resumeSeekCaptureBackend,
            resumeSeekTargetMs, resumeSeekTargetMs, resumeSeekAutoPlay, 'suppress', -1,
            resumeAutoplayDecisionSource, resumeAutoplayDecisionOrigin);
        }
        this.recordPendingResumeAutoplayResult('paused', true);
        this.suppressPlayAfterSeekOnce = false;
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

    if (this.backend === 'ijkplayer') {
      // IjkPlayer 需要先由 UI 层绑定 XComponent context，
      // VideoPlayer.ets 的 onLoad 回调会调用 setIjkContext() 来完成真正的 init
      // 注意：VPE AI 画质增强不适用于 ijkplayer 路径（ijkplayer 使用 XComponent native hook 渲染）
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        'IjkPlayerAdapter 已创建，等待 UI 层 setIjkContext() 绑定 XComponent...');
    } else if (this.backend === 'mpv') {
      // MPV 使用 XComponentController 模式获取 surfaceId，
      // VideoPlayer.ets 的 onAreaChange 回调会调用 setMpvSurface() 来完成绑定和 init
      this.mpvSurfaceBound = false;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        'MpvPlayerAdapter 已创建，等待 UI 层 setMpvSurface() 绑定 XComponent...');
      // 检查是否有缓存的 surface 参数（onAreaChange 可能先于 initPlayer 触发）
      if (this.pendingMpvSurfaceId.length > 0 && this.pendingMpvSurfaceWidth > 0 &&
        this.pendingMpvSurfaceHeight > 0) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `initPlayer 检测到缓存的 surface 参数，自动绑定: w=${this.pendingMpvSurfaceWidth} h=${this.pendingMpvSurfaceHeight}`);
        const sid = this.pendingMpvSurfaceId;
        const sw = this.pendingMpvSurfaceWidth;
        const sh = this.pendingMpvSurfaceHeight;
        this.pendingMpvSurfaceId = '';
        this.pendingMpvSurfaceWidth = 0;
        this.pendingMpvSurfaceHeight = 0;
        await this.setMpvSurface(sid, sw, sh);
      }
    } else {
      // avplayer 路径：若 AI 画质增强已开启，尝试在播放器与显示层之间插入 VPE；
      // VPE 增强仍由 controller 负责（service 不持有 aiEnhance 状态）。
      const effectiveSurfaceId = this.tryCreateVpeEnhancer(surfaceId);
      try {
        await this.player?.init(videoData, effectiveSurfaceId);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(CommonConstants.LOG_DOMAIN, TAG,
          `init 失败: code=${err.code} msg=${err.message}`);
        this.rejectPendingReload(new Error(err.message));
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
    this.ffmpegPreviewUri = '';
    this.sourceProtocol = '';
    // 切换视频时清零 ijkplayer 宽高比，防止旧 ratio 残留影响下一个视频的渲染（Task 2.2）
    this.ijkVideoRatio = 0;
  }

  // ─── VPE AI 画质增强 ──────────────────────────────────────────

  /**
   * 开启/切换 AI 画质增强。
   * - VPE 已运行：直接更新质量参数（不重建管线，不影响播放）
   * - VPE 未运行（首次启用）：下次 initPlayer 时才会创建（当前播放不影响）
   */
  setAiEnhance(quality: VpeQualityLevel = 'low'): void {
    const runtimeSupported = this.syncAiEnhanceAvailability();
    if (!runtimeSupported) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[VPE] 运行时不可用，忽略启用请求: quality=${quality}`);
      return;
    }
    this.aiEnhanceEnabled = true;
    this.aiEnhanceQuality = quality;
    if (VpeEnhancerUtil.isRunning) {
      VpeEnhancerUtil.updateQuality(quality);
    }
    // VPE 未运行时无需操作，下次播放时 initPlayer 会按 aiEnhanceEnabled/Quality 创建
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
    return shouldShowAiEnhanceSettingsByRuntime(this.aiEnhanceRuntimeSupported, this.backend);
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
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[VPE] tryCreate: supported=${runtimeSupported} enabled=${this.aiEnhanceEnabled} backend=${this.backend} quality=${this.aiEnhanceQuality}`);
    if (!runtimeSupported || !this.aiEnhanceEnabled || this.backend !== 'avplayer') {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[VPE] 跳过创建: supported=${runtimeSupported} enabled=${this.aiEnhanceEnabled} backend=${this.backend}`);
      return displaySurfaceId;
    }
    const vpeSurfaceId = VpeEnhancerUtil.createEnhancer(displaySurfaceId, this.aiEnhanceQuality);
    const effectiveSurfaceId = resolveEffectivePlaybackSurfaceId(displaySurfaceId, vpeSurfaceId);
    if (effectiveSurfaceId !== displaySurfaceId) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, `[VPE] 管线建立: vpeSurfaceId=${vpeSurfaceId}`);
      return effectiveSurfaceId;
    }
    hilog.warn(CommonConstants.LOG_DOMAIN, TAG, '[VPE] 创建失败，回退到原始 surfaceId');
    return displaySurfaceId;
  }

  private prepareFfmpegPreview(videoData: VideoData): void {
    this.ffmpegFrameQueue = [];
    this.ffmpegDecodedUntilMs = 0;
    this.ffmpegPreviewExtracting = false;
    this.ffmpegLastRenderTickAtMs = 0;
    this.ffmpegLastObservedPlaybackMs = -1;
    this.ffmpegStallAdvanceMs = 0;
    this.ffmpegNextDecodeAllowedAtMs = 0;
    this.ffmpegLastDiagLogAtMs = 0;
    this.ffmpegLastRenderedUri = '';
    this.ffmpegLastRenderedPtsMs = -1;
    this.ffmpegSameFrameTicks = 0;
    this.ffmpegExtractStartAtMs = 0;
    this.ffmpegCatchupExtracting = false;
    this.ffmpegLastForceRestartAtMs = 0;
    this.ffmpegLastEmptyQueueCatchupAtMs = 0;
    this.ffmpegSingleFrameMode = false;
    const token = ++this.ffmpegPipelineToken;
    this.decodeFfmpegFrameChunk(videoData, 100, token);
  }

  private startFfmpegRenderTimer(): void {
    if (this.ffmpegRenderTimer !== undefined) {
      return;
    }
    const renderIntervalMs = Math.max(60, Math.floor(1000 / FFMPEG_PREVIEW_RENDER_FPS));
    this.ffmpegLastRenderTickAtMs = Date.now();
    this.ffmpegLastObservedPlaybackMs = this.currentTime;
    this.ffmpegStallAdvanceMs = 0;
    this.ffmpegRenderTimer = setInterval(() => {
      const now = Date.now();
      const tickDeltaMs = Math.max(0, now - this.ffmpegLastRenderTickAtMs);
      this.ffmpegLastRenderTickAtMs = now;

      if (this.currentTime > this.ffmpegLastObservedPlaybackMs + 5) {
        this.ffmpegLastObservedPlaybackMs = this.currentTime;
        this.ffmpegStallAdvanceMs = 0;
      } else if (this.isPlaying) {
        const stalled = this.ffmpegStallAdvanceMs + tickDeltaMs;
        this.ffmpegStallAdvanceMs = Math.min(FFMPEG_PREVIEW_STALL_STEP_MAX_MS, stalled);
      }

      const targetPtsMs = Math.max(0,
        this.currentTime + FFMPEG_PREVIEW_SYNC_OFFSET_MS + this.ffmpegStallAdvanceMs);

      // 丢弃明显落后的旧帧，避免“停一下再跳一下”。
      while (this.ffmpegFrameQueue.length > 1 &&
        targetPtsMs - this.ffmpegFrameQueue[0].ptsMs > FFMPEG_PREVIEW_MAX_LAG_DROP_MS) {
        this.ffmpegFrameQueue.shift();
      }

      // 选择不超过目标时钟的最新帧进行渲染。
      while (this.ffmpegFrameQueue.length > 1 && this.ffmpegFrameQueue[1].ptsMs <= targetPtsMs) {
        this.ffmpegFrameQueue.shift();
      }

      // 队列只剩 1 帧且严重落后时，主动淘汰以触发空队列追帧。
      if (this.ffmpegFrameQueue.length === 1 &&
        targetPtsMs - this.ffmpegFrameQueue[0].ptsMs > FFMPEG_PREVIEW_MAX_LAG_DROP_MS * 2) {
        this.ffmpegFrameQueue.shift();
      }

      if (this.ffmpegFrameQueue.length > 0) {
        const currentFrame = this.ffmpegFrameQueue[0];
        if (currentFrame.uri === this.ffmpegLastRenderedUri) {
          this.ffmpegSameFrameTicks += 1;
        } else {
          this.ffmpegSameFrameTicks = 0;
          this.ffmpegLastRenderedUri = currentFrame.uri;
        }
        this.ffmpegLastRenderedPtsMs = currentFrame.ptsMs;
        this.ffmpegPreviewUri = currentFrame.uri;
      }
      this.logFfmpegPreviewTick(targetPtsMs);
      this.scheduleFfmpegDecodeIfNeeded(this.currentTime);
      this.tryCatchupFrameWhileExtracting(targetPtsMs);
      this.tryCatchupFrameWhenQueueEmpty(targetPtsMs);
    }, renderIntervalMs);
  }

  private stopFfmpegRenderTimer(): void {
    if (this.ffmpegRenderTimer !== undefined) {
      clearInterval(this.ffmpegRenderTimer);
      this.ffmpegRenderTimer = undefined;
    }
    this.ffmpegLastRenderTickAtMs = 0;
    this.ffmpegLastObservedPlaybackMs = -1;
    this.ffmpegStallAdvanceMs = 0;
    this.ffmpegNextDecodeAllowedAtMs = 0;
    this.ffmpegLastDiagLogAtMs = 0;
    this.ffmpegLastRenderedUri = '';
    this.ffmpegLastRenderedPtsMs = -1;
    this.ffmpegSameFrameTicks = 0;
    this.ffmpegExtractStartAtMs = 0;
    this.ffmpegCatchupExtracting = false;
    this.ffmpegLastForceRestartAtMs = 0;
    this.ffmpegLastEmptyQueueCatchupAtMs = 0;
    this.ffmpegSingleFrameMode = false;
  }

  private scheduleFfmpegDecodeIfNeeded(currentTimeMs: number): void {
    const restartVideoData = this.currentVideoData;
    if (!restartVideoData) {
      return;
    }
    if (this.ffmpegPreviewExtracting) {
      return;
    }
    if (this.ffmpegFrameQueue.length >= FFMPEG_PREVIEW_LOW_WATERMARK_FRAMES) {
      return;
    }
    if (Date.now() < this.ffmpegNextDecodeAllowedAtMs) {
      return;
    }

    const leadMs = Math.floor(FFMPEG_PREVIEW_LEAD_SECONDS * 1000);
    const expectedStartMs = Math.max(currentTimeMs + leadMs, this.ffmpegDecodedUntilMs);
    const token = this.ffmpegPipelineToken;
    if (this.ffmpegSingleFrameMode) {
      this.ffmpegNextDecodeAllowedAtMs = Date.now() + FFMPEG_PREVIEW_SINGLE_FRAME_INTERVAL_MS;
      this.decodeFfmpegSingleFrameFallback(restartVideoData, expectedStartMs, token);
      return;
    }
    this.decodeFfmpegFrameChunk(restartVideoData, expectedStartMs, token);
  }

  private decodeFfmpegFrameChunk(videoData: VideoData, startTimeMs: number, token: number): void {
    this.ffmpegPreviewExtracting = true;
    this.ffmpegExtractStartAtMs = Date.now();
    const startSeconds = Math.max(0, startTimeMs) / 1000;
    const prefixPath = `/data/storage/el2/base/cache/vidall_ffmpeg_seq_${token}_${Date.now()}`;
    FfmpegVideoFrameUtil.extractFrameSequenceToJpeg(
      videoData.videoSrc,
      prefixPath,
      videoData.httpHeader,
      startSeconds,
      FFMPEG_PREVIEW_CHUNK_SECONDS,
      FFMPEG_PREVIEW_RENDER_FPS,
      FFMPEG_PREVIEW_DECODE_TIMEOUT_MS,
      { quality: FFMPEG_PREVIEW_JPEG_QUALITY, maxWidth: FFMPEG_PREVIEW_MAX_WIDTH }
    ).then((result) => {
      if (token !== this.ffmpegPipelineToken) {
        this.ffmpegPreviewExtracting = false;
        this.ffmpegExtractStartAtMs = 0;
        return;
      }
      if (result.success && result.outputPaths.length > 0) {
        const frameCount = Math.min(result.outputPaths.length, result.frameTimesMs.length);
        this.ffmpegSingleFrameMode = false;
        for (let i = 0; i < frameCount; i++) {
          if (this.ffmpegFrameQueue.length >= FFMPEG_PREVIEW_MAX_QUEUE_FRAMES) {
            break;
          }
          const queued: FfmpegQueuedFrame = {
            uri: 'file://' + result.outputPaths[i],
            ptsMs: result.frameTimesMs[i]
          };
          this.ffmpegFrameQueue.push(queued);
        }
        const chunkMs = Math.floor(FFMPEG_PREVIEW_CHUNK_SECONDS * 1000);
        this.ffmpegDecodedUntilMs = Math.max(this.ffmpegDecodedUntilMs, startTimeMs + chunkMs);
        this.ffmpegNextDecodeAllowedAtMs = 0;
        if (ENABLE_FFMPEG_PREVIEW_DIAG_LOG) {
          const firstPts = result.frameTimesMs.length > 0 ? result.frameTimesMs[0] : -1;
          const lastPts = result.frameTimesMs.length > 0
            ? result.frameTimesMs[result.frameTimesMs.length - 1]
            : -1;
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `[ffmpeg-preview] chunk ok token=${token} start=${startTimeMs}ms ` +
            `frames=${frameCount} queue=${this.ffmpegFrameQueue.length} firstPts=${firstPts} lastPts=${lastPts} ` +
            `decodedUntil=${this.ffmpegDecodedUntilMs}`);
        }
        if (this.ffmpegPreviewUri.length === 0 && this.ffmpegFrameQueue.length > 0) {
          this.ffmpegPreviewUri = this.ffmpegFrameQueue[0].uri;
        }
        this.ffmpegPreviewExtracting = false;
        this.ffmpegExtractStartAtMs = 0;
        if (this.isPlaying) {
          this.scheduleFfmpegDecodeIfNeeded(this.currentTime);
        }
      } else {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `ffmpeg 连续帧解码失败: ${result.errorMessage ?? 'unknown'}, start=${startTimeMs}, ` +
          `queue=${this.ffmpegFrameQueue.length}, decodedUntil=${this.ffmpegDecodedUntilMs}`);
        this.decodeFfmpegSingleFrameFallback(videoData, startTimeMs, token);
        return;
      }
    }).catch(() => {
      if (token !== this.ffmpegPipelineToken) {
        this.ffmpegPreviewExtracting = false;
        this.ffmpegExtractStartAtMs = 0;
        return;
      }
      this.decodeFfmpegSingleFrameFallback(videoData, startTimeMs, token);
    });
  }

  private decodeFfmpegSingleFrameFallback(videoData: VideoData, startTimeMs: number, token: number): void {
    const outputPath = `/data/storage/el2/base/cache/vidall_ffmpeg_fallback_${token}_${Date.now()}.jpg`;
    const seekSeconds = Math.max(0, startTimeMs) / 1000;

    FfmpegVideoFrameUtil.extractFrameToJpeg(
      videoData.videoSrc,
      outputPath,
      videoData.httpHeader,
      seekSeconds,
      FFMPEG_PREVIEW_DECODE_TIMEOUT_MS,
      { quality: FFMPEG_PREVIEW_JPEG_QUALITY, maxWidth: FFMPEG_PREVIEW_MAX_WIDTH }
    ).then((single) => {
      if (token !== this.ffmpegPipelineToken) {
        this.ffmpegPreviewExtracting = false;
        return;
      }

      if (single.success) {
        const queued: FfmpegQueuedFrame = {
          uri: 'file://' + single.outputPath,
          ptsMs: startTimeMs
        };
        if (this.ffmpegFrameQueue.length >= FFMPEG_PREVIEW_MAX_QUEUE_FRAMES) {
          this.ffmpegFrameQueue.shift();
        }
        this.ffmpegFrameQueue.push(queued);
        this.ffmpegDecodedUntilMs = Math.max(this.ffmpegDecodedUntilMs, startTimeMs + 300);
        this.ffmpegNextDecodeAllowedAtMs = 0;
        if (this.ffmpegPreviewUri.length === 0) {
          this.ffmpegPreviewUri = queued.uri;
        }
        if (ENABLE_FFMPEG_PREVIEW_DIAG_LOG) {
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `[ffmpeg-preview] single fallback ok token=${token} pts=${startTimeMs} queue=${this.ffmpegFrameQueue.length}`);
        }
      } else {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `ffmpeg 单帧兜底失败: ${single.errorMessage ?? 'unknown'}`);
        this.ffmpegNextDecodeAllowedAtMs = Date.now() + FFMPEG_PREVIEW_DECODE_RETRY_DELAY_MS;
      }

      this.ffmpegPreviewExtracting = false;
      this.ffmpegExtractStartAtMs = 0;
      if (this.isPlaying) {
        this.scheduleFfmpegDecodeIfNeeded(this.currentTime);
      }
    }).catch(() => {
      if (token !== this.ffmpegPipelineToken) {
        this.ffmpegPreviewExtracting = false;
        return;
      }
      this.ffmpegNextDecodeAllowedAtMs = Date.now() + FFMPEG_PREVIEW_DECODE_RETRY_DELAY_MS;
      this.ffmpegPreviewExtracting = false;
      this.ffmpegExtractStartAtMs = 0;
    });
  }

  private tryCatchupFrameWhileExtracting(targetPtsMs: number): void {
    if (!this.isPlaying) {
      return;
    }
    const videoData = this.currentVideoData;
    if (!videoData) {
      return;
    }
    if (!this.ffmpegPreviewExtracting) {
      return;
    }
    if (this.ffmpegCatchupExtracting) {
      return;
    }
    if (this.ffmpegExtractStartAtMs <= 0) {
      return;
    }
    const extractingElapsedMs = Date.now() - this.ffmpegExtractStartAtMs;
    if (!this.ffmpegSingleFrameMode && this.ffmpegFrameQueue.length === 0 &&
      extractingElapsedMs >= FFMPEG_PREVIEW_EXTRACT_STUCK_MS) {
      this.ffmpegSingleFrameMode = true;
      this.ffmpegPipelineToken += 1;
      this.ffmpegPreviewExtracting = false;
      this.ffmpegExtractStartAtMs = 0;
      this.ffmpegCatchupExtracting = false;
      this.ffmpegNextDecodeAllowedAtMs = 0;
      const singleModeToken = this.ffmpegPipelineToken;
      if (ENABLE_FFMPEG_PREVIEW_DIAG_LOG) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `[ffmpeg-preview] switch to single-frame mode elapsed=${extractingElapsedMs} ` +
          `target=${targetPtsMs} token=${singleModeToken}`);
      }
      this.decodeFfmpegSingleFrameFallback(videoData, Math.max(0, targetPtsMs), singleModeToken);
      return;
    }
    if (extractingElapsedMs > FFMPEG_PREVIEW_EXTRACT_HARD_TIMEOUT_MS) {
      // 单次提帧任务超时过久，切断旧流水线并直接追当前时钟，避免长期卡在同一帧。
      this.ffmpegSingleFrameMode = true;
      this.ffmpegPipelineToken += 1;
      this.ffmpegPreviewExtracting = false;
      this.ffmpegExtractStartAtMs = 0;
      this.ffmpegCatchupExtracting = false;
      this.ffmpegNextDecodeAllowedAtMs = 0;
      this.ffmpegLastForceRestartAtMs = Date.now();
      const rescueToken = this.ffmpegPipelineToken;
      if (ENABLE_FFMPEG_PREVIEW_DIAG_LOG) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `[ffmpeg-preview] extracting hard-timeout rescue elapsed=${extractingElapsedMs} ` +
          `target=${targetPtsMs} token=${rescueToken}`);
      }
      this.decodeFfmpegSingleFrameFallback(videoData, Math.max(0, targetPtsMs), rescueToken);
      return;
    }
    if (extractingElapsedMs < FFMPEG_PREVIEW_EXTRACT_STUCK_MS) {
      return;
    }

    this.ffmpegCatchupExtracting = true;
    const token = this.ffmpegPipelineToken;
    const seekMs = Math.max(0, targetPtsMs);
    const outputPath = `/data/storage/el2/base/cache/vidall_ffmpeg_catchup_${token}_${Date.now()}.jpg`;

    FfmpegVideoFrameUtil.extractFrameToJpeg(
      videoData.videoSrc,
      outputPath,
      videoData.httpHeader,
      seekMs / 1000,
      FFMPEG_PREVIEW_DECODE_TIMEOUT_MS,
      { quality: FFMPEG_PREVIEW_JPEG_QUALITY, maxWidth: FFMPEG_PREVIEW_MAX_WIDTH }
    ).then((single) => {
      this.ffmpegCatchupExtracting = false;
      if (token !== this.ffmpegPipelineToken) {
        return;
      }
      if (!single.success) {
        return;
      }

      const queued: FfmpegQueuedFrame = {
        uri: 'file://' + single.outputPath,
        ptsMs: seekMs
      };
      if (this.ffmpegFrameQueue.length >= FFMPEG_PREVIEW_MAX_QUEUE_FRAMES) {
        this.ffmpegFrameQueue.shift();
      }
      this.ffmpegFrameQueue.push(queued);
      this.ffmpegDecodedUntilMs = Math.max(this.ffmpegDecodedUntilMs, seekMs);
      if (ENABLE_FFMPEG_PREVIEW_DIAG_LOG) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[ffmpeg-preview] catchup frame ok token=${token} pts=${seekMs} queue=${this.ffmpegFrameQueue.length}`);
      }
    }).catch(() => {
      this.ffmpegCatchupExtracting = false;
    });
  }

  private maybeForceRestartDecode(targetPtsMs: number): void {
    // 当前阶段禁用激进重启，避免重复打断导致解码任务饥饿。
    void targetPtsMs;
    return;
    // 历史强制重启逻辑已停用，暂保留注释以便后续回溯。
    // if (!this.isPlaying) {
    //   return;
    // }
    // if (!this.currentVideoData) {
    //   return;
    // }
    // if (!this.ffmpegPreviewExtracting) {
    //   return;
    // }
    // if (this.ffmpegExtractStartAtMs <= 0) {
    //   return;
    // }
    // if (this.ffmpegLastRenderedPtsMs < 0) {
    //   return;
    // }
    // if (this.ffmpegSameFrameTicks < FFMPEG_PREVIEW_FORCE_RESTART_SAME_TICKS) {
    //   return;
    // }
    // const lagMs = targetPtsMs - this.ffmpegLastRenderedPtsMs;
    // if (lagMs < FFMPEG_PREVIEW_FORCE_RESTART_LAG_MS) {
    //   return;
    // }
    // const now = Date.now();
    // if (now - this.ffmpegLastForceRestartAtMs < FFMPEG_PREVIEW_FORCE_RESTART_INTERVAL_MS) {
    //   return;
    // }
    // this.ffmpegLastForceRestartAtMs = now;
    // this.ffmpegPipelineToken += 1;
    // this.ffmpegPreviewExtracting = false;
    // this.ffmpegExtractStartAtMs = 0;
    // this.ffmpegCatchupExtracting = false;
    // this.ffmpegFrameQueue = [];
    // const leadMs = Math.floor(FFMPEG_PREVIEW_LEAD_SECONDS * 1000);
    // const restartStartMs = Math.max(0, this.currentTime + leadMs);
    // this.ffmpegDecodedUntilMs = restartStartMs;
    // if (ENABLE_FFMPEG_PREVIEW_DIAG_LOG) {
    //   hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
    //     `[ffmpeg-preview] force restart decode lag=${lagMs} sameTicks=${this.ffmpegSameFrameTicks} ` +
    //     `target=${targetPtsMs} rendered=${this.ffmpegLastRenderedPtsMs} restartStart=${restartStartMs}`);
    // }
    // this.decodeFfmpegFrameChunk(this.currentVideoData, restartStartMs, this.ffmpegPipelineToken);
  }

  private tryCatchupFrameWhenQueueEmpty(targetPtsMs: number): void {
    if (!this.isPlaying) {
      return;
    }
    const videoData = this.currentVideoData;
    if (!videoData) {
      return;
    }
    if (this.ffmpegFrameQueue.length > 0) {
      return;
    }
    if (this.ffmpegPreviewExtracting || this.ffmpegCatchupExtracting) {
      return;
    }
    const now = Date.now();
    if (now - this.ffmpegLastEmptyQueueCatchupAtMs < FFMPEG_PREVIEW_EMPTY_QUEUE_CATCHUP_INTERVAL_MS) {
      return;
    }
    this.ffmpegLastEmptyQueueCatchupAtMs = now;

    if (ENABLE_FFMPEG_PREVIEW_DIAG_LOG) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `[ffmpeg-preview] empty queue catchup trigger target=${targetPtsMs} t=${this.currentTime}`);
    }

    this.decodeFfmpegSingleFrameFallback(videoData, Math.max(0, targetPtsMs), this.ffmpegPipelineToken);
  }

  private logFfmpegPreviewTick(targetPtsMs: number): void {
    if (!ENABLE_FFMPEG_PREVIEW_DIAG_LOG) {
      return;
    }
    const now = Date.now();
    if (now - this.ffmpegLastDiagLogAtMs < FFMPEG_PREVIEW_DIAG_LOG_INTERVAL_MS) {
      return;
    }
    this.ffmpegLastDiagLogAtMs = now;

    let headPts = -1;
    let nextPts = -1;
    if (this.ffmpegFrameQueue.length > 0) {
      headPts = this.ffmpegFrameQueue[0].ptsMs;
    }
    if (this.ffmpegFrameQueue.length > 1) {
      nextPts = this.ffmpegFrameQueue[1].ptsMs;
    }

    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[ffmpeg-preview] tick t=${this.currentTime} target=${targetPtsMs} ` +
      `queue=${this.ffmpegFrameQueue.length} headPts=${headPts} nextPts=${nextPts} ` +
      `renderPts=${this.ffmpegLastRenderedPtsMs} sameTicks=${this.ffmpegSameFrameTicks} ` +
      `decodedUntil=${this.ffmpegDecodedUntilMs} extracting=${this.ffmpegPreviewExtracting} ` +
      `stallAdvance=${this.ffmpegStallAdvanceMs} singleMode=${this.ffmpegSingleFrameMode}`);
  }

  /**
   * 注入字幕缓存上下文，用于步骤 4 本地缓存自动加载。
   * 由 player page 在持有 UIAbilityContext 后调用，注入 filesDir 等信息。
   */
  setSubtitleCacheContext(ctx: SubtitleCacheContext): void {
    this.subtitleCacheContext = ctx;
  }

  /**
   * 时序说明（thin delegation to `PlaybackBackendService.bindIjkContext`）：
   * 1. UI 层先注册 emitter.once(PREPARED)
   * 2. UI 层调 initPlayer()（创建 IjkPlayerAdapter 但不调 native_setup）
   * 3. UI 层调 setIjkContext()（setContext → native_setup → setDataSource → prepareAsync）
   *
   * service 负责：
   * - SMB fallback 时的代理重启
   * - adapter.init 编排
   * controller 负责：
   * - 校验 backend / player 就绪
   * - 缓存 context/componentId 供 reloadSource 复用
   * - init 失败的 rejectPendingReload
   */
  async setIjkContext(context: object, xComponentId: string): Promise<void> {
    if (this.backend !== 'ijkplayer') {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        'setIjkContext() 被调用但 backend 不是 ijkplayer，忽略');
      return;
    }
    if (!this.player) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        'setIjkContext() 被调用但 player 未初始化，可能 initPlayer() 还未完成');
      return;
    }
    this.cachedIjkContext = context;
    this.cachedIjkComponentId = xComponentId;
    if (this.currentVideoData) {
      // 委托 SMB 代理重启给 service
      if (this.smbOriginalSrc.length > 0) {
        this.backendService.restartSmbProxyForFallback(this.smbOriginalSrc, this.currentVideoData);
      }
      try {
        await this.backendService.bindIjkContext(
          this.player,
          context,
          xComponentId,
          this.currentVideoData,
          this.surfaceId
        );
      } catch (e) {
        const err = e as Error;
        hilog.error(CommonConstants.LOG_DOMAIN, TAG,
          `setIjkContext init 失败: ${err.message}`);
        this.rejectPendingReload(err);
      }
    }
  }

  /**
   * 供 VideoPlayer UI 层在 native so XComponent.onLoad 回调中调用。
   * 当前阶段仅完成原生播放器骨架绑定，真实解码/渲染链路后续接入。
   * 行为已迁移至 `PlaybackBackendService.bindNativeContext`，controller 仅保留 façade 校验与回退。
   */
  async setNativeContext(context: object, xComponentId: string): Promise<void> {
    if (this.backend !== 'native') {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        'setNativeContext() 被调用但 backend 不是 native，忽略');
      return;
    }
    if (!this.player) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        'setNativeContext() 被调用但 player 未初始化，可能 initPlayer() 还未完成');
      return;
    }
    this.cachedNativeContext = context;
    this.cachedNativeComponentId = xComponentId;
    this.startNativeReadyGuard(this.playbackSessionId);
    if (this.currentVideoData) {
      try {
        await this.backendService.bindNativeContext(
          this.player,
          context,
          xComponentId,
          this.currentVideoData,
          this.surfaceId
        );
      } catch (e) {
        const err = e as Error;
        hilog.error(CommonConstants.LOG_DOMAIN, TAG,
          `setNativeContext init 失败: ${err.message}`);
        this.rejectPendingReload(err);
        this.fallbackNativeToIjk('native_init_error', 'native 初始化失败，已自动回退到 IJK 播放', err.message);
      }
    }
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
    if (this.backend !== 'mpv') {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        'setMpvSurface() 被调用但 backend 不是 mpv，忽略');
      return;
    }
    if (!this.player) {
      // player 还未初始化（fallback 场景 onAreaChange 可能先于 initPlayer 触发）
      // 缓存参数，等 initPlayer 完成后自动绑定
      this.pendingMpvSurfaceId = surfaceId;
      this.pendingMpvSurfaceWidth = width;
      this.pendingMpvSurfaceHeight = height;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `setMpvSurface() player 未初始化，缓存 surface 参数: id=${surfaceId.substring(0, 8)}... w=${width} h=${height}`);
      return;
    }
    if (this.mpvSurfaceBound) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        'setMpvSurface() surface 已绑定，忽略重复调用');
      return;
    }
    this.mpvSurfaceWidth = width;
    this.mpvSurfaceHeight = height;
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
        this.rejectPendingReload(err);
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

  setNativeSeekDiagLogEnabled(enabled: boolean): void {
    this.nativeSeekDiagLogEnabled = enabled;
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
    const reloadToken = this.pendingReloadToken + 1;
    this.pendingReloadToken = reloadToken;
    this.activeReloadToken = reloadToken;
    const reloadPromise = new Promise<void>((resolve, reject) => {
      this.pendingReloadResolve = resolve;
      this.pendingReloadReject = reject;
      this.reloadTimeoutId = setTimeout(() => {
        if (reloadToken !== this.activeReloadToken) {
          return;
        }
        this.rejectPendingReload(new Error('reloadSource prepared timeout'));
      }, 15000);
    });
    try {
      await this.initPlayer(videoData, this.surfaceId);
      if (this.backend === 'ijkplayer') {
        if (this.cachedIjkContext === undefined || this.cachedIjkComponentId.length === 0) {
          throw new Error('reloadSource missing ijk context');
        }
        await this.setIjkContext(this.cachedIjkContext, this.cachedIjkComponentId);
      } else if (this.backend === 'mpv') {
        // 重置绑定状态，使 setMpvSurface 可重新执行
        this.mpvSurfaceBound = false;
        await this.setMpvSurface(this.surfaceId, this.mpvSurfaceWidth, this.mpvSurfaceHeight);
      } else if (this.backend === 'native') {
        if (this.cachedNativeContext === undefined || this.cachedNativeComponentId.length === 0) {
          throw new Error('reloadSource missing native context');
        }
        await this.setNativeContext(this.cachedNativeContext, this.cachedNativeComponentId);
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

  private clearPendingReloadState(): void {
    if (this.reloadTimeoutId !== undefined) {
      clearTimeout(this.reloadTimeoutId);
      this.reloadTimeoutId = undefined;
    }
    this.pendingReloadResolve = undefined;
    this.pendingReloadReject = undefined;
  }

  private resolvePendingReload(): void {
    const resolve = this.pendingReloadResolve;
    this.clearPendingReloadState();
    if (resolve !== undefined) {
      resolve();
    }
  }

  private rejectPendingReload(error: Error): void {
    const reject = this.pendingReloadReject;
    this.clearPendingReloadState();
    if (reject !== undefined) {
      reject(error);
    }
  }

  private clearCachedXComponentState(): void {
    this.cachedIjkContext = undefined;
    this.cachedIjkComponentId = '';
    this.cachedNativeContext = undefined;
    this.cachedNativeComponentId = '';
  }

  /**
   * 设置 AVPlayer 遇到格式不支持时的回退后端。
   *
    * 默认先尝试 native，若 native 不可用会自动继续回退到 ijkplayer。
   */
  setUnsupportedFormatFallback(fallback: UnsupportedFormatFallback): void {
    this.unsupportedFormatFallback = fallback;
    this.unsupportedFallbackLockedByUser = true;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `unsupportedFormatFallback 已更新为 ${fallback}`);
  }

  /** 清除外部锁定，恢复根据音轨自动选择回退策略。 */
  resetUnsupportedFormatFallbackAutoPolicy(): void {
    this.unsupportedFallbackLockedByUser = false;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      'unsupportedFormatFallback 已恢复自动策略');
  }

  /**
   * 播放中切换内核（用户主动切换）。
   * 保存当前进度 → 释放旧播放器 → 切换 backend → 重新 initPlayer → seek 到保存位置。
   */
  switchBackendInPlayback(targetBackend: PlayerBackend): void {
    if (this.backend === targetBackend) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `switchBackendInPlayback: 已是 ${targetBackend}，无需切换`);
      return;
    }
    if (targetBackend !== 'ijkplayer' && targetBackend !== 'mpv') {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `switchBackendInPlayback: 不支持切换到 ${targetBackend}，仅支持 ijkplayer/mpv`);
      return;
    }
    const savedPosition = this.currentTime;
    const savedDuration = this.duration;
    const savedVideoData = this.currentVideoData;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `switchBackendInPlayback: ${this.backend} → ${targetBackend}, savedPosition=${savedPosition}ms`);

    // 释放当前播放器
    this.release().then(() => {
      // 切换 backend
      this.backend = targetBackend;
      this.unsupportedFormatFallback = targetBackend;
      this.unsupportedFallbackLockedByUser = true;

      // 如果有视频数据，重新初始化
      if (savedVideoData) {
        if (targetBackend === 'mpv') {
          // MPV 后端：不在此处调 initPlayer，避免与 XComponent onLoad 的 initPlayer 并发冲突。
          // XComponent 重建后 onLoad 会自动调用 initPlayer + setMpvSurface。
          // 通过 pendingResumeState 保存恢复位置，MPV prepared 后 onPlayerReady 自动 seek 恢复。
          this.savePendingResumeState(savedPosition, true, 'switch_backend', 'explicit',
            'switch_backend_to_mpv', targetBackend);
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `switchBackendInPlayback: MPV 后端，等待 XComponent onLoad 自动初始化，savedPosition=${savedPosition}ms`);
        } else {
          // ijkplayer 后端：同样使用 pendingResumeState 机制。
          // initPlayer() 完成时 ijkplayer 的 prepareAsync 尚未就绪，
          // 直接在 .then() 中调 seek/play 会被 IjkPlayerAdapter 忽略（_isPrepared=false）。
          // 通过 pendingResumeState 让 onPlayerReady 在 prepared 后统一处理 seek 恢复。
          this.savePendingResumeState(savedPosition, true, 'switch_backend', 'explicit',
            'switch_backend_to_ijkplayer', targetBackend);
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `switchBackendInPlayback: ijkplayer 后端，通过 pendingResumeState 等待 prepared，savedPosition=${savedPosition}ms`);
          this.initPlayer(savedVideoData, this.surfaceId).catch(() => {
            hilog.error(CommonConstants.LOG_DOMAIN, TAG,
              `switchBackendInPlayback: 切换到 ${targetBackend} 失败`);
          });
        }
      }
    }).catch(() => {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `switchBackendInPlayback: 释放当前播放器失败`);
    });
  }

  /**
   * 依据预置音轨信息判断是否优先回退 ffmpeg。
   * 命中 AC-3/E-AC-3/DTS/TrueHD 时返回 true。
   */
  private shouldPreferFfmpegFallback(videoData: VideoData): boolean {
    const tracks = videoData.presetAudioTracks;
    if (!tracks || tracks.length === 0) {
      return false;
    }

    for (let i = 0; i < tracks.length; i++) {
      const track = tracks[i];
      const mime = (track.mimeType ?? '').toLowerCase();
      const name = track.displayName.toLowerCase();
      if (
        mime.includes('ac-3') ||
        mime.includes('eac3') ||
        mime.includes('dts') ||
        mime.includes('truehd') ||
        name.includes('ac-3') ||
        name.includes('e-ac-3') ||
        name.includes('eac3') ||
        name.includes('dts') ||
        name.includes('truehd')
      ) {
        return true;
      }
    }
    return false;
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
      `decodePlan=${currentDecodePlan}; ` +
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

  // ─── 路由决策 / 初始选轨 helpers 已迁移至 `AudioTrackRoutingService` ───
  // - readPresetAudioHint
  // - inferTrackChannels
  // - normalizeChannelsForSort
  // - normalizeTargetChannels
  // - isLikelySystemHardDecodeSupported
  // - isAudioTrackPlayable
  // controller 仅保留 façade 调用 `audioRoutingService.resolveRoutingDecision` /
  // `serviceFindInitialAudioTrackIndex`，并把状态投影到 @Trace 字段。

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
    this.clearNativeReadyGuardTimer();
    this.hasPrepared = true;
    const playerDuration = this.player?.duration ?? 0;
    this.duration = playerDuration > 0
      ? playerDuration
      : (this.currentVideoData?.durationHintMs ?? 0);
    this.currentTime = this.player?.currentTime ?? 0;
    this.isReady = true;
    this.isLoading = false;
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
    emitter.emit(PlayerEvents.PREPARED);
    if (this.playbackSpeed !== 1.0 && this.player) {
      this.player.setPlaybackSpeed(this.playbackSpeed);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `onPlayerReady: 重新应用播放速率 speed=${this.playbackSpeed}`);
    }

    const resumeTimeMs = pendingResumeState?.positionMs ?? -1;
    const shouldResumePlay = pendingResumeState?.shouldResumePlay ?? false;
    const resumeSource = pendingResumeState?.reason ?? '';
    const resumeCaptureBackend = pendingResumeState?.captureBackend ?? this.backend;
    const resumeAutoplayDecisionSource = pendingResumeState?.autoplayDecisionSource ?? '';
    const resumeAutoplayDecisionOrigin = pendingResumeState?.autoplayDecisionOrigin ?? '';
    const effectiveResumeTimeMs = resumeTimeMs > 0 && this.duration > 0 && resumeTimeMs > this.duration
      ? this.duration
      : (resumeTimeMs > 0 ? resumeTimeMs : 0);
    if (pendingResumeState !== null) {
      this.logResumeDiagnostic('resume_pending_consume', resumeSource, resumeCaptureBackend, resumeTimeMs,
        effectiveResumeTimeMs, shouldResumePlay, 'pending', -1,
        resumeAutoplayDecisionSource, resumeAutoplayDecisionOrigin);
    }

    if (pendingResumeState !== null && pendingResumeState.positionMs > 0 && this.player) {
      const safeResumeTimeMs = effectiveResumeTimeMs;
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
      this.suppressPlayAfterSeekOnce = true;
      this.pendingReadyTrackInitAfterSeek = true;
      this.pendingReadyTrackInitResumePlay = shouldResumePlay;
      this.pendingResumeSeekInFlight = true;
      this.pendingResumeSeekSource = resumeSource;
      this.pendingResumeSeekCaptureBackend = resumeCaptureBackend;
      this.pendingResumeSeekTargetMs = safeResumeTimeMs;
      this.pendingResumeSeekAutoPlay = shouldResumePlay;
      this.primePendingResumeAutoplayResult(resumeSource, resumeCaptureBackend, resumeTimeMs,
        safeResumeTimeMs, shouldResumePlay, shouldResumePlay ? 'play_after_seek' : 'suppress_after_seek',
        resumeAutoplayDecisionSource, resumeAutoplayDecisionOrigin);
      this.logResumeDiagnostic('resume_seek_dispatch', resumeSource, resumeCaptureBackend, resumeTimeMs,
        safeResumeTimeMs, shouldResumePlay, shouldResumePlay ? 'play_after_seek' : 'suppress_after_seek', -1,
        resumeAutoplayDecisionSource, resumeAutoplayDecisionOrigin);
      this.player.seek(safeResumeTimeMs);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `后端切换续播定位: backend=${this.backend} time=${safeResumeTimeMs}`);
      return;
    }

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
    this.pendingResumeAutoplayResultState = {
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
    const pendingState = this.pendingResumeAutoplayResultState;
    if (pendingState === null) {
      return;
    }
    this.logResumeDiagnostic('resume_autoplay_result', pendingState.resumeSource, pendingState.captureBackend,
      pendingState.pendingResumeMs, pendingState.effectiveResumeMs, pendingState.shouldResumePlay,
      pendingState.autoplayDecision, -1, pendingState.autoplayDecisionSource, pendingState.autoplayDecisionOrigin, result);
    if (shouldClear) {
      this.pendingResumeAutoplayResultState = null;
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
    if (sessionId !== this.playbackSessionId || !this.pendingReadyTrackInitAfterSeek) {
      return;
    }
    const shouldResumePlay = this.pendingReadyTrackInitResumePlay;
    this.pendingReadyTrackInitAfterSeek = false;
    this.pendingReadyTrackInitResumePlay = false;
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

  private clearNativeReadyGuardTimer(): void {
    if (this.nativeReadyGuardTimer !== undefined) {
      clearTimeout(this.nativeReadyGuardTimer);
      this.nativeReadyGuardTimer = undefined;
    }
  }

  private startNativeReadyGuard(sessionId: number): void {
    this.clearNativeReadyGuardTimer();
    this.nativeReadyGuardTimer = setTimeout(() => {
      this.nativeReadyGuardTimer = undefined;
      if (sessionId !== this.playbackSessionId) {
        return;
      }
      if (this.backend !== 'native') {
        return;
      }
      if (!this.isReady) {
        this.fallbackNativeToIjk('native_ready_timeout', 'native 初始化超时，已自动回退到 IJK 播放');
        return;
      }
      if (!this.isPlaying) {
        return;
      }
      const currentDuration = this.player?.duration ?? this.duration;
      const currentPosition = this.player?.currentTime ?? this.currentTime;
      if (currentDuration <= 0 && currentPosition <= 100) {
        this.fallbackNativeToIjk('native_no_timeline_output', 'native 未输出可播时间轴，已自动回退到 IJK 播放');
      }
    }, NATIVE_READY_GUARD_MS);
  }

  private fallbackNativeToIjk(fallbackReason: string, userMessage: string, detailMessage: string = ''): void {
    if (this.backend !== 'native') {
      return;
    }
    const fallbackPosition = this.player?.currentTime ?? this.currentTime;
    const safeFallbackPosition = fallbackPosition > 0 ? fallbackPosition : 0;
    const autoplayDecision = this.resolvePendingResumeAutoplayDecision(this.isPlaying, 'transient_player_state');
    this.logFallbackEvent(fallbackReason, 'native', 'ijkplayer', detailMessage);
    hilog.warn(CommonConstants.LOG_DOMAIN, TAG, userMessage);
    this.lastErrorMessage = userMessage;
    this.isLoading = true;
    this.clearNativeReadyGuardTimer();
    this.savePendingResumeState(safeFallbackPosition, autoplayDecision.shouldResumePlay,
      autoplayDecision.source, autoplayDecision.origin, fallbackReason, 'native');
    const oldPlayer = this.player;
    this.player = undefined;
    this.backend = 'ijkplayer';
    oldPlayer?.release().catch(() => {});
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
    // 成功播放后清理历史错误，避免底部长期显示旧报错。
    this.lastErrorMessage = '';
    if (ENABLE_SESSION_DIAG_LOG) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[session=${currentSessionId}] onPlay`);
    }
    this.resumeSubtitleTimer();
    this.startProgressTimer();
    if (this.backend === 'ffmpeg') {
      this.startFfmpegRenderTimer();
      this.scheduleFfmpegDecodeIfNeeded(this.currentTime);
    }
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

  private safeErrorMessage(e: Object): string {
    const err = e as BusinessError;
    if (typeof err.message === 'string' && err.message.length > 0) {
      return err.message;
    }
    return JSON.stringify(err);
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
    const nativeArgumentError = this.resolveNativeArgumentErrorHint(msg);
    if (nativeArgumentError.length > 0) {
      return nativeArgumentError;
    }
    const nativeStateCode = this.extractNativeStateCode(msg);
    if (nativeStateCode > 0) {
      return this.resolveNativeStateErrorHint(nativeStateCode);
    }
    if (msg.includes('[NAPI/')) {
      const hintText = this.extractNativeHint(msg);
      if (hintText.length > 0) {
        return `原生播放器调用失败：${hintText}`;
      }
      return '原生播放器调用失败，请重试';
    }
    if (msg.toLowerCase() === GENERIC_SYSTEM_ERROR) {
      return '播放器内部错误，请重试';
    }
    return msg;
  }

  private resolveNativeArgumentErrorHint(message: string): string {
    const lower = message.toLowerCase();
    if (lower.includes('invalid player handle')) {
      return '播放器实例已失效，请退出后重试';
    }
    if (lower.includes('player handle overflow')) {
      return '播放器实例异常，请重启应用后重试';
    }
    if (lower.includes('requires (handle')) {
      return '播放器调用参数缺失，请重试';
    }
    if (lower.includes('must be int32')) {
      return '播放器调用参数类型错误，请重试';
    }
    if (lower.includes('must be int64')) {
      return '播放器调用参数范围错误，请重试';
    }
    if (lower.includes('must be string')) {
      return '播放器调用字符串参数错误，请重试';
    }
    if (lower.includes('must be object')) {
      return '播放器渲染上下文参数错误，请重试';
    }
    if (lower.includes('must be function') || lower.includes('failed to create callback references')) {
      return '播放器回调注册失败，请重试';
    }
    if (lower.includes('failed to read args')) {
      return '播放器调用参数读取失败，请重试';
    }
    return '';
  }

  private extractNativeStateCode(message: string): number {
    if (!message.startsWith('[')) {
      return -1;
    }
    const end = message.indexOf(']');
    if (end <= 1) {
      return -1;
    }
    const codeText = message.substring(1, end).trim();
    if (codeText.length === 0) {
      return -1;
    }
    const parsed = Number(codeText);
    if (!Number.isFinite(parsed)) {
      return -1;
    }
    return Math.trunc(parsed);
  }

  private extractNativeHint(message: string): string {
    const hintKey = 'hint=';
    const hintIndex = message.indexOf(hintKey);
    if (hintIndex < 0) {
      return '';
    }
    const hintText = message.substring(hintIndex + hintKey.length).trim();
    if (hintText.length === 0) {
      return '';
    }
    return hintText;
  }

  private resolveNativeStateErrorHint(code: number): string {
    if (code === 1001) {
      return '播放器初始化失败：未设置播放地址';
    }
    if (code === 1002) {
      return '播放器初始化失败：未绑定渲染组件';
    }
    if (code === 1003) {
      return '播放器尚未就绪，暂时无法播放';
    }
    if (code === 1004) {
      return '播放器尚未就绪，暂时无法切换轨道';
    }
    if (code === 1005) {
      return '播放器尚未就绪，暂时无法暂停';
    }
    if (code === 1006) {
      return '播放器尚未就绪，暂时无法跳转进度';
    }
    if (code === 1007) {
      return '轨道切换参数无效，请刷新后重试';
    }
    return `播放器状态异常（错误码 ${code}）`;
  }

  async pause(): Promise<void> {
    if (this.resumeSeekAutoplayFallbackTimer !== undefined) {
      this.clearResumeSeekAutoplayFallbackState();
      this.clearPendingResumeAutoplayDecision();
      this.suppressPlayAfterSeekOnce = true;
    }
    await this.player?.pause().catch((err: BusinessError) => {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `pause 失败: code=${err.code} msg=${err.message}`);
    });
  }

  async toggle(): Promise<void> {
    await this.player?.toggle();
  }

  async release(): Promise<void> {
    this.rejectPendingReload(new Error('player released'));
    this.clearCachedXComponentState();
    this.clearNativeReadyGuardTimer();
    this.pendingResumeAutoplayResultState = null;
    this.clearResumeSeekAutoplayFallbackState();
    this.stopProgressTimer();
    this.saveProgressNow();
    // 重置 MPV surface 绑定状态，避免 switchBackendInPlayback 后 onAreaChange
    // 检查 isMpvSurfaceBound=true 而跳过 setMpvSurface，导致黑屏。
    this.mpvSurfaceBound = false;
    if (this.backend === 'ffmpeg') {
      this.stopFfmpegRenderTimer();
      this.ffmpegFrameQueue = [];
      this.ffmpegPreviewExtracting = false;
      this.ffmpegDecodedUntilMs = 0;
      this.ffmpegPipelineToken += 1;
      this.ffmpegSingleFrameMode = false;
    }
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
    // 清理 SMB 代理孤立线程（keepProxy=true 释放后遗留）——委托给 backend service
    if (this.smbProxyActive) {
      this.backendService.cleanupOrphanedProxies();
      this.smbProxyActive = false;
    }
    // 释放 VPE 实例（播放器已销毁后再销毁 VPE，避免 Surface 竞争）
    VpeEnhancerUtil.destroyEnhancer();
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
    } else if (this.nativeSeekDiagLogEnabled && this.duration <= 0 && safeTime > 0) {
      const now = Date.now();
      if (now - this.lastSeekDurationUnknownLogMs >= 3000) {
        this.lastSeekDurationUnknownLogMs = now;
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `[seek] duration 未就绪，暂不做上限裁剪 target=${safeTime}`);
      }
    }
    if (this.backend === 'ffmpeg') {
      this.ffmpegFrameQueue = [];
      this.ffmpegDecodedUntilMs = safeTime;
      this.ffmpegPipelineToken += 1;
      this.ffmpegPreviewExtracting = false;
      this.ffmpegLastRenderTickAtMs = 0;
      this.ffmpegLastObservedPlaybackMs = safeTime;
      this.ffmpegStallAdvanceMs = 0;
      this.ffmpegNextDecodeAllowedAtMs = 0;
      const seekVideoData = this.currentVideoData;
      if (seekVideoData) {
        if (this.ffmpegSingleFrameMode) {
          this.decodeFfmpegSingleFrameFallback(seekVideoData, safeTime, this.ffmpegPipelineToken);
        } else {
          this.decodeFfmpegFrameChunk(seekVideoData, safeTime, this.ffmpegPipelineToken);
        }
      }
    }
    if (autoplayDecisionSource.length > 0) {
      this.rememberPendingResumeAutoplayDecision(true, autoplayDecisionSource);
      this.preservePendingResumeAutoplayDecisionOnPaused = true;
    } else {
      this.preservePendingResumeAutoplayDecisionOnPaused = false;
    }
    await this.pause();
    this.currentTime = safeTime;
    this.subtitleAdapter.onSeekSync();
    this.applySubtitleBridgeState(this.subtitleAdapter.getState());
    if (!this.isSeeking) {
      this.isSeeking = true;
      try {
        this.player.seek(safeTime);
        if (autoplayDecisionSource.length > 0) {
          this.armResumeSeekAutoplayFallback(this.playbackSessionId);
        }
      } catch (seekErr) {
        // seek 调用失败（如 native 地底抛异常）：重置 isSeeking 防止永久卡住。
        // onError 回调已在 callNativeVoid 里触发，此处仅做状态修复。
        this.isSeeking = false;
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
    FileSourceDatabase.getInstance().upsertPlayProgress(progress).catch((e: BusinessError) => {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `进度写入失败: code=${e.code} msg=${e.message}`);
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
      this.smbOriginalSrc,
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
        if (this.backend === 'ffmpeg') {
          this.activeAudioIndex = 0;
          return;
        }
        await this.selectInitialAudioTrackByService();
        return;
      }

      // ── player.getTrackInfos()（AVPlayer 原生 / IjkPlayer getMediaInfo 解析）──
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
        if (this.backend === 'ffmpeg') {
          this.activeAudioIndex = 0;
        } else {
          await this.selectInitialAudioTrackByService();
        }
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
    const videoPath = this.smbOriginalSrc.length > 0
      ? this.smbOriginalSrc
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
   * - SMB 源代理 URL 端口随机，必须用 smbOriginalSrc 作为绑定 key
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
      this.smbOriginalSrc,
      allIndex
    );
    this.applySubtitleBridgeState(this.subtitleAdapter.getState());

    // 应用 binding directive 持久化
    const rawVideoSrc = this.currentVideoData?.videoSrc ?? '';
    const videoPath = this.smbOriginalSrc.length > 0 ? this.smbOriginalSrc : rawVideoSrc;
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

    // ffmpeg 当前阶段固定首音轨软解，不执行 pause/seek/play 切轨流程，避免重入导致时间回跳。
    if (this.backend === 'ffmpeg') {
      this.activeAudioIndex = trackIndex;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[switchAudioTrack] ffmpeg 后端仅更新 UI 选中项: index=${trackIndex}`);
      return;
    }

    // 初始化加载时（isReady 刚触发，尚未真正播放）直接切换，不需要暂停/恢复
    const wasPlaying = this.isPlaying;
    const seekBack = this.currentTime;

    try {
      // 1. 暂停视频（避免音轨切换期间画面继续走而音轨还在旧轨）
      if (wasPlaying) {
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
      const seekTarget = this.pendingResumeSeekInFlight
        ? this.pendingResumeSeekTargetMs
        : seekBack;
      if (wasPlaying && seekTarget > 0) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[switchAudioTrack] seek flush 到 ${seekTarget}ms${this.pendingResumeSeekInFlight ? ' (resume seek 目标)' : ''}`);
        // 借用 seek() 的暂停-seek-恢复流程：isSeeking=true，seekDone 后自动 play()
        this.isSeeking = true;
        this.player.seek(seekTarget);
        // seekDone 回调里会调 play()，不需要在这里手动恢复
      } else if (wasPlaying) {
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
