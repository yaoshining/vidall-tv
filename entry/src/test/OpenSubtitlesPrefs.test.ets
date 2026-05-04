import { describe, it, expect, beforeEach, afterEach } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@ohos.abilityAccessCtrl';
import {
  AppPreferences,
  AppPreferencesLoader,
  AppPreferencesStore,
  PrefKey
} from '../main/ets/utils/AppPreferences';

// ─────────────────────────────────────────────
// 内存 Store（与 AppPreferences.test.ets 相同模式）
// ─────────────────────────────────────────────

class InMemoryStore implements AppPreferencesStore {
  private readonly values: Map<string, string | number> = new Map<string, string | number>();

  seed(key: string, value: string | number): void {
    this.values.set(key, value);
  }

  async get(key: string, defaultValue: string | number): Promise<string | number> {
    const value = this.values.get(key);
    return value === undefined ? defaultValue : value;
  }

  async put(key: string, value: string | number): Promise<void> {
    this.values.set(key, value);
  }

  async flush(): Promise<void> {
  }
}

// ─────────────────────────────────────────────
// 测试套件
// ─────────────────────────────────────────────

export default function openSubtitlesPrefsTest() {
  describe('OpenSubtitlesPrefs_key_constants', () => {
    it('should expose OPENSUBTITLES_API_KEY constant with correct value', 0, () => {
      expect(PrefKey.OPENSUBTITLES_API_KEY).assertEqual('opensubtitles_api_key');
    });

    it('should expose OPENSUBTITLES_DEVICE_ID constant with correct value', 0, () => {
      expect(PrefKey.OPENSUBTITLES_DEVICE_ID).assertEqual('opensubtitles_device_id');
    });
  });

  describe('OpenSubtitlesPrefs_api_key_readwrite', () => {
    beforeEach(() => {
      AppPreferences.resetForTesting();
    });

    afterEach(() => {
      AppPreferences.setStoreLoaderForTesting(null);
      AppPreferences.resetForTesting();
    });

    it('should return empty string when OPENSUBTITLES_API_KEY is not set', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      const loader: AppPreferencesLoader = async () => store;

      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      const value = await AppPreferences.get(PrefKey.OPENSUBTITLES_API_KEY, '');
      expect(value).assertEqual('');
    });

    it('should persist and read back OPENSUBTITLES_API_KEY after write', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      const loader: AppPreferencesLoader = async () => store;

      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      await AppPreferences.set(PrefKey.OPENSUBTITLES_API_KEY, 'test-key');
      const value = await AppPreferences.get(PrefKey.OPENSUBTITLES_API_KEY, '');
      expect(value).assertEqual('test-key');
    });
  });

  describe('OpenSubtitlesPrefs_device_id', () => {
    beforeEach(() => {
      AppPreferences.resetForTesting();
    });

    afterEach(() => {
      AppPreferences.setStoreLoaderForTesting(null);
      AppPreferences.resetForTesting();
    });

    it('should create and persist device id on first call', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      const loader: AppPreferencesLoader = async () => store;

      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      const deviceId = await AppPreferences.getOrCreateDeviceId();
      const persisted = await AppPreferences.get(PrefKey.OPENSUBTITLES_DEVICE_ID, '');

      expect(deviceId.length > 0).assertTrue();
      expect(persisted).assertEqual(deviceId);
    });

    it('should return same device id on consecutive calls', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      const loader: AppPreferencesLoader = async () => store;

      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      const firstCall = await AppPreferences.getOrCreateDeviceId();
      const secondCall = await AppPreferences.getOrCreateDeviceId();

      expect(firstCall.length > 0).assertTrue();
      expect(firstCall).assertEqual(secondCall);
    });

    it('should reuse pre-existing device id when already stored', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      const loader: AppPreferencesLoader = async () => store;

      store.seed(PrefKey.OPENSUBTITLES_DEVICE_ID, 'preset-device-id-abc');
      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      const deviceId = await AppPreferences.getOrCreateDeviceId();
      expect(deviceId).assertEqual('preset-device-id-abc');
    });
  });
}
