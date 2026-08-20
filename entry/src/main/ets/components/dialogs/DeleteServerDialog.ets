/**
 * 共享删除影视服务器确认弹窗。
 * 供 VideoServerTab / VideoServerSettingBuilder 复用，消除行为分歧。
 */

@ComponentV2
export struct DeleteServerDialog {
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
          Text('删除影视服务器')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 12 })
          Text('确认删除该影视服务器？此操作仅移除服务器配置，不影响其他数据。')
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
      .onClick(() => {})
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
  }
}