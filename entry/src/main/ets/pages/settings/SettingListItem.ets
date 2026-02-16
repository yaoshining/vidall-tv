@ComponentV2
export struct SettingListItem {
  @Param title: string = ''
  @Param value: string = ''
  @Param isLink: boolean = false
  @Param onItemClick: () => void = () => {}
  @BuilderParam iconBuilder?: () => void

  build() {
    ListItem() {
      Row() {
        Row({ space: 6 }) {
          // 插入自定义图标
          if (this.iconBuilder) {
            this.iconBuilder()
          }
          Text(this.title)
            .fontSize($r("app.float.font_subtitle_1"))
        }
        .alignItems(VerticalAlign.Center)

        Row() {
          if (this.value) {
            Text(this.value)
          }
          if (this.isLink) {
            Text("›")
              .fontSize(24)
              .fontColor(Color.Gray)
          }
        }
        .justifyContent(FlexAlign.End)
      }
      .width("100%")
      .height("100%")
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)
    }
    .padding({
      left: 16,
      right: 16
    })
    .hoverEffect(HoverEffect.Highlight)
    .height(50)
    .borderRadius(8)
    .backgroundColor("#333333")
    .onClick(() => {
      if (this.onItemClick) {
        this.onItemClick()
      }
    })
  }
}