import { PlayerEvents, VideoDataType } from "./Constants";
import { VideoData } from "./VideoData";
import { BusinessError, emitter } from "@kit.BasicServicesKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { CommonConstants } from "../../../common/constants/CommonConstants";
import { millisecondsToTime } from "../../../utils/TimeUtil";
import { IPlayer, TrackInfo } from "./IPlayer";
import { AVPlayerAdapter } from "./AVPlayerAdapter";
import { IjkPlayerAdapter } from "./IjkPlayerAdapter";
import { VidAllPlayerAdapter } from "./VidAllPlayerAdapter";
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

export type { SubtitleTrackItem } from "./SubtitleBridgeAdapter";

/** 播放内核类型 */
export type PlayerBackend = 'avplayer' | 'ijkplayer' | 'ffmpeg' | 'native';

const TAG = '[VideoPlayerController]';
const METRICS_TAG = 'VidAll_Metrics';
const GENERIC_SYSTEM_ERROR = 'system error';
const DEFAULT_NATIVE_SEEK_DIAG_LOG_ENABLED = false;
const NATIVE_READY_GUARD_MS = 3500;
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

interface AudioRoutingDecision {
  preferredBackend: PlayerBackend;
  fallback: UnsupportedFormatFallback;
  preferredChannels: number;
  summary: string;
  detectedCodec: string;
  detectedChannels: number;
  hardSupported: boolean;
  precheckProbeFailed: boolean;
  precheckProbeError: string;
  /** 视频编码名称（如 'hevc', 'h264'），由 ffprobe 探测，未探测到为空字符串 */
  videoCodecName: string;
}

interface PresetAudioHint {
  codecName: string;
  channels: number;
}

interface FallbackLogRecord {
  fallbackReason: string;
  fallbackFrom: PlayerBackend;
  fallbackTo: PlayerBackend;
  videoId: number;
  filePath: string;
  detailMessage: string;
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
}

