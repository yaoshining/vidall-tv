import { SettingListItem } from "../SettingListItem";
import { SettingListItemGroup } from "../SettingListItemGroup";
import { SettingContainer } from "../SettingContainer";
import { SettingsController } from "../SettingsController";
import SettingType from "../SettingType";
import { OpenSubtitlesConfigBuilder } from "./OpenSubtitlesConfigBuilder";
import {
  buildSubtitleLanguagePreferenceSummary,
  DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE,
  loadSubtitleLanguagePreference
} from "../../../subtitle/SubtitleLanguagePreference";
import {
  buildSubtitleLanguagePreferenceEntryValue,
  navigateToSubtitleLanguagePreference
} from "./HomeSettingBuilderModel";
import { SubtitleCacheManager, formatCacheSize } from '../../../subtitle/SubtitleCacheManager';
import { LoginWithHuaweiIDButton, loginComponentManager } from '@kit.AccountKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AccountService } from '../../../services/account/AccountService';
import { HuaweiAuthProvider } from '../../../services/account/providers/HuaweiAuthProvider';
import { AppPreferences } from '../../../utils/AppPreferences';

@Builder
function vipTitleBuilder() {
  Text("VidAll")
    .fontSize($r("app.float.font_subtitle_1"))
    .fontWeight(FontWeight.Bold)

  Column() {
    Text("Pro")
      .fontSize($r("app.float.font_subtitle_2"))
      .fontWeight(FontWeight.Bold)
  }
  .backgroundColor("#ffa56e03")
  .padding({ top: 2, bottom: 2, left: 10, right: 10 })
  .borderRadius("30%")
}

@ComponentV2
struct HomeSettingBuilderComponent {
  @Consumer('settingsController') controller: SettingsController = new SettingsController()
  @Local subtitleLanguageSummary: string = buildSubtitleLanguagePreferenceSummary(DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE)
  @Local isSubtitleLanguageSummaryLoaded: boolean = false
  @Local private isClearingCache: boolean = false
  @Local private cacheSizeText: string = ''
  @Local private isLogged: boolean = false

  aboutToAppear(): void {
    this.loadSubtitlePreference()
    this.loadCacheSize()
    this.initAccount()
  }

  private async loadSubtitlePreference(): Promise<void> {
    try {
      const preference = await loadSubtitleLanguagePreference()
      this.subtitleLanguageSummary = buildSubtitleLanguagePreferenceSummary(preference)
      this.isSubtitleLanguageSummaryLoaded = true
    } catch {
      this.subtitleLanguageSummary = buildSubtitleLanguagePreferenceSummary(DEFAULT_SUBTITLE_LANGUAGE_PREFERENCE)
      this.isSubtitleLanguageSummaryLoaded = true
    }
  }

