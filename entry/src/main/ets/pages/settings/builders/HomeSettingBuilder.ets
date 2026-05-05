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

  aboutToAppear(): void {
    this.loadSubtitlePreference()
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

  build() {
    SettingContainer({
      title: "配置"
    }) {
      SettingListItemGroup({
        title: "账号"
      }) {
        SettingListItem({
          value: "全平台可用",
          titleBuilder: vipTitleBuilder
        })
        SettingListItem({
          title: "退出登录",
          isLink: true,
        })
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
