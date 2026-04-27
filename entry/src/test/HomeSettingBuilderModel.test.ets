import { describe, it, expect } from '@ohos/hypium'
import { SettingsController } from '../main/ets/pages/settings/SettingsController'
import SettingType from '../main/ets/pages/settings/SettingType'
import { buildSubtitleLanguagePreferenceEntryModel } from '../main/ets/pages/settings/builders/HomeSettingBuilderModel'

const LONG_SUBTITLE_LANGUAGE_SUMMARY: string =
  '简体中文（中国大陆） > 繁體中文（台灣） > English > 日本語 > 한국어 > Español > Français'

export default function homeSettingBuilderModelTest() {
  describe('HomeSettingBuilderModel', () => {
    it('首页字幕语言偏好入口右侧摘要区域点击后应进入偏好页', 0, () => {
      const controller = new SettingsController()
      const entryModel = buildSubtitleLanguagePreferenceEntryModel(controller, '简体中文 > English', true)

      entryModel.onRightIconClick()

      expect(controller.type).assertEqual(SettingType.SUBTITLE_LANGUAGE_PREFERENCE)
    })

    it('首页字幕语言偏好入口长摘要文本不应影响整行与右侧区域跳转', 0, () => {
      const controller = new SettingsController()
      const entryModel = buildSubtitleLanguagePreferenceEntryModel(controller, LONG_SUBTITLE_LANGUAGE_SUMMARY, true)

      expect(entryModel.value).assertEqual(LONG_SUBTITLE_LANGUAGE_SUMMARY)

      entryModel.onItemClick()
      expect(controller.type).assertEqual(SettingType.SUBTITLE_LANGUAGE_PREFERENCE)

      controller.reset()
      entryModel.onRightIconClick()
      expect(controller.type).assertEqual(SettingType.SUBTITLE_LANGUAGE_PREFERENCE)
    })
  })
}
