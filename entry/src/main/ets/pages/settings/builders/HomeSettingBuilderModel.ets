import { SettingsController } from "../SettingsController";
import SettingType from "../SettingType";

export interface HomeSettingListItemModel {
  title: string
  value: string
  isLink: boolean
  onItemClick: () => void
  onRightIconClick: () => void
}

export function buildSubtitleLanguagePreferenceEntryModel(controller: SettingsController, subtitleLanguageSummary: string,
  isSubtitleLanguageSummaryLoaded: boolean): HomeSettingListItemModel {
  const navigateToSubtitleLanguagePreference = (): void => {
    controller.pushType(SettingType.SUBTITLE_LANGUAGE_PREFERENCE)
  }

  return {
    title: "字幕语言偏好",
    value: isSubtitleLanguageSummaryLoaded ? subtitleLanguageSummary : "正在加载…",
    isLink: true,
    onItemClick: navigateToSubtitleLanguagePreference,
    onRightIconClick: navigateToSubtitleLanguagePreference
  }
}
