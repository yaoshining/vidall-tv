import SettingType from "./SettingType";

@ObservedV2
export class SettingsController {
  @Trace title: string = "设置"
  @Trace type: SettingType = SettingType.HOME
  private typeStack: SettingType[] = []

  /**
   * 推入新的设置类型到堆栈
   * @param newType 新的设置类型
   */
  pushType(newType: SettingType): void {
    // 将当前类型压入堆栈
    this.typeStack.push(this.type)
    // 切换到新类型
    this.type = newType
  }

  /**
   * 从堆栈弹出上一个设置类型
   * @returns 是否成功弹出（false 表示已经是根菜单）
   */
  popType(): boolean {
    if (this.typeStack.length > 0) {
      // 从堆栈中取出上一个类型
      const previousType = this.typeStack.pop()
      if (previousType) {
        this.type = previousType
        return true
      }
    }
    return false
  }

  /**
   * 检查是否可以返回
   * @returns 是否有历史记录
   */
  canGoBack(): boolean {
    return this.typeStack.length > 0
  }

  /**
   * 清空堆栈
   */
  clearStack(): void {
    this.typeStack = []
  }

  /**
   * 重置到初始状态
   * @param initialType 初始类型
   */
  reset(initialType: SettingType = SettingType.HOME): void {
    this.typeStack = []
    this.type = initialType
  }
}