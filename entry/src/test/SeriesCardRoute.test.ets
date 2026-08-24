import { describe, it, expect } from '@ohos/hypium'
import { resolveSeriesCardDestination } from '../main/ets/services/sourceAdapter/SeriesCardRoute'
import { SeriesGroup } from '../main/ets/db/models/MediaEntity'

/** 构造一个系列卡片数据。seasonNumber 传 undefined 表示无季号。 */
function makeGroup(tvSeriesId: number | undefined, seasonNumber: number | undefined): SeriesGroup {
  const group: SeriesGroup = {
    title: '测试剧',
    tvSeriesId: tvSeriesId,
    seasonNumber: seasonNumber,
    episodeCount: 10,
    episodes: [],
    latestScannedAt: 0
  }
  return group
}

export default function seriesCardRouteTest(): void {
  describe('resolveSeriesCardDestination - 系列卡片点击分流', () => {
    it('最近添加/混合卡片：有季号 → 季详情页', 0, () => {
      const dest = resolveSeriesCardDestination(true, makeGroup(1, 2))
      expect(dest).assertEqual('seasonDetail')
    })

    it('最近添加/混合卡片：无季号 → 剧集详情页（修复点击无法打开）', 0, () => {
      const dest = resolveSeriesCardDestination(true, makeGroup(1, undefined))
      expect(dest).assertEqual('seriesDetail')
    })

    it('电视剧栏：无季号 → 剧集详情页', 0, () => {
      const dest = resolveSeriesCardDestination(false, makeGroup(1, undefined))
      expect(dest).assertEqual('seriesDetail')
    })

    it('电视剧栏：有季号也进剧集详情页', 0, () => {
      const dest = resolveSeriesCardDestination(false, makeGroup(1, 3))
      expect(dest).assertEqual('seriesDetail')
    })

    it('tvSeriesId 缺失 → 不跳转（返回 null）', 0, () => {
      const dest = resolveSeriesCardDestination(true, makeGroup(undefined, undefined))
      expect(dest).assertEqual(null)
    })
  })
}
