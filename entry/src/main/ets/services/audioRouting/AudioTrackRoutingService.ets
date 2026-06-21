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
  AudioTrackItem,
  AudioTrackAnalysis
} from "./AudioRoutingTypes";
import { AudioDispatcher, AudioBinding } from "../../audio/AudioDispatcher";

const DOMAIN = 0x0002;
const TAG = '[AudioTrackRoutingService]';

/** 经验规则：命中下列关键字时优先软解，避免先硬解再失败切换带来的卡顿。 */
const SOFT_ONLY_KEYWORDS: string[] = [
  'ac3', 'eac3', 'dts', 'truehd', 'mlp', 'vivid', 'atmos'
];

/**
 * 构造路由决策：基于整组音轨分析，而非单条首轨。
 *
 * 策略：
 * - 整组音轨中存在至少一条系统稳态可硬解轨道 → preferredBackend=avplayer
 *   （让 avplayer 自行尝试，并在 onPlay 后由 `loadAudioTracks` 通过 `resolveInitialTrackIndex`
 *   选中最优可硬解轨道）
 * - 整组音轨全部应软解（如全 TrueHD/DTS/AC3）→ preferredBackend=avplayer，fallback=ijkplayer
 *   （保留现有 fallback 路径，让 avplayer 失败后自动切 ijkplayer 软解）
 * - 探测完全失败且无任何音轨提示 → preferredBackend=ijkplayer（保守）
 * - preferredChannels 取首条可播放轨道的归一化声道
 */
export function buildRoutingDecision(input: AudioRoutingInput): AudioRoutingDecision {
  const tracks = input.trackAnalyses;
  const trackCount = tracks.length;

  // 整组分析
  let anyHardSupported = false;
  let anyPlayable = true;
  let allSoftDecodeOnly = true;
  let firstHardSupported: AudioTrackAnalysis | null = null;
  let firstPlayable: AudioTrackAnalysis | null = null;
  let unplayableCount = 0;
  for (let i = 0; i < trackCount; i++) {
    const t = tracks[i];
    if (t.hardSupported) {
      anyHardSupported = true;
      allSoftDecodeOnly = false;
      if (firstHardSupported === null) {
        firstHardSupported = t;
      }
    }
    if (firstPlayable === null && t.codec.length > 0) {
      firstPlayable = t;
    }
    if (!t.hardSupported && t.codec.length > 0) {
      // 已知 codec 但应软解
    } else if (t.codec.length === 0) {
      unplayableCount++;
    }
  }
  if (unplayableCount === trackCount && trackCount > 0) {
    anyPlayable = false;
  }
  const anyUnplayable = unplayableCount > 0;

  // 选择用于日志的 "代表 codec/channels"
  const detectedCodec = firstHardSupported !== null
    ? firstHardSupported.codec
    : (firstPlayable !== null ? firstPlayable.codec : 'unknown');
  const detectedChannels = firstHardSupported !== null
    ? firstHardSupported.channels
    : (firstPlayable !== null ? firstPlayable.channels : 2);
  const preferredChannels = normalizeTargetChannels(detectedChannels);

  const summary = `tracks=${trackCount}, ` +
    `firstHardSupported=${firstHardSupported !== null ? firstHardSupported.codec : 'none'}, ` +
    `allSoftDecodeOnly=${allSoftDecodeOnly}, anyHardSupported=${anyHardSupported}, ` +
    `precheckProbeFailed=${input.precheckProbeFailed}`;

  // preferredBackend 决策：
  // 1. 探测完全失败且无任何音轨提示 → ijkplayer（保守）
  // 2. 整组音轨存在至少一条可硬解轨道 → avplayer（让 avplayer 尝试，初始选轨由 resolveInitialTrackIndex 决定）
  // 3. 整组音轨全部应软解 → avplayer（保持现有 fallback 路径）
  let preferredBackend: 'avplayer' | 'ijkplayer' | 'ffmpeg' | 'native' = 'avplayer';
  if (input.precheckProbeFailed && trackCount === 0 && !input.presetHasAudio) {
    preferredBackend = 'ijkplayer';
  }

  const decision: AudioRoutingDecision = {
    preferredBackend,
    fallback: 'ijkplayer',
    preferredChannels,
    summary,
    detectedCodec,
    detectedChannels,
    anyHardSupported,
    allSoftDecodeOnly,
    anyPlayable,
    anyUnplayable,
    precheckProbeFailed: input.precheckProbeFailed,
    precheckProbeError: input.precheckProbeError,
    videoCodecName: (input.probeVideoCodecName ?? '').toLowerCase(),
    trackAnalyses: tracks
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
   * 关键变化（与历史实现对照）：**遍历整组音轨**（probe + preset 合并去重），
   * 而非仅看 probe.audioTracks[0] 决定一切。
   *
   * 行为：
   * - 整组音轨存在至少一条系统稳态可硬解轨道 → preferredBackend=avplayer
   * - 整组音轨全部应软解（如全 TrueHD/DTS/AC3）→ preferredBackend=avplayer + fallback=ijkplayer
   * - 探测完全失败且无任何音轨提示 → preferredBackend=ijkplayer
   * - 初始选轨由 controller 调用 `resolveInitialTrackIndex` 决定（与 backend route 决策解耦）
   */
  async resolveRoutingDecision(videoData: VideoData): Promise<AudioRoutingDecision> {
    const presetHint = readPresetAudioHint(videoData);
    let probeCodec = '';
    let probeChannels = presetHint.channels;
    let precheckProbeFailed = false;
    let precheckProbeError = '';
    let videoCodecName = '';
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
      const probe = await FfprobeUtil.probe(videoData.videoSrc, videoData.httpHeader, 9000);
      probeSuccess = probe.success;
      if (probe.success && probe.audioTracks.length > 0) {
        const first = probe.audioTracks[0];
        probeCodec = first.codecName;
        probeChannels = first.channels ?? probeChannels;
        // ── 关键：收集整组 audio tracks ──
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

    // 合并 probe + preset 为整组音轨分析（probe 优先，preset 作为补充）
    const trackAnalyses: AudioTrackAnalysis[] = [];
    const seenCodecs = new Set<string>();
    for (let i = 0; i < probeAudioTracks.length; i++) {
      const t = probeAudioTracks[i];
      const codec = t.codec.toLowerCase();
      if (seenCodecs.has(codec)) {
        continue;
      }
      seenCodecs.add(codec);
      const analysis: AudioTrackAnalysis = {
        index: i,
        codec,
        channels: t.channels,
        hardSupported: isLikelySystemHardDecodeSupported(codec),
        source: 'probe'
      };
      trackAnalyses.push(analysis);
    }
    // preset hint 补充：仅在 probe 为空时使用
    if (trackAnalyses.length === 0 && presetHint.codecName.length > 0) {
      const codec = presetHint.codecName.toLowerCase();
      trackAnalyses.push({
        index: 0,
        codec,
        channels: presetHint.channels,
        hardSupported: isLikelySystemHardDecodeSupported(codec),
        source: 'preset'
      });
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
      precheckProbeError,
      trackAnalyses
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
