import { describe, it, expect } from '@ohos/hypium'
import {
  ServerMediaLibraryContext,
  ServerMediaLibraryMeta,
  PlaybackContextItem
} from '../main/ets/components/core/player/PlaybackContext'
import { VideoServerEpisode } from '../main/ets/lib/JellyfinClient'

function buildServerEpisode(id: string, episodeNumber: number): VideoServerEpisode {
  const ep: VideoServerEpisode = {
    id,
    episodeNumber,
    seasonNumber: 1,
    title: episodeNumber === 2 ? '第二集标题' : '',
    overview: '',
    stillUrl: `${id}-still`,
    durationMs: 1800000,
    rating: 0,
    positionMs: episodeNumber === 2 ? 60000 : 0,
    lastPlayedDate: 0
  }
  return ep
}

function buildServerMeta(): ServerMediaLibraryMeta {
  const meta: ServerMediaLibraryMeta = {
    serverType: 'jellyfin',
    serverId: 7,
    seriesId: 'series-1',
    seriesTitle: '测试剧集',
    seasonNumber: 1,
    seasonName: '第 1 季',
    posterUrl: 'https://example.com/poster.jpg',
    backdropUrl: 'https://example.com/backdrop.jpg'
  }
  return meta
}

export default function serverMediaLibraryContextTest() {
  describe('ServerMediaLibraryContext', () => {
    it('buildItems 按集号升序排列并定位当前集', 0, () => {
      const episodes = [buildServerEpisode('ep3', 3), buildServerEpisode('ep1', 1), buildServerEpisode('ep2', 2)]
      const result = ServerMediaLibraryContext.buildItems(episodes, 'ep2')
      expect(result.items.length).assertEqual(3)
      expect(result.currentIndex).assertEqual(1)
      expect(result.items[0].videoPath).assertEqual('ep1')
      expect(result.items[1].videoPath).assertEqual('ep2')
      expect(result.items[2].videoPath).assertEqual('ep3')
    })

    it('当前条目不在列表时索引回退 0', 0, () => {
      const episodes = [buildServerEpisode('ep1', 1), buildServerEpisode('ep2', 2)]
      const result = ServerMediaLibraryContext.buildItems(episodes, 'missing-id')
      expect(result.currentIndex).assertEqual(0)
      expect(result.items[0].videoPath).assertEqual('ep1')
    })

    it('条目字段完整：标题、缩略图、季集号、时长与续播位置', 0, () => {
      const episodes = [buildServerEpisode('ep2', 2)]
      const result = ServerMediaLibraryContext.buildItems(episodes, 'ep2')
      const item: PlaybackContextItem = result.items[0]
      expect(item.videoPath).assertEqual('ep2')
      expect(item.title).assertEqual('第2集 第二集标题')
      expect(item.thumbnailUrl ?? '').assertEqual('ep2-still')
      expect(item.seasonNumber ?? 0).assertEqual(1)
      expect(item.episodeNumber ?? 0).assertEqual(2)
      expect(item.durationMs ?? 0).assertEqual(1800000)
      expect(item.positionMs ?? 0).assertEqual(60000)
    })

    it('缺集名时标题回退为「第N集」，缺缩略图与续播位时字段省略', 0, () => {
      const episodes = [buildServerEpisode('ep1', 1)]
      const result = ServerMediaLibraryContext.buildItems(episodes, 'ep1')
      const item: PlaybackContextItem = result.items[0]
      expect(item.title).assertEqual('第1集')
      expect(item.thumbnailUrl).assertEqual('ep1-still')
      expect(item.positionMs).assertUndefined()
    })

    it('build 工厂携带服务器标识并支持 jumpToNext', 0, () => {
      const episodes = [buildServerEpisode('ep1', 1), buildServerEpisode('ep2', 2)]
      const context = ServerMediaLibraryContext.build(episodes, 'ep1', buildServerMeta())
      expect(context.contextType).assertEqual('server_media_library')
      expect(context.serverType).assertEqual('jellyfin')
      expect(context.serverId).assertEqual(7)
      expect(context.seriesId).assertEqual('series-1')
      expect(context.currentIndex).assertEqual(0)
      expect(context.hasNext).assertTrue()

      const nextItem = context.jumpToNext()
      expect(nextItem?.videoPath ?? '').assertEqual('ep2')
      expect(context.hasNext).assertFalse()
    })

    it('最后一集 jumpToNext 返回 null（不跨季连播）', 0, () => {
      const episodes = [buildServerEpisode('ep1', 1), buildServerEpisode('ep2', 2)]
      const context = ServerMediaLibraryContext.build(episodes, 'ep2', buildServerMeta())
      expect(context.hasNext).assertFalse()
      expect(context.jumpToNext()).assertNull()
    })

    it('切集标题组合系列名与季名，缺省段自动省略', 0, () => {
      const episodes = [buildServerEpisode('ep2', 2)]
      const context = ServerMediaLibraryContext.build(episodes, 'ep2', buildServerMeta())
      const item: PlaybackContextItem = context.items[0]
      expect(context.buildEpisodeSwitchTitle(item)).assertEqual('测试剧集 第 1 季 第2集 第二集标题')

      const meta = buildServerMeta()
      meta.seasonName = ''
      const contextNoSeason = ServerMediaLibraryContext.build(episodes, 'ep2', meta)
      expect(contextNoSeason.buildEpisodeSwitchTitle(item)).assertEqual('测试剧集 第2集 第二集标题')
    })
  })
}
