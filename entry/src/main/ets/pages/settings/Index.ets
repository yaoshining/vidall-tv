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
        Column() {
          Button("Close").onClick((event: ClickEvent) => {
            this.pageStack.pop()
          })
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
        .height("100%")
        .shadow({
          radius: 16,
          offsetX: 0,
          color: "#222222"
        })
        .animation({
          duration: 300,
          curve: Curve.EaseOut
        })
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