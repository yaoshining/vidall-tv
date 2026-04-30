import { describe, it, expect } from '@ohos/hypium'
import {
  PlayerSettingsAutoplayCountdownChipRenderModel,
  PlayerSettingsAutoplayToggleChipRenderModel,
  PlayerSettingsAspectRatioChipRenderModel,
  PlayerSettingsDiagnosticVisualSnapshot,
  PlayerSettingsSelectionMirrorState,
  buildAutoplayCountdownChipRenderModels,
  buildAutoplayToggleChipRenderModels,
  buildPlayerSettingsSelectionChipKey,
  buildPlayerSettingsSelectionStateKey,
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
import {
  buildEpisodeAnchorRanges,
  buildEpisodeAnchorScrollRequest,
  buildEpisodeContinuousListItems,
  buildEpisodeInitialScrollRequest,
  EpisodeAnchorRange,
  EpisodeScrollRequest
} from '../main/ets/components/core/player/EpisodeListPanel'
import { PlaybackContextItem } from '../main/ets/components/core/player/PlaybackContext'
import { AspectRatioMode } from '../main/ets/components/core/player/VideoPlayerController'

function makeVideoControlsEpisodeItems(count: number): PlaybackContextItem[] {
  const result: PlaybackContextItem[] = []
  for (let i = 0; i < count; i++) {
    const item: PlaybackContextItem = {
      videoPath: `/video-controls-episode-${i + 1}.mp4`,
      title: `Episode ${i + 1}`,
      index: i,
      episodeNumber: i + 1
    }
    result.push(item)
  }
  return result
}

export default function videoControlsTest() {
  describe('VideoControls', () => {
    describe('episode list continuous scroll anchors', () => {
      it('全部集数在同一列表可访问且不分页过滤', 0, () => {
        const items: PlaybackContextItem[] = makeVideoControlsEpisodeItems(15)

        const listItems: PlaybackContextItem[] = buildEpisodeContinuousListItems(items)
        const anchorRanges: EpisodeAnchorRange[] = buildEpisodeAnchorRanges(items.length)

        expect(listItems.length).assertEqual(15)
        expect(listItems[0].episodeNumber).assertEqual(1)
        expect(listItems[14].episodeNumber).assertEqual(15)
        expect(anchorRanges.length).assertEqual(3)
        expect(anchorRanges[0].label).assertEqual('1-6')
        expect(anchorRanges[1].label).assertEqual('7-12')
        expect(anchorRanges[2].label).assertEqual('13-15')
      })

      it('点击 1-6 锚点触发 scrollToIndex(0, true, ScrollAlign.START)', 0, () => {
        const request: EpisodeScrollRequest = buildEpisodeAnchorScrollRequest(0, 15)

        expect(request.index).assertEqual(0)
        expect(request.smooth).assertTrue()
        expect(request.align).assertEqual(ScrollAlign.START)
      })

      it('点击 7-12 锚点触发 scrollToIndex(6, true, ScrollAlign.START)', 0, () => {
        const request: EpisodeScrollRequest = buildEpisodeAnchorScrollRequest(1, 15)

        expect(request.index).assertEqual(6)
        expect(request.smooth).assertTrue()
        expect(request.align).assertEqual(ScrollAlign.START)
      })

      it('最后一组不足 6 集时锚点仍指向正确 groupStartIndex', 0, () => {
        const anchorRanges: EpisodeAnchorRange[] = buildEpisodeAnchorRanges(10)
        const request: EpisodeScrollRequest = buildEpisodeAnchorScrollRequest(1, 10)

        expect(anchorRanges.length).assertEqual(2)
        expect(anchorRanges[1].label).assertEqual('7-10')
        expect(anchorRanges[1].startIndex).assertEqual(6)
        expect(request.index).assertEqual(6)
        expect(request.smooth).assertTrue()
        expect(request.align).assertEqual(ScrollAlign.START)
      })

      it('onAppear 时调用 scrollToIndex(currentIndex, false, ScrollAlign.START)', 0, () => {
        const request: EpisodeScrollRequest = buildEpisodeInitialScrollRequest(14, 30)

        expect(request.index).assertEqual(14)
        expect(request.smooth).assertFalse()
        expect(request.align).assertEqual(ScrollAlign.START)
      })
    })

    describe('player settings selection bridge', () => {
      it('诊断日志统一带稳定播放器设置前缀并保留作用域与摘要', 0, () => {
        expect(formatPlayerSettingsDiagnosticLog(
          'interaction/speed',
          'focusedIndex=2 label=1.5x'
        )).assertEqual('[#player-settings] interaction/speed: focusedIndex=2 label=1.5x')
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

      it('倍速 chip 文案恢复原始文案，选中态不再依赖文案后缀', 0, () => {
        const models: PlayerSettingsSpeedChipRenderModel[] =
          buildPlaybackSpeedChipRenderModels(1.25, -1, -1)

        expect(models[2].label).assertEqual('1.0x')
        expect(models[3].label).assertEqual('1.25x')
        expect(models[4].label).assertEqual('1.5x')
      })

      it('倍速最终渲染 key 会随选中态切换，同时保持原始文案', 0, () => {
        const initialModels: PlayerSettingsSpeedChipRenderModel[] =
          buildPlaybackSpeedChipRenderModels(1.0, -1, -1)
        const updatedModels: PlayerSettingsSpeedChipRenderModel[] =
          buildPlaybackSpeedChipRenderModels(1.25, -1, -1)

        const initialLabelKey = buildPlayerSettingsSelectionChipKey(
          initialModels[2].speed.toString(),
          initialModels[2].label
        )
        const updatedLabelKey = buildPlayerSettingsSelectionChipKey(
          updatedModels[3].speed.toString(),
          updatedModels[3].label
        )
        const initialSelectedKey = buildPlayerSettingsSelectionStateKey(
          initialModels[2].speed.toString(),
          initialModels[2].styleState.isSelected
        )
        const updatedOldKey = buildPlayerSettingsSelectionStateKey(
          updatedModels[2].speed.toString(),
          updatedModels[2].styleState.isSelected
        )
        const updatedSelectedKey = buildPlayerSettingsSelectionStateKey(
          updatedModels[3].speed.toString(),
          updatedModels[3].styleState.isSelected
        )

        expect(initialModels[2].label).assertEqual('1.0x')
        expect(updatedModels[3].label).assertEqual('1.25x')
        expect(initialLabelKey).assertEqual('1:1.0x')
        expect(updatedLabelKey).assertEqual('1.25:1.25x')
        expect(initialSelectedKey).assertEqual('1:selected')
        expect(updatedOldKey).assertEqual('1:not-selected')
        expect(updatedSelectedKey).assertEqual('1.25:selected')
        expect(initialSelectedKey === updatedOldKey).assertFalse()
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

      it('画面比例 chip 文案恢复原始文案，选中态不再依赖文案后缀', 0, () => {
        const models: PlayerSettingsAspectRatioChipRenderModel[] =
          buildAspectRatioChipRenderModels(AspectRatioMode.FILL, -1, -1)

        expect(models[0].label).assertEqual('适应')
        expect(models[1].label).assertEqual('填充')
        expect(models[2].label).assertEqual('拉伸')
      })

      it('画面比例最终渲染 key 会随选中态切换，同时保持原始文案', 0, () => {
        const initialModels: PlayerSettingsAspectRatioChipRenderModel[] =
          buildAspectRatioChipRenderModels(AspectRatioMode.FIT, -1, -1)
        const updatedModels: PlayerSettingsAspectRatioChipRenderModel[] =
          buildAspectRatioChipRenderModels(AspectRatioMode.FILL, -1, -1)

        const initialLabelKey = buildPlayerSettingsSelectionChipKey(
          initialModels[0].mode.toString(),
          initialModels[0].label
        )
        const updatedLabelKey = buildPlayerSettingsSelectionChipKey(
          updatedModels[1].mode.toString(),
          updatedModels[1].label
        )
        const initialSelectedKey = buildPlayerSettingsSelectionStateKey(
          initialModels[0].mode.toString(),
          initialModels[0].styleState.isSelected
        )
        const updatedOldKey = buildPlayerSettingsSelectionStateKey(
          updatedModels[0].mode.toString(),
          updatedModels[0].styleState.isSelected
        )
        const updatedSelectedKey = buildPlayerSettingsSelectionStateKey(
          updatedModels[1].mode.toString(),
          updatedModels[1].styleState.isSelected
        )

        expect(initialModels[0].label).assertEqual('适应')
        expect(updatedModels[1].label).assertEqual('填充')
        expect(initialLabelKey).assertEqual('0:适应')
        expect(updatedLabelKey).assertEqual('1:填充')
        expect(initialSelectedKey).assertEqual('0:selected')
        expect(updatedOldKey).assertEqual('0:not-selected')
        expect(updatedSelectedKey).assertEqual('1:selected')
        expect(initialSelectedKey === updatedOldKey).assertFalse()
      })

      it('自动下一集选项 key 会随选中态切换', 0, () => {
        const enabledSelectedKey = buildPlayerSettingsSelectionStateKey('enabled', true)
        const enabledUnselectedKey = buildPlayerSettingsSelectionStateKey('enabled', false)
        const disabledSelectedKey = buildPlayerSettingsSelectionStateKey('disabled', true)

        expect(enabledSelectedKey).assertEqual('enabled:selected')
        expect(enabledUnselectedKey).assertEqual('enabled:not-selected')
        expect(disabledSelectedKey).assertEqual('disabled:selected')
        expect(enabledSelectedKey === enabledUnselectedKey).assertFalse()
      })

      it('自动下一集倒计时选项 key 会随选中态切换', 0, () => {
        const seconds8SelectedKey = buildPlayerSettingsSelectionStateKey('8', true)
        const seconds8UnselectedKey = buildPlayerSettingsSelectionStateKey('8', false)
        const seconds10SelectedKey = buildPlayerSettingsSelectionStateKey('10', true)

        expect(seconds8SelectedKey).assertEqual('8:selected')
        expect(seconds8UnselectedKey).assertEqual('8:not-selected')
        expect(seconds10SelectedKey).assertEqual('10:selected')
        expect(seconds8SelectedKey === seconds8UnselectedKey).assertFalse()
      })

      it('自动下一集最终渲染 key 会随选中态切换，同时保持显式选中态刷新', 0, () => {
        const initialModels: PlayerSettingsAutoplayToggleChipRenderModel[] =
          buildAutoplayToggleChipRenderModels(true, -1, -1)
        const updatedModels: PlayerSettingsAutoplayToggleChipRenderModel[] =
          buildAutoplayToggleChipRenderModels(false, -1, -1)

        const initialSelectedKey = buildPlayerSettingsSelectionStateKey(
          initialModels[0].enabled ? 'enabled' : 'disabled',
          initialModels[0].styleState.isSelected
        )
        const updatedOldKey = buildPlayerSettingsSelectionStateKey(
          updatedModels[0].enabled ? 'enabled' : 'disabled',
          updatedModels[0].styleState.isSelected
        )
        const updatedSelectedKey = buildPlayerSettingsSelectionStateKey(
          updatedModels[1].enabled ? 'enabled' : 'disabled',
          updatedModels[1].styleState.isSelected
        )

        expect(initialSelectedKey).assertEqual('enabled:selected')
        expect(updatedOldKey).assertEqual('enabled:not-selected')
        expect(updatedSelectedKey).assertEqual('disabled:selected')
        expect(initialSelectedKey === updatedOldKey).assertFalse()
      })

      it('自动下一集倒计时最终渲染 key 会随选中态切换，同时保持显式选中态刷新', 0, () => {
        const initialModels: PlayerSettingsAutoplayCountdownChipRenderModel[] =
          buildAutoplayCountdownChipRenderModels(8, -1, -1)
        const updatedModels: PlayerSettingsAutoplayCountdownChipRenderModel[] =
          buildAutoplayCountdownChipRenderModels(10, -1, -1)

        const initialSelectedKey = buildPlayerSettingsSelectionStateKey(
          initialModels[2].seconds.toString(),
          initialModels[2].styleState.isSelected
        )
        const updatedOldKey = buildPlayerSettingsSelectionStateKey(
          updatedModels[2].seconds.toString(),
          updatedModels[2].styleState.isSelected
        )
        const updatedSelectedKey = buildPlayerSettingsSelectionStateKey(
          updatedModels[3].seconds.toString(),
          updatedModels[3].styleState.isSelected
        )

        expect(initialSelectedKey).assertEqual('8:selected')
        expect(updatedOldKey).assertEqual('8:not-selected')
        expect(updatedSelectedKey).assertEqual('10:selected')
        expect(initialSelectedKey === updatedOldKey).assertFalse()
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

      it('自动下一集选项 selected 与 unselected 样式对齐当前倍速 chip', 0, () => {
        const models: PlayerSettingsAutoplayToggleChipRenderModel[] =
          buildAutoplayToggleChipRenderModels(true, -1, -1)
        const selectedState: PlayerSettingsChipStyleState = models[0].styleState
        const unselectedState: PlayerSettingsChipStyleState = models[1].styleState

        expect(selectedState.isSelected).assertTrue()
        expect(selectedState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.45)')
        expect(selectedState.borderWidth).assertEqual(2)
        expect(selectedState.borderColor).assertEqual('#fffefe')
        expect(selectedState.shadowRadius).assertEqual(14)
        expect(selectedState.scale).assertEqual(1.05)
        expect(unselectedState.isSelected).assertFalse()
        expect(unselectedState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.1)')
        expect(unselectedState.borderWidth).assertEqual(1)
        expect(unselectedState.borderColor).assertEqual('#45ffffff')
        expect(unselectedState.shadowRadius).assertEqual(0)
        expect(unselectedState.scale).assertEqual(1)
      })

      it('自动下一集倒计时 selected 与 unselected 样式对齐当前画面比例 chip', 0, () => {
        const models: PlayerSettingsAutoplayCountdownChipRenderModel[] =
          buildAutoplayCountdownChipRenderModels(8, -1, -1)
        const selectedState: PlayerSettingsChipStyleState = models[2].styleState
        const unselectedState: PlayerSettingsChipStyleState = models[0].styleState

        expect(selectedState.isSelected).assertTrue()
        expect(selectedState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.45)')
        expect(selectedState.labelColor).assertEqual('#F3F7FF')
        expect(selectedState.borderWidth).assertEqual(2)
        expect(selectedState.borderColor).assertEqual('#fffefe')
        expect(selectedState.shadowColor).assertEqual('#33597FB8')
        expect(selectedState.scale).assertEqual(1.05)
        expect(unselectedState.isSelected).assertFalse()
        expect(unselectedState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.1)')
        expect(unselectedState.labelColor).assertEqual('#D7DCE7')
        expect(unselectedState.borderWidth).assertEqual(1)
        expect(unselectedState.borderColor).assertEqual('#45ffffff')
        expect(unselectedState.shadowColor).assertEqual('#00000000')
        expect(unselectedState.scale).assertEqual(1)
      })

      it('自动下一集聚焦态仍保留原有 focus 视觉，不跟随倍速 hover 边框', 0, () => {
        const models: PlayerSettingsAutoplayToggleChipRenderModel[] =
          buildAutoplayToggleChipRenderModels(false, 0, -1)
        const focusedState: PlayerSettingsChipStyleState = models[0].styleState

        expect(focusedState.isFocused).assertTrue()
        expect(focusedState.isSelected).assertFalse()
        expect(focusedState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.22)')
        expect(focusedState.borderWidth).assertEqual(0)
        expect(focusedState.borderColor).assertEqual('#00000000')
        expect(focusedState.shadowRadius).assertEqual(12)
        expect(focusedState.scale).assertEqual(1.04)
      })

      it('自动下一集倒计时 hover 态仍保留原有 hover 视觉，不跟随倍速 hover 边框', 0, () => {
        const models: PlayerSettingsAutoplayCountdownChipRenderModel[] =
          buildAutoplayCountdownChipRenderModels(8, -1, 0)
        const hoveredState: PlayerSettingsChipStyleState = models[0].styleState

        expect(hoveredState.isHovered).assertTrue()
        expect(hoveredState.isSelected).assertFalse()
        expect(hoveredState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.22)')
        expect(hoveredState.borderWidth).assertEqual(0)
        expect(hoveredState.borderColor).assertEqual('#00000000')
        expect(hoveredState.shadowRadius).assertEqual(12)
        expect(hoveredState.scale).assertEqual(1.04)
      })

      it('自动下一集开启项 selected 与 focused 叠加时仍保持当前值白色选中边框', 0, () => {
        const models: PlayerSettingsAutoplayToggleChipRenderModel[] =
          buildAutoplayToggleChipRenderModels(true, 0, -1)
        const focusedSelectedState: PlayerSettingsChipStyleState = models[0].styleState

        expect(focusedSelectedState.isSelected).assertTrue()
        expect(focusedSelectedState.isFocused).assertTrue()
        expect(focusedSelectedState.borderWidth).assertEqual(2)
        expect(focusedSelectedState.borderColor).assertEqual('#fffefe')
        expect(focusedSelectedState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.45)')
        expect(focusedSelectedState.scale).assertEqual(1.05)
      })

      it('自动下一集开启项 selected 与 hovered 叠加时仍保持当前值白色选中边框', 0, () => {
        const models: PlayerSettingsAutoplayToggleChipRenderModel[] =
          buildAutoplayToggleChipRenderModels(true, -1, 0)
        const hoveredSelectedState: PlayerSettingsChipStyleState = models[0].styleState

        expect(hoveredSelectedState.isSelected).assertTrue()
        expect(hoveredSelectedState.isHovered).assertTrue()
        expect(hoveredSelectedState.borderWidth).assertEqual(2)
        expect(hoveredSelectedState.borderColor).assertEqual('#fffefe')
        expect(hoveredSelectedState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.45)')
        expect(hoveredSelectedState.scale).assertEqual(1.05)
      })

      it('自动下一集倒计时 selected 与 focused 叠加时仍保持当前值白色选中边框', 0, () => {
        const models: PlayerSettingsAutoplayCountdownChipRenderModel[] =
          buildAutoplayCountdownChipRenderModels(8, 2, -1)
        const focusedSelectedState: PlayerSettingsChipStyleState = models[2].styleState

        expect(focusedSelectedState.isSelected).assertTrue()
        expect(focusedSelectedState.isFocused).assertTrue()
        expect(focusedSelectedState.borderWidth).assertEqual(2)
        expect(focusedSelectedState.borderColor).assertEqual('#fffefe')
        expect(focusedSelectedState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.45)')
        expect(focusedSelectedState.scale).assertEqual(1.05)
      })

      it('自动下一集倒计时 selected 与 hovered 叠加时仍保持当前值白色选中边框', 0, () => {
        const models: PlayerSettingsAutoplayCountdownChipRenderModel[] =
          buildAutoplayCountdownChipRenderModels(8, -1, 2)
        const hoveredSelectedState: PlayerSettingsChipStyleState = models[2].styleState

        expect(hoveredSelectedState.isSelected).assertTrue()
        expect(hoveredSelectedState.isHovered).assertTrue()
        expect(hoveredSelectedState.borderWidth).assertEqual(2)
        expect(hoveredSelectedState.borderColor).assertEqual('#fffefe')
        expect(hoveredSelectedState.backgroundColor).assertEqual('rgba(255, 255, 255, 0.45)')
        expect(hoveredSelectedState.scale).assertEqual(1.05)
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
