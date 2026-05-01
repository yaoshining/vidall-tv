import { hilog } from '@kit.PerformanceAnalysisKit';
import { EntitlementService, UserTier } from './EntitlementService';

const DOMAIN = 0x0001;
const TAG = 'LocalFreeEntitlementService';

/**
 * LocalFreeEntitlementService - "全功能免费" 权限服务实现
 * 
 * v1.x 默认实现，维持当前产品行为：
 * - 所有功能对所有用户开放
 * - 所有内容无访问限制
 * - 用户等级固定为 'free'
 * 
 * 设计特点：
 * 1. **零网络开销**：所有方法立即同步返回，无 I/O 操作
 * 2. **零配置**：无需初始化参数，开箱即用
 * 3. **Fail-Open 策略**：即使发生异常也返回 true，避免阻塞用户
 * 4. **性能优化**：< 1ms 响应时间，适合高频调用场景
 * 
 * 使用场景：
 * - v1.x 生产环境默认服务
 * - 开发/测试环境功能全开模式
 * - v2.0 降级方案（认证服务不可用时回退）
 * 
 * 迁移到 v2.0：
 * 仅需在 EntryAbility.onCreate() 中替换服务注册：
 * ```typescript
 * // v1.x
 * ServiceLocator.register('entitlement', new LocalFreeEntitlementService());
 * 
 * // v2.0
 * ServiceLocator.register('entitlement', new AuthEntitlementService(config));
 * ```
 * 
 * @see EntitlementService - 接口定义
 * @see docs/entitlement-integration.md - 集成指南
 */
export class LocalFreeEntitlementService implements EntitlementService {
  
  /**
   * 构造函数
   * 
   * 无需参数，服务即刻可用
   */
  constructor() {
    hilog.info(DOMAIN, TAG, 'LocalFreeEntitlementService initialized (all features enabled)');
  }

  /**
   * 查询用户是否有权访问指定功能
   * 
   * v1.x 行为：固定返回 true
   * 
   * @param featureId - 功能标识符（未使用，保持接口一致性）
   * @returns Promise<true> - 永远允许访问
   */
  async hasFeature(featureId: string): Promise<boolean> {
    try {
      // v1.x 策略：所有功能对所有用户开放
      // 参数 featureId 未使用，但保留用于接口一致性和日志记录
      hilog.debug(DOMAIN, TAG, `hasFeature(${featureId}) -> true (local-free mode)`);
      return Promise.resolve(true);
    } catch (error) {
      // Fail-open 策略：异常情况下仍然返回 true，避免阻塞用户
      hilog.error(DOMAIN, TAG, `hasFeature(${featureId}) error: ${JSON.stringify(error)}, returning true (fail-open)`);
      return Promise.resolve(true);
    }
  }

  /**
   * 查询用户是否有权访问指定内容
   * 
   * v1.x 行为：固定返回 true
   * 
   * @param contentId - 内容标识符（未使用）
   * @param contentType - 内容类型（未使用）
   * @returns Promise<true> - 永远允许访问
   */
  async canAccessContent(contentId: string, contentType: string): Promise<boolean> {
    try {
      // v1.x 策略：所有内容无访问限制
      hilog.debug(DOMAIN, TAG, `canAccessContent(${contentId}, ${contentType}) -> true (local-free mode)`);
      return Promise.resolve(true);
    } catch (error) {
      // Fail-open 策略
      hilog.error(DOMAIN, TAG, `canAccessContent(${contentId}, ${contentType}) error: ${JSON.stringify(error)}, returning true (fail-open)`);
      return Promise.resolve(true);
    }
  }

  /**
   * 获取用户当前订阅等级
   * 
   * v1.x 行为：固定返回 'free'
   * 
   * @returns Promise<'free'> - 用户等级固定为 free
   */
  async getUserTier(): Promise<UserTier> {
    try {
      // v1.x 策略：所有用户为免费等级
      hilog.debug(DOMAIN, TAG, 'getUserTier() -> free (local-free mode)');
      return Promise.resolve('free');
    } catch (error) {
      // 即使异常也返回 free，保持一致性
      hilog.error(DOMAIN, TAG, `getUserTier() error: ${JSON.stringify(error)}, returning 'free' (fail-open)`);
      return Promise.resolve('free');
    }
  }
}
