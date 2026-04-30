import { describe, it, expect } from '@ohos/hypium'
import {
  buildEpisodeAnchorRanges,
  buildEpisodeContinuousListItems,
  getEpisodeItemRenderKey,
  getEpisodeSectionTitleStyleState,
  getEpisodeCardStyleState,
  getEpisodePageTabStyleState,
  EpisodeAnchorRange,
  EpisodeSectionTitleStyleState,
  EpisodeCardStyleState,
  EpisodePageTabStyleState
} from '../main/ets/components/core/player/EpisodeListPanel'
import { PlaybackContextItem } from '../main/ets/components/core/player/PlaybackContext'

function makeItems(count: number): PlaybackContextItem[] {
  const result: PlaybackContextItem[] = []
  for (let i = 0; i < count; i++) {
    const item: PlaybackContextItem = {
      videoPath: `/episode-${i + 1}.mp4`,
      title: `Episode ${i + 1}`,
      index: i,
      episodeNumber: i + 1
    }
    result.push(item)
  }
  return result
}

export default function EpisodeListPanelTest() {
  describe('EpisodeListPanel anchors', () => {
    it('按每 6 集生成连续列表锚点，最后一组保留不足 6 集的范围', 0, () => {
      const items: PlaybackContextItem[] = makeItems(15)

      const ranges: EpisodeAnchorRange[] = buildEpisodeAnchorRanges(items.length)
      const listItems: PlaybackContextItem[] = buildEpisodeContinuousListItems(items)

      expect(ranges.length).assertEqual(3)
      expect(ranges[0].label).assertEqual('1-6')
      expect(ranges[1].label).assertEqual('7-12')
      expect(ranges[2].label).assertEqual('13-15')
      expect(listItems.length).assertEqual(15)
      expect(listItems[6].episodeNumber).assertEqual(7)
      expect(listItems[14].episodeNumber).assertEqual(15)
    })

    it('连续列表渲染 key 使用全局唯一值，滚动后不复用局部索引', 0, () => {
      const items: PlaybackContextItem[] = makeItems(15)

      const listItems: PlaybackContextItem[] = buildEpisodeContinuousListItems(items)
      const firstGroupKeys: string[] = listItems.slice(0, 6).map((item: PlaybackContextItem): string => getEpisodeItemRenderKey(item))
      const secondGroupFirstKey: string = getEpisodeItemRenderKey(listItems[6])

      expect(firstGroupKeys.indexOf(secondGroupFirstKey)).assertEqual(-1)
      expect(secondGroupFirstKey).assertEqual('/episode-7.mp4')
    })

    it('总集数不超过 6 时仅生成一个锚点', 0, () => {
      const ranges: EpisodeAnchorRange[] = buildEpisodeAnchorRanges(6)

      expect(ranges.length).assertEqual(1)
      expect(ranges[0].label).assertEqual('1-6')
    })
  })

  describe('EpisodeListPanel style states', () => {
    it('选集标题收敛为与下方设置分组一致的 section title 节奏', 0, () => {
      const titleStyleState: EpisodeSectionTitleStyleState = getEpisodeSectionTitleStyleState()

      expect(titleStyleState.fontSize).assertEqual(32)
      expect(titleStyleState.leftMargin).assertEqual(0)
      expect(titleStyleState.bottomMargin).assertEqual(12)
    })

    it('聚焦卡片时使用整项 scale 提亮，不再依赖边框语义', 0, () => {
      const styleState: EpisodeCardStyleState = getEpisodeCardStyleState(true, false)

      expect(styleState.showLegacyFocusRing).assertFalse()
      expect(styleState.showFocusOutline).assertFalse()
      expect(styleState.showCurrentOutline).assertFalse()
      expect(styleState.scale).assertEqual(1.04)
      expect(styleState.focusBorderWidth).assertEqual(0)
      expect(styleState.currentBorderWidth).assertEqual(0)
    })

    it('hover 卡片时也沿用同一套放大语义', 0, () => {
      const styleState: EpisodeCardStyleState = getEpisodeCardStyleState(false, false, true)

      expect(styleState.scale).assertEqual(1.04)
      expect(styleState.focusBorderWidth).assertEqual(0)
      expect(styleState.currentBorderWidth).assertEqual(0)
    })

    it('当前播放项与聚焦项叠加时保留波形图与放大效果', 0, () => {
      const styleState: EpisodeCardStyleState = getEpisodeCardStyleState(true, true)

      expect(styleState.showLegacyFocusRing).assertFalse()
      expect(styleState.showFocusOutline).assertFalse()
      expect(styleState.showCurrentOutline).assertFalse()
      expect(styleState.showWaveIcon).assertTrue()
      expect(styleState.waveBarCount).assertEqual(3)
      expect(styleState.scale).assertEqual(1.04)
    })

    it('选集项恢复为上图下字布局，并回到更易读的中号卡片尺寸', 0, () => {
      const styleState: EpisodeCardStyleState = getEpisodeCardStyleState(false, false)

      expect(styleState.useVerticalLayout).assertTrue()
      expect(styleState.layoutWidth).assertEqual(200)
      expect(styleState.layoutHeight).assertEqual(130)
      expect(styleState.borderRadius).assertEqual(20)
      expect(styleState.thumbnailWidth).assertEqual(184)
      expect(styleState.thumbnailHeight).assertEqual(84)
      expect(styleState.labelFontSize).assertEqual(20)
      expect(styleState.contentGap).assertEqual(10)
      expect(styleState.horizontalPadding).assertEqual(8)
      expect(styleState.rightPadding).assertEqual(8)
      expect(styleState.verticalPadding).assertEqual(8)
      expect(styleState.layoutWidth > 184).assertTrue()
      expect(styleState.layoutWidth < 220).assertTrue()
      expect(styleState.layoutHeight > 68).assertTrue()
      expect(styleState.layoutHeight < 140).assertTrue()
      expect(styleState.thumbnailWidth > 64).assertTrue()
      expect(styleState.thumbnailHeight > 40).assertTrue()
      expect(styleState.labelFontSize > 18).assertTrue()
      expect(styleState.labelFontSize < 22).assertTrue()
    })

    it('锚点 tab 使用无边框 chip 风格，当前组与聚焦态仍可区分', 0, () => {
      const styleState: EpisodePageTabStyleState = getEpisodePageTabStyleState(true, true)

      expect(styleState.showFocusPill).assertFalse()
      expect(styleState.showFocusBackground).assertTrue()
      expect(styleState.showCurrentUnderline).assertTrue()
      expect(styleState.isCurrentAnchor).assertTrue()
      expect(styleState.isFocused).assertTrue()
      expect(styleState.focusBorderWidth).assertEqual(0)
      expect(styleState.scale).assertEqual(1.04)
      expect(styleState.borderRadius).assertEqual(20)
      expect(styleState.fontSize).assertEqual(18)
      expect(styleState.horizontalPadding).assertEqual(16)
      expect(styleState.verticalPadding).assertEqual(8)
    })

    it('分页 tab 在 hover 时同样使用 scale 而不是边框', 0, () => {
      const styleState: EpisodePageTabStyleState = getEpisodePageTabStyleState(false, false, true)

      expect(styleState.showFocusBackground).assertTrue()
      expect(styleState.focusBorderWidth).assertEqual(0)
      expect(styleState.scale).assertEqual(1.04)
    })
  })
}
