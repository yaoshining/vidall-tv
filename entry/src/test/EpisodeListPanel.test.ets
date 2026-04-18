import { describe, it, expect } from '@ohos/hypium'
import {
  buildEpisodePageRanges,
  getEpisodePageItems,
  getEpisodeItemRenderKey
} from '../main/ets/components/core/player/EpisodeListPanel'
import { PlaybackContextItem } from '../main/ets/components/core/player/PlaybackContext'

interface EpisodePageRangeExpectation {
  label: string
}

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
  describe('EpisodeListPanel pagination', () => {
    it('切换到第二组选集后返回 7 到最后一集', 0, () => {
      const items: PlaybackContextItem[] = makeItems(15)

      const ranges: EpisodePageRangeExpectation[] = buildEpisodePageRanges(items.length)
      const secondPageItems: PlaybackContextItem[] = getEpisodePageItems(items, 1)

      expect(ranges.length).assertEqual(2)
      expect(ranges[1].label).assertEqual('7-15')
      expect(secondPageItems.length).assertEqual(9)
      expect(secondPageItems[0].episodeNumber).assertEqual(7)
      expect(secondPageItems[8].episodeNumber).assertEqual(15)
    })

    it('分页切换后渲染 key 使用全局唯一值，不复用第一页索引', 0, () => {
      const items: PlaybackContextItem[] = makeItems(15)

      const firstPageItems: PlaybackContextItem[] = getEpisodePageItems(items, 0)
      const secondPageItems: PlaybackContextItem[] = getEpisodePageItems(items, 1)
      const firstPageKeys: string[] = firstPageItems.map((item: PlaybackContextItem): string => getEpisodeItemRenderKey(item))
      const secondPageFirstKey: string = getEpisodeItemRenderKey(secondPageItems[0])

      expect(firstPageKeys.indexOf(secondPageFirstKey)).assertEqual(-1)
      expect(secondPageFirstKey).assertEqual('/episode-7.mp4')
    })

    it('总集数不超过 6 时不生成第二组', 0, () => {
      const ranges: EpisodePageRangeExpectation[] = buildEpisodePageRanges(6)

      expect(ranges.length).assertEqual(1)
      expect(ranges[0].label).assertEqual('1-6')
    })
  })
}
