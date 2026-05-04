import BuildProfile from 'BuildProfile';

/**
 * 应用运行环境枚举。
 * - development：开发调试（product=default，build mode=debug）
 * - production：正式发布（product=production，build mode=release）
 */
export const enum AppEnvironment {
  Development = 'development',
  Production = 'production',
}

/**
 * 应用环境配置单例。
 *
 * 环境判断规则：
 *   PRODUCT_NAME === 'production'  →  Production
 *   其他                          →  Development
 *
 * 使用方式：
 *   import { AppEnv } from '../config/AppEnv';
 *   const url = AppEnv.OS_PROXY_BASE_URL;
 */
export class AppEnv {
  // 将编译期字面量类型拓宽为 string，避免 ArkTS 字面量类型比较警告
  private static readonly _productName: string = BuildProfile.PRODUCT_NAME as string;

  static readonly ENV: AppEnvironment = AppEnv._productName === 'production'
    ? AppEnvironment.Production
    : AppEnvironment.Development;

  static readonly IS_PRODUCTION: boolean = AppEnv.ENV === AppEnvironment.Production;

  /** OpenSubtitles API 直连地址（用户自配 API Key 时使用） */
  static readonly OS_DIRECT_BASE_URL: string = 'https://api.opensubtitles.com/api/v1';

  /**
   * OpenSubtitles 代理 Worker 地址。
   * - 开发环境：本地 wrangler dev（http://localhost:8787/v1）
   * - 生产环境：Cloudflare Worker（https://os-proxy.vidall.app/v1）
   */
  static readonly OS_PROXY_BASE_URL: string = AppEnv.IS_PRODUCTION
    ? 'https://os-proxy.vidall.app/v1'
    : 'http://localhost:8787/v1';
}
