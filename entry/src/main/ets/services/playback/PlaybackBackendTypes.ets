// filepath: entry/src/main/ets/services/playback/PlaybackBackendTypes.ets
//
// PlaybackBackendService 的类型契约。
//
// 背景：原 `VideoPlayerController.initPlayer()` 负责：
//   1. 自动音频路由决策（resolveAudioRoutingDecision）
//   2. 适配器工厂（IjkPlayerAdapter / AVPlayerAdapter / VidAllPlayerAdapter）
//   3. SMB 代理生命周期（startSmbProxy / cleanupOrphanedProxies）
//   4. XComponent 上下文绑定时序（setIjkContext / setNativeContext）
//   5. unsupported format / native → IJK fallback 编排
//
// Module 4 目标：以上职责由 `PlaybackBackendService` 统一编排，
// `VideoPlayerController` 退化为 façade 并把状态投影到现有 `@Trace` 字段。
//
// 兼容性：
// - 公开方法与 controller 现有 API 行为等价，外部 import 不破坏。
// - `PlayerBackend` / `UnsupportedFormatFallback` 类型由本文件 re-export，
//   controller 旧 import 路径继续可用。

import type { VideoData } from "../../components/core/player/VideoData";
import type { IPlayer } from "../../components/core/player/IPlayer";
import type { ISubtitleBridgeAdapter } from "../../components/core/player/SubtitleBridgeAdapter";

/** 播放内核类型（service 内部命名，controller 已有同名类型，alias 复用）。 */
export type ServicePlayerBackend = 'avplayer' | 'ijkplayer' | 'mpv' | 'ffmpeg' | 'native';

/** AVPlayer 遇到不支持格式时的回退目标（service 内部命名）。 */
export type ServiceUnsupportedFormatFallback = 'ijkplayer' | 'mpv' | 'native';

/** 后端选择决策输入（ffprobe + preset 提示）。 */
export interface PlaybackBackendProbeInput {
  codecName: string;
  channels: number;
  precheckProbeFailed: boolean;
  precheckProbeError: string;
  videoCodecName: string;
  /** 原始 ffprobe 是否成功（用于日志上下文）。 */
  probeSuccess: boolean;
}

/**
 * 后端选择决策输出（已与 `AudioRoutingDecision` 字段对齐）。
 * 字段语义升级为基于整组音轨分析（anyHardSupported / allSoftDecodeOnly）。
 */
/** 整组音轨分析条目（用于 backend decision / routing decision 共享类型）。 */
export interface BackendTrackAnalysis {
  index: number;
  codec: string;
  channels: number;
  hardSupported: boolean;
  /** 'probe' | 'preset' */
  source: string;
}

export interface PlaybackBackendDecision {
  preferredBackend: ServicePlayerBackend;
  fallback: ServiceUnsupportedFormatFallback;
  preferredChannels: number;
  summary: string;
  detectedCodec: string;
  detectedChannels: number;
  /** 整组音轨中是否存在至少一条系统稳态可硬解轨道。 */
  anyHardSupported: boolean;
  /** 整组音轨是否全部应软解。 */
  allSoftDecodeOnly: boolean;
  /** 整组音轨是否存在至少一条系统可播放轨道。 */
  anyPlayable: boolean;
  /** 整组音轨是否存在至少一条不可播放轨道。 */
  anyUnplayable: boolean;
  precheckProbeFailed: boolean;
  precheckProbeError: string;
  videoCodecName: string;
  /** 整组音轨分析详情（调试用）。 */
  trackAnalyses: BackendTrackAnalysis[];
}

/** 默认后端决策（探测未启动时使用）。 */
export const DEFAULT_BACKEND_DECISION: PlaybackBackendDecision = {
  preferredBackend: 'avplayer',
  fallback: 'ijkplayer',
  preferredChannels: 2,
  summary: 'default: 未探测到音轨细节',
  detectedCodec: 'unknown',
  detectedChannels: 2,
  anyHardSupported: true,
  allSoftDecodeOnly: false,
  anyPlayable: true,
  anyUnplayable: false,
  precheckProbeFailed: false,
  precheckProbeError: '',
  videoCodecName: '',
  trackAnalyses: []
};

/** 字幕桥接 adapter 类型（service 内部命名以避免与 controller 现有类型冲突）。 */
export type SubtitleBridgeKind = 'none' | 'av' | 'ijk' | 'mpv' | 'smb-av';

/** Adapter 创建产物。 */
export interface PlaybackAdapterHandle {
  /** 选定后端。 */
  backend: ServicePlayerBackend;
  /** 适配器实例（未绑定 XComponent 上下文前可能为 undefined）。 */
  player?: IPlayer;
  /** 字幕桥接 adapter（service 内部创建并注入回调，controller 持有此引用以调用 switch/delay）。 */
  subtitleBridge?: ISubtitleBridgeAdapter;
  /** 字幕桥接类型标签（冗余字段，便于 controller 调试与 fallback 决策）。 */
  subtitleBridgeKind: SubtitleBridgeKind;
  /** 启动 SMB 代理后写回 videoData.videoSrc（用于 controller 持有原始 URL 记录）。 */
  effectiveVideoSrc: string;
  /** 若原始视频源是 smb://，记录原始 URL（用于 fallback 时重启代理）。 */
  smbOriginalSrc: string;
  /** 代理是否处于活动态（释放时触发 cleanupOrphanedProxies）。 */
  smbProxyActive: boolean;
  /** 错误回调：仅在 adapter 创建阶段失败时填充。 */
  errorMessage?: string;
}

/** Adapter 绑定上下文。 */
export interface PlaybackAdapterContext {
  surfaceId: string;
  videoData: VideoData;
}

/** 后端 fallback 触发原因。 */
export type PlaybackFallbackReason =
  | 'avplayer_unsupported_format'
  | 'native_error_callback'
  | 'native_ready_timeout'
  | 'precheck_probe_failed'
  | 'manual_backend_switch'
  | 'mpv_error_callback';

/** 后端 fallback 上下文。 */
export interface PlaybackFallbackContext {
  reason: PlaybackFallbackReason;
  fallbackFrom: ServicePlayerBackend;
  fallbackTo: ServicePlayerBackend;
  positionMs: number;
  shouldResumePlay: boolean;
  autoplayDecisionSource: string;
  autoplayDecisionOrigin: string;
  detailMessage: string;
}

/** 续播自动播放决策纯函数输入。 */
export interface ResumeAutoplayInput {
  isPlaying: boolean;
  isSeeking: boolean;
}

/** 续播自动播放决策纯函数输出。 */
export interface ResumeAutoplayDecision {
  shouldResumePlay: boolean;
  source: string;
  origin: string;
}

/** 工厂函数：构造 `PlaybackBackendDecision`（用于 backend service 内部默认值）。 */
export function buildDefaultBackendDecision(): PlaybackBackendDecision {
  const decision: PlaybackBackendDecision = {
    preferredBackend: 'avplayer',
    fallback: 'ijkplayer',
    preferredChannels: 2,
    summary: 'default: 未探测到音轨细节',
    detectedCodec: 'unknown',
    detectedChannels: 2,
    anyHardSupported: true,
    allSoftDecodeOnly: false,
    anyPlayable: true,
    anyUnplayable: false,
    precheckProbeFailed: false,
    precheckProbeError: '',
    videoCodecName: '',
    trackAnalyses: []
  };
  return decision;
}
