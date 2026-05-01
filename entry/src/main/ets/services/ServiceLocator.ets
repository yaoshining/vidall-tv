import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0002;
const TAG = 'ServiceLocator';

/**
 * ServiceLocator - 简单的依赖注入容器
 * 
 * 提供全局服务注册与检索功能，支持：
 * - 类型安全的服务注册和检索
 * - 单例模式（同一服务名返回同一实例）
 * - 运行时服务替换（用于测试 mock）
 * 
 * 使用示例：
 * ```typescript
 * // 1. 在应用启动时注册服务 (EntryAbility.onCreate)
 * ServiceLocator.register('entitlement', new LocalFreeEntitlementService());
 * 
 * // 2. 在组件中获取服务
 * const service = ServiceLocator.get<EntitlementService>('entitlement');
 * const hasAccess = await service.hasFeature('feature:advanced-playback');
 * 
 * // 3. 在测试中替换为 mock 服务
 * ServiceLocator.register('entitlement', mockService);
 * ```
 * 
 * 设计说明：
 * - 静态类设计，全局单例容器
 * - 不支持层级容器或作用域，保持简单
 * - 服务生命周期由注册方管理
 * 
 * @see EntitlementService - 典型使用场景
 */
export class ServiceLocator {
  /**
   * 服务注册表
   * key: 服务名称（字符串）
   * value: 服务实例（object 类型，通过泛型在使用时保证类型安全）
   */
  private static services: Map<string, object> = new Map();

  /**
   * 注册服务
   * 
   * @param name - 服务名称（唯一标识符）
   * @param service - 服务实例
   * 
   * 注意：
   * - 重复注册同名服务会覆盖原服务（用于测试 mock）
   * - 服务名称建议使用 kebab-case（如 'entitlement', 'user-profile'）
   */
  static register<T extends object>(name: string, service: T): void {
    if (ServiceLocator.services.has(name)) {
      hilog.warn(DOMAIN, TAG, `Service '${name}' already registered, will be replaced`);
    }
    
    ServiceLocator.services.set(name, service);
    hilog.info(DOMAIN, TAG, `Service '${name}' registered successfully`);
  }

  /**
   * 获取服务
   * 
   * @param name - 服务名称
   * @returns 服务实例
   * @throws Error - 如果服务未注册
   * 
   * 类型安全：
   * 使用泛型指定返回类型，编译时类型检查：
   * ```typescript
   * const service = ServiceLocator.get<EntitlementService>('entitlement');
   * // service 类型为 EntitlementService
   * ```
   */
  static get<T>(name: string): T {
    const service = ServiceLocator.services.get(name);
    
    if (service === undefined) {
      const errorMsg = `Service '${name}' not found. Did you forget to register it in EntryAbility.onCreate()?`;
      hilog.error(DOMAIN, TAG, errorMsg);
      throw new Error(errorMsg);
    }
    
    hilog.debug(DOMAIN, TAG, `Service '${name}' retrieved`);
    return service as T;
  }

  /**
   * 检查服务是否已注册
   * 
   * @param name - 服务名称
   * @returns true 如果服务已注册，否则 false
   */
  static has(name: string): boolean {
    return ServiceLocator.services.has(name);
  }

  /**
   * 重置服务注册表
   * 
   * 清空所有已注册服务，主要用于测试场景。
   * 
   * ⚠️ 警告：生产代码不应调用此方法
   */
  static reset(): void {
    const count = ServiceLocator.services.size;
    ServiceLocator.services.clear();
    hilog.info(DOMAIN, TAG, `ServiceLocator reset, ${count} services cleared`);
  }

  /**
   * 获取所有已注册服务名称（调试用）
   * 
   * @returns 服务名称列表
   */
  static getRegisteredServiceNames(): string[] {
    return Array.from(ServiceLocator.services.keys());
  }
}
