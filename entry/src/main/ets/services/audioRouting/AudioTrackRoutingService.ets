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
 * codec 兼容性等级（数字越小越优先，作为初轨选择与 route decision 的排序依据）。
 *
 * 关键点：AC-3 / EAC-3 虽属软解，但 MPV 可作为系统播放失败后的兼容后端；
 * TrueHD / MLP / Audio Vivid 解码链不成熟，默认应排在 AC-3 之后。
 *
 * 1 = 系统稳态可硬解（HARD_PREFERRED）
 * 2 = 软解但常见（AC-3 / EAC-3 / DTS）— 优先选择
 * 3 = 软解且罕见（TrueHD / MLP / Audio Vivid）— 仅在别无选择时使用
 * 4 = 未知 codec
 */
function codecCompatibilityRank(codec: string): number {
  if (codec.length === 0) {
    return 4;
  }
  const c = codec.toLowerCase();
  // 硬解友好
  if (c.includes('aac') || c.includes('mp3') || c.includes('opus') ||
    c.includes('flac') || c.includes('pcm') || c.includes('vorbis')) {
    return 1;
  }
  // 软解常见：AC-3 / EAC-3 / DTS（注意 DTS 排后面，会被 AC-3 抢优先）
  if (c.includes('ac3') && !c.includes('eac3')) {
    return 2;
  }
  if (c.includes('eac3')) {
    return 2;
  }
  if (c.includes('dts')) {
    return 3;
  }
  // 软解罕见：TrueHD / MLP / Audio Vivid
  if (c.includes('truehd') || c.includes('mlp') || c.includes('vivid') || c.includes('atmos')) {
    return 3;
  }
  return 4;
}

/**
 * 构造路由决策：基于整组音轨分析 + codec compatibility rank。
 *
 * 关键策略（按用户场景 TrueHD + AC-3 混合片源）：
 * 1. 整组音轨存在至少一条 rank≤1（硬解）或 rank≤2（AC-3/EAC-3 软解常见）轨道 → preferredBackend=avplayer
 *    （avplayer 启动后由 `loadAudioTracks` + `findInitialAudioTrackIndex` 切到该轨道，避免无声）
 * 2. 整组音轨全部 rank≥3（仅 TrueHD / MLP / DTS / Audio Vivid 等软解罕见或 DTS）→ preferredBackend=avplayer
 *    + fallback=mpv（让 AVPlayer 失败后自动切 MPV 软解）
 * 3. 探测完全失败且无任何音轨提示 → 仍先尝试 AVPlayer，再按不支持格式回退
 * 4. detectedCodec / detectedChannels 取整组中 rank 最低的轨道（最兼容），不再是 probe[0]
 */
