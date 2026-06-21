// filepath: entry/src/main/ets/services/audioRouting/AudioTrackRoutingService.ets
//
// AudioTrackRoutingService - 音频 codec 探测 + 初始音轨恢复策略。
//
// 目标：把 `VideoPlayerController` 中以下职责迁移到本 service：
//   1. ffprobe 探测（probe 失败时降级到 preset 提示）
//   2. backend route / fallback / preferredChannels 决策
//   3. codec-aware 初始音轨选择（findInitialAudioTrackIndex）
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
  DEFAULT_AUDIO_ROUTING_DECISION,
  InitialTrackIndexInput,
  InitialTrackIndexResult,
  AudioTrackItem
} from "./AudioRoutingTypes";
import { AudioDispatcher, AudioBinding } from "../../audio/AudioDispatcher";

const DOMAIN = 0x0002;
const TAG = '[AudioTrackRoutingService]';

/** 经验规则：命中下列关键字时优先软解，避免先硬解再失败切换带来的卡顿。 */
const SOFT_ONLY_KEYWORDS: string[] = [
  'ac3', 'eac3', 'dts', 'truehd', 'mlp', 'vivid', 'atmos'
];

/**
 * 构造路由决策。
 * 输入来自 controller 持有的 preset/probe 结果；service 不发起 ffprobe。
 */
export function buildRoutingDecision(input: AudioRoutingInput): AudioRoutingDecision {
  const probeCodec = (input.probeCodecName ?? '').toLowerCase();
  const presetCodec = (input.presetCodecName ?? '').toLowerCase();
  const effectiveCodec = probeCodec.length > 0 ? probeCodec : presetCodec;
  const effectiveChannels = input.probeChannels > 0 ? input.probeChannels : input.presetChannels;
  const safeChannels = normalizeTargetChannels(effectiveChannels);
  const hardSupported = isLikelySystemHardDecodeSupported(effectiveCodec);

  const summary = `codec=${effectiveCodec.length > 0 ? effectiveCodec : 'unknown'}, ` +
    `channels=${safeChannels}, hardSupported=${hardSupported}, precheckProbeFailed=${input.precheckProbeFailed}`;

  // 策略：始终优先 avplayer，让系统自行尝试播放（含 TrueHD/DTS/AC3 等非标音频）。
  // avplayer 报 onUnsupportedFormat 时会自动 fallback 到 ijkplayer。
  // 仅在探测完全失败且没有任何音轨提示时，保守走 ijkplayer 避免 avplayer 进入不可恢复错误态。
  let preferredBackend: 'avplayer' | 'ijkplayer' | 'ffmpeg' | 'native' = 'avplayer';
  if (input.precheckProbeFailed && effectiveCodec.length === 0 && !input.presetHasAudio) {
    preferredBackend = 'ijkplayer';
  }

  const decision: AudioRoutingDecision = {
    preferredBackend,
    fallback: 'ijkplayer',
    preferredChannels: safeChannels,
    summary,
    detectedCodec: effectiveCodec.length > 0 ? effectiveCodec : 'unknown',
    detectedChannels: safeChannels,
    hardSupported,
    precheckProbeFailed: input.precheckProbeFailed,
    precheckProbeError: input.precheckProbeError,
    videoCodecName: (input.probeVideoCodecName ?? '').toLowerCase()
  };
  return decision;
}

