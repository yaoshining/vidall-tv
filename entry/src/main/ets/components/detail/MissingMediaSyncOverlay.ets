@ComponentV2
export struct MissingMediaSyncOverlay {
  @Param visible: boolean = false;
  @Param checked: number = 0;
  @Param total: number = 0;

  build() {
    if (this.visible) {
      Column({ space: 18 }) {
        LoadingProgress()
          .width(52)
          .height(52)
          .color('#5CA8FF')
        Text('正在同步信息')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
        Text(`已检查 ${this.checked}/${this.total}`)
          .fontSize(16)
          .fontColor('#B8C0CC')
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
      .height('100%')
      .backgroundColor('#CC090C12')
      .focusable(true)
      .zIndex(100)
    }
  }
}
