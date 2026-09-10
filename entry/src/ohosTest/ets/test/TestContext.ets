import { common } from '@kit.AbilityKit';

/** RDB 需要携带模块信息的 UIAbilityContext，不能使用 Delegator 的 ApplicationContext。 */
export class TestContext {
  static current: common.UIAbilityContext | null = null;

  static require(): common.UIAbilityContext {
    if (TestContext.current === null) { throw new Error('TestAbilityContext 尚未初始化'); }
    return TestContext.current;
  }
}