/** 将原始声道数归一化到实际解码计划所对应的层级。 */
function normalizeTargetChannels(channels?: number): number {
  if (!channels || channels <= 0) {
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

/** 判断指定 codec 是否优先走硬解。 */
function isLikelySystemHardDecodeSupported(codec: string): boolean {
  if (codec.length === 0) {
    return true;
  }
  for (let i = 0; i < SOFT_ONLY_KEYWORDS.length; i++) {
    if (codec.includes(SOFT_ONLY_KEYWORDS[i])) {
      return false;
    }
  }
  return true;
}

/** Preset audio hint 容器（用于 readPresetAudioHint 显式类型）。 */
export interface PresetAudioHint {
  codecName: string;
  channels: number;
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

/** 排序前对声道数做归一化处理。 */
function normalizeChannelsForSort(ch: number): number {
  if (ch <= 1) {
    return 1;
  }
  if (ch <= 2) {
    return 2;
  }
  if (ch <= 6) {
    return 6;
  }
  return 8;
}

/** 判断音轨是否可播放（与原 `isAudioTrackPlayable` 等价）。 */
function isAudioTrackPlayable(track: AudioTrackItem): boolean {
  const raw = ((track.codecName ?? track.mimeType) ?? '').toLowerCase();
  const codec = raw.replace('audio/', '').split('-').join('');
  return isLikelySystemHardDecodeSupported(codec);
}

/** codec-aware 初始音轨选择（与原 `findInitialAudioTrackIndex` 等价）。 */
export function findInitialAudioTrackIndex(audioTracks: AudioTrackItem[]): number {
  if (audioTracks.length === 0) {
    return 0;
  }
  const preferred = audioTracks[0];
  const preferredCodec = ((preferred.codecName ?? preferred.mimeType) ?? '');

  if (isAudioTrackPlayable(preferred)) {
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[findInitialAudioTrackIndex] 偏好轨可播放，直接选中: index=0 lang=${preferred.language ?? 'unknown'} codec=${preferredCodec || 'unknown'}`);
    return 0;
  }

  hilog.info(CommonConstants.LOG_DOMAIN, TAG,
    `[findInitialAudioTrackIndex] 偏好轨不可播放: index=0 lang=${preferred.language ?? 'unknown'} codec=${preferredCodec || 'unknown'}，尝试降级`);

  const preferredLang = preferred.language ?? '';
  if (preferredLang.length > 0) {
    for (let i = 1; i < audioTracks.length; i++) {
      const t = audioTracks[i];
      if (t.language === preferredLang && isAudioTrackPlayable(t)) {
        const tCodec = ((t.codecName ?? t.mimeType) ?? '');
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[findInitialAudioTrackIndex] 同语言降级: index=${i} lang=${preferredLang} codec=${tCodec || 'unknown'}`);
        return i;
      }
    }
  }

  for (let i = 1; i < audioTracks.length; i++) {
    const t = audioTracks[i];
    if (isAudioTrackPlayable(t)) {
      const tCodec = ((t.codecName ?? t.mimeType) ?? '');
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[findInitialAudioTrackIndex] 任意可播放降级: index=${i} lang=${t.language ?? 'unknown'} codec=${tCodec || 'unknown'}`);
      return i;
    }
  }

  hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
    `[findInitialAudioTrackIndex] 全部音轨不可播放（共 ${audioTracks.length} 条），返回 0 沿用现有降级策略`);
  return 0;
}

/** AudioTrackRoutingService façade。 */
export class AudioTrackRoutingService {
  private readonly audioDispatcher: AudioDispatcher = new AudioDispatcher();

  /**
   * 计算 backend route 决策。
   *
   * 行为与原 `VideoPlayerController.resolveAudioRoutingDecision` 字节级一致：
   * - 优先用 probe 结果；失败时降级 preset。
   * - 始终优先 avplayer；仅探测完全失败且无音轨提示时走 ijkplayer。
   */
  async resolveRoutingDecision(videoData: VideoData): Promise<AudioRoutingDecision> {
    const presetHint = readPresetAudioHint(videoData);
    let probeCodec = '';
    let probeChannels = presetHint.channels;
    let precheckProbeFailed = false;
    let precheckProbeError = '';
    let videoCodecName = '';
    let probeSuccess = false;

    try {
      const probe = await FfprobeUtil.probe(videoData.videoSrc, videoData.httpHeader, 9000);
      probeSuccess = probe.success;
      if (probe.success && probe.audioTracks.length > 0) {
        const first = probe.audioTracks[0];
        probeCodec = first.codecName;
        probeChannels = first.channels ?? probeChannels;
      }
      if (probe.success && probe.videoTracks.length > 0) {
        videoCodecName = (probe.videoTracks[0].codecName ?? '').toLowerCase();
      }
    } catch (e) {
      precheckProbeFailed = true;
      const err = e as Record<string, string>;
      precheckProbeError = err['message'] ?? JSON.stringify(e);
    }

    const input: AudioRoutingInput = {
      presetCodecName: presetHint.codecName,
      presetChannels: presetHint.channels,
      presetHasAudio: (videoData.presetAudioTracks?.length ?? 0) > 0,
      probeCodecName: probeCodec,
      probeChannels,
      probeVideoCodecName: videoCodecName,
      probeSuccess,
      probeError: precheckProbeError,
      precheckProbeFailed,
      precheckProbeError
    };
    return buildRoutingDecision(input);
  }

  /**
   * 计算初始音轨选择。
   * - 用户绑定命中且 displayName 匹配 → 命中
   * - 用户绑定命中但 displayName 不在列表中 → 清除绑定 + 默认选轨
   * - 无用户绑定 → codec-aware 默认选轨
   */
  async resolveInitialTrackIndex(
    videoPath: string,
    audioTracks: AudioTrackItem[]
  ): Promise<InitialTrackIndexResult> {
    if (audioTracks.length === 0) {
      return { trackIndex: 0, source: 'all-unplayable', shouldClearUserBinding: false };
    }

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
      // displayName 不在列表中：清除绑定并回退默认选轨
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `绑定 displayName 不在轨道列表中，自动清除: ${userBinding.displayName}`);
      try {
        await this.audioDispatcher.clearAudioBinding(videoPath);
      } catch (e) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG, `清除失效绑定失败: ${String(e)}`);
      }
      return { trackIndex: findInitialAudioTrackIndex(audioTracks), source: 'preferred-playable', shouldClearUserBinding: true };
    }

    // 步骤 2：默认选轨（codec-aware）
    return { trackIndex: findInitialAudioTrackIndex(audioTracks), source: 'preferred-playable', shouldClearUserBinding: false };
  }
}

/** 默认无依赖实例（pure service）。 */
export const audioTrackRoutingService: AudioTrackRoutingService = new AudioTrackRoutingService();
