// filepath: entry/src/main/ets/services/audioRouting/AudioTrackRoutingService.ets
//
// AudioTrackRoutingService - 音频 codec 探测 + 设备解码能力路由 + 初始音轨恢复策略。
//
// 目标：把 `VideoPlayerController` 中以下职责迁移到本 service：
//   1. ffprobe 探测（probe 失败时降级到 preset 提示）
//   2. backend route / fallback / preferredChannels 决策（基于设备真实解码能力）
//   3. codec-aware 初始音轨选择（findInitialAudioTrackIndex + 能力排名）
//   4. 用户历史绑定恢复建议（与 AudioDispatcher 协作）
//
// 约束：
// - 不直接调用具体 adapter（routing service 只负责建议与决策）。
// - 不依赖 `VideoPlayerController` 任何状态（pure service）。
// - 不修改 `AudioDispatcher` / `FfprobeUtil` / `IPlayer` 的现有签名。
//
// 设计要点：
// - `resolveRoutingDecision(input)` 接收 probe 输入，返回 backend/fallback 决策。
// - `resolveInitialTrackIndex(input)` 接收轨道列表 + 用户绑定，返回建议 index。
// - 决策 pure function：service 内部计算，controller 消费结果并应用。
//
// 兼容性：
// - controller 内的 `resolveAudioRoutingDecision` / `findInitialAudioTrackIndex` 旧
//   方法保留为 thin wrapper 调用本 service，确保外部 import 兼容。
// - `AudioTrackItem` 类型由 `AudioRoutingTypes.ets` re-export，调用方无感。

import { hilog } from '@kit.PerformanceAnalysisKit';
import { CommonConstants } from "../../common/constants/CommonConstants";
import { FfprobeUtil } from "../../utils/FfprobeUtil";
import { VideoData } from "../../components/core/player/VideoData";
import { PresetAudioTrack } from "../../components/core/player/VideoData";
import {
  AudioRoutingDecision,
  AudioRoutingInput,
  InitialTrackIndexResult,
  AudioTrackItem,
  AudioTrackAnalysis
} from "./AudioRoutingTypes";
import {
  normalizeAudioCodec,
  codecCompatibilityRank,
  normalizeTargetChannels,
  normalizeChannelsForSort,
  isLikelySystemHardDecodeSupported
} from "./AudioCodecUtil";
import { AudioDispatcher, AudioBinding } from "../../audio/AudioDispatcher";
import { audioDecoderCapabilityService } from "../audioCapability/AudioDecoderCapabilityService";
import type { AudioTrackCompatibility } from "../audioCapability/AudioCapabilityTypes";

// 兼容历史 import 路径：外部仍可从 AudioTrackRoutingService 导入 normalizeAudioCodec。
export { normalizeAudioCodec };

const DOMAIN = 0x0002;
const TAG = '[AudioTrackRoutingService]';

/** Preset audio hint 容器（用于 readPresetAudioHint 显式类型）。 */
export interface PresetAudioHint {
  codecName: string;
  channels: number;
}

/**
 * 构造路由决策：基于整组音轨分析 + 设备解码能力兼容性。
 *
 * 决策优先级（Issue #243）：
 * 1. 设备/固件纠偏结果（已由 capability service 在 trackAnalysis.capabilitySource 体现）
 * 2. 系统 codec 能力 + 最大声道范围（trackAnalysis.compatible）
 * 3. 能力未知或查询异常 → 保守选择 MPV
 *
 * - 存在兼容音轨 → preferredBackend=avplayer，并预选兼容性最高（硬解优先/声道高/索引小）的音轨
 * - 无兼容音轨 → preferredBackend=mpv（直接，避免 AVPlayer prepare 后再初始化后端）
 * - 探测完全失败且无任何音轨提示 → 仍先尝试 AVPlayer（沿用历史行为）
 */
