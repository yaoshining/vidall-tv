@ComponentV2
export struct SettingsPage {
  static PAGE_NAME = 'settings'
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()

  build() {
    NavDestination() {
      RelativeContainer() {
        Column() {
          Button("Close").onClick((event: ClickEvent) => {
            this.pageStack.pop()
          })
        }
        .onClick((event) => {
          try {
            event.preventDefault()
          } catch (error) {
            // TODO: Implement error handling.
          }
        })
        .backgroundColor("#282828")
        .width("35%")
        .height("100%")
      }
      .width("100%")
      .height("100%")
      .onClick(() => {
        this.pageStack.pop()
      })
      .backgroundColor('#4d000000')
    }
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.FADE)
    .mode(NavDestinationMode.DIALOG)
  }
}