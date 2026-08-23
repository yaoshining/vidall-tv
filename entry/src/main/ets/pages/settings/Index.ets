import { AddFileSourceBuilder } from "./builders/AddFileSourceBuilder"
import { AddVideoServerBuilder } from "./builders/AddVideoServerBuilder"
import { FileSourceSettingBuilder } from "./builders/FileSourceSettingBuilder"
import { HomeSettingBuilder } from "./builders/HomeSettingBuilder"
import { ResourceLibrarySettingBuilder } from "./builders/ResourceLibrarySettingBuilder"
import { VideoServerSettingBuilder } from "./builders/VideoServerSettingBuilder"
import { VideoServerConfigBuilder } from "./builders/VideoServerConfigBuilder"
import { WebDAVConfigBuilder } from "./builders/WebDAVConfigBuilder"
import { SMBConfigBuilder } from "./builders/SMBConfigBuilder"
import { DirectorySelectorBuilder } from "./builders/DirectorySelectorBuilder"
import { SubtitleLanguagePreferenceBuilder } from "./builders/SubtitleLanguagePreferenceBuilder"
import { SettingsController } from "./SettingsController"
import SettingType from "./SettingType"
import { UmamiAnalyticsService } from "../../services/analytics/UmamiAnalyticsService"
import { AccountModel } from "../../stores/account/AccountModel"

export interface SettingsPageParam {
  type: SettingType
  /** 直接进入某类型配置表单时透传的服务器类型（jellyfin/emby/plex） */
  serverType?: string
  /** 编辑模式下的服务器 ID */
  serverId?: number
}

@ComponentV2
export struct SettingsPage {
  static PAGE_NAME = 'settings'
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  @Local menuVisible: boolean = false
  @Local accountModel: AccountModel = AccountModel.getInstance()
  @Provider('settingsController') controller: SettingsController = new SettingsController()

  private settingsPagePath(): string {
    if (this.controller.type === SettingType.FILE_SOURCE ||
      this.controller.type === SettingType.ADD_FILE_SOURCE ||
      this.controller.type === SettingType.WEBDAV_CONFIG ||
      this.controller.type === SettingType.SMB_CONFIG ||
      this.controller.type === SettingType.DIRECTORY_SELECTOR ||
      this.controller.type === SettingType.SMB_DIRECTORY_SELECTOR ||
      this.controller.type === SettingType.VIDEO_SERVER ||
      this.controller.type === SettingType.ADD_VIDEO_SERVER ||
      this.controller.type === SettingType.JELLYFIN_CONFIG ||
      this.controller.type === SettingType.EMBY_CONFIG ||
      this.controller.type === SettingType.PLEX_CONFIG) {
      return '/settings/sources';
    }
    return '/settings/player';
  }

  aboutToAppear(): void {
    // trackPageView 在 onReady 中 controller.reset() 之后调用，确保 type 已正确设置
  }

  /**
   * 处理返回操作
   */
  handleBack(): void {
    // 使用 controller 的统一返回处理
    const handled = this.controller.handleBack()

    // 如果 controller 没有处理（返回 false），则关闭设置页面
    if (!handled) {
      this.pageStack.pop()
    }
  }

  build() {
    NavDestination() {
      Row() {
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
            if (this.controller.type === SettingType.SMB_CONFIG) {
              SMBConfigBuilder()
            }
            if (this.controller.type === SettingType.DIRECTORY_SELECTOR) {
              DirectorySelectorBuilder()
            }
            if (this.controller.type === SettingType.SMB_DIRECTORY_SELECTOR) {
              DirectorySelectorBuilder()
            }
            if (this.controller.type === SettingType.VIDEO_SERVER) {
              VideoServerSettingBuilder()
            }
            if (this.controller.type === SettingType.ADD_VIDEO_SERVER) {
              AddVideoServerBuilder()
            }
            if (this.controller.type === SettingType.JELLYFIN_CONFIG ||
              this.controller.type === SettingType.EMBY_CONFIG ||
              this.controller.type === SettingType.PLEX_CONFIG) {
              VideoServerConfigBuilder()
            }
            if (this.controller.type === SettingType.RESOURCE_LIBRARY) {
              ResourceLibrarySettingBuilder()
            }
            if (this.controller.type === SettingType.SUBTITLE_LANGUAGE_PREFERENCE) {
              SubtitleLanguagePreferenceBuilder()
            }
          }
        }
        .id("settingMenu")
        .scrollBar(BarState.Off)
        .width("35%")
        .height("100%")
        .translate({
          x: this.menuVisible ? 0 : -400
        })
        .animation({
          duration: 300,
          curve: Curve.EaseOut
        })

        Column() {
        }
        .layoutWeight(1)
        .height("100%")
        .onClick(() => {
          this.pageStack.pop(true)
        })
      }
      .width("100%")
      .height("100%")
      .padding(20)
      .backgroundColor('#88000000')
    }
    .onReady((context) => {
      const param = context.pathInfo.param as SettingsPageParam
      if (param) {
        this.controller.reset(param.type)
        // 直连编辑场景：把服务器类型/ID 透传给配置表单 builder
        if (param.serverId !== undefined) {
          const p: Record<string, Object> = {}
          if (param.serverType !== undefined) {
            p['serverType'] = param.serverType
          }
          p['serverId'] = param.serverId
          this.controller.params = p
        }
      }
      // reset 之后上报，此时 controller.type 已是正确值
      if (UmamiAnalyticsService.isInitialized()) {
        UmamiAnalyticsService.getInstance().trackPageView(this.settingsPagePath());
      }
      // 触发首次滑入动画
      setTimeout(() => {
        this.menuVisible = true
      }, 50)
    })
    .onBackPressed(() => {
      // 退出确认弹层打开时，返回键只关闭弹层，不退出设置页
      if (this.accountModel.logoutConfirmVisible) {
        this.accountModel.hideLogoutConfirm()
        return true
      }
      // 登录弹层打开时，返回键只关闭弹层，不退出设置页
      if (this.accountModel.loginDialogVisible) {
        this.accountModel.hideLoginDialog()
        return true
      }
      this.handleBack()
      return true // 阻止默认返回行为
    })
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.FADE)
    .mode(NavDestinationMode.DIALOG)
  }
}
