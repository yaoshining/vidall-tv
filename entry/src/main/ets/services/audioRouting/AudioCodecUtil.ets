// filepath: entry/src/main/ets/services/audioRouting/AudioCodecUtil.ets
//
// AudioCodecUtil - 音频 codec / 声道归一化与排名纯函数。
//
// 目的：把 `AudioTrackRoutingService` 中的纯函数（归一化、声道计划、兼容排名）
// 抽到独立模块，供 `AudioTrackRoutingService` 与 `AudioDecoderCapabilityService`
// 共同复用，避免二者互相 import 造成循环依赖。
//
// 约束：
// - 仅包含无副作用的纯函数，不依赖 NAPI、不依赖具体 adapter。

/** 经验规则：命中下列关键字时优先软解，避免先硬解再失败切换带来的卡顿。 */
export const SOFT_ONLY_KEYWORDS: string[] = [
  'ac3', 'eac3', 'dts', 'truehd', 'mlp', 'vivid', 'atmos'
];

/**
 * codec 兼容性等级（数字越小越优先，作为初轨选择与 route decision 的排序依据）。
 *
 * 注意：此排名仅在设备能力信息不可用（如 MPV 运行时轨道）时作为回退。
 * 有真实设备能力时，应由 `AudioDecoderCapabilityService` 提供兼容性判定。
 *
 * 1 = 系统稳态可硬解（HARD_PREFERRED）
 * 2 = 软解但常见（AC-3 / EAC-3）
 * 3 = 软解且罕见（DTS / TrueHD / MLP / Audio Vivid）
 * 4 = 未知 codec
 */
export function codecCompatibilityRank(codec: string): number {
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

/** 将原始声道数归一化到实际解码计划所对应的层级（1/2/6/8）。 */
export function normalizeTargetChannels(channels?: number): number {
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

/** 排序前对声道数做归一化处理。 */
export function normalizeChannelsForSort(ch: number): number {
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

/** 判断指定 codec 是否优先走硬解（仅作为设备能力缺失时的回退启发式）。 */
export function isLikelySystemHardDecodeSupported(codec: string): boolean {
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

/** 将 AVPlayer MIME 与 ffprobe codec 统一为路由使用的 codec 名。 */
export function normalizeAudioCodec(rawCodec: string): string {
  const codec = rawCodec.toLowerCase().replace('audio/', '').split('-').join('');
  if (codec === 'mp4alatm' || codec === 'mp4a' || codec === 'aaclatm') {
    return 'aac';
  }
  if (codec === 'vnd.dts') {
    return 'dts';
  }
  if (codec === 'vnd.dts.hd') {
    return 'dtshd';
  }
  return codec;
}