export function buildRoutingDecision(input: AudioRoutingInput): AudioRoutingDecision {
  const tracks = input.trackAnalyses;
  const trackCount = tracks.length;

  let anyCompatible = false;
  let anyUnknown = false;
  let anyCorrection = false;
  let anyHardware = false;
  let bestCompatIndex = -1;

  for (let i = 0; i < trackCount; i++) {
    const t = tracks[i];
    if (t.compatible) {
      anyCompatible = true;
      if (t.isHardware) {
        anyHardware = true;
      }
      if (bestCompatIndex < 0) {
        bestCompatIndex = i;
      } else if (compareCompatibleAnalysis(t, tracks[bestCompatIndex]) < 0) {
        bestCompatIndex = i;
      }
    }
    if (t.capabilitySource === 'unknown') {
      anyUnknown = true;
    }
    if (t.capabilitySource === 'correction') {
      anyCorrection = true;
    }
  }

  const recommendedInitialTrackIndex = bestCompatIndex >= 0 ? tracks[bestCompatIndex].index : -1;
  const recommendedCodec = bestCompatIndex >= 0 ? tracks[bestCompatIndex].codec : '';
  const detectedCodec = bestCompatIndex >= 0 ? tracks[bestCompatIndex].codec : 'unknown';
  const detectedChannels = bestCompatIndex >= 0 ? tracks[bestCompatIndex].channels : 2;

  // backend 决策
  let preferredBackend: 'avplayer' | 'mpv' = 'avplayer';
  if (trackCount > 0 && !anyCompatible) {
    // 无任何兼容音轨（已知不支持或能力未知）→ 直接 MPV
    preferredBackend = 'mpv';
  }

  const allSoftDecodeOnly = trackCount > 0 && !anyHardware;
  const anyPlayable = anyCompatible || trackCount === 0;
  const anyUnplayable = trackCount > 0 && !anyCompatible;

  const summary = `tracks=${trackCount}, ` +
    `anyCompatible=${anyCompatible}, anyUnknown=${anyUnknown}, anyCorrection=${anyCorrection}, ` +
    `recommendedIndex=${recommendedInitialTrackIndex}, recommendedCodec=${recommendedCodec}, ` +
    `precheckProbeFailed=${input.precheckProbeFailed}`;

  const capabilitySummary = buildCapabilitySummary(tracks);

  const decision: AudioRoutingDecision = {
    preferredBackend,
    fallback: 'mpv',
    preferredChannels: normalizeTargetChannels(detectedChannels),
    summary,
    detectedCodec,
    detectedChannels,
    anyHardSupported: anyHardware,
    allSoftDecodeOnly,
    anyPlayable,
    anyUnplayable,
    precheckProbeFailed: input.precheckProbeFailed,
    precheckProbeError: input.precheckProbeError,
    videoCodecName: (input.probeVideoCodecName ?? '').toLowerCase(),
    videoHdrType: input.probeVideoHdrType ?? '',
    videoWidth: input.probeVideoWidth,
    videoHeight: input.probeVideoHeight,
    trackAnalyses: tracks,
    recommendedInitialTrackIndex,
    recommendedCodec,
    capabilitySummary
  };
  return decision;
}

/** 兼容音轨排序：硬解优先 → 声道更高 → 索引更小（负值表示 a 更优）。 */
function compareCompatibleAnalysis(a: AudioTrackAnalysis, b: AudioTrackAnalysis): number {
  if (a.isHardware !== b.isHardware) {
    return a.isHardware ? -1 : 1;
  }
  if (a.channels !== b.channels) {
    return b.channels - a.channels;
  }
  return a.index - b.index;
}

/** 汇总能力判定来源，供日志/UI 展示。 */
function buildCapabilitySummary(tracks: AudioTrackAnalysis[]): string {
  if (tracks.length === 0) {
    return '无音轨信息';
  }
  const parts: string[] = [];
  for (let i = 0; i < tracks.length; i++) {
    const t = tracks[i];
    parts.push(`${t.codec || '?'}:${t.capabilitySource}${t.compatible ? '(兼容)' : '(不兼容)'}`);
  }
  return parts.join(', ');
}

