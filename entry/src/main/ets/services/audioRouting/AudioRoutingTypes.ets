// filepath: entry/src/main/ets/services/audioRouting/AudioRoutingTypes.ets
//
// AudioTrackRoutingService 的类型契约。
//
// 背景：原 `VideoPlayerController.resolveAudioRoutingDecision()` 负责：
//   1. ffprobe 探测（首次启动时）
//   2. preset 提示降级（probe 失败时）
//   3. 决策 backend route / fallback / preferredChannels
//   4. 初始音轨恢复建议（用户绑定命中时直接返回该 index）
//
// Module 4 目标：把这些统一为 `AudioTrackRoutingService.resolveRoutingDecision()` 与
// `resolveInitialTrackIndex()`，controller 仅消费结果并应用。
//
// 与 `findInitialAudioTrackIndex` 的差异：
// - 旧实现 controller 同时持有「路由决策」与「codec-aware 选轨」两类职责；
// - 新实现 routing service 负责纯计算，controller 仅负责「应用」与「持久化」。
//
// 兼容性：
// - `AudioTrackItem` 由本文件 re-export，controller 旧 import 路径继续可用。

import type { AudioTrackItem } from "../../components/core/player/VideoPlayerController";

export type { AudioTrackItem };

/** 单条音轨分析结果（service 内部使用，可被 controller 日志引用）。 */
export interface AudioTrackAnalysis {
  /** 在原始轨道列表中的索引（service 不持有列表，仅记录位置）。 */
  index: number;
  /** 归一化后的 codec（如 'aac' / 'eac3' / 'ac3' / 'truehd' / ''）。 */
  codec: string;
  /** 归一化后的声道计划（1/2/6/8）。 */
  channels: number;
  /** 是否系统稳态可硬解。 */
  hardSupported: boolean;
  /** 来源：probe（ffprobe） / preset（数据库预置）。 */
  source: 'probe' | 'preset';
}

/** 路由决策输入（controller 持有 videoData 与 ffprobe 状态）。 */
export interface AudioRoutingInput {
  /** 预置音轨（来自数据库已读取，可选）。 */
  presetCodecName: string;
  presetChannels: number;
  presetHasAudio: boolean;
  /** ffprobe 探测结果（来自外部已发起，可选）。 */
  probeCodecName: string;
  probeChannels: number;
  probeVideoCodecName: string;
  /** ffprobe 首条视频轨的 HDR 类型（'HDR10'|'HLG'|'DOLBY_VISION'|'SDR'），探测失败传 ''。 */
  probeVideoHdrType: string;
  probeSuccess: boolean;
  probeError: string;
  /** 探测是否失败（service 内部用于决策）。 */
  precheckProbeFailed: boolean;
  /** 探测失败错误信息。 */
  precheckProbeError: string;
  /**
   * 整组音轨分析结果（probe + preset 合并去重后的有序列表）。
   * 注意：本字段优先级高于 probeCodecName / presetCodecName，
   * controller 应优先传入整组分析；旧字段仅作单轨快速路径。
   */
  trackAnalyses: AudioTrackAnalysis[];
}

/** 路由决策输出。 */
export interface AudioRoutingDecision {
  /** 推荐 backend。 */
  preferredBackend: 'avplayer' | 'mpv';
  /** AVPlayer 报 unsupported format 时固定回退到 MPV。 */
  fallback: 'mpv';
  /** ffmpeg 软解声道计划。 */
  preferredChannels: number;
  /** 诊断摘要。 */
  summary: string;
  /** 整组音轨中第一条稳态可硬解轨道的 codec（用于日志）。 */
  detectedCodec: string;
  /** 整组音轨中第一条稳态可硬解轨道的声道。 */
  detectedChannels: number;
  /** 整组音轨中是否存在至少一条稳态可硬解轨道。 */
  anyHardSupported: boolean;
  /** 整组音轨中是否所有轨道都应软解。 */
  allSoftDecodeOnly: boolean;
  /** 整组音轨中是否存在至少一条系统可播放的轨道。 */
  anyPlayable: boolean;
  /** 整组音轨中是否存在至少一条不可播放的轨道（用于日志）。 */
  anyUnplayable: boolean;
  /** 探测是否失败。 */
  precheckProbeFailed: boolean;
  precheckProbeError: string;
  /** 视频编码名称（来自 ffprobe 首条 video track）。 */
  videoCodecName: string;
  /** 视频 HDR 类型（来自 ffprobe 首条 video track）：'HDR10'|'HLG'|'DOLBY_VISION'|'SDR'，'' 表示未知（探测失败/无视频轨）。 */
  videoHdrType: string;
  /** 整组音轨分析结果。 */
  trackAnalyses: AudioTrackAnalysis[];
}

/** 默认路由决策（探测未启动时使用）。 */
export const DEFAULT_AUDIO_ROUTING_DECISION: AudioRoutingDecision = {
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
  trackAnalyses: []
};

/** 初始音轨选择输入。 */
export interface InitialTrackIndexInput {
  audioTracks: AudioTrackItem[];
  /** 用户历史绑定（来自 AppPreferences）；null 表示无绑定。 */
  userBindingDisplayName: string | null;
}

/** 初始音轨选择输出。 */
export interface InitialTrackIndexResult {
  trackIndex: number;
  /** 决策来源（用于诊断日志）。 */
  source: 'user-binding' | 'preferred-playable' | 'same-lang-fallback' | 'any-playable' | 'all-unplayable';
  /** 用户绑定命中后是否需要清除（绑定存在但 displayName 不在列表中）。 */
  shouldClearUserBinding: boolean;
}
