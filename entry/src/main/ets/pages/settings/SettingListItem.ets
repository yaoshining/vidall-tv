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
  /** 是否可交互；纯展示行设为 false，不参与遥控器焦点导航 */
  @Param interactive: boolean = true
  /** 页面初始焦点锚点（每个页面仅一处应设为 true） */
  @Param autoFocus: boolean = false
  @Param onItemClick: () => void = () => {}
  @Param onRightIconClick: () => void = () => {}
  @Param menuItems: Array<MenuItem> = []
  @Local private isRowFocused: boolean = false
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
    .height(50)
    .borderRadius(8)
    .backgroundColor(this.isRowFocused ? "#3F3F3F" : "#333333")
    .scale({ x: this.isRowFocused ? 1.02 : 1.0, y: this.isRowFocused ? 1.02 : 1.0 })
    .animation({ duration: 120, curve: Curve.EaseInOut })
    .focusable(this.interactive)
    .defaultFocus(this.autoFocus)
    .onFocus(() => { this.isRowFocused = true })
    .onBlur(() => { this.isRowFocused = false })
    .onClick(() => {
      if (!this.interactive) {
        return
      }
      this.onItemClick()
    })
  }
}