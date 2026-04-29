import { describe, it, expect } from '@ohos/hypium'
import {
  PlayerSettingsAspectRatioChipRenderModel,
  PlayerSettingsDiagnosticVisualSnapshot,
  PlayerSettingsSelectionMirrorState,
  createPlayerSettingsSelectionMirrorState,
  PlayerSettingsChipStyleState,
  PlayerSettingsSpeedChipRenderModel,
  buildAspectRatioChipRenderModels,
  buildPlaybackSpeedChipRenderModels,
  buildPlayerSettingsVisualSnapshotSummary,
  formatPlayerSettingsDiagnosticLog,
  formatPlayerSettingsEventSequenceDetail,
  getPlayerSettingsValueChipStyleState,
  isAspectRatioOptionSelected,
  resolveSelectedPlaybackRateIndex,
  syncPlayerSettingsSelectionMirrorState,
  shouldApplyEpisodeAutoplaySettingsLoad
} from '../main/ets/components/core/player/VideoControls'
import { AspectRatioMode } from '../main/ets/components/core/player/VideoPlayerController'

export default function videoControlsTest() {
  describe('VideoControls', () => {
    describe('player settings selection bridge', () => {
      it('诊断日志统一带 #180 前缀并保留作用域与摘要', 0, () => {
        expect(formatPlayerSettingsDiagnosticLog(
          'interaction/speed',
          'focusedIndex=2 label=1.5x'
        )).assertEqual('[#180-settings] interaction/speed: focusedIndex=2 label=1.5x')
      })

      it('视觉快照摘要会合并同一 chip 的多重角色并输出真实样式字段', 0, () => {
        const visualSnapshot: PlayerSettingsDiagnosticVisualSnapshot = {
          idx: 4,
          label: '1.5x',
          roles: 'selected|hovered',
          styleState: getPlayerSettingsValueChipStyleState(false, true, true)
        }

        expect(buildPlayerSettingsVisualSnapshotSummary('speed', [visualSnapshot])).assertEqual(
          'group=speed idx=4 label=1.5x roles=selected|hovered isSelected=true isHovered=true isFocused=false backgroundColor=rgba(255, 255, 255, 0.45) borderWidth=2 borderColor=#fffefe shadowRadius=14 shadowColor=#33597FB8 scale=1.05 labelColor=#F3F7FF'
        )
      })

      it('事件序列日志会记录事件类型与触发时索引摘要', 0, () => {
        expect(formatPlayerSettingsEventSequenceDetail(
          'hover',
          3,
          '1.25x',
          'hoveredIndex=3',
          -1,
          2,
          4
        )).assertEqual(
          'eventType=hover idx=3 label=1.25x next=hoveredIndex=3 focusedIndex=-1 hoveredIndex=2 selectedIndex=4'
        )
      })

      it('播放速度镜像会在控制器倍速变化后刷新', 0, () => {
        const initialState: PlayerSettingsSelectionMirrorState =
          createPlayerSettingsSelectionMirrorState(1.0, AspectRatioMode.FIT)

        const updatedState: PlayerSettingsSelectionMirrorState =
          syncPlayerSettingsSelectionMirrorState(initialState, 1.5, AspectRatioMode.FIT)

        expect(initialState.playbackSpeed).assertEqual(1.0)
        expect(updatedState.playbackSpeed).assertEqual(1.5)
        expect(updatedState.aspectRatioMode).assertEqual(AspectRatioMode.FIT)
      })

      it('画面比例镜像会在控制器比例变化后刷新', 0, () => {
        const initialState: PlayerSettingsSelectionMirrorState =
          createPlayerSettingsSelectionMirrorState(1.0, AspectRatioMode.FIT)

        const updatedState: PlayerSettingsSelectionMirrorState =
          syncPlayerSettingsSelectionMirrorState(initialState, 1.0, AspectRatioMode.FILL)

        expect(initialState.aspectRatioMode).assertEqual(AspectRatioMode.FIT)
        expect(updatedState.playbackSpeed).assertEqual(1.0)
        expect(updatedState.aspectRatioMode).assertEqual(AspectRatioMode.FILL)
      })
    })

    describe('player settings selection state', () => {
      it('倍速选中项直接从控制器实际倍速推导，未命中时回退到 1.0x', 0, () => {
        expect(resolveSelectedPlaybackRateIndex(1.5)).assertEqual(4)
        expect(resolveSelectedPlaybackRateIndex(1.33)).assertEqual(2)
      })

      it('倍速 chip 渲染模型直接由当前倍速驱动，便于切到非参数化渲染路径', 0, () => {
        const models: PlayerSettingsSpeedChipRenderModel[] =
          buildPlaybackSpeedChipRenderModels(1.5, 1, 3)

        expect(models.length).assertEqual(6)
        expect(models[1].styleState.isFocused).assertTrue()
        expect(models[1].styleState.scale).assertEqual(1.04)
        expect(models[3].styleState.isHovered).assertTrue()
        expect(models[4].label).assertEqual('1.5x')
        expect(models[4].styleState.isSelected).assertTrue()
        expect(models[4].styleState.borderColor).assertEqual('#fffefe')
      })

      it('画面比例选中态直接比较控制器当前模式', 0, () => {
        expect(isAspectRatioOptionSelected(AspectRatioMode.FILL, AspectRatioMode.FILL)).assertTrue()
        expect(isAspectRatioOptionSelected(AspectRatioMode.FILL, AspectRatioMode.FIT)).assertFalse()
      })

      it('画面比例 chip 渲染模型直接由当前比例驱动，避免参数化 Builder 选中态丢失', 0, () => {
        const models: PlayerSettingsAspectRatioChipRenderModel[] =
          buildAspectRatioChipRenderModels(AspectRatioMode.STRETCH, 0, 1)

        expect(models.length).assertEqual(3)
        expect(models[0].label).assertEqual('适应')
        expect(models[0].styleState.isFocused).assertTrue()
        expect(models[1].label).assertEqual('填充')
        expect(models[1].styleState.isHovered).assertTrue()
        expect(models[2].label).assertEqual('拉伸')
        expect(models[2].styleState.isSelected).assertTrue()
        expect(models[2].styleState.borderColor).assertEqual('#fffefe')
      })
    })

    describe('player settings value chip styles', () => {
      it('倍速与画面比例项保留当前 chip 结构，但选中态对齐画质增强语义', 0, () => {
        const styleState: PlayerSettingsChipStyleState = getPlayerSettingsValueChipStyleState(false, true)

        expect(styleState.showFocusOutline).assertFalse()
        expect(styleState.showSelectedOutline).assertFalse()
        expect(styleState.showWaveIcon).assertFalse()
        expect(styleState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.45)')
        expect(styleState.selectedBorderWidth).assertEqual(2)
        expect(styleState.focusBorderWidth).assertEqual(0)
        expect(styleState.borderWidth).assertEqual(2)
        expect(styleState.borderColor).assertEqual('#fffefe')
      })

      it('聚焦态保持 chip 交互，但只做轻微提亮与放大', 0, () => {
        const styleState: PlayerSettingsChipStyleState = getPlayerSettingsValueChipStyleState(true, false)

        expect(styleState.scale).assertEqual(1.04)
        expect(styleState.shadowRadius).assertEqual(12)
        expect(styleState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.18)')
        expect(styleState.focusBorderWidth).assertEqual(2)
        expect(styleState.selectedBorderWidth).assertEqual(0)
        expect(styleState.borderWidth).assertEqual(2)
        expect(styleState.borderColor).assertEqual('#66A9D8FF')
      })

      it('倍速与画面比例项收敛到与选集 chip 一致的高度、字号、圆角与间距', 0, () => {
        const chipStyleState: PlayerSettingsChipStyleState = getPlayerSettingsValueChipStyleState(false, false)

        expect(chipStyleState.height).assertEqual(68)
        expect(chipStyleState.borderRadius).assertEqual(22)
        expect(chipStyleState.labelFontSize).assertEqual(18)
        expect(chipStyleState.groupGap).assertEqual(10)
        expect(chipStyleState.borderWidth).assertEqual(1)
        expect(chipStyleState.borderColor).assertEqual('#45ffffff')
      })

      it('当前值与聚焦态仍可区分，叠加时保留当前值表达', 0, () => {
        const selectedState: PlayerSettingsChipStyleState = getPlayerSettingsValueChipStyleState(false, true)
        const focusedState: PlayerSettingsChipStyleState = getPlayerSettingsValueChipStyleState(true, false)
        const focusedSelectedState: PlayerSettingsChipStyleState = getPlayerSettingsValueChipStyleState(true, true)

        expect(selectedState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.45)')
        expect(selectedState.scale).assertEqual(1.05)
        expect(selectedState.selectedBorderWidth).assertEqual(2)
        expect(focusedState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.18)')
        expect(focusedState.scale).assertEqual(1.04)
        expect(focusedState.focusBorderWidth).assertEqual(2)
        expect(focusedSelectedState.backgroundColor).assertEqual(selectedState.backgroundColor)
        expect(focusedSelectedState.scale).assertEqual(selectedState.scale)
        expect(focusedSelectedState.selectedBorderWidth).assertEqual(2)
        expect(focusedSelectedState.borderWidth).assertEqual(2)
        expect(focusedSelectedState.borderColor).assertEqual('#fffefe')
      })

      it('当未选中项处于 hovered 时，selected 项仍保持最强的视觉语义', 0, () => {
        const speedModels: PlayerSettingsSpeedChipRenderModel[] =
          buildPlaybackSpeedChipRenderModels(1.5, -1, 3)
        const hoveredSpeedState: PlayerSettingsChipStyleState = speedModels[3].styleState
        const selectedSpeedState: PlayerSettingsChipStyleState = speedModels[4].styleState

        expect(selectedSpeedState.isSelected).assertTrue()
        expect(hoveredSpeedState.isHovered).assertTrue()
        expect(selectedSpeedState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.45)')
        expect(selectedSpeedState.scale >= hoveredSpeedState.scale).assertTrue()
        expect(selectedSpeedState.shadowRadius >= hoveredSpeedState.shadowRadius).assertTrue()

        const aspectModels: PlayerSettingsAspectRatioChipRenderModel[] =
          buildAspectRatioChipRenderModels(AspectRatioMode.STRETCH, -1, 1)
        const hoveredAspectState: PlayerSettingsChipStyleState = aspectModels[1].styleState
        const selectedAspectState: PlayerSettingsChipStyleState = aspectModels[2].styleState

        expect(selectedAspectState.isSelected).assertTrue()
        expect(hoveredAspectState.isHovered).assertTrue()
        expect(selectedAspectState.scale >= hoveredAspectState.scale).assertTrue()
        expect(selectedAspectState.shadowRadius >= hoveredAspectState.shadowRadius).assertTrue()
      })

      it('当未选中项处于 focused 时，selected 项仍保持最强的视觉语义', 0, () => {
        const speedModels: PlayerSettingsSpeedChipRenderModel[] =
          buildPlaybackSpeedChipRenderModels(1.5, 3, -1)
        const focusedSpeedState: PlayerSettingsChipStyleState = speedModels[3].styleState
        const selectedSpeedState: PlayerSettingsChipStyleState = speedModels[4].styleState

        expect(focusedSpeedState.isFocused).assertTrue()
        expect(selectedSpeedState.isSelected).assertTrue()
        expect(selectedSpeedState.scale >= focusedSpeedState.scale).assertTrue()
        expect(selectedSpeedState.shadowRadius >= focusedSpeedState.shadowRadius).assertTrue()

        const aspectModels: PlayerSettingsAspectRatioChipRenderModel[] =
          buildAspectRatioChipRenderModels(AspectRatioMode.STRETCH, 1, -1)
        const focusedAspectState: PlayerSettingsChipStyleState = aspectModels[1].styleState
        const selectedAspectState: PlayerSettingsChipStyleState = aspectModels[2].styleState

        expect(focusedAspectState.isFocused).assertTrue()
        expect(selectedAspectState.isSelected).assertTrue()
        expect(selectedAspectState.scale >= focusedAspectState.scale).assertTrue()
        expect(selectedAspectState.shadowRadius >= focusedAspectState.shadowRadius).assertTrue()
      })
    })

    describe('autoplay settings load guard', () => {
      it('用户已修改设置后不再应用旧的异步加载结果', 0, () => {
        expect(shouldApplyEpisodeAutoplaySettingsLoad(1, 1, true)).assertFalse()
      })

      it('弹窗重新打开后只接受最新一次加载结果', 0, () => {
        expect(shouldApplyEpisodeAutoplaySettingsLoad(1, 2, false)).assertFalse()
        expect(shouldApplyEpisodeAutoplaySettingsLoad(2, 2, false)).assertTrue()
      })
    })
  })
}
