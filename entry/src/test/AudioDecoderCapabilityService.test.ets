import { describe, it, expect } from '@ohos/hypium';
import { AudioDecoderCapabilityService } from '../main/ets/services/audioCapability/AudioDecoderCapabilityService';
import {
  AudioDecoderCapability,
  CapabilityProvider,
  DeviceInfoProvider
} from '../main/ets/services/audioCapability/AudioCapabilityTypes';

function makeCapability(
  supported: boolean,
  maxChannels: number,
  isHardware: boolean,
  known: boolean = true
): AudioDecoderCapability {
  const cap: AudioDecoderCapability = {
    capabilityKnown: known,
    supported,
    isHardware,
    maxChannels,
    decoderName: known ? 'test-decoder' : '',
    mimeType: '',
    errorMessage: ''
  };
  return cap;
}

interface CountingProviderResult {
  provider: CapabilityProvider;
  calls: string[];
}

function makeCountingProvider(results: Record<string, AudioDecoderCapability>): CountingProviderResult {
  const calls: string[] = [];
  const provider: CapabilityProvider = {
    query: (codecOrMime: string): AudioDecoderCapability => {
      calls.push(codecOrMime);
      const r = results[codecOrMime];
      if (r !== undefined) {
        return r;
      }
      return makeCapability(false, 0, false, true);
    }
  };
  const result: CountingProviderResult = { provider, calls };
  return result;
}

function makeThrowingProvider(): CapabilityProvider {
  const provider: CapabilityProvider = {
    query: (_codecOrMime: string): AudioDecoderCapability => {
      throw new Error('capability query boom');
    }
  };
  return provider;
}

function makeDeviceInfo(model: string, os: string): DeviceInfoProvider {
  const provider: DeviceInfoProvider = {
    getDeviceModel: (): string => model,
    getOsVersion: (): string => os
  };
  return provider;
}

export default function audioDecoderCapabilityServiceTest() {
  describe('AudioDecoderCapabilityService', () => {
    it('三条音轨两种唯一 codec 时最多查询两次（去重）', 0, () => {
      const svc = new AudioDecoderCapabilityService();
      const counting = makeCountingProvider({
        'aac': makeCapability(true, 2, true),
        'eac3': makeCapability(true, 6, false)
      });
      svc.setCapabilityProviderForTesting(counting.provider);
      svc.setDeviceInfoProviderForTesting(makeDeviceInfo('model-A', 'os-1'));
      svc.resolveTrackCompatibility('aac', 2);
      svc.resolveTrackCompatibility('aac', 2);
      svc.resolveTrackCompatibility('aac', 6);
      svc.resolveTrackCompatibility('eac3', 6);
      expect(counting.calls.length).assertEqual(2);
    });

    it('codec 支持但声道超上限时判为不兼容', 0, () => {
      const svc = new AudioDecoderCapabilityService();
      svc.setCapabilityProviderForTesting(makeCountingProvider({
        'truehd': makeCapability(true, 2, false)
      }).provider);
      svc.setDeviceInfoProviderForTesting(makeDeviceInfo('model-A', 'os-1'));
      const r = svc.resolveTrackCompatibility('truehd', 6);
      expect(r.compatible).assertFalse();
      expect(r.source).assertEqual('system');
    });

    it('缓存命中复用结果且不重复查询', 0, () => {
      const svc = new AudioDecoderCapabilityService();
      const counting = makeCountingProvider({
        'aac': makeCapability(true, 2, true)
      });
      svc.setCapabilityProviderForTesting(counting.provider);
      svc.setDeviceInfoProviderForTesting(makeDeviceInfo('model-A', 'os-1'));
      svc.resolveTrackCompatibility('aac', 2);
      svc.resolveTrackCompatibility('aac', 2);
      const r = svc.resolveTrackCompatibility('aac', 2);
      expect(r.source).assertEqual('cache');
      expect(counting.calls.length).assertEqual(1);
    });

    it('系统版本变化后旧缓存失效并重新查询', 0, () => {
      const svc = new AudioDecoderCapabilityService();
      const counting = makeCountingProvider({
        'aac': makeCapability(true, 2, true)
      });
      svc.setCapabilityProviderForTesting(counting.provider);
      svc.setDeviceInfoProviderForTesting(makeDeviceInfo('model-A', 'os-1'));
      svc.resolveTrackCompatibility('aac', 2);
      svc.setDeviceInfoProviderForTesting(makeDeviceInfo('model-A', 'os-2'));
      svc.resolveTrackCompatibility('aac', 2);
      expect(counting.calls.length).assertEqual(2);
    });

    it('能力查询异常时软解 codec 保守判未知不兼容', 0, () => {
      const svc = new AudioDecoderCapabilityService();
      svc.setCapabilityProviderForTesting(makeThrowingProvider());
      svc.setDeviceInfoProviderForTesting(makeDeviceInfo('model-A', 'os-1'));
      const r = svc.resolveTrackCompatibility('eac3', 2);
      expect(r.compatible).assertFalse();
      expect(r.source).assertEqual('unknown');
    });

    it('能力查询异常时硬解友好 codec 迁移兜底假定兼容', 0, () => {
      const svc = new AudioDecoderCapabilityService();
      svc.setCapabilityProviderForTesting(makeThrowingProvider());
      svc.setDeviceInfoProviderForTesting(makeDeviceInfo('model-A', 'os-1'));
      const r = svc.resolveTrackCompatibility('aac', 2);
      expect(r.compatible).assertTrue();
      expect(r.source).assertEqual('migration-blacklist');
    });

    it('纠偏结果优先于系统声明能力', 0, () => {
      const svc = new AudioDecoderCapabilityService();
      svc.setCapabilityProviderForTesting(makeCountingProvider({
        'eac3': makeCapability(true, 6, false)
      }).provider);
      svc.setDeviceInfoProviderForTesting(makeDeviceInfo('model-A', 'os-1'));
      svc.recordCorrection('eac3', 'avplayer_unsupported_format');
      const r = svc.resolveTrackCompatibility('eac3', 2);
      expect(r.compatible).assertFalse();
      expect(r.source).assertEqual('correction');
    });
  });
}
