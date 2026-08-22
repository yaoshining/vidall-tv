// filepath: entry/src/main/ets/services/playback/PlaybackBackendTypes.ets
//
// PlaybackBackendService 的类型契约。
//
// `VideoPlayerController` 通过本契约编排 AVPlayer 主路径与 MPV 唯一回退路径。
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
export type ServicePlayerBackend = 'avplayer' | 'mpv';

/** AVPlayer 遇到不支持格式或初始化失败时的唯一回退目标。 */
export type ServiceUnsupportedFormatFallback = 'mpv';

/** 历史入口值仅在边界归一化，绝不进入运行时后端状态。 */
export type LegacyPlayerBackend = 'native' | 'ffmpeg';

export function normalizePlayerBackend(backend: ServicePlayerBackend | LegacyPlayerBackend): ServicePlayerBackend {
  return backend === 'avplayer' ? 'avplayer' : 'mpv';
}

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
  /** 设备能力兼容性（codec 支持且声道数不超上限）。 */
  compatible: boolean;
  /** 设备该 codec 的最大声道能力（未知/不支持时为 0）。 */
  maxChannels: number;
  /** 是否为硬件解码。 */
  isHardware: boolean;
  /** 兼容性结论来源。 */
  capabilitySource: string;
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
  /** 视频 HDR 类型（'HDR10'|'HLG'|'DOLBY_VISION'|'SDR'|''），'' 表示未知/SDR。 */
  videoHdrType: string;
  /** 视频宽度（像素，来自 ffprobe 首条 video track），探测失败/缺失为 undefined。 */
  videoWidth?: number;
  /** 视频高度（像素，来自 ffprobe 首条 video track），探测失败/缺失为 undefined。 */
  videoHeight?: number;
  /** 整组音轨分析详情（调试用）。 */
  trackAnalyses: BackendTrackAnalysis[];
  /** 预选的初始音轨索引（-1 表示无兼容轨）。 */
  recommendedInitialTrackIndex: number;
  /** 预选音轨的归一化 codec（无兼容轨或未知时为空串）。 */
  recommendedCodec: string;
  /** 能力判定摘要（来源/缓存/纠偏，供日志与 UI）。 */
  capabilitySummary: string;
}

/** 默认后端决策（探测未启动时使用）。 */
export const DEFAULT_BACKEND_DECISION: PlaybackBackendDecision = {
  preferredBackend: 'avplayer',
  fallback: 'mpv',
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
  videoHdrType: '',
  videoWidth: undefined,
  videoHeight: undefined,
  trackAnalyses: [],
  recommendedInitialTrackIndex: -1,
  recommendedCodec: '',
  capabilitySummary: 'default: 未查询设备解码能力'
};

/** 字幕桥接 adapter 类型（service 内部命名以避免与 controller 现有类型冲突）。 */
export type SubtitleBridgeKind = 'none' | 'av' | 'mpv' | 'smb-av';

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
  | 'avplayer_init_failure'
  | 'precheck_probe_failed'
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
    fallback: 'mpv',
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
    videoHdrType: '',
    videoWidth: undefined,
    videoHeight: undefined,
    trackAnalyses: [],
    recommendedInitialTrackIndex: -1,
    recommendedCodec: '',
    capabilitySummary: 'default: 未查询设备解码能力'
  };
  return decision;
}