export function buildRoutingDecision(input: AudioRoutingInput): AudioRoutingDecision {
  const tracks = input.trackAnalyses;
  const trackCount = tracks.length;

  // 整组分析：累加硬解 / 软解统计 + 收集 rank 最低轨道
  let anyHardSupported = false;
  let anyPlayable = true;
  let allSoftDecodeOnly = true;
  let firstHardSupported: AudioTrackAnalysis | null = null;
  let unplayableCount = 0;
  let bestRankedTrack: AudioTrackAnalysis | null = null;
  let bestRankedIndex = -1;
  for (let i = 0; i < trackCount; i++) {
    const t = tracks[i];
    if (t.hardSupported) {
      anyHardSupported = true;
      allSoftDecodeOnly = false;
      if (firstHardSupported === null) {
        firstHardSupported = t;
      }
    }
    if (t.codec.length === 0) {
      unplayableCount++;
    } else {
      const rank = codecCompatibilityRank(t.codec);
      if (bestRankedTrack === null || rank < codecCompatibilityRank(bestRankedTrack.codec)) {
        bestRankedTrack = t;
        bestRankedIndex = i;
      }
    }
  }
  if (unplayableCount === trackCount && trackCount > 0) {
    anyPlayable = false;
  }
  const anyUnplayable = unplayableCount > 0;

  // 决定 detectedCodec / detectedChannels：取整组中 rank 最低的轨道（最兼容）
  const representative = bestRankedTrack !== null
    ? bestRankedTrack
    : (firstHardSupported !== null ? firstHardSupported : null);
  const detectedCodec = representative !== null ? representative.codec : 'unknown';
  const detectedChannels = representative !== null ? representative.channels : 2;
  const preferredChannels = normalizeTargetChannels(detectedChannels);

  const summary = `tracks=${trackCount}, ` +
    `firstHardSupported=${firstHardSupported !== null ? firstHardSupported.codec : 'none'}, ` +
    `allSoftDecodeOnly=${allSoftDecodeOnly}, anyHardSupported=${anyHardSupported}, ` +
    `bestRankedIndex=${bestRankedIndex}, bestRankedCodec=${detectedCodec}, ` +
    `precheckProbeFailed=${input.precheckProbeFailed}`;

  // preferredBackend 决策（关键修复：TrueHD+AC-3 混合时不能默认 TrueHD）
  // 1. 探测完全失败且无任何音轨提示 → 仍先尝试 avplayer
  // 2. 整组音轨存在至少一条 rank≤2 轨道（硬解 / AC-3 / EAC-3）→ avplayer
  //    （avplayer 启动后由 loadAudioTracks 切到该轨道）
  // 3. 整组音轨全部 rank≥3（仅 TrueHD / MLP / Audio Vivid / DTS）→ avplayer + fallback=mpv
  //    （让 AVPlayer 失败后自动切 MPV 软解）
  const preferredBackend: 'avplayer' | 'mpv' = 'avplayer';

  const decision: AudioRoutingDecision = {
    preferredBackend,
    fallback: 'mpv',
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
    videoHdrType: input.probeVideoHdrType ?? '',
    videoWidth: input.probeVideoWidth,
    videoHeight: input.probeVideoHeight,
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

/** 将 AVPlayer MIME 与 ffprobe codec 统一为路由使用的 codec 名。 */
export function normalizeAudioCodec(rawCodec: string): string {
  const codec = rawCodec.toLowerCase().replace('audio/', '').split('-').join('');
  if (codec === 'mp4alatm' || codec === 'mp4a' || codec === 'aaclatm') {
    return 'aac';
  }
  return codec;
}

/** 判断音轨是否"系统级可用"（与原 `isAudioTrackPlayable` 等价）。
 *  含义：AVPlayer 不进入 onUnsupportedFormat 路径；TrueHD / MLP / Audio Vivid 等"软解罕见"
 *  仍被视为"可用"，但兼容性更差，由 `codecCompatibilityRank` 进一步排序。
 */
function isAudioTrackPlayable(track: AudioTrackItem): boolean {
  const raw = (track.codecName ?? track.mimeType) ?? '';
  const codec = normalizeAudioCodec(raw);
  // 注意：不能把 TrueHD / AC-3 一律视为不可用，否则"全部不可用"会回退到 track 0。
  // 这里仅过滤"完全无法识别的未知 codec"，硬解 / 软解兼容性由 rank 决定。
  if (codec.length === 0) {
    return false;
  }
  // 若 codec 在 SOFT_ONLY_KEYWORDS 中，视为软解可用，AVPlayer 失败后由 MPV 接管
  if (SOFT_ONLY_KEYWORDS.indexOf(codec) >= 0) {
    return true;
  }
  // 硬解友好
  if (isLikelySystemHardDecodeSupported(codec)) {
    return true;
  }
  // 未知 codec：保守视为不可用
  return false;
}

/** 提取音轨的归一化 codec 字符串（用于日志与排序）。 */
function getNormalizedCodec(track: AudioTrackItem): string {
  const raw = (track.codecName ?? track.mimeType) ?? '';
  return normalizeAudioCodec(raw);
}

/**
 * codec-aware 初始音轨选择（与原 `findInitialAudioTrackIndex` 等价，但按 compatibility rank 排序）。
 *
 * 关键修复：
 * - 旧实现把所有"软解罕见"（TrueHD/MLP/Audio Vivid）和"软解常见"（AC-3/EAC-3/DTS）一同视为"软解"，
 *   然后"按可播放性"返回首条，导致 TrueHD 排在 AC-3 前面被选中。
 * - 新实现按 `codecCompatibilityRank` 排序：硬解 > AC-3/EAC-3 > DTS > TrueHD/MLP > unknown。
 *   偏好轨不可用时，按"同语言可播放轨中 rank 最低"选择。
 *
 * 注意：导出为 free function 仅供 `AudioTrackRoutingService` 内部 `resolveInitialTrackIndex` 调用；
 * 外部调用方请改用 `audioTrackRoutingService.resolveInitialTrackIndex(...)`，避免直接
 * 绕过 service 入口。controller 旧 import 路径 `findInitialAudioTrackIndex` 已被替换为
 * `serviceFindInitialAudioTrackIndex` 包装，仅为兼容历史 import 路径（见 W2 修复说明）。
 */
export function findInitialAudioTrackIndex(audioTracks: AudioTrackItem[]): number {
  if (audioTracks.length === 0) {
    return 0;
  }
  const preferred = audioTracks[0];
  const preferredCodec = getNormalizedCodec(preferred);
  const preferredRank = codecCompatibilityRank(preferredCodec);

  if (preferredRank === 1) {
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[findInitialAudioTrackIndex] 偏好轨硬解可播(rank=1)，直接选中: index=0 lang=${preferred.language ?? 'unknown'} codec=${preferredCodec || 'unknown'}`);
    return 0;
  }

  if (preferredRank <= 2) {
    // AC-3/EAC-3 在 AVPlayer 上下文中可通过软解播放，但若有硬解轨（rank=1）则优先用硬解轨
    for (let i = 1; i < audioTracks.length; i++) {
      const t = audioTracks[i];
      const tRank = codecCompatibilityRank(getNormalizedCodec(t));
      if (tRank === 1) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[findInitialAudioTrackIndex] 偏好轨为软解常见(rank=2)，发现硬解轨(index=${i})，优先选中`);
        return i;
      }
    }
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[findInitialAudioTrackIndex] 偏好轨软解常见(rank=2)，无硬解替代，选中: index=0 lang=${preferred.language ?? 'unknown'} codec=${preferredCodec || 'unknown'}`);
    return 0;
  }

  hilog.info(CommonConstants.LOG_DOMAIN, TAG,
    `[findInitialAudioTrackIndex] 偏好轨不优先(rank=${preferredRank}): index=0 lang=${preferred.language ?? 'unknown'} codec=${preferredCodec || 'unknown'}，按 rank 降级`);

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
    const t = audioTracks[bestSameLangIdx];
    const tCodec = getNormalizedCodec(t);
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[findInitialAudioTrackIndex] 同语言降级: index=${bestSameLangIdx} lang=${preferredLang} rank=${bestSameLangRank} codec=${tCodec || 'unknown'}`);
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
    const t = audioTracks[bestAnyIdx];
    const tCodec = getNormalizedCodec(t);
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[findInitialAudioTrackIndex] 任意可播放降级: index=${bestAnyIdx} rank=${bestAnyRank} lang=${t.language ?? 'unknown'} codec=${tCodec || 'unknown'}`);
    return bestAnyIdx;
  }

  hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
    `[findInitialAudioTrackIndex] 全部音轨 rank>4（不可解析），返回 0 沿用现有降级策略`);
  return 0;
}

/**
 * controller façade 调用入口：薄包装 `findInitialAudioTrackIndex` 让 controller 仍可走
 * service import 路径。完整推荐调用方式：
 *   `await this.audioRoutingService.resolveInitialTrackIndex(videoPath, audioTracks)`
 * 该方法会先查用户绑定，再调本函数做默认选轨。
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
   * 关键变化（与历史实现对照）：**遍历整组音轨**（probe + preset 合并去重），
   * 而非仅看 probe.audioTracks[0] 决定一切。
   *
   * 行为：
   * - 整组音轨存在至少一条系统稳态可硬解轨道 → preferredBackend=avplayer
   * - 整组音轨全部应软解（如全 TrueHD/DTS/AC3）→ preferredBackend=avplayer + fallback=mpv
   * - 探测完全失败且无任何音轨提示 → 仍先尝试 AVPlayer，再按不支持格式回退
   * - 初始选轨由 controller 调用 `resolveInitialTrackIndex` 决定（与 backend route 决策解耦）
   */
  async resolveRoutingDecision(videoData: VideoData): Promise<AudioRoutingDecision> {
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
        // 未知/缺失统一用空串表示；已知类型为 'SDR' | 'HDR10' | 'HLG' | 'DOLBY_VISION'。
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

    // 合并 probe + preset 为整组音轨分析（probe 优先，preset 作为补充）
    const trackAnalyses: AudioTrackAnalysis[] = [];
    const seenCodecs = new Set<string>();
    for (let i = 0; i < probeAudioTracks.length; i++) {
      const t = probeAudioTracks[i];
      const codec = normalizeAudioCodec(t.codec);
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
      const codec = normalizeAudioCodec(presetHint.codecName);
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
