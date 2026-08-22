// filepath: entry/src/main/ets/services/audioCapability/AudioDecoderCapabilityService.ets
//
// AudioDecoderCapabilityService - 设备音频解码能力查询、缓存与纠偏。
//
// 目标：把音频路由决策的"能力真值"统一收敛到本 service：
//   1. 封装 NAPI `queryAudioDecoderCapability()`（类型安全 bridge）。
//   2. 二级缓存：原始能力按 codec 去重 + 派生兼容结论按 codec/声道键控。
//   3. 设备/固件纠偏结果优先于系统声明能力，支持持久化复用。
//
// 约束：
// - 能力查询与结论计算为同步纯逻辑（NAPI 查询为同步本地调用）。
// - 纠偏持久化异步进行，不阻塞决策；`ensureLoaded()` 由调用方在决策前 await。
// - 不直接依赖 `VideoPlayerController` / 具体 adapter。

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CommonConstants } from '../../common/constants/CommonConstants';
import * as VidAllNapiModule from 'libvidall_core_player_napi.so';
import deviceInfo from '@ohos.deviceInfo';
import { normalizeAudioCodec } from '../audioRouting/AudioCodecUtil';
import { AppPreferences, PrefKey } from '../../utils/AppPreferences';
import {
  AudioDecoderCapability,
  AudioTrackCompatibility,
  AudioCorrectionEntry,
  CapabilityProvider,
  DeviceInfoProvider
} from './AudioCapabilityTypes';

const TAG = '[AudioDecoderCapabilityService]';

// ─── NAPI Bridge ───────────────────────────────────────────────────────────────

interface AudioCapabilityNapiBridge {
  queryAudioDecoderCapability: (codecOrMime: string) => AudioDecoderCapability;
}

interface AudioCapabilityNapiModule {
  default?: AudioCapabilityNapiBridge;
}

function resolveNapiBridge(): AudioCapabilityNapiBridge | undefined {
  const mod = VidAllNapiModule as AudioCapabilityNapiModule | AudioCapabilityNapiBridge | undefined;
  if (mod === undefined) {
    return undefined;
  }
  const def = (mod as AudioCapabilityNapiModule).default;
  if (def !== undefined) {
    return def as AudioCapabilityNapiBridge;
  }
  return mod as AudioCapabilityNapiBridge;
}

/** 默认设备/系统信息提供者（基于 @ohos.deviceInfo）。 */
const DEFAULT_DEVICE_INFO_PROVIDER: DeviceInfoProvider = {
  getDeviceModel: (): string => {
    try {
      const model = deviceInfo.productModel;
      if (model !== undefined && model.length > 0) {
        return model;
      }
      const market = deviceInfo.marketName;
      if (market !== undefined && market.length > 0) {
        return market;
      }
      const type = deviceInfo.deviceType;
      return (type !== undefined && type.length > 0) ? type : 'unknown';
    } catch (e) {
      return 'unknown';
    }
  },
  getOsVersion: (): string => {
    try {
      const os = deviceInfo.osFullName;
      return (os !== undefined && os.length > 0) ? os : 'unknown';
    } catch (e) {
      return 'unknown';
    }
  }
};

/**
 * 设备音频解码能力服务（单例）。
 *
 * `resolveTrackCompatibility(codec, channels)` 中 `channels` 为归一化声道计划
 * （1/2/6/8）；传 0 表示声道未知，跳过声道上限校验。
 */
export class AudioDecoderCapabilityService {
  private readonly codecCapCache: Map<string, AudioDecoderCapability> = new Map<string, AudioDecoderCapability>();
  private readonly compatCache: Map<string, AudioTrackCompatibility> = new Map<string, AudioTrackCompatibility>();
  private readonly corrections: Map<string, AudioCorrectionEntry> = new Map<string, AudioCorrectionEntry>();
  private capabilityProvider?: CapabilityProvider;
  private deviceInfoProvider: DeviceInfoProvider = DEFAULT_DEVICE_INFO_PROVIDER;
  private correctionsLoaded: boolean = false;
  private correctionsLoadPromise: Promise<void> | null = null;

  /** 测试注入钩子：替换 NAPI 能力提供者。 */
  setCapabilityProviderForTesting(provider: CapabilityProvider | undefined): void {
    this.capabilityProvider = provider;
    this.codecCapCache.clear();
    this.compatCache.clear();
  }

