import { describe, it, expect } from '@ohos/hypium'
import {
  PlayerSettingsChipStyleState,
  getPlayerSettingsChipStyleState,
  shouldApplyEpisodeAutoplaySettingsLoad
} from '../main/ets/components/core/player/VideoControls'

export default function videoControlsTest() {
  describe('VideoControls player settings chip styles', () => {
    it('倍速与画面比例项不再使用边框与描边语义，也不显示波形图', 0, () => {
      const styleState: PlayerSettingsChipStyleState = getPlayerSettingsChipStyleState(true, false)

      expect(styleState.showFocusOutline).assertFalse()
      expect(styleState.showSelectedOutline).assertFalse()
      expect(styleState.focusBorderWidth).assertEqual(0)
      expect(styleState.selectedBorderWidth).assertEqual(0)
      expect(styleState.showWaveIcon).assertFalse()
    })

    it('聚焦态改为使用 scale、背景与阴影提亮', 0, () => {
      const styleState: PlayerSettingsChipStyleState = getPlayerSettingsChipStyleState(true, false)

      expect(styleState.scale).assertEqual(1.04)
      expect(styleState.shadowRadius).assertEqual(12)
      expect(styleState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.22)')
      expect(styleState.focusBorderWidth).assertEqual(0)
    })

    it('倍速与画面比例项收敛到与选集 chip 一致的高度、字号、圆角与间距', 0, () => {
      const chipStyleState: PlayerSettingsChipStyleState = getPlayerSettingsChipStyleState(false, false)

      expect(chipStyleState.height).assertEqual(68)
      expect(chipStyleState.borderRadius).assertEqual(22)
      expect(chipStyleState.labelFontSize).assertEqual(18)
      expect(chipStyleState.groupGap).assertEqual(10)
    })

    it('当前值与聚焦态仍可区分，叠加时保留当前值表达', 0, () => {
      const selectedState: PlayerSettingsChipStyleState = getPlayerSettingsChipStyleState(false, true)
      const focusedState: PlayerSettingsChipStyleState = getPlayerSettingsChipStyleState(true, false)
      const focusedSelectedState: PlayerSettingsChipStyleState = getPlayerSettingsChipStyleState(true, true)

      expect(selectedState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.28)')
      expect(selectedState.scale).assertEqual(1)
      expect(focusedState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.22)')
      expect(focusedState.scale).assertEqual(1.04)
      expect(focusedSelectedState.backgroundColor).assertEqual(selectedState.backgroundColor)
      expect(focusedSelectedState.scale).assertEqual(focusedState.scale)
    })
  })

  describe('VideoControls autoplay settings load guard', () => {
    it('用户已修改设置后不再应用旧的异步加载结果', 0, () => {
      expect(shouldApplyEpisodeAutoplaySettingsLoad(1, 1, true)).assertFalse()
    })

    it('弹窗重新打开后只接受最新一次加载结果', 0, () => {
      expect(shouldApplyEpisodeAutoplaySettingsLoad(1, 2, false)).assertFalse()
      expect(shouldApplyEpisodeAutoplaySettingsLoad(2, 2, false)).assertTrue()
    })
  })
}
