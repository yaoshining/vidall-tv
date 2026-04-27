import { describe, it, expect } from '@ohos/hypium'
import { SettingsController } from '../main/ets/pages/settings/SettingsController'
import SettingType from '../main/ets/pages/settings/SettingType'
import {
  buildSubtitleLanguagePreferenceEntryValue,
  navigateToSubtitleLanguagePreference
} from '../main/ets/pages/settings/builders/HomeSettingBuilderModel'

const LONG_SUBTITLE_LANGUAGE_SUMMARY: string =
  '简体中文（中国大陆） > 繁體中文（台灣） > English > 日本語 > 한국어 > Español > Français'

export default function homeSettingBuilderModelTest() {
  describe('HomeSettingBuilderModel', () => {
    it('首页字幕语言偏好入口右侧摘要区域点击后应进入偏好页', 0, () => {
      const controller = new SettingsController()

      navigateToSubtitleLanguagePreference(controller)

      expect(controller.type).assertEqual(SettingType.SUBTITLE_LANGUAGE_PREFERENCE)
    })

    it('首页字幕语言偏好入口长摘要文本不应影响整行与右侧区域跳转', 0, () => {
      const controller = new SettingsController()
      const loadedValue = buildSubtitleLanguagePreferenceEntryValue(LONG_SUBTITLE_LANGUAGE_SUMMARY, true)

      expect(loadedValue).assertEqual(LONG_SUBTITLE_LANGUAGE_SUMMARY)

      navigateToSubtitleLanguagePreference(controller)
      expect(controller.type).assertEqual(SettingType.SUBTITLE_LANGUAGE_PREFERENCE)

      controller.reset()
      navigateToSubtitleLanguagePreference(controller)
      expect(controller.type).assertEqual(SettingType.SUBTITLE_LANGUAGE_PREFERENCE)
    })

    it('首页字幕语言偏好入口在摘要加载完成后应显示已设置语言而不是加载文案', 0, () => {
      const loadingValue = buildSubtitleLanguagePreferenceEntryValue('简体中文 / 英语', false)
      const loadedValue = buildSubtitleLanguagePreferenceEntryValue('简体中文 / 英语', true)

      expect(loadingValue).assertEqual('正在加载…')
      expect(loadedValue).assertEqual('简体中文 / 英语')
    })
  })
}
