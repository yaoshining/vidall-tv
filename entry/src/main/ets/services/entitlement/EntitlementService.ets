/**
 * EntitlementService Interface
 * 
 * 定义用户权限查询服务的契约接口
 * 
 * 设计目标：
 * - 为 v1.x 提供 "全功能免费" 的本地实现 (LocalFreeEntitlementService)
 * - 为 v2.0 预留扩展点，支持远程认证服务 (AuthEntitlementService)
 * - Promise-based API 支持未来的网络调用场景
 * 
 * 使用示例：
 * ```typescript
 * const service = ServiceLocator.get<EntitlementService>('entitlement');
 * const hasAccess = await service.hasFeature('feature:advanced-playback');
 * if (hasAccess) {
 *   // 渲染高级功能 UI
 * }
 * ```
 * 
 * @see LocalFreeEntitlementService - v1.x 实现
 * @see docs/entitlement-integration.md - 集成指南
 */

/**
 * 用户订阅等级
 * - free: 免费用户 (v1.x 全部用户)
 * - basic: 基础付费用户 (v2.0 规划)
 * - premium: 高级付费用户 (v2.0 规划)
 */
export type UserTier = 'free' | 'basic' | 'premium';

/**
 * 权限服务接口
 */
export interface EntitlementService {
  /**
   * 查询用户是否有权访问指定功能
   * 
   * @param featureId - 功能标识符，格式：'feature:<kebab-case-name>'
   *                    示例：'feature:advanced-playback', 'feature:cloud-sync'
   * @returns Promise<boolean> - true 表示有权访问，false 表示无权访问
   * 
   * 使用场景：
   * - 条件渲染（Hide Pattern）：不显示用户无权访问的功能
   * - 功能启用/禁用（Disable Pattern）：显示但禁用无权访问的功能，引导升级
   * 
   * 性能要求：
   * - v1.x LocalFree 实现：< 1ms (同步返回)
   * - v2.0 Auth 实现：< 100ms (含缓存)
   */
  hasFeature(featureId: string): Promise<boolean>;

  /**
   * 查询用户是否有权访问指定内容
   * 
   * @param contentId - 内容标识符（如视频ID、剧集ID）
   * @param contentType - 内容类型（如 'video', 'series', 'live'）
   * @returns Promise<boolean> - true 表示有权访问，false 表示无权访问
   * 
   * 使用场景：
   * - 付费内容门控：检查用户是否购买或订阅了特定内容
   * - 地域限制内容：检查用户地区是否可访问（v2.0）
   * 
   * v1.x 行为：全部返回 true（所有内容免费）
   */
  canAccessContent(contentId: string, contentType: string): Promise<boolean>;

  /**
   * 获取用户当前订阅等级
   * 
   * @returns Promise<UserTier> - 用户订阅等级
   * 
   * 使用场景：
   * - 分级功能逻辑：根据订阅等级提供不同功能集
   * - UI 个性化：显示订阅状态徽章、升级提示
   * - 分析统计：记录用户等级分布
   * 
   * v1.x 行为：固定返回 'free'
   * v2.0 行为：从认证服务查询用户实际订阅等级
   */
  getUserTier(): Promise<UserTier>;
}
