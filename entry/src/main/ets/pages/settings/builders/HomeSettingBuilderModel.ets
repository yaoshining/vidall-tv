import { SettingsController } from "../SettingsController"
import SettingType from "../SettingType"

export function buildSubtitleLanguagePreferenceEntryValue(subtitleLanguageSummary: string,
  isSubtitleLanguageSummaryLoaded: boolean): string {
  return isSubtitleLanguageSummaryLoaded ? subtitleLanguageSummary : "正在加载…"
}

export function navigateToSubtitleLanguagePreference(controller: SettingsController): void {
  controller.pushType(SettingType.SUBTITLE_LANGUAGE_PREFERENCE)
}
