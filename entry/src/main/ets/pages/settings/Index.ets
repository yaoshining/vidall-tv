import { AddFileSourceBuilder } from "./builders/AddFileSourceBuilder"
import { FileSourceSettingBuilder } from "./builders/FileSourceSettingBuilder"
import { HomeSettingBuilder } from "./builders/HomeSettingBuilder"
import { ResourceLibrarySettingBuilder } from "./builders/ResourceLibrarySettingBuilder"
import { VideoServerSettingBuilder } from "./builders/VideoServerSettingBuilder"
import { WebDAVConfigBuilder } from "./builders/WebDAVConfigBuilder"
import { SettingsController } from "./SettingsController"
import SettingType from "./SettingType"

export interface SettingsPageParam {
  type: SettingType
}

@ComponentV2
export struct SettingsPage {
  static PAGE_NAME = 'settings'
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  @Local menuVisible: boolean = false
  @Provider('settingsController') controller: SettingsController = new SettingsController()

  /**
   * 处理返回操作
   */
  handleBack(): void {
    // 如果有历史记录，返回上一个菜单
    if (this.controller.canGoBack()) {
      this.controller.popType()
    } else {
      // 否则关闭设置页面
      this.pageStack.pop()
    }
  }

  build() {
    NavDestination() {
      RelativeContainer() {
        Scroll() {
          Column() {
            if (this.controller.type === SettingType.HOME) {
              HomeSettingBuilder()
            }
            if (this.controller.type === SettingType.FILE_SOURCE) {
              FileSourceSettingBuilder(this.controller)
            }
            if (this.controller.type === SettingType.ADD_FILE_SOURCE) {
              AddFileSourceBuilder()
            }
            if (this.controller.type === SettingType.WEBDAV_CONFIG) {
              WebDAVConfigBuilder()
            }
            if (this.controller.type === SettingType.VIDEO_SERVER) {
              VideoServerSettingBuilder()
            }
            if (this.controller.type === SettingType.RESOURCE_LIBRARY) {
              ResourceLibrarySettingBuilder()
            }
          }
        }
        .id("settingMenu")
        .scrollBar(BarState.Off)
        .width("35%")
        .height("100%")
        .alignRules({
          top: { anchor: '__container__', align: VerticalAlign.Top },
          left: { anchor: '__container__', align: HorizontalAlign.Start }
        })
        .translate({
          x: this.menuVisible ? 0 : -400
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
        this.pageStack.pop(true)
      })
      .backgroundColor('#88000000')
    }
    .onReady((context) => {
      const param = context.pathInfo.param as SettingsPageParam
      if (param) {
        this.controller.reset(param.type)
      }
      // 触发首次滑入动画
      setTimeout(() => {
        this.menuVisible = true
      }, 50)
    })
    .onBackPressed(() => {
      this.handleBack()
      return true // 阻止默认返回行为
    })
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.FADE)
    .mode(NavDestinationMode.DIALOG)
  }
}