  /** 测试注入钩子：替换设备/系统信息。 */
  setDeviceInfoProviderForTesting(provider: DeviceInfoProvider | undefined): void {
    this.deviceInfoProvider = provider ?? DEFAULT_DEVICE_INFO_PROVIDER;
    this.codecCapCache.clear();
    this.compatCache.clear();
  }

  /** 测试辅助：清空内存态（缓存 + 纠偏）。 */
  resetForTesting(): void {
    this.codecCapCache.clear();
    this.compatCache.clear();
    this.corrections.clear();
    this.correctionsLoaded = false;
    this.correctionsLoadPromise = null;
  }

  /** 确保纠偏结果已从 AppPreferences 加载（幂等，并发调用共享同一 in-flight Promise）。 */
  async ensureLoaded(): Promise<void> {
    if (this.correctionsLoaded) {
      return;
    }
    if (this.correctionsLoadPromise === null) {
      this.correctionsLoadPromise = this.loadCorrections().then(() => {
        this.correctionsLoadPromise = null;
      });
    }
    await this.correctionsLoadPromise;
  }

  /** 实际加载纠偏结果（内部吞掉所有异常，correctionsLoaded 在 finally 置位）。 */
  private async loadCorrections(): Promise<void> {
    try {
      const raw = await AppPreferences.get(PrefKey.AUDIO_CAPABILITY_CORRECTIONS, '');
      if (raw.length > 0) {
        const parsed = JSON.parse(raw) as AudioCorrectionEntry[];
        if (Array.isArray(parsed)) {
          const device = this.deviceInfoProvider.getDeviceModel();
          const os = this.deviceInfoProvider.getOsVersion();
          for (let i = 0; i < parsed.length; i++) {
            const entry = parsed[i];
            if (entry.deviceModel === device && entry.osVersion === os) {
              this.corrections.set(this.correctionKey(entry.codec), entry);
            }
          }
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `纠偏加载完成: 匹配 ${this.corrections.size} 条（device=${device} os=${os}）`);
        }
      }
    } catch (e) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `纠偏加载失败（忽略，按无纠偏处理）: ${(e as BusinessError).message ?? JSON.stringify(e)}`);
    } finally {
      this.correctionsLoaded = true;
    }
  }

  /**
   * 判定单条音轨的兼容性（同步）。
   * 优先级：纠偏 > 派生兼容缓存 > 原始能力缓存 > NAPI 查询。
   */
  resolveTrackCompatibility(codecRaw: string, channels: number): AudioTrackCompatibility {
    const codec = normalizeAudioCodec(codecRaw);
    const normChannels = channels > 0 ? channels : 0;

    // 1. 纠偏优先
    const correction = this.corrections.get(this.correctionKey(codec));
    if (correction !== undefined && correction.forceUnsupported) {
      const result: AudioTrackCompatibility = {
        codec,
        channels: normChannels,
        compatible: false,
        isHardware: false,
        maxChannels: 0,
        source: 'correction',
        reason: correction.reason
      };
      return result;
    }

    // 2. 派生兼容缓存
    const compatKey = this.compatCacheKey(codec, normChannels);
    const cachedCompat = this.compatCache.get(compatKey);
    if (cachedCompat !== undefined) {
      const result: AudioTrackCompatibility = {
        codec: cachedCompat.codec,
        channels: cachedCompat.channels,
        compatible: cachedCompat.compatible,
        isHardware: cachedCompat.isHardware,
        maxChannels: cachedCompat.maxChannels,
        source: 'cache',
        reason: cachedCompat.reason
      };
      return result;
    }

    // 3. 原始能力（按 codec 去重）
    const codecKey = this.codecCapKey(codec);
    let capability = this.codecCapCache.get(codecKey);
    if (capability === undefined) {
      capability = this.queryCapability(codec);
      this.codecCapCache.set(codecKey, capability);
    }

    const result = this.buildCompatibility(codec, normChannels, capability);
    this.compatCache.set(compatKey, result);
    return result;
  }

  /** 记录纠偏结果（AVPlayer 明确失败时调用），同步写内存 + 异步持久化。 */
  recordCorrection(codecRaw: string, reason: string): void {
    const codec = normalizeAudioCodec(codecRaw);
    if (codec.length === 0) {
      return;
    }
    const entry: AudioCorrectionEntry = {
      deviceModel: this.deviceInfoProvider.getDeviceModel(),
      osVersion: this.deviceInfoProvider.getOsVersion(),
      codec,
      forceUnsupported: true,
      reason,
      updatedAt: Date.now()
    };
    this.corrections.set(this.correctionKey(codec), entry);
    // 使该 codec 的派生缓存失效，后续查询按纠偏重新计算
    this.invalidateCodecCaches(codec);
    hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
      `记录纠偏: codec=${codec} reason=${reason}`);
    this.persistCorrections().catch(() => {});
  }

  /** 测试辅助：读取当前内存中的纠偏条数。 */
  getCorrectionCountForTesting(): number {
    return this.corrections.size;
  }

  // ─── 内部实现 ───

  private correctionKey(codec: string): string {
    return `${this.deviceInfoProvider.getDeviceModel()}|${this.deviceInfoProvider.getOsVersion()}|${codec}`;
  }

  private codecCapKey(codec: string): string {
    return `${this.deviceInfoProvider.getDeviceModel()}|${this.deviceInfoProvider.getOsVersion()}|${codec}`;
  }

  private compatCacheKey(codec: string, channels: number): string {
    return `${this.deviceInfoProvider.getDeviceModel()}|${this.deviceInfoProvider.getOsVersion()}|${codec}|${channels}`;
  }

  private queryCapability(codec: string): AudioDecoderCapability {
    try {
      if (this.capabilityProvider !== undefined) {
        return this.capabilityProvider.query(codec);
      }
      const bridge = resolveNapiBridge();
      if (bridge === undefined) {
        return this.unknownCapability(codec, 'libvidall_core_player_napi.so 未加载');
      }
      return bridge.queryAudioDecoderCapability(codec);
    } catch (e) {
      const err = e as BusinessError;
      return this.unknownCapability(codec, err.message ?? '能力查询异常');
    }
  }

  private unknownCapability(codec: string, reason: string): AudioDecoderCapability {
    const cap: AudioDecoderCapability = {
      capabilityKnown: false,
      supported: false,
      isHardware: false,
      maxChannels: 0,
      decoderName: '',
      mimeType: codec,
      errorMessage: reason
    };
    return cap;
  }

  private buildCompatibility(
    codec: string,
    channels: number,
    capability: AudioDecoderCapability
  ): AudioTrackCompatibility {
    if (!capability.capabilityKnown) {
      // 能力未知/查询异常：无论 codec 是否硬解友好，一律保守判不兼容，
      // 由路由层选择 MPV 兜底（不基于任何 codec 启发式假设兼容性）。
      const result: AudioTrackCompatibility = {
        codec,
        channels,
        compatible: false,
        isHardware: false,
        maxChannels: 0,
        source: 'unknown',
        reason: capability.errorMessage
      };
      return result;
    }
    if (!capability.supported) {
      const result: AudioTrackCompatibility = {
        codec,
        channels,
        compatible: false,
        isHardware: false,
        maxChannels: 0,
        source: 'system',
        reason: capability.errorMessage.length > 0 ? capability.errorMessage : 'decoder not found'
      };
      return result;
    }
    // codec 支持；声道未知（channels<=0）时跳过上限校验
    const withinChannels = channels <= 0 || channels <= capability.maxChannels;
    const result: AudioTrackCompatibility = {
      codec,
      channels,
      compatible: withinChannels,
      isHardware: capability.isHardware,
      maxChannels: capability.maxChannels,
      source: 'system',
      reason: withinChannels ? '' : `channels ${channels} > max ${capability.maxChannels}`
    };
    return result;
  }

  private invalidateCodecCaches(codec: string): void {
    const prefix = this.codecCapKey(codec);
    const keysToDelete: string[] = [];
    this.compatCache.forEach((_value: AudioTrackCompatibility, key: string) => {
      if (key.startsWith(prefix)) {
        keysToDelete.push(key);
      }
    });
    for (let i = 0; i < keysToDelete.length; i++) {
      this.compatCache.delete(keysToDelete[i]);
    }
    this.codecCapCache.delete(prefix);
  }

  private async persistCorrections(): Promise<void> {
    const entries: AudioCorrectionEntry[] = [];
    this.corrections.forEach((value: AudioCorrectionEntry) => {
      entries.push(value);
    });
    const json = JSON.stringify(entries);
    await AppPreferences.set(PrefKey.AUDIO_CAPABILITY_CORRECTIONS, json);
  }
}

/** 默认单例（pure service，无构造依赖）。 */
export const audioDecoderCapabilityService: AudioDecoderCapabilityService =
  new AudioDecoderCapabilityService();
