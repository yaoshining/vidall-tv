import { describe, it, expect } from '@ohos/hypium'
import {
  PlayerSettingsChipStyleState,
  getPlayerSettingsValueChipStyleState,
  isAspectRatioOptionSelected,
  resolveSelectedPlaybackRateIndex,
  shouldApplyEpisodeAutoplaySettingsLoad
} from '../main/ets/components/core/player/VideoControls'
import { AspectRatioMode } from '../main/ets/components/core/player/VideoPlayerController'

export default function videoControlsTest() {
  describe('VideoControls player settings selection state', () => {
    it('倍速选中项直接从控制器实际倍速推导，未命中时回退到 1.0x', 0, () => {
      expect(resolveSelectedPlaybackRateIndex(1.5)).assertEqual(4)
      expect(resolveSelectedPlaybackRateIndex(1.33)).assertEqual(2)
    })

    it('画面比例选中态直接比较控制器当前模式', 0, () => {
      expect(isAspectRatioOptionSelected(AspectRatioMode.FILL, AspectRatioMode.FILL)).assertTrue()
      expect(isAspectRatioOptionSelected(AspectRatioMode.FILL, AspectRatioMode.FIT)).assertFalse()
    })
  })

  describe('VideoControls player settings value chip styles', () => {
    it('倍速与画面比例项保留当前 chip 结构，但选中态对齐画质增强语义', 0, () => {
      const styleState: PlayerSettingsChipStyleState = getPlayerSettingsValueChipStyleState(false, true)

      expect(styleState.showFocusOutline).assertFalse()
      expect(styleState.showSelectedOutline).assertFalse()
      expect(styleState.showWaveIcon).assertFalse()
      expect(styleState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.45)')
      expect(styleState.selectedBorderWidth).assertEqual(2)
      expect(styleState.focusBorderWidth).assertEqual(0)
    })

    it('聚焦态保持 chip 交互，但只做轻微提亮与放大', 0, () => {
      const styleState: PlayerSettingsChipStyleState = getPlayerSettingsValueChipStyleState(true, false)

      expect(styleState.scale).assertEqual(1.04)
      expect(styleState.shadowRadius).assertEqual(12)
      expect(styleState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.18)')
      expect(styleState.focusBorderWidth).assertEqual(2)
      expect(styleState.selectedBorderWidth).assertEqual(0)
    })

    it('倍速与画面比例项收敛到与选集 chip 一致的高度、字号、圆角与间距', 0, () => {
      const chipStyleState: PlayerSettingsChipStyleState = getPlayerSettingsValueChipStyleState(false, false)

      expect(chipStyleState.height).assertEqual(68)
      expect(chipStyleState.borderRadius).assertEqual(22)
      expect(chipStyleState.labelFontSize).assertEqual(18)
      expect(chipStyleState.groupGap).assertEqual(10)
    })

    it('当前值与聚焦态仍可区分，叠加时保留当前值表达', 0, () => {
      const selectedState: PlayerSettingsChipStyleState = getPlayerSettingsValueChipStyleState(false, true)
      const focusedState: PlayerSettingsChipStyleState = getPlayerSettingsValueChipStyleState(true, false)
      const focusedSelectedState: PlayerSettingsChipStyleState = getPlayerSettingsValueChipStyleState(true, true)

      expect(selectedState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.45)')
      expect(selectedState.scale).assertEqual(1)
      expect(selectedState.selectedBorderWidth).assertEqual(2)
      expect(focusedState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.18)')
      expect(focusedState.scale).assertEqual(1.04)
      expect(focusedState.focusBorderWidth).assertEqual(2)
      expect(focusedSelectedState.backgroundColor).assertEqual(selectedState.backgroundColor)
      expect(focusedSelectedState.scale).assertEqual(focusedState.scale)
      expect(focusedSelectedState.selectedBorderWidth).assertEqual(2)
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
