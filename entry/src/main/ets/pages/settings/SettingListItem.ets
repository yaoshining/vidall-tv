@ComponentV2
export struct SettingListItem {
  @Param title: string = ''
  @Param value: string = ''
  @Param isLink: boolean = false
  @Param onItemClick: () => void = () => {}
  @BuilderParam titleBuilder?: () => void

  build() {
    ListItem() {
      Row() {
        if (this.titleBuilder) {
          this.titleBuilder()
        } else {
          Text(this.title)
            .fontSize($r("app.float.font_subtitle_1"))
        }
        Row() {
          if (this.value) {
            Text(this.value)
          }
          if (this.isLink) {
            Image($r("sys.media.ohos_ic_public_arrow_right"))
              .width(20)
              .height(20)
              .fillColor(Color.Gray)
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