export type UnsupportedFormatFallback = 'ijkplayer' | 'native';

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
  /** 音轨列表 */
  @Trace audioTracks: AudioTrackItem[] = [];
  @Trace activeAudioIndex: number = -1;
  /** 当前播放源的协议类型标识（如 'SMB'），用于 UI 展示与路由决策 */
  @Trace sourceProtocol: string = '';
  private subtitleAdapter: ISubtitleBridgeAdapter = new NoSubtitleBridgeAdapter();
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
  /** 10s 防抖进度写入定时器 */
  private progressTimer?: number;
  /** 播放会话编号：每次 initPlayer 自增，用于忽略旧实例回调 */
  private playbackSessionId: number = 0;
  /** 指标埋点：initPlayer 开始时间（用于计算首帧耗时） */
  private metricsLoadStartMs: number = 0;
  /** 指标埋点：seek 开始时间（用于计算 seek 完成耗时） */
  private metricsSeekStartMs: number = 0;
  /** 时间回退诊断：记录最近一次 timeUpdate 值 */
  private lastTimeUpdateMs: number = -1;
  /** duration 未就绪时 seek 的诊断日志节流 */
  private lastSeekDurationUnknownLogMs: number = 0;
  /** native seek 诊断开关（默认关闭） */
  private nativeSeekDiagLogEnabled: boolean = DEFAULT_NATIVE_SEEK_DIAG_LOG_ENABLED;
  /** native 初始化就绪保护定时器：超时后自动回退到 ijkplayer */
  private nativeReadyGuardTimer?: number;
  /** native 自动回退到 ijkplayer 时，待恢复的播放进度 */
  private pendingBackendResumeTimeMs: number = -1;
  /** native 自动回退后，是否在 seek 完成后自动续播 */
  private pendingBackendResumePlay: boolean = false;
  /** SMB 源当前是否通过 HTTP 代理运行（用于 release 时触发 cleanupOrphanedProxies） */
  private smbProxyActive: boolean = false;
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
    if (this.smbProxyActive) {
      VidAllPlayerAdapter.cleanupOrphanedProxies();
      this.smbProxyActive = false;
    }
    const shouldPreserveBackendResume = this.backend === 'ijkplayer' && this.pendingBackendResumeTimeMs >= 0;
    if (!shouldPreserveBackendResume) {
      this.pendingBackendResumeTimeMs = -1;
      this.pendingBackendResumePlay = false;
    }
    this.suppressPlayAfterSeekOnce = false;
    if (ENABLE_SESSION_DIAG_LOG) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[session=${currentSessionId}] initPlayer start backend=${this.backend}`);
    }

    // 先重置可展示状态，避免复用上次播放残留。
    this.audioCapabilityText = '';
    this.ffmpegPreviewUri = '';
    this.sourceProtocol = '';

    // 若外部未显式锁定策略，则根据探测结果自动选择硬解/软解路由。
    if (!this.unsupportedFallbackLockedByUser) {
      const backendBeforeAutoRouting = this.backend;
      const decision = await this.resolveAudioRoutingDecision(videoData);
      this.unsupportedFormatFallback = decision.fallback;
      videoData.ffmpegDecodeChannels = decision.preferredChannels;
      videoData.audioProbeSummary = decision.summary;
      videoData.videoCodec = decision.videoCodecName;
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
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `自动音频路由: backend=${this.backend}, fallback=${this.unsupportedFormatFallback}, ` +
        `ffmpegChannels=${videoData.ffmpegDecodeChannels}, summary=${decision.summary}`);
      this.logAudioCapabilityReport(decision);
    }

    if (this.backend === 'ffmpeg') {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        'ffmpeg 播放后端已从主路径下线，自动回退到 ijkplayer');
      this.backend = 'ijkplayer';
    }

    // native 后端已停止主路径接入（SMB 源现通过 HTTP 代理 + AVPlayer 播放），强制回退到 ijkplayer。
    if (this.backend === 'native') {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        'native 播放后端已从主路径下线，自动回退到 ijkplayer');
      this.backend = 'ijkplayer';
    }

    // SMB 源（smb://）统一通过本地 HTTP 代理转发，avplayer 和 ijkplayer 均适用。
    // 在所有自动路由决策完成后（backend 已确定为 avplayer/ijkplayer），启动代理并将
    // videoSrc 替换为代理 URL，下游 AVPlayerAdapter / IjkPlayerAdapter 均透明使用。
    let smbOriginalUrl: string = '';
    if (videoData.videoSrc.startsWith('smb://')) {
      this.sourceProtocol = 'SMB';
      smbOriginalUrl = videoData.videoSrc;
      // SMB 源统一通过本地 HTTP 代理转发，avplayer 和 ijkplayer 均适用
      const proxyUrl = VidAllPlayerAdapter.startSmbProxy(smbOriginalUrl);
      if (proxyUrl.length > 0) {
        videoData.videoSrc = proxyUrl;
        this.smbProxyActive = true;
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `SMB 源已通过代理 URL 转交 ${this.backend}（proxy started → rewritten to ${proxyUrl}）`);
      } else {
        // 代理启动失败，保留原始 smb:// URL（ijkplayer 会尝试直连，大概率失败）
        smbOriginalUrl = '';
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `SMB 代理启动失败，backend=${this.backend} 将使用原始 smb:// URL`);
      }
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
          mimeType: p.mimeType
        };
        tracks.push(item);
      }
      this.audioTracks = tracks;
      this.activeAudioIndex = 0;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[initPlayer] 预置音轨已提前填充: ${tracks.length} 条`);
    }

    // 根据 backend 创建对应适配器
    let adapter: IPlayer;
    if (this.backend === 'ijkplayer') {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        'initPlayer: 使用 IjkPlayerAdapter，等待 UI 层调用 setIjkContext()');
      const ijkAdapter = new IjkPlayerAdapter();
      const ijkSubAdapter = new IjkSubtitleBridgeAdapter();
      this.subtitleAdapter = ijkSubAdapter;
      // 注册内嵌字幕回调：onTimedText → subtitleAdapter → currentSubtitleText
      ijkAdapter.setOnEmbeddedSubtitleCallback((text: string) => {
        if (currentSessionId !== this.playbackSessionId || this.subtitleAdapter !== ijkSubAdapter) {
          return;
        }
        ijkSubAdapter.onEmbeddedTimedText(text);
        this.applySubtitleBridgeState(ijkSubAdapter.getState());
      });
      adapter = ijkAdapter;
    } else {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        'initPlayer: 使用 AVPlayerAdapter');
      adapter = new AVPlayerAdapter();
      if (smbOriginalUrl.length > 0) {
        // SMB 源：AVPlayer 通过代理 URL 播放，内嵌字幕走 AVPlayer 原生 selectTrack，
        // 外置字幕走 SmbAvSubtitleBridgeAdapter.loadExternalTracks（SMB client 读取）
        this.subtitleAdapter = new SmbAvSubtitleBridgeAdapter(smbOriginalUrl);
      } else {
        this.subtitleAdapter = new AvSubtitleBridgeAdapter();
      }
    }

    // 注册所有 IPlayer 事件回调
    adapter.onReady(() => {
      if (currentSessionId !== this.playbackSessionId) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `[session=${currentSessionId}] 忽略过期 onReady`);
        return;
      }
      this.onPlayerReady();
    });
    adapter.onPlay(() => {
      if (currentSessionId !== this.playbackSessionId) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `[session=${currentSessionId}] 忽略过期 onPlay`);
        return;
      }
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
    });
    adapter.onPaused(() => {
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
      this.isPlaying = false;
      this.pauseSubtitleTimer();
      this.stopProgressTimer();
      this.saveProgressNow();
      if (this.backend === 'ffmpeg') {
        this.stopFfmpegRenderTimer();
      }
    });
    adapter.onCompleted(() => {
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
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
    adapter.onStopped(() => {
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
      this.isPlaying = false;
      this.stopProgressTimer();
      if (this.backend === 'ffmpeg') {
        this.stopFfmpegRenderTimer();
      }
    });
    adapter.onTimeUpdate((currentTime: number) => {
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
    adapter.onError((error: Error) => {
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `播放器错误: ${error.message}`);
      // 指标埋点：play_result=error
      const metricsElapsedOnError = Date.now() - this.metricsLoadStartMs;
      hilog.warn(CommonConstants.LOG_DOMAIN, METRICS_TAG,
        `{"event":"play_result","backend":"${this.backend}","video_id":${this.progressContext?.videoId ?? -1},"result":"error","error_code":"${error.message.substring(0, 80)}","elapsed_ms":${metricsElapsedOnError}}`);
      if (this.backend === 'native') {
        this.fallbackNativeToIjk('native_error_callback', 'native 错误回调触发，已自动回退到 IJK 播放', error.message);
        return;
      }
      this.isLoading = false;
      this.lastErrorMessage = this.normalizePlayerError(error.message);
    });
    adapter.onBuffering((isBuffering: boolean) => {
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
      this.isLoading = isBuffering;
      if (!isBuffering && this.lastErrorMessage.length > 0) {
        this.lastErrorMessage = '';
      }
    });
    adapter.onUnsupportedFormat(() => {
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
      const targetBackend: PlayerBackend = this.unsupportedFormatFallback;
      this.logFallbackEvent('avplayer_unsupported_format', 'avplayer', targetBackend);
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `AVPlayer 不支持当前格式，自动切换到 ${targetBackend}...`);
      this.isLoading = true;
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
    adapter.onSeekDone(() => {
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
      // 指标埋点：seek_result（非 native 后端在此记录；native 在 VidAllPlayerAdapter 内分别记录 done/timeout）
      if (this.backend !== 'native') {
        const seekElapsed = Date.now() - this.metricsSeekStartMs;
        hilog.info(CommonConstants.LOG_DOMAIN, METRICS_TAG,
          `{"event":"seek_result","backend":"${this.backend}","result":"done","elapsed_ms":${seekElapsed}}`);
      }
      if (this.timeToSeek >= 0) {
        adapter.seek(this.timeToSeek);
        this.timeToSeek = -1;
      } else {
        if (this.suppressPlayAfterSeekOnce) {
          this.suppressPlayAfterSeekOnce = false;
        } else {
          this.player?.play().catch(() => {});
        }
      }
      this.isSeeking = false;
    });
    adapter.onSubtitleUpdate((info) => {
      if (currentSessionId !== this.playbackSessionId) {
        return;
      }
      // 外部字幕激活时屏蔽内嵌回调
      if (this.subtitleAdapter.getState().hasExternalActive) {
        return;
      }
      this.subtitleAdapter.onSubtitleUpdate(info);
      this.applySubtitleBridgeState(this.subtitleAdapter.getState());
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

    this.player = adapter;

    if (this.backend === 'ijkplayer') {
      // IjkPlayer 需要先由 UI 层绑定 XComponent context，
      // VideoPlayer.ets 的 onLoad 回调会调用 setIjkContext() 来完成真正的 init
      // 注意：VPE AI 画质增强不适用于 ijkplayer 路径（ijkplayer 使用 XComponent native hook 渲染）
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        'IjkPlayerAdapter 已创建，等待 UI 层 setIjkContext() 绑定 XComponent...');
    } else {
      // avplayer 路径：若 AI 画质增强已开启，尝试在播放器与显示层之间插入 VPE
      const effectiveSurfaceId = this.tryCreateVpeEnhancer(surfaceId);
      try {
        await adapter.init(videoData, effectiveSurfaceId);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(CommonConstants.LOG_DOMAIN, TAG,
          `init 失败: code=${err.code} msg=${err.message}`);
      }
    }
  }

  // ─── VPE AI 画质增强 ──────────────────────────────────────────

  /**
   * 开启/切换 AI 画质增强。
   * - VPE 已运行：直接更新质量参数（不重建管线，不影响播放）
   * - VPE 未运行（首次启用）：下次 initPlayer 时才会创建（当前播放不影响）
   */
  setAiEnhance(quality: VpeQualityLevel = 'low'): void {
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
    VpeEnhancerUtil.setPassthrough();
  }

  /**
   * 尝试创建 VPE 增强实例，返回有效的 surfaceId。
   * - 增强成功：返回 VPE 输入 surfaceId（替代 XComponent surfaceId 传给播放器）
   * - 增强失败或不支持：返回原始 displaySurfaceId（透明降级）
   */
  private tryCreateVpeEnhancer(displaySurfaceId: string): string {
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[VPE] tryCreate: enabled=${this.aiEnhanceEnabled} backend=${this.backend} quality=${this.aiEnhanceQuality}`);
    if (!this.aiEnhanceEnabled || this.backend !== 'avplayer') {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[VPE] 跳过创建: enabled=${this.aiEnhanceEnabled} backend=${this.backend}`);
      return displaySurfaceId;
    }
    const vpeSurfaceId = VpeEnhancerUtil.createEnhancer(displaySurfaceId, this.aiEnhanceQuality);
    if (vpeSurfaceId.length > 0) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, `[VPE] 管线建立: vpeSurfaceId=${vpeSurfaceId}`);
      return vpeSurfaceId;
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
   * 供 VideoPlayer UI 层在 ijkplayer XComponent.onLoad 回调中调用。
   * 必须在 initPlayer() 之后调用，绑定 XComponent context 后触发真正的 init。
   *
   * 时序说明：
   * 1. UI 层先注册 emitter.once(PREPARED)
   * 2. UI 层调 initPlayer()（创建 IjkPlayerAdapter 但不调 native_setup）
  * 3. UI 层调 setIjkContext()（setContext → native_setup → setDataSource → prepareAsync）
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
    const ijkAdapter = this.player as IjkPlayerAdapter;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `setIjkContext: 绑定 XComponent id=${xComponentId}，开始完整 init 流程...`);
    // 把 context 传给 adapter，由 adapter 的 init() 内部在 native_setup 前调用 setContext
    ijkAdapter.setPendingContext(context, xComponentId);
    if (this.currentVideoData) {
      try {
        await ijkAdapter.init(this.currentVideoData, this.surfaceId);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(CommonConstants.LOG_DOMAIN, TAG,
          `setIjkContext init 失败: ${err.message}`);
      }
    }
  }

  /**
   * 供 VideoPlayer UI 层在 native so XComponent.onLoad 回调中调用。
   * 当前阶段仅完成原生播放器骨架绑定，真实解码/渲染链路后续接入。
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
    const nativeAdapter = this.player as VidAllPlayerAdapter;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `setNativeContext: 绑定 XComponent id=${xComponentId}，开始 native 骨架 init...`);
    this.startNativeReadyGuard(this.playbackSessionId);
    if (this.currentVideoData) {
      try {
        let safeContext: object = context;
        if (safeContext === null || safeContext === undefined) {
          const fallbackContext: NativeXComponentFallbackContext = {};
          safeContext = fallbackContext as object;
          hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
            `setNativeContext: onLoad context 为空，使用空对象兜底 id=${xComponentId}`);
        }
        await nativeAdapter.initWithContext(this.currentVideoData, this.surfaceId, safeContext, xComponentId);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(CommonConstants.LOG_DOMAIN, TAG,
          `setNativeContext init 失败: ${err.message}`);
        this.fallbackNativeToIjk('native_init_error', 'native 初始化失败，已自动回退到 IJK 播放', err.message);
      }
    }
  }

  setNativeSeekDiagLogEnabled(enabled: boolean): void {
    this.nativeSeekDiagLogEnabled = enabled;
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

  private async resolveAudioRoutingDecision(videoData: VideoData): Promise<AudioRoutingDecision> {
    const defaultDecision: AudioRoutingDecision = {
      preferredBackend: 'avplayer',
      fallback: 'ijkplayer',
      preferredChannels: 2,
      summary: 'default: 未探测到音轨细节',
      detectedCodec: 'unknown',
      detectedChannels: 2,
      hardSupported: true,
      precheckProbeFailed: false,
      precheckProbeError: '',
      videoCodecName: ''
    };

    const presetHint = this.readPresetAudioHint(videoData);
    let codecName = presetHint.codecName;
    let channels = presetHint.channels;
    let precheckProbeFailed = false;
    let precheckProbeError = '';
    let videoCodecName = '';

    try {
      // 优先用 ffprobe 读取真实流信息；失败时再退回 preset 提示。
      const probe = await FfprobeUtil.probe(videoData.videoSrc, videoData.httpHeader, 9000);
      if (probe.success && probe.audioTracks.length > 0) {
        const first = probe.audioTracks[0];
        codecName = first.codecName;
        channels = first.channels ?? channels;
      }
      // 同时捕获视频编码，供 IjkPlayerAdapter 决策硬解策略（HEVC 硬解+HDR/DV 会花屏）
      if (probe.success && probe.videoTracks.length > 0) {
        videoCodecName = (probe.videoTracks[0].codecName ?? '').toLowerCase();
      }
    } catch (e) {
      precheckProbeFailed = true;
      precheckProbeError = this.safeErrorMessage(e);
      // 探测失败时使用预置音轨提示继续决策。
    }

    const normalizedCodec = (codecName ?? '').toLowerCase();
    const safeChannels = this.normalizeTargetChannels(channels);
    const hardSupported = this.isLikelySystemHardDecodeSupported(normalizedCodec);

    const summary = `codec=${normalizedCodec.length > 0 ? normalizedCodec : 'unknown'}, ` +
      `channels=${safeChannels}, hardSupported=${hardSupported}, precheckProbeFailed=${precheckProbeFailed}`;

    // 策略：始终优先 avplayer，让系统自行尝试播放（含 TrueHD/DTS/AC3 等非标音频）。
    // avplayer 报 onUnsupportedFormat 时会自动 fallback 到 ijkplayer（见 unsupportedFormatFallback='ijkplayer'）。
    // 仅在探测完全失败且没有任何音轨提示时，保守走 ijkplayer 避免 avplayer 进入不可恢复错误态。
    let preferredBackend: PlayerBackend = 'avplayer';
    if (precheckProbeFailed && normalizedCodec.length === 0) {
      preferredBackend = 'ijkplayer';
    }

    const decision: AudioRoutingDecision = {
      preferredBackend,
      fallback: 'ijkplayer',
      preferredChannels: safeChannels,
      summary,
      detectedCodec: normalizedCodec.length > 0 ? normalizedCodec : 'unknown',
      detectedChannels: safeChannels,
      hardSupported,
      precheckProbeFailed,
      precheckProbeError,
      videoCodecName
    };
    return decision;
  }

  private logAudioCapabilityReport(decision: AudioRoutingDecision): void {
    // 结构化日志：后续可直接平移到 UI 能力面板，减少二次拼装成本。
    const channelTag = this.getChannelTag(decision.detectedChannels);
    const currentDecodePlan = decision.preferredBackend === 'avplayer'
      ? `system-harddecode-${channelTag}`
      : `${decision.preferredBackend}-fallback-${channelTag}`;

    const message =
      '[AudioCapability] ' +
      `detectedCodec=${decision.detectedCodec}, detectedChannels=${decision.detectedChannels}(${channelTag}), ` +
      `hardSupported=${decision.hardSupported}, route=${decision.preferredBackend}, fallback=${decision.fallback}, ` +
      `decodePlan=${currentDecodePlan}; ` +
      `systemHardPreferred=[${SYSTEM_HARD_PREFERRED_CODECS.join(', ')}]; ` +
      `systemSoftFallback=[${SYSTEM_SOFT_FALLBACK_CODECS.join(', ')}]; ` +
      `channelHints=[${SUPPORTED_CHANNEL_LAYOUT_HINTS.join(', ')}]`;

    this.audioCapabilityText =
      `音频能力: 检测=${decision.detectedCodec} ${channelTag} | ` +
      `硬解=${decision.hardSupported ? '是' : '否'} | ` +
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

  private readPresetAudioHint(videoData: VideoData): PresetAudioHint {
    const tracks = videoData.presetAudioTracks;
    if (!tracks || tracks.length === 0) {
      const emptyHint: PresetAudioHint = { codecName: '', channels: 2 };
      return emptyHint;
    }
    const first = tracks[0];
    const mime = (first.mimeType ?? '').toLowerCase();
    const display = first.displayName.toLowerCase();

    let channels = 2;
    if (display.includes('7.1')) {
      channels = 8;
    } else if (display.includes('5.1')) {
      channels = 6;
    } else if (display.includes('mono')) {
      channels = 1;
    }

    const codecName = mime.length > 0 ? mime : display;
    const hint: PresetAudioHint = { codecName, channels };
    return hint;
  }

  private normalizeTargetChannels(channels?: number): number {
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

  private isLikelySystemHardDecodeSupported(codec: string): boolean {
    if (codec.length === 0) {
      return true;
    }

    // 经验规则：命中下列关键字时优先软解，避免先硬解再失败切换带来的卡顿。
    const softOnlyKeywords: string[] = [
      'ac3', 'eac3', 'dts', 'truehd', 'mlp', 'vivid', 'atmos'
    ];
    for (let i = 0; i < softOnlyKeywords.length; i++) {
      if (codec.includes(softOnlyKeywords[i])) {
        return false;
      }
    }

    return true;
  }

  /** prepared 后回调：读取 duration、加载字幕轨道和音轨 */
  private async onPlayerReady(): Promise<void> {
    this.clearNativeReadyGuardTimer();
    const playerDuration = this.player?.duration ?? 0;
    this.duration = playerDuration > 0
      ? playerDuration
      : (this.currentVideoData?.durationHintMs ?? 0);
    this.currentTime = this.player?.currentTime ?? 0;
    this.isReady = true;
    this.isLoading = false;
    // 指标埋点：首帧到达 + play_result=success
    const firstFrameElapsed = Date.now() - this.metricsLoadStartMs;
    hilog.info(CommonConstants.LOG_DOMAIN, METRICS_TAG,
      `{"event":"first_frame","backend":"${this.backend}","video_id":${this.progressContext?.videoId ?? -1},"elapsed_ms":${firstFrameElapsed}}`);
    hilog.info(CommonConstants.LOG_DOMAIN, METRICS_TAG,
      `{"event":"play_result","backend":"${this.backend}","video_id":${this.progressContext?.videoId ?? -1},"result":"success","elapsed_ms":${firstFrameElapsed}}`);
    const resumeTimeMs = this.pendingBackendResumeTimeMs;
    const shouldResumePlay = this.pendingBackendResumePlay;
    if (resumeTimeMs >= 0) {
      this.pendingBackendResumeTimeMs = -1;
      this.pendingBackendResumePlay = false;
    }
    emitter.emit(PlayerEvents.PREPARED);
    await this.loadSubtitleTracks();
    await this.loadAudioTracks();
    if (resumeTimeMs > 0 && this.player) {
      const safeResumeTimeMs = this.duration > 0 && resumeTimeMs > this.duration
        ? this.duration
        : resumeTimeMs;
      this.currentTime = safeResumeTimeMs;
      this.progress = this.duration > 0 ? safeResumeTimeMs / this.duration : 0;
      this.subtitleAdapter.onSeekSync();
      this.applySubtitleBridgeState(this.subtitleAdapter.getState());
      this.isSeeking = true;
      this.suppressPlayAfterSeekOnce = !shouldResumePlay;
      this.player.seek(safeResumeTimeMs);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `后端切换续播定位: backend=${this.backend} time=${safeResumeTimeMs}`);
      return;
    }
    if (shouldResumePlay && !this.isPlaying) {
      await this.play();
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
    const shouldResumePlay = this.isPlaying;
    this.logFallbackEvent(fallbackReason, 'native', 'ijkplayer', detailMessage);
    hilog.warn(CommonConstants.LOG_DOMAIN, TAG, userMessage);
    this.lastErrorMessage = userMessage;
    this.isLoading = true;
    this.clearNativeReadyGuardTimer();
    this.pendingBackendResumeTimeMs = safeFallbackPosition;
    this.pendingBackendResumePlay = shouldResumePlay;
    this.currentTime = safeFallbackPosition;
    this.progress = this.duration > 0 ? safeFallbackPosition / this.duration : 0;
    const oldPlayer = this.player;
    this.player = undefined;
    this.backend = 'ijkplayer';
    oldPlayer?.release().catch(() => {});
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

  private extractFileName(filePath: string): string {
    if (filePath.length === 0) {
      return '';
    }
    const clean = filePath.replace(/\?.*$/, '');
    const lastSlash = clean.lastIndexOf('/');
    return lastSlash >= 0 ? clean.substring(lastSlash + 1) : clean;
  }

  private sanitizeLogFilePath(filePath: string): string {
    if (filePath.length === 0) {
      return '';
    }
    let sanitized = filePath;
    sanitized = sanitized.replace(/\?.*$/, '');
    sanitized = sanitized.replace(/\/\/([^\/@]+)@/, '//***@');
    sanitized = sanitized.replace(/(authorization=)[^&]*/ig, '$1***');
    sanitized = sanitized.replace(/(token=)[^&]*/ig, '$1***');
    return sanitized;
  }

  private safeErrorMessage(e: Object): string {
    const err = e as BusinessError;
    if (typeof err.message === 'string' && err.message.length > 0) {
      return err.message;
    }
    return JSON.stringify(err);
  }

  async play(): Promise<void> {
    await this.player?.play().catch((err: BusinessError) => {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `play 失败: code=${err.code} msg=${err.message}`);
      this.lastErrorMessage = this.normalizePlayerError(err.message);
    });
    this.duration = this.player?.duration ?? this.duration;
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
    await this.player?.pause().catch((err: BusinessError) => {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `pause 失败: code=${err.code} msg=${err.message}`);
    });
  }

  async toggle(): Promise<void> {
    await this.player?.toggle();
  }

  async release(): Promise<void> {
    this.clearNativeReadyGuardTimer();
    this.stopProgressTimer();
    this.saveProgressNow();
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
    // 清理 SMB 代理孤立线程（keepProxy=true 释放后遗留）
    if (this.smbProxyActive) {
      VidAllPlayerAdapter.cleanupOrphanedProxies();
      this.smbProxyActive = false;
    }
    // 释放 VPE 实例（播放器已销毁后再销毁 VPE，避免 Surface 竞争）
    VpeEnhancerUtil.destroyEnhancer();
  }

  async seek(time: number): Promise<void> {
    if (!this.player) { return; }
    this.metricsSeekStartMs = Date.now();
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
    await this.pause();
    this.currentTime = safeTime;
    this.subtitleAdapter.onSeekSync();
    this.applySubtitleBridgeState(this.subtitleAdapter.getState());
    if (!this.isSeeking) {
      this.isSeeking = true;
      try {
        this.player.seek(safeTime);
      } catch (seekErr) {
        // seek 调用失败（如 native 地底抛异常）：重置 isSeeking 防止永久卡住。
        // onError 回调已在 callNativeVoid 里触发，此处仅做状态修复。
        this.isSeeking = false;
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

  private async loadSubtitleTracks(): Promise<void> {
    if (!this.player) {
      return;
    }
    try {
      await this.subtitleAdapter.init(this.player, this.currentVideoData);
      this.applySubtitleBridgeState(this.subtitleAdapter.getState());
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `[loadSubtitleTracks] 字幕适配器初始化失败，回退无字幕模式: code=${err.code} msg=${err.message}`);
      this.subtitleAdapter.release();
      this.subtitleAdapter = new NoSubtitleBridgeAdapter();
      this.applySubtitleBridgeState(this.subtitleAdapter.getState());
    }
  }

  /** 加载音轨列表 */
  private async loadAudioTracks(): Promise<void> {
    if (!this.player) { return; }

    try {
      // ── 已在 initPlayer 提前填充（presetAudioTracks 路径）──
      // initPlayer 时若有 presetAudioTracks 已立即写入 this.audioTracks，
      // onPlayerReady 时只需触发首轨选择，不需要重新构建列表
      if (this.audioTracks.length > 0) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[loadAudioTracks] 已提前填充 ${this.audioTracks.length} 条音轨，直接选择默认轨道`);
        if (this.backend === 'ffmpeg') {
          this.activeAudioIndex = 0;
        } else {
          await this.switchAudioTrack(0);
        }
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
          await this.switchAudioTrack(0);
        }
      }
    } catch (e) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `加载音轨失败: ${JSON.stringify(e)}`);
    }
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
   * 通过 allSubtitleTracks 索引切换字幕
   * allIndex = -1 表示关闭字幕
   */
  async switchSubtitleTrack(allIndex: number): Promise<void> {
    if (this.subtitleClearTimer !== undefined) {
      clearTimeout(this.subtitleClearTimer);
      this.subtitleClearTimer = undefined;
    }
    this.subtitleRemainingTime = 0;
    await this.subtitleAdapter.switchTrack(allIndex);
    this.applySubtitleBridgeState(this.subtitleAdapter.getState());
  }

  // ─────────────────────────────────────────────
  // 音轨切换（供 UI 调用）
  // ─────────────────────────────────────────────

  /**
   * 通过 audioTracks 索引切换音轨
   */
  async switchAudioTrack(trackIndex: number): Promise<void> {
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
        `[switchAudioTrack] 音轨已切换: ${audioTrack.displayName} (trackIndex=${audioTrack.trackIndex})`);

      // 3. seek 到当前位置，强制音频解码器 flush 并从正确位置开始解码
      //    这样恢复播放时新音轨与视频帧完全对齐
      if (wasPlaying && seekBack > 0) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[switchAudioTrack] seek flush 到 ${seekBack}ms`);
        // 借用 seek() 的暂停-seek-恢复流程：isSeeking=true，seekDone 后自动 play()
        this.isSeeking = true;
        this.player.seek(seekBack);
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
   * 调整字幕延迟偏移量。
   *
   * @param deltaMs 增量（单位 ms）。
   *   正值 → 字幕偏慢（画面已出但字幕还没出），增大 subtitleDelayMs，使字幕显示时刻后移
   *   负值 → 字幕偏快（字幕出早了），减小 subtitleDelayMs，使字幕显示时刻前移
   *
   * 原理：SRT 查找时使用 `currentTime - subtitleDelayMs`。
   *   - subtitleDelayMs > 0 → 在视频时间 T，查找 T - D 处的字幕，相当于字幕到 T + D 才出现（延迟）。
   *   - subtitleDelayMs < 0 → 查找 T + |D| 处的字幕，相当于字幕在 T - |D| 时出现（提前）。
   *
   * 效果可感知时间 <= 下一帧 onTimeUpdate 间隔（≈ 250ms）。
   */
  adjustSubtitleDelay(deltaMs: number): void {
    this.subtitleAdapter.adjustDelay(deltaMs);
    this.applySubtitleBridgeState(this.subtitleAdapter.getState());
  }

}

