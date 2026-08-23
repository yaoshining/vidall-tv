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
import { AccountModel } from '../../../stores/account/AccountModel';

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
  @Local accountModel: AccountModel = AccountModel.getInstance()
  @Local private avatarLoadFailed: boolean = false

  aboutToAppear(): void {
    this.loadSubtitlePreference()
    this.loadCacheSize()
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

  private showLoginDialog(): void {
    console.info('[HomeSettingBuilder] 打开登录弹层')
    this.accountModel.showLoginDialog()
  }

  private showLogoutConfirm(): void {
    this.accountModel.showLogoutConfirm()
  }

  private getAccountDisplayName(): string {
    return this.accountModel.displayName.length > 0 ? this.accountModel.displayName : '华为用户'
  }

  @Builder
  private accountAvatarBuilder() {
    if (this.accountModel.avatarUri.length > 0 && !this.avatarLoadFailed) {
      Image(this.accountModel.avatarUri)
        .width(34)
        .height(34)
        .borderRadius(17)
        .objectFit(ImageFit.Cover)
        .clip(true)
        .onError(() => {
          this.avatarLoadFailed = true
        })
    } else {
      Text('华')
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .backgroundColor('#C9272C')
        .borderRadius(17)
    }
  }

  build() {
    SettingContainer({
      title: "配置"
    }) {
      SettingListItemGroup({
        title: "账号"
      }) {
        if (this.accountModel.isLogged) {
          SettingListItem({
            title: this.getAccountDisplayName(),
            value: '华为账号',
            interactive: false,
            iconBuilder: () => { this.accountAvatarBuilder() }
          })
          SettingListItem({
            value: "全平台可用",
            interactive: false,
            titleBuilder: vipTitleBuilder
          })
          SettingListItem({
            title: "退出登录",
            isLink: true,
            onItemClick: () => { this.showLogoutConfirm() }
          })
        } else {
          SettingListItem({
            title: '登录',
            value: '同步账号与跨设备体验',
            isLink: true,
            onItemClick: () => {
              this.showLoginDialog()
            },
            onRightIconClick: () => {
              this.showLoginDialog()
            }
          })
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