/** 从 preset 列表中读取最匹配的首条 hint（多声道 > 高码率 > 原始顺序）。 */
export function readPresetAudioHint(videoData: VideoData): PresetAudioHint {
  const tracks = videoData.presetAudioTracks;
  if (!tracks || tracks.length === 0) {
    const empty: PresetAudioHint = { codecName: '', channels: 2 };
    return empty;
  }

  const sorted = tracks.slice().sort((a: PresetAudioTrack, b: PresetAudioTrack) => {
    const chA = normalizeChannelsForSort(inferTrackChannels(a));
    const chB = normalizeChannelsForSort(inferTrackChannels(b));
    if (chB !== chA) {
      return chB - chA;
    }
    const brA = a.bitrate ?? 0;
    const brB = b.bitrate ?? 0;
    return brB - brA;
  });

  const best = sorted[0];
  const mime = (best.mimeType ?? '').toLowerCase();
  const channels = inferTrackChannels(best);
  const codecName = mime.length > 0 ? mime : best.displayName.toLowerCase();
  const hint: PresetAudioHint = { codecName, channels };
  return hint;
}

/** 推断音轨的实际声道数。 */
function inferTrackChannels(track: PresetAudioTrack): number {
  if (track.channels !== undefined && track.channels > 0) {
    return track.channels;
  }
  const display = track.displayName.toLowerCase();
  if (display.includes('7.1')) {
    return 8;
  }
  if (display.includes('5.1')) {
    return 6;
  }
  if (display.includes('mono')) {
    return 1;
  }
  return 2;
}

/** 提取音轨的归一化 codec 字符串（用于日志与排序）。 */
function getNormalizedCodec(track: AudioTrackItem): string {
  const raw = (track.codecName ?? track.mimeType) ?? '';
  return normalizeAudioCodec(raw);
}

/** 提取音轨的归一化声道（未知返回 0）。 */
function getNormalizedChannels(track: AudioTrackItem): number {
  if (track.channels !== undefined && track.channels > 0) {
    return normalizeTargetChannels(track.channels);
  }
  return 0;
}

/**
 * codec-aware 初始音轨选择（codec 排名回退；设备能力信息缺失时使用）。
 *
 * 与历史实现等价：偏好轨（audioTracks[0]）rank=1 直接选中；否则按 rank 降级
 * （同语言 → 任意可播放）。设备能力信息可用时请使用 rankAudioTracksByCapability。
 */
export function findInitialAudioTrackIndex(audioTracks: AudioTrackItem[]): number {
  if (audioTracks.length === 0) {
    return 0;
  }
  const preferred = audioTracks[0];
  const preferredCodec = getNormalizedCodec(preferred);
  const preferredRank = codecCompatibilityRank(preferredCodec);

  if (preferredRank === 1) {
    return 0;
  }

  if (preferredRank <= 2) {
    // AC-3/EAC-3 软解常见：若有硬解轨（rank=1）则优先硬解轨
    for (let i = 1; i < audioTracks.length; i++) {
      const tRank = codecCompatibilityRank(getNormalizedCodec(audioTracks[i]));
      if (tRank === 1) {
        return i;
      }
    }
    return 0;
  }

  const preferredLang = preferred.language ?? '';

  // 步骤 1：同语言 + 任意可播放轨中 rank 最低者
  let bestSameLangIdx = -1;
  let bestSameLangRank = Number.MAX_SAFE_INTEGER;
  for (let i = 1; i < audioTracks.length; i++) {
    const t = audioTracks[i];
    const tRank = codecCompatibilityRank(getNormalizedCodec(t));
    if (tRank > 4) {
      continue;
    }
    if (preferredLang.length > 0 && t.language === preferredLang && tRank < bestSameLangRank) {
      bestSameLangIdx = i;
      bestSameLangRank = tRank;
    }
  }
  if (bestSameLangIdx >= 0) {
    return bestSameLangIdx;
  }

  // 步骤 2：任意可播放轨中 rank 最低者（跨语言）
  let bestAnyIdx = -1;
  let bestAnyRank = Number.MAX_SAFE_INTEGER;
  for (let i = 1; i < audioTracks.length; i++) {
    const t = audioTracks[i];
    const tRank = codecCompatibilityRank(getNormalizedCodec(t));
    if (tRank > 4) {
      continue;
    }
    if (tRank < bestAnyRank) {
      bestAnyIdx = i;
      bestAnyRank = tRank;
    }
  }
  if (bestAnyIdx >= 0) {
    return bestAnyIdx;
  }

  return 0;
}

