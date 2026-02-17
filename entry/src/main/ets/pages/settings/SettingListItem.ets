/**
 * 菜单项接口
 */
export interface MenuItem {
  value: string
  action: () => void
}

@ComponentV2
export struct SettingListItem {
  @Param title: string = ''
  @Param value: string = ''
  @Param isLink: boolean = false
  @Param onItemClick: () => void = () => {}
  @Param onRightIconClick: () => void = () => {}
  @Param menuItems: Array<MenuItem> = []
  @BuilderParam icon?: () => void
  @BuilderParam iconBuilder?: () => void
  @BuilderParam titleBuilder?: () => void
  @BuilderParam rightIcon?: () => void

  build() {
    ListItem() {
      Row() {
        Row({ space: 12 }) {
          // 插入自定义图标
          if (this.icon) {
            this.icon()
          } else if (this.iconBuilder) {
            this.iconBuilder()
          }
          if (this.titleBuilder) {
            this.titleBuilder()
          } else {
            Text(this.title)
              .fontSize($r("app.float.font_subtitle_1"))
          }
        }
        .alignItems(VerticalAlign.Center)

        Row({ space: 4 }) {
          if (this.value) {
            Text(this.value)
              .fontSize($r("app.float.font_subtitle_1"))
              .fontColor($r('sys.color.font_secondary'))
          }
          if (this.rightIcon) {
            this.rightIcon()
          } else if (this.isLink) {
            Text("›")
              .fontSize(24)
              .fontColor(Color.Gray)
          }
        }
        .justifyContent(FlexAlign.End)
        .bindMenu(this.menuItems.length > 0 ? this.menuItems : [])
        .onClick(() => {
          if (this.menuItems.length === 0) {
            this.onRightIconClick()
          }
        })
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
      this.onItemClick()
    })
  }
}