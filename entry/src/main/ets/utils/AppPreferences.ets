import dataPreferences from '@ohos.data.preferences';
import { Context } from '@ohos.abilityAccessCtrl';
import { BusinessError } from '@kit.BasicServicesKit';

export type AppPreferenceValue = string | number;

export interface AppPreferencesStore {
  get(key: string, defaultValue: AppPreferenceValue): Promise<AppPreferenceValue>;
  put(key: string, value: AppPreferenceValue): Promise<void>;
  flush(): Promise<void>;
}

export type AppPreferencesLoader = (context: Context, storeName: string) => Promise<AppPreferencesStore>;

// ─────────────────────────────────────────────
// Key 常量
// ─────────────────────────────────────────────

export class PrefKey {
  /** TMDB API Key */
  static readonly TMDB_API_KEY = 'tmdb_api_key';
  /** 刮削并发数，默认 2 */
  static readonly SCRAPE_CONCURRENCY = 'scrape_concurrency';
  /**
   * 刮削 Provider 优先级列表，JSON 序列化的 string[]
   * 例：'["tmdb","douban"]'
   */
  static readonly SCRAPE_PROVIDER_ORDER = 'scrape_provider_order';
  /** 播放器诊断面包屑（用于无 faultlog 场景定位最后阶段） */
  static readonly PLAYER_LAST_BREADCRUMB = 'player_last_breadcrumb';
  /** 剧集播放结束前是否自动切到下一集（1=开启，0=关闭） */
  static readonly PLAYER_EPISODE_AUTOPLAY_ENABLED = 'player_episode_autoplay_enabled';
  /** 自动切到下一集前的倒计时秒数 */
  static readonly PLAYER_EPISODE_AUTOPLAY_COUNTDOWN_SECONDS = 'player_episode_autoplay_countdown_seconds';
  /** 字幕语言偏好（JSON 序列化字符串） */
  static readonly SUBTITLE_LANGUAGE_PREFERENCE = 'subtitle_language_preference';
}

// ─────────────────────────────────────────────
// AppPreferences 单例
// ─────────────────────────────────────────────

const STORE_NAME = 'app_preferences';

const DEFAULT_APP_PREFERENCES_LOADER: AppPreferencesLoader = async (
  context: Context,
  storeName: string
): Promise<AppPreferencesStore> => {
  const store = await dataPreferences.getPreferences(context, storeName);
  return store as AppPreferencesStore;
};

/**
 * 应用偏好设置工具（EL1）
 *
 * 使用前须在 EntryAbility.onCreate 中调用 AppPreferences.init(context)
 *
 * ```typescript
 * await AppPreferences.init(context);
 * await AppPreferences.set(PrefKey.TMDB_API_KEY, 'your_key');
 * const key = await AppPreferences.get(PrefKey.TMDB_API_KEY, '');
 * ```
 */
export class AppPreferences {
  private static store: AppPreferencesStore | null = null;
  private static initPromise: Promise<void> | null = null;
  private static storeLoader: AppPreferencesLoader = DEFAULT_APP_PREFERENCES_LOADER;

  static setStoreLoaderForTesting(loader: AppPreferencesLoader | null): void {
    AppPreferences.storeLoader = loader ?? DEFAULT_APP_PREFERENCES_LOADER;
    AppPreferences.store = null;
    AppPreferences.initPromise = null;
  }

  static resetForTesting(): void {
    AppPreferences.store = null;
    AppPreferences.initPromise = null;
  }

  /** 在 EntryAbility.onCreate 里调用一次 */
  static async init(context: Context): Promise<void> {
    if (AppPreferences.store !== null) {
      return;
    }
    if (AppPreferences.initPromise !== null) {
      return AppPreferences.initPromise;
    }
    AppPreferences.initPromise = (async () => {
      try {
        AppPreferences.store = await AppPreferences.storeLoader(context, STORE_NAME);
        console.info('[AppPreferences] 初始化成功');
      } catch (e) {
        const err = e as BusinessError;
        console.error(`[AppPreferences] 初始化失败: ${err.message ?? JSON.stringify(e)}`);
        throw new Error(`AppPreferences init failed: ${err.message}`);
      } finally {
        AppPreferences.initPromise = null;
      }
    })();
    return AppPreferences.initPromise;
  }

  private static async waitForStore(): Promise<AppPreferencesStore | null> {
    if (AppPreferences.store !== null) {
      return AppPreferences.store;
    }
    if (AppPreferences.initPromise !== null) {
      try {
        await AppPreferences.initPromise;
      } catch {
        return null;
      }
      return AppPreferences.store;
    }
    return null;
  }

  /** 读取字符串值 */
  static async get(key: string, defaultValue: string): Promise<string> {
    const store = await AppPreferences.waitForStore();
    if (!store) {
      console.warn(`[AppPreferences] 未初始化，key=${key} 返回默认值`);
      return defaultValue;
    }
    try {
      const val = await store.get(key, defaultValue);
      return val as string;
    } catch {
      return defaultValue;
    }
  }

  /** 读取数字值 */
  static async getNumber(key: string, defaultValue: number): Promise<number> {
    const store = await AppPreferences.waitForStore();
    if (!store) {
      console.warn(`[AppPreferences] 未初始化，key=${key} 返回默认值`);
      return defaultValue;
    }
    try {
      const val = await store.get(key, defaultValue);
      return val as number;
    } catch {
      return defaultValue;
    }
  }

  /** 写入值（string 或 number） */
  static async set(key: string, value: string | number): Promise<void> {
    const store = await AppPreferences.waitForStore();
    if (!store) {
      console.warn(`[AppPreferences] 未初始化，key=${key} 写入失败`);
      return;
    }
    try {
      await store.put(key, value);
      await store.flush();
      console.info(`[AppPreferences] 写入 key=${key}`);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[AppPreferences] 写入失败 key=${key}: ${err.message ?? JSON.stringify(e)}`);
    }
  }
}