/**
 * 基于设备能力的初始音轨选择：兼容音轨中硬解优先 → 语言偏好 → 声道高 → 索引小。
 * `compatibilities` 与 `audioTracks` 等长；无能力信息（compatible 默认 true）时仍可排序。
 */
export function rankAudioTracksByCapability(
  audioTracks: AudioTrackItem[],
  compatibilities: AudioTrackCompatibility[]
): number {
  if (audioTracks.length === 0) {
    return 0;
  }
  const preferredLang = audioTracks[0].language ?? '';
  let bestIdx = -1;
  for (let i = 0; i < audioTracks.length; i++) {
    const comp = i < compatibilities.length ? compatibilities[i] : undefined;
    const compatible = comp === undefined ? true : comp.compatible;
    if (!compatible) {
      continue;
    }
    if (bestIdx < 0) {
      bestIdx = i;
      continue;
    }
    if (compareCompatibleItem(audioTracks[i], audioTracks[bestIdx],
      i < compatibilities.length ? compatibilities[i] : undefined,
      bestIdx < compatibilities.length ? compatibilities[bestIdx] : undefined,
      preferredLang) < 0) {
      bestIdx = i;
    }
  }
  return bestIdx >= 0 ? bestIdx : 0;
}

/** 兼容音轨比较：硬解 → 语言匹配 → 声道 → 索引（负值表示 a 更优）。 */
function compareCompatibleItem(
  a: AudioTrackItem,
  b: AudioTrackItem,
  compA: AudioTrackCompatibility | undefined,
  compB: AudioTrackCompatibility | undefined,
  preferredLang: string
): number {
  const aHw = compA !== undefined && compA.isHardware;
  const bHw = compB !== undefined && compB.isHardware;
  if (aHw !== bHw) {
    return aHw ? -1 : 1;
  }
  const aLang = a.language ?? '';
  const bLang = b.language ?? '';
  const aMatch = preferredLang.length > 0 && aLang === preferredLang;
  const bMatch = preferredLang.length > 0 && bLang === preferredLang;
  if (aMatch !== bMatch) {
    return aMatch ? -1 : 1;
  }
  const aCh = compA !== undefined && compA.channels > 0 ? compA.channels : 0;
  const bCh = compB !== undefined && compB.channels > 0 ? compB.channels : 0;
  if (aCh !== bCh) {
    return bCh - aCh;
  }
  return a.trackIndex - b.trackIndex;
}

/**
 * controller façade 调用入口：薄包装 `findInitialAudioTrackIndex` 让 controller 仍可走
 * service import 路径。完整推荐调用方式：
 *   `await this.audioRoutingService.resolveInitialTrackIndex(videoPath, audioTracks)`
 * 该方法会先查用户绑定，再按设备能力做默认选轨。
 */
export function serviceFindInitialAudioTrackIndex(audioTracks: AudioTrackItem[]): number {
  return findInitialAudioTrackIndex(audioTracks);
}

/** AudioTrackRoutingService façade。 */
export class AudioTrackRoutingService {
  private readonly audioDispatcher: AudioDispatcher = new AudioDispatcher();

