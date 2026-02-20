/**
 * 带取消功能的防抖函数类
 */
export class CancellableFunction {
  private func: (arg: string) => void;
  private delay: number;
  private timeoutId: number | undefined = undefined;

  constructor(func: (arg: string) => void, delay: number) {
    this.func = func;
    this.delay = delay;
  }

  /**
   * 执行函数
   */
  call(arg: string): void {
    // 清除之前的定时器
    if (this.timeoutId !== undefined) {
      clearTimeout(this.timeoutId);
    }

    // 设置新的定时器
    this.timeoutId = setTimeout(() => {
      this.func(arg);
      this.timeoutId = undefined;
    }, this.delay);
  }

  /**
   * 取消待执行的函数
   */
  cancel(): void {
    if (this.timeoutId !== undefined) {
      clearTimeout(this.timeoutId);
      this.timeoutId = undefined;
    }
  }
}

/**
 * 防抖工具类
 * 用于延迟执行函数，避免频繁触发
 */
export class DebounceUtil {
  /**
   * 创建防抖函数
   * @param func 需要防抖的函数
   * @param delay 延迟时间（毫秒），默认 300ms
   * @returns 返回带 cancel 方法的防抖函数
   */
  static debounce(
    func: (arg: string) => void,
    delay: number = 300
  ): CancellableFunction {
    return new CancellableFunction(func, delay);
  }
}



