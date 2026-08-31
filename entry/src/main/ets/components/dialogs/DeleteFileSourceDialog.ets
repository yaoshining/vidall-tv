/**
 * 共享删除文件夹确认弹窗。
 * 供 FileSourceTab 首页文件源列表复用，表达「删除单个文件夹」语义。
 */

@ComponentV2
export struct DeleteFileSourceDialog {
  /** 是否显示弹窗 */
  @Param visible: boolean = false
  /** 是否正在删除中 */
  @Param isDeleting: boolean = false
  /** 取消回调 */
  @Event onCancel: () => void = () => {}
  /** 确认删除回调 */
  @Event onConfirm: () => void = () => {}

  build() {
    if (this.visible) {
      Column() {
        Column() {
          Text('删除文件夹')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 12 })
          Text('确认删除该文件夹？此操作将删除该文件夹下的扫描媒体记录及播放进度，不会影响文件源及其其他文件夹。')
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
            .textAlign(TextAlign.Start)
            .margin({ bottom: 20 })
          Row() {
            Button('取消')
              .layoutWeight(1)
              .margin({ right: 8 })
              .fontColor($r('sys.color.font_primary'))
              .backgroundColor($r('sys.color.comp_background_tertiary'))
              .enabled(!this.isDeleting)
              .onClick(() => {
                this.onCancel()
              })
            Button(this.isDeleting ? '删除中...' : '确认删除')
              .layoutWeight(1)
              .fontColor(Color.White)
              .backgroundColor('#FF4444')
              .enabled(!this.isDeleting)
              .onClick(() => {
                this.onConfirm()
              })
          }
          .width('100%')
        }
        .width(360)
        .padding(24)
        .backgroundColor($r('sys.color.comp_background_primary'))
        .borderRadius(12)
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#80000000')
      .onClick(() => {}) // 拦截蒙层点击穿透
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
  }
}