  /**
   * 计算 backend route 决策。
   *
   * 流程：
   * - ffprobe / preset 收集整组音轨（probe 优先，preset 兜底）
   * - 按归一化 codec 去重
   * - 逐唯一 codec 查询设备解码能力（含声道上限），填充每条音轨兼容性
   * - 交给 buildRoutingDecision 做后端与预选决策
   */
  async resolveRoutingDecision(videoData: VideoData): Promise<AudioRoutingDecision> {
    await audioDecoderCapabilityService.ensureLoaded();
    const presetHint = readPresetAudioHint(videoData);
    let probeCodec = '';
    let probeChannels = presetHint.channels;
    let precheckProbeFailed = false;
    let precheckProbeError = '';
    let videoCodecName = '';
    let probeVideoHdrType = '';
    let probeVideoWidth: number | undefined = undefined;
    let probeVideoHeight: number | undefined = undefined;
    let probeSuccess = false;
    interface ProbeAudio {
      codec: string;
      channels: number;
    }
    interface ProbeVideo {
      codec: string;
    }
    const probeAudioTracks: ProbeAudio[] = [];
    const probeVideoTracks: ProbeVideo[] = [];

    try {
      const probe = videoData.videoSrc.toLowerCase().startsWith('smb://')
        ? await FfprobeUtil.probeSmb(videoData.videoSrc, videoData.httpHeader, 9000)
        : await FfprobeUtil.probe(videoData.videoSrc, videoData.httpHeader, 9000);
      probeSuccess = probe.success;
      if (!probe.success) {
        precheckProbeFailed = true;
        precheckProbeError = probe.errorMessage ?? '媒体探测失败';
      }
      if (probe.success && probe.audioTracks.length > 0) {
        const first = probe.audioTracks[0];
        probeCodec = first.codecName;
        probeChannels = first.channels ?? probeChannels;
        for (let i = 0; i < probe.audioTracks.length; i++) {
          const t = probe.audioTracks[i];
          const entry: ProbeAudio = {
            codec: t.codecName,
            channels: t.channels ?? 2
          };
          probeAudioTracks.push(entry);
        }
      }
      if (probe.success && probe.videoTracks.length > 0) {
        videoCodecName = (probe.videoTracks[0].codecName ?? '').toLowerCase();
        probeVideoHdrType = probe.videoTracks[0].hdrType ?? '';
        probeVideoWidth = probe.videoTracks[0].width;
        probeVideoHeight = probe.videoTracks[0].height;
        for (let i = 0; i < probe.videoTracks.length; i++) {
          const v: ProbeVideo = { codec: (probe.videoTracks[i].codecName ?? '').toLowerCase() };
          probeVideoTracks.push(v);
        }
      }
    } catch (e) {
      precheckProbeFailed = true;
      const err = e as Record<string, string>;
      precheckProbeError = err['message'] ?? JSON.stringify(e);
    }

    // 合并 probe + preset 为整组音轨分析（probe 优先，preset 作为补充）。
    // 注意：不再按归一化 codec 去重——相同 codec 不同声道的音轨必须全部保留，
    // 否则声道超上限的轨会遮蔽同 codec 的兼容轨（如 8ch eac3 不兼容、2ch eac3 兼容时误选 MPV）。
    // 能力查询的按 codec 去重由 AudioDecoderCapabilityService.codecCapCache 内部保证。
    const trackAnalyses: AudioTrackAnalysis[] = [];
    for (let i = 0; i < probeAudioTracks.length; i++) {
      const t = probeAudioTracks[i];
      const codec = normalizeAudioCodec(t.codec);
      trackAnalyses.push(this.buildTrackAnalysis(i, codec, t.channels, 'probe'));
    }
    if (trackAnalyses.length === 0 && presetHint.codecName.length > 0) {
      const codec = normalizeAudioCodec(presetHint.codecName);
      trackAnalyses.push(this.buildTrackAnalysis(0, codec, presetHint.channels, 'preset'));
    }

    const input: AudioRoutingInput = {
      presetCodecName: presetHint.codecName,
      presetChannels: presetHint.channels,
      presetHasAudio: (videoData.presetAudioTracks?.length ?? 0) > 0,
      probeCodecName: probeCodec,
      probeChannels,
      probeVideoCodecName: videoCodecName,
      probeVideoHdrType,
      probeVideoWidth,
      probeVideoHeight,
      probeSuccess,
      probeError: precheckProbeError,
      precheckProbeFailed,
      precheckProbeError,
      trackAnalyses
    };
    return buildRoutingDecision(input);
  }

