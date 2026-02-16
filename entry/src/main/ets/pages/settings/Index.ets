import { FileSourceSettingBuilder } from "./builders/FileSourceSettingBuilder"
import { HomeSettingBuilder } from "./builders/HomeSettingBuilder"
import { SettingsController } from "./SettingsController"
import SettingType from "./SettingType"

export interface SettingsPageParam {
  type: SettingType
}

@ComponentV2
export struct SettingsPage {
  static PAGE_NAME = 'settings'
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  // @Local menuVisible: boolean = false
  @Provider('settingsController') controller: SettingsController = new SettingsController()

  build() {
    NavDestination() {
      RelativeContainer() {
        Scroll() {
          if (this.controller.type === SettingType.HOME) {
            HomeSettingBuilder()
          }
          if (this.controller.type === SettingType.FILE_SOURCE) {
            FileSourceSettingBuilder()
          }
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
    .onReady((context) => {
      const param = context.pathInfo.param as SettingsPageParam
      if (param) {
        this.controller.type = param.type
      }
    })
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.FADE)
    .mode(NavDestinationMode.DIALOG)
  }
}