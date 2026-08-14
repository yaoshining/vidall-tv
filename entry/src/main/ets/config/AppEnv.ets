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
   * - 生产环境：Cloudflare Worker（https://os-proxy.vidall.app/v1）
   * - 开发环境：Mac 局域网 IP + wrangler dev 端口
   *
   * ⚠️ 开发注意事项：
   *   1. 在 proxy/opensubtitles-worker/ 执行 `npm run dev`（监听 0.0.0.0:8787）
   *   2. 若 Mac 的 LAN IP 变化，更新下方 DEV_PROXY_HOST 后重新编译 App
   *   3. Mac LAN IP 查询：`ipconfig getifaddr en0`
   */
  private static readonly DEV_PROXY_HOST: string = '192.168.3.199';
  static readonly OS_PROXY_BASE_URL: string = AppEnv.IS_PRODUCTION
    ? 'https://os-proxy.vidall.app/v1'
    : `http://${AppEnv.DEV_PROXY_HOST}:8787/v1`;

  /**
   * SubHub 统一字幕出口网关 host。
   * - 线上服务：公共域名 subhub.softeehub.com
   * - 本地自建：localhost:3000（如需自建，可在演示页手动覆盖 base URL）
   */
  private static readonly PROD_SUBHUB_HOST: string = 'subhub.softeehub.com';

  /**
   * SubHub 公共 base URL（无尾斜杠）。
   * 线上服务已部署，无论 debug/release 构建都固定指向 subhub.softeehub.com；
   * 本地自建环境可在演示页「连接配置」里手动覆盖为 http://localhost:3000。
   */
  static readonly SUBHUB_BASE_URL: string = `https://${AppEnv.PROD_SUBHUB_HOST}`;

  /**
   * SubHub Caller Key（对外字幕 API 的 Bearer 鉴权凭据）。
   * ⚠️ 账户体系建立前暂用常量；正式接入时应改用 BuildProfile/secret 注入，避免明文进 git。
   */
  static readonly SUBHUB_API_KEY: string = 'subhub_live_KE9pl9UT4-Eo_zhSJedlDXn_i5xeVlax8Rlcs3Rn8wQ';
}