  /** 构造单条音轨分析（含设备能力查询结果）。 */
  private buildTrackAnalysis(
    index: number,
    codec: string,
    channels: number,
    source: 'probe' | 'preset'
  ): AudioTrackAnalysis {
    const normChannels = normalizeTargetChannels(channels);
    const compatibility = audioDecoderCapabilityService.resolveTrackCompatibility(codec, normChannels);
    const analysis: AudioTrackAnalysis = {
      index,
      codec,
      channels: normChannels,
      hardSupported: isLikelySystemHardDecodeSupported(codec),
      source,
      compatible: compatibility.compatible,
      maxChannels: compatibility.maxChannels,
      isHardware: compatibility.isHardware,
      capabilitySource: compatibility.source
    };
    return analysis;
  }

  /**
   * 计算初始音轨选择。
   * - 用户绑定命中且 displayName 匹配 → 命中
   * - 用户绑定命中但 displayName 不在列表中 → 清除绑定 + 默认选轨
   * - 无用户绑定 → 基于设备能力的 codec-aware 默认选轨
   */
  async resolveInitialTrackIndex(
    videoPath: string,
    audioTracks: AudioTrackItem[]
  ): Promise<InitialTrackIndexResult> {
    if (audioTracks.length === 0) {
      return { trackIndex: 0, source: 'all-unplayable', shouldClearUserBinding: false };
    }

    await audioDecoderCapabilityService.ensureLoaded();

    // 步骤 1：用户绑定命中
    let userBinding: AudioBinding | null = null;
    try {
      userBinding = await this.audioDispatcher.getAudioBinding(videoPath);
    } catch (e) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, `读取用户绑定失败: ${String(e)}`);
    }

    if (userBinding !== null) {
      let foundIndex = -1;
      for (let i = 0; i < audioTracks.length; i++) {
        if (audioTracks[i].displayName === userBinding.displayName) {
          foundIndex = i;
          break;
        }
      }
      if (foundIndex >= 0) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `命中用户绑定: index=${foundIndex} displayName=${userBinding.displayName}`);
        return { trackIndex: foundIndex, source: 'user-binding', shouldClearUserBinding: false };
      }
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `绑定 displayName 不在轨道列表中，自动清除: ${userBinding.displayName}`);
      try {
        await this.audioDispatcher.clearAudioBinding(videoPath);
      } catch (e) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG, `清除失效绑定失败: ${String(e)}`);
      }
      return {
        trackIndex: rankAudioTracksByCapability(audioTracks, this.resolveCompatibilities(audioTracks)),
        source: 'preferred-playable',
        shouldClearUserBinding: true
      };
    }

    // 步骤 2：基于设备能力的默认选轨
    return {
      trackIndex: rankAudioTracksByCapability(audioTracks, this.resolveCompatibilities(audioTracks)),
      source: 'preferred-playable',
      shouldClearUserBinding: false
    };
  }

  /** 为每条音轨计算设备能力兼容性（声道未知传 0，跳过上限校验）。 */
  private resolveCompatibilities(audioTracks: AudioTrackItem[]): AudioTrackCompatibility[] {
    const result: AudioTrackCompatibility[] = [];
    for (let i = 0; i < audioTracks.length; i++) {
      const track = audioTracks[i];
      const codec = getNormalizedCodec(track);
      const channels = getNormalizedChannels(track);
      result.push(audioDecoderCapabilityService.resolveTrackCompatibility(codec, channels));
    }
    return result;
  }
}

/** 默认无依赖实例（pure service）。 */
export const audioTrackRoutingService: AudioTrackRoutingService = new AudioTrackRoutingService();
