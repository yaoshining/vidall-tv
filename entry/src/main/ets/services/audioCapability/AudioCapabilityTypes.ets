// filepath: entry/src/main/ets/services/audioCapability/AudioCapabilityTypes.ets
//
// AudioDecoderCapabilityService 的类型契约。
//
// 职责：定义设备音频解码能力查询结果、单条音轨兼容性结论、设备/固件纠偏条目，
// 以及可供测试注入的能力提供者抽象。

/** NAPI `queryAudioDecoderCapability()` 返回形状（与 index.d.ts 对齐）。 */
export interface AudioDecoderCapability {
  capabilityKnown: boolean;
  supported: boolean;
  isHardware: boolean;
  maxChannels: number;
  decoderName: string;
  mimeType: string;
  errorMessage: string;
}

/** 兼容性结论来源。 */
export type AudioCapabilitySource =
  | 'correction'
  | 'system'
  | 'cache'
  | 'unknown'
  | 'migration-blacklist';

/** 单条音轨的兼容性结论。 */
export interface AudioTrackCompatibility {
  /** 归一化 codec（如 'aac' / 'eac3' / 'vnd.dts'）。 */
  codec: string;
  /** 归一化后的声道计划（1/2/6/8）。 */
  channels: number;
  /** 是否可被当前设备解码（codec 支持且声道数不超上限）。 */
  compatible: boolean;
  /** 是否为硬件解码。 */
  isHardware: boolean;
  /** 设备该 codec 的最大声道能力（未知/不支持时为 0）。 */
  maxChannels: number;
  /** 结论来源。 */
  source: AudioCapabilitySource;
  /** 额外说明（纠偏原因 / 错误信息）。 */
  reason?: string;
}

/** 设备/固件纠偏条目（持久化到 AppPreferences）。 */
export interface AudioCorrectionEntry {
  deviceModel: string;
  osVersion: string;
  codec: string;
  forceUnsupported: boolean;
  reason: string;
  updatedAt: number;
}

/** 能力提供者抽象：默认走 NAPI，测试可注入假实现。 */
export interface CapabilityProvider {
  query: (codecOrMime: string) => AudioDecoderCapability;
}

/** 设备/系统信息提供者抽象：测试可注入固定值。 */
export interface DeviceInfoProvider {
  getDeviceModel: () => string;
  getOsVersion: () => string;
}
