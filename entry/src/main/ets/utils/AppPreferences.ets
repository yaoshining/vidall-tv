import dataPreferences from '@ohos.data.preferences';
import { Context } from '@ohos.abilityAccessCtrl';
import { BusinessError } from '@kit.BasicServicesKit';

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
}

// ─────────────────────────────────────────────
// AppPreferences 单例
// ─────────────────────────────────────────────

const STORE_NAME = 'app_preferences';

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
  private static store: dataPreferences.Preferences | null = null;

  /** 在 EntryAbility.onCreate 里调用一次 */
  static async init(context: Context): Promise<void> {
    if (AppPreferences.store !== null) {
      return;
    }
    try {
      AppPreferences.store = await dataPreferences.getPreferences(context, STORE_NAME);
      console.info('[AppPreferences] 初始化成功');
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[AppPreferences] 初始化失败: ${err.message ?? JSON.stringify(e)}`);
      throw new Error(`AppPreferences init failed: ${err.message}`);
    }
  }

  /** 读取字符串值 */
  static async get(key: string, defaultValue: string): Promise<string> {
    if (!AppPreferences.store) {
      console.warn(`[AppPreferences] 未初始化，key=${key} 返回默认值`);
      return defaultValue;
    }
    try {
      const val = await AppPreferences.store.get(key, defaultValue);
      return val as string;
    } catch {
      return defaultValue;
    }
  }

  /** 读取数字值 */
  static async getNumber(key: string, defaultValue: number): Promise<number> {
    if (!AppPreferences.store) {
      console.warn(`[AppPreferences] 未初始化，key=${key} 返回默认值`);
      return defaultValue;
    }
    try {
      const val = await AppPreferences.store.get(key, defaultValue);
      return val as number;
    } catch {
      return defaultValue;
    }
  }

  /** 写入值（string 或 number） */
  static async set(key: string, value: string | number): Promise<void> {
    if (!AppPreferences.store) {
      console.warn(`[AppPreferences] 未初始化，key=${key} 写入失败`);
      return;
    }
    try {
      await AppPreferences.store.put(key, value);
      await AppPreferences.store.flush();
      console.info(`[AppPreferences] 写入 key=${key}`);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[AppPreferences] 写入失败 key=${key}: ${err.message ?? JSON.stringify(e)}`);
    }
  }
}

