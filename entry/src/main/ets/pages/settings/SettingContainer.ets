import { SettingsController } from "./SettingsController"

@ComponentV2
export struct SettingContainer {
  @Param title: string = "设置"
  @Consumer('settingsController') controller: SettingsController = new SettingsController()
  @BuilderParam menuBuilder: () => void
  @Local menuVisible: boolean = false

  aboutToAppear(): void {
    // Trigger animation after component appears
    setTimeout(() => {
      this.menuVisible = true
    }, 50)
  }

  build() {
    Column() {
      Row() {
        Text(this.title)
          .fontSize($r("app.float.font_subtitle_1"))
      }
      .padding({
        top: 20,
        bottom: 20
      })
      .justifyContent(FlexAlign.Center)

      List({ space: 20 }) {
        this.menuBuilder()
      }
      .width("100%")
      .height("100%")
      .backgroundColor("#222222")
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
}