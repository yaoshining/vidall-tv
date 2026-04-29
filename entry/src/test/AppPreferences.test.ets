import { describe, it, expect, beforeEach, afterEach } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@ohos.abilityAccessCtrl';
import {
  AppPreferences,
  AppPreferencesLoader,
  AppPreferencesStore
} from '../main/ets/utils/AppPreferences';
import {
  loadSubtitleLanguagePreference,
  saveSubtitleLanguagePreference,
  SubtitleLanguagePreference
} from '../main/ets/subtitle/SubtitleLanguagePreference';

class InMemoryAppPreferencesStore implements AppPreferencesStore {
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

class DeferredAppPreferencesLoader {
  private resolveStore: ((store: AppPreferencesStore) => void) | null = null;
  readonly promise: Promise<AppPreferencesStore> = new Promise<AppPreferencesStore>((resolve) => {
    this.resolveStore = resolve;
  });

  release(store: AppPreferencesStore): void {
    if (this.resolveStore !== null) {
      const resolve = this.resolveStore;
      this.resolveStore = null;
      resolve(store);
    }
  }
}

export default function appPreferencesTest() {
  describe('AppPreferences_pending_init', () => {
    beforeEach(() => {
      AppPreferences.resetForTesting();
    });

    afterEach(() => {
      AppPreferences.setStoreLoaderForTesting(null);
      AppPreferences.resetForTesting();
    });

    it('should wait pending init before loading subtitle preference', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const deferredLoader = new DeferredAppPreferencesLoader();
      const store = new InMemoryAppPreferencesStore();
      const loader: AppPreferencesLoader = async () => deferredLoader.promise;
      store.seed('subtitle_language_preference', JSON.stringify({
        languages: ['en', 'zh-CN'],
        hideOtherLanguages: true
      }));

      AppPreferences.setStoreLoaderForTesting(loader);
      const initPromise = AppPreferences.init(ctx);
      const loadPromise = loadSubtitleLanguagePreference();

      deferredLoader.release(store);
      const loadedPreference = await loadPromise;
      await initPromise;

      expect(loadedPreference.languages.length).assertEqual(2);
      expect(loadedPreference.languages[0]).assertEqual('en');
      expect(loadedPreference.languages[1]).assertEqual('zh-CN');
      expect(loadedPreference.hideOtherLanguages).assertTrue();
    });

    it('should wait pending init before saving subtitle preference', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const deferredLoader = new DeferredAppPreferencesLoader();
      const store = new InMemoryAppPreferencesStore();
      const loader: AppPreferencesLoader = async () => deferredLoader.promise;
      const nextPreference: SubtitleLanguagePreference = {
        languages: ['en', 'zh-CN'],
        hideOtherLanguages: false
      };

      AppPreferences.setStoreLoaderForTesting(loader);
      const initPromise = AppPreferences.init(ctx);
      const savePromise = saveSubtitleLanguagePreference(nextPreference);

      deferredLoader.release(store);
      await savePromise;
      await initPromise;

      const loadedPreference = await loadSubtitleLanguagePreference();
      expect(loadedPreference.languages.length).assertEqual(2);
      expect(loadedPreference.languages[0]).assertEqual('en');
      expect(loadedPreference.languages[1]).assertEqual('zh-CN');
      expect(loadedPreference.hideOtherLanguages).assertFalse();
    });
  });
}
