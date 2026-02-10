@Entry
@Component
export struct BasicClock {
  // 1. 使用 @State 装饰器，当 timeStr 变化时，UI会自动更新
  @State timeStr: string = this.getCurrentTime();

  // 2. 定时器ID (使用 number 类型)
  private timerId: number | undefined = undefined;

  // 3. 获取当前时间并格式化为字符串的函数
  private getCurrentTime(): string {
    const now = new Date();
    // 格式化为: 时:分:秒
    const hour = now.getHours().toString().padStart(2, '0');
    const minute = now.getMinutes().toString().padStart(2, '0');
    const second = now.getSeconds().toString().padStart(2, '0');
    return `${hour}:${minute}:${second}`;
  }

  // 4. 启动定时器的函数 (使用原生 setInterval)
  private startTimer() {
    if (this.timerId === undefined) {
      // 每秒（1000毫秒）更新一次时间
      this.timerId = setInterval(() => {
        // 更新 @State 变量，触发UI重绘
        this.timeStr = this.getCurrentTime();
      }, 1000);
    }
  }

  // 5. 停止定时器的函数 (使用原生 clearInterval)
  private stopTimer() {
    if (this.timerId !== undefined) {
      clearInterval(this.timerId);
      this.timerId = undefined;
    }
  }

  // 6. 生命周期：组件加载完成后启动定时器
  aboutToAppear() {
    this.startTimer();
  }

  // 7. 生命周期：组件销毁前清理定时器，防止内存泄漏
  aboutToDisappear() {
    this.stopTimer();
  }

  build() {
    Column({ space: 20 }) {
      // 8. 显示时间，文本内容绑定到 @State 变量
      Text(this.timeStr)
        .fontSize(20)
        .letterSpacing(2)

      // 9. 添加一个日期显示
      // Text(new Date().toLocaleDateString())
      //   .fontSize(16)
      //   .fontColor('#666666')
      //   .margin({ top: 8 })
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}