import SettingType from "./SettingType";

@ObservedV2
export class SettingsController {
  @Trace title: string = "设置"
  @Trace type: SettingType = SettingType.HOME
  @Trace params: Record<string, Object> | undefined = undefined
  private typeStack: SettingType[] = []
  private paramsStack: (Record<string, Object> | undefined)[] = []

  // 自定义返回处理器
  private customBackHandler: (() => boolean) | null = null

  /**
   * 设置自定义返回处理器
   * @param handler 返回处理函数，返回 true 表示已处理，false 表示使用默认行为
   */
  setBackHandler(handler: (() => boolean) | null): void {
    this.customBackHandler = handler
  }

  /**
   * 处理返回操作
   * @returns true 表示已处理，false 表示使用默认行为
   */
  handleBack(): boolean {
    // 先尝试自定义处理器
    if (this.customBackHandler) {
      const handled = this.customBackHandler()
      if (handled) {
        return true
      }
    }
    // 默认行为：从堆栈弹出
    return this.popType()
  }

  /**
   * 推入新的设置类型到堆栈
   * @param newType 新的设置类型
   * @param params 可选的参数对象
   */
  pushType(newType: SettingType, params?: Record<string, Object>): void {
    // 将当前类型和参数压入堆栈
    this.typeStack.push(this.type)
    this.paramsStack.push(this.params)
    // 切换到新类型和新参数
    this.type = newType
    this.params = params
  }

  /**
   * 从堆栈弹出上一个设置类型
   * @returns 是否成功弹出（false 表示已经是根菜单）
   */
  popType(): boolean {
    if (this.typeStack.length > 0) {
      // 从堆栈中取出上一个类型和参数
      const previousType = this.typeStack.pop()
      const previousParams = this.paramsStack.pop()
      if (previousType) {
        this.type = previousType
        this.params = previousParams
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
    this.paramsStack = []
    this.params = undefined
  }

  /**
   * 重置到初始状态
   * @param initialType 初始类型
   */
  reset(initialType: SettingType = SettingType.HOME): void {
    this.typeStack = []
    this.paramsStack = []
    this.type = initialType
    this.params = undefined
  }
}