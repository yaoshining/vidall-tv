/** 文件浏览器的电视端提示状态；重复操作延长显示，不叠加弹窗。 */
@ObservedV2
export class FileExplorerToastState {
  @Trace message: string = '';
  private timer: number = -1;

  show(message: string): void {
    this.clear();
    this.message = message;
    this.timer = setTimeout(() => {
      this.message = '';
      this.timer = -1;
    }, 4000);
  }

  clear(): void {
    if (this.timer !== -1) { clearTimeout(this.timer); }
    this.timer = -1;
    this.message = '';
  }
}

@ComponentV2
export struct FileExplorerToast {
  @Param @Require state: FileExplorerToastState;

  aboutToDisappear(): void { this.state.clear(); }

  build() {
    if (this.state.message.length > 0) {
      Row({ space: 16 }) {
        Text('i').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#6AA7FF')
          .width(30).height(30).textAlign(TextAlign.Center)
          .borderRadius(15).border({ width: 1.5, color: '#6AA7FF' })
        Text(this.state.message).fontSize(22).fontWeight(FontWeight.Medium)
          .fontColor('#F0F2F5').layoutWeight(1)
      }
      .width(460).constraintSize({ minHeight: 80 })
      .padding({ left: 22, right: 22, top: 20, bottom: 20 })
      .backgroundColor('#292C31').borderRadius(14)
      .border({ width: 1, color: '#4B5058' })
      .shadow({ radius: 16, color: '#50000000', offsetY: 6 })
      .hitTestBehavior(HitTestMode.None)
      .focusable(false)
    }
  }
}