  private async loadCacheSize(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext()
      if (context) {
        const filesDir = context.filesDir
        const bytes = await new SubtitleCacheManager().getTotalCacheSizeBytes(filesDir)
        this.cacheSizeText = formatCacheSize(bytes)
      }
    } catch {
      this.cacheSizeText = ''
    }
  }

  private showCacheClearConfirm(): void {
    this.getUIContext().showAlertDialog({
      title: '清理字幕缓存',
      message: '将清空所有已下载的字幕缓存，此操作不可恢复。',
      primaryButton: {
        value: '确认清理',
        action: () => { this.doClearCache() }
      },
      secondaryButton: {
        value: '取消',
        action: () => {}
      }
    })
  }

  private doClearCache(): void {
    if (this.isClearingCache) { return }
    this.isClearingCache = true
    const context = this.getUIContext().getHostContext()
    if (!context) {
      this.isClearingCache = false
      return
    }
    const filesDir = context.filesDir
    const mgr = new SubtitleCacheManager()
    mgr.clearAllSubtitleCaches(filesDir).then(() => {
      this.isClearingCache = false
      this.cacheSizeText = formatCacheSize(0)
      this.showToast('字幕缓存已清理')
    }).catch(() => {
      this.isClearingCache = false
      this.showToast('清理失败，请重试')
    })
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration: 2000 })
    } catch {
      console.warn(`[HomeSettingBuilder] toast failed: ${message}`)
    }
  }

  private async initAccount(): Promise<void> {
    try {
      this.isLogged = await AppPreferences.isLogged()
    } catch {
      this.isLogged = false
    }
    if (!this.isLogged) {
      this.armHuaweiLogin()
    }
  }

  private armHuaweiLogin(): void {
    AccountService.getInstance().loginWith('huawei')
      .then(async () => {
        this.isLogged = await AppPreferences.isLogged()
      })
      .catch((e: BusinessError) => {
        if (e.code === 1001502012) {
          this.armHuaweiLogin()
        } else {
          this.showToast('华为登录失败：' + (e.message ?? ''))
        }
      })
  }

  private doLogout(): void {
    AccountService.getInstance().logout()
      .then(async () => {
        this.isLogged = await AppPreferences.isLogged()
        this.showToast('已退出登录')
        if (!this.isLogged) {
          this.armHuaweiLogin()
        }
      })
      .catch(() => {
        this.showToast('退出登录失败')
      })
  }

  private getHuaweiController(): loginComponentManager.LoginWithHuaweiIDButtonController {
    const p = AccountService.getInstance().getProvider('huawei')
    if (p instanceof HuaweiAuthProvider) {
      return p.getController()
    }
    return new loginComponentManager.LoginWithHuaweiIDButtonController()
  }

  @Builder
  private huaweiLoginButton() {
    ListItem() {
      LoginWithHuaweiIDButton({
        params: {
          style: loginComponentManager.Style.BUTTON_RED,
          borderRadius: 24,
          supportDarkMode: true
        },
        controller: this.getHuaweiController()
      })
    }
    .width('100%')
    .height(50)
    .borderRadius(8)
    .backgroundColor('#333333')
    .padding({ left: 12, right: 12 })
  }

  build() {
    SettingContainer({
      title: "配置"
    }) {
      SettingListItemGroup({
        title: "账号"
      }) {
        if (this.isLogged) {
          SettingListItem({
            value: "全平台可用",
            titleBuilder: vipTitleBuilder
          })
          SettingListItem({
            title: "退出登录",
            isLink: true,
            onItemClick: () => { this.doLogout() }
          })
        } else {
          this.huaweiLoginButton()
        }
      }

      SettingListItemGroup({
        title: "网络"
      }) {
        SettingListItem({
          title: "文件源",
          isLink: true,
          onItemClick: () => {
            this.controller.pushType(SettingType.FILE_SOURCE)
          },
        })
        SettingListItem({
          title: "影视服务器",
          isLink: true,
          onItemClick: () => {
            this.controller.pushType(SettingType.VIDEO_SERVER)
          },
        })
        SettingListItem({
          title: "资源库",
          isLink: true,
          onItemClick: () => {
            this.controller.pushType(SettingType.RESOURCE_LIBRARY)
          },
        })
      }

      SettingListItemGroup({
        title: "字幕"
      }) {
        SettingListItem({
          title: "字幕语言偏好",
          value: buildSubtitleLanguagePreferenceEntryValue(
            this.subtitleLanguageSummary,
            this.isSubtitleLanguageSummaryLoaded
          ),
          isLink: true,
          onItemClick: () => {
            navigateToSubtitleLanguagePreference(this.controller)
          },
          onRightIconClick: () => {
            navigateToSubtitleLanguagePreference(this.controller)
          }
        })
        SettingListItem({
          title: '清理字幕缓存',
          value: this.cacheSizeText,
          onItemClick: () => { this.showCacheClearConfirm() }
        })
      }

      OpenSubtitlesConfigBuilder()

      SettingListItemGroup({
        title: "通用"
      }) {
        SettingListItem({
          title: "Trakt",
          value: "连接到Trakt",
          isLink: true
        })
        SettingListItem({
          title: "隐藏剧透",
          value: "关闭"
        })
        SettingListItem({
          title: "显示媒体库顶部分类栏",
          value: "开启"
        })
        SettingListItem({
          title: "媒体排序方式",
          value: "↓添加日期",
          isLink: true
        })
      }
    }
  }
}

@Builder
export function HomeSettingBuilder() {
  HomeSettingBuilderComponent()
}
