import { HomeMenuBuilder } from "./menus/HomeMenu"

@ComponentV2
export struct SettingsPage {
  static PAGE_NAME = 'settings'
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  @Local menuVisible: boolean = false

  aboutToAppear(): void {
    // Trigger animation after component appears
    setTimeout(() => {
      this.menuVisible = true
    }, 50)
  }

  build() {
    NavDestination() {
      RelativeContainer() {
        Scroll() {
          Column() {
            Row() {
              Text("设置")
                .fontSize($r("app.float.font_subtitle_1"))
            }
            .padding({
              top: 20,
              bottom: 20
            })
            .justifyContent(FlexAlign.Center)

            //TODO: 账号列表组，带标题，每个列表项左右两边布局，有可以点击进入的图标引道，就是左边是属性名，右边是属性值，最后面如果可以点就就有一个图标显示一下
            List({ space: 20 }) {
              HomeMenuBuilder()
            }
            .width("100%")
            .height("100%")
            .backgroundColor("#222222")
            //TODO: 网络列表组
            //TODO: 通用列表组
          }
          .id("menuContainer")
          .onClick((event) => {
            try {
              event.preventDefault()
            } catch (error) {
              // TODO: Implement error handling.
            }
          })
          .translate({
            x: this.menuVisible ? 0 : -300
          })
          .backgroundColor("#222222")
          .width("35%")
          .shadow({
            radius: 16,
            offsetX: 1,
            offsetY: 1,
            color: "#222222"
          })
          .animation({
            duration: 300,
            curve: Curve.EaseOut
          })
          .padding({
            left: 10,
            right: 10
          })
        }
        .scrollBar(BarState.Off)
        .height("100%")
      }
      .width("100%")
      .height("100%")
      .padding(20)
      .onClick(() => {
        this.pageStack.pop()
      })
      .backgroundColor('#88000000')
    }
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.FADE)
    .mode(NavDestinationMode.DIALOG)
  }
}