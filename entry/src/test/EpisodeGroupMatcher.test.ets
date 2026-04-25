import { describe, it, expect } from '@ohos/hypium'
import {
  EpisodeGroupMatcher,
  EpisodeGroupMatchResult
} from '../main/ets/components/core/player/EpisodeGroupMatcher'
import { MediaItem, TvEpisodeEntity } from '../main/ets/db/models/MediaEntity'

class FakeEpisodeGroupMatcherDatabase {
  mediaItemsCalls: number = 0
  episodeEntitiesCalls: number = 0
  private readonly mediaItems: MediaItem[]
  private readonly episodeEntities: TvEpisodeEntity[]

  constructor(mediaItems: MediaItem[], episodeEntities: TvEpisodeEntity[]) {
    this.mediaItems = mediaItems
    this.episodeEntities = episodeEntities
  }

  async getMediaItemsByTvSeriesId(_seriesId: number): Promise<MediaItem[]> {
    this.mediaItemsCalls += 1
    return this.mediaItems
  }

  async getEpisodesBySeriesAndSeason(_seriesId: number, _seasonNumber: number): Promise<TvEpisodeEntity[]> {
    this.episodeEntitiesCalls += 1
    return this.episodeEntities
  }
}

export default function episodeGroupMatcherTest() {
  describe('EpisodeGroupMatcher', () => {
    it('matchSeasonEpisodes 会按当前季过滤并按集号升序返回可播放条目', 0, async () => {
      const matcher = new EpisodeGroupMatcher()
      const db = new FakeEpisodeGroupMatcherDatabase(
        [
          {
            id: 2, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
            filePath: '/s1e2.mkv', fileName: 's1e2.mkv', seasonNumber: 1, episodeNumber: 2,
            title: '剧级标题'
          },
          {
            id: 1, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
            filePath: '/s1e1.mkv', fileName: 's1e1.mkv', seasonNumber: 1, episodeNumber: 1,
            title: '剧级标题'
          },
          {
            id: 3, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
            filePath: '/s2e1.mkv', fileName: 's2e1.mkv', seasonNumber: 2, episodeNumber: 1,
            title: '第二季'
          }
        ],
        [
          {
            seriesId: 7, provider: 'tmdb', providerId: 'ep-1', seasonNumber: 1, episodeNumber: 1,
            title: '第一集', stillUrl: 'https://image.tmdb.org/t/p/w342/ep1.jpg', scrapedAt: 0
          },
          {
            seriesId: 7, provider: 'tmdb', providerId: 'ep-2', seasonNumber: 1, episodeNumber: 2,
            title: '第二集', scrapedAt: 0
          }
        ]
      )

      const result: EpisodeGroupMatchResult = await matcher.matchSeasonEpisodes(
        7,
        1,
        (): Promise<MediaItem[]> => db.getMediaItemsByTvSeriesId(7),
        (): Promise<TvEpisodeEntity[]> => db.getEpisodesBySeriesAndSeason(7, 1)
      )

      expect(result.items.length).assertEqual(2)
      expect(result.items[0].videoPath).assertEqual('/s1e1.mkv')
      expect(result.items[0].title).assertEqual('第一集')
      expect(result.items[0].thumbnailUrl).assertEqual('https://image.tmdb.org/t/p/w342/ep1.jpg')
      expect(result.items[1].videoPath).assertEqual('/s1e2.mkv')
      expect(result.items[1].title).assertEqual('第二集')
    })

    it('matchSeasonEpisodes 在集元数据缺失时回退到文件名或第X集', 0, async () => {
      const matcher = new EpisodeGroupMatcher()
      const db = new FakeEpisodeGroupMatcherDatabase(
        [
          {
            id: 5, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
            filePath: '/s1e5.mkv', fileName: 's1e5.mkv', seasonNumber: 1, episodeNumber: 5,
            title: '整剧标题'
          },
          {
            id: 6, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
            filePath: '/special.mkv', fileName: 'special.mkv', seasonNumber: 1,
            title: ''
          }
        ],
        []
      )

      const result: EpisodeGroupMatchResult = await matcher.matchSeasonEpisodes(
        7,
        1,
        (): Promise<MediaItem[]> => db.getMediaItemsByTvSeriesId(7),
        (): Promise<TvEpisodeEntity[]> => db.getEpisodesBySeriesAndSeason(7, 1)
      )

      expect(result.items.length).assertEqual(2)
      expect(result.items[0].title).assertEqual('第5集')
      expect(result.items[1].title).assertEqual('special.mkv')
    })

    it('matchSeasonEpisodes 在本地缺少部分剧集时返回可播放子集且保持升序', 0, async () => {
      const matcher = new EpisodeGroupMatcher()
      const db = new FakeEpisodeGroupMatcherDatabase(
        [
          {
            id: 13, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
            filePath: '/s1e3.mkv', fileName: 's1e3.mkv', seasonNumber: 1, episodeNumber: 3,
            title: '整剧标题'
          },
          {
            id: 11, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
            filePath: '/s1e1.mkv', fileName: 's1e1.mkv', seasonNumber: 1, episodeNumber: 1,
            title: '整剧标题'
          }
        ],
        [
          {
            seriesId: 7, provider: 'tmdb', providerId: 'ep-1', seasonNumber: 1, episodeNumber: 1,
            title: '第一集', scrapedAt: 0
          },
          {
            seriesId: 7, provider: 'tmdb', providerId: 'ep-2', seasonNumber: 1, episodeNumber: 2,
            title: '第二集', scrapedAt: 0
          },
          {
            seriesId: 7, provider: 'tmdb', providerId: 'ep-3', seasonNumber: 1, episodeNumber: 3,
            title: '第三集', scrapedAt: 0
          }
        ]
      )

      const result: EpisodeGroupMatchResult = await matcher.matchSeasonEpisodes(
        7,
        1,
        (): Promise<MediaItem[]> => db.getMediaItemsByTvSeriesId(7),
        (): Promise<TvEpisodeEntity[]> => db.getEpisodesBySeriesAndSeason(7, 1)
      )

      expect(result.items.length).assertEqual(2)
      expect(result.items[0].videoPath).assertEqual('/s1e1.mkv')
      expect(result.items[0].title).assertEqual('第一集')
      expect(result.items[1].videoPath).assertEqual('/s1e3.mkv')
      expect(result.items[1].title).assertEqual('第三集')
    })

    it('matchSeasonEpisodes 在同一 matcher 会话内命中 series+season 缓存', 0, async () => {
      const matcher = new EpisodeGroupMatcher()
      const db = new FakeEpisodeGroupMatcherDatabase(
        [
          {
            id: 1, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
            filePath: '/s1e1.mkv', fileName: 's1e1.mkv', seasonNumber: 1, episodeNumber: 1
          }
        ],
        [
          {
            seriesId: 7, provider: 'tmdb', providerId: 'ep-1', seasonNumber: 1, episodeNumber: 1,
            title: '第一集', scrapedAt: 0
          }
        ]
      )

      const first: EpisodeGroupMatchResult = await matcher.matchSeasonEpisodes(
        7,
        1,
        (): Promise<MediaItem[]> => db.getMediaItemsByTvSeriesId(7),
        (): Promise<TvEpisodeEntity[]> => db.getEpisodesBySeriesAndSeason(7, 1)
      )
      const second: EpisodeGroupMatchResult = await matcher.matchSeasonEpisodes(
        7,
        1,
        (): Promise<MediaItem[]> => db.getMediaItemsByTvSeriesId(7),
        (): Promise<TvEpisodeEntity[]> => db.getEpisodesBySeriesAndSeason(7, 1)
      )

      expect(first.items.length).assertEqual(1)
      expect(second.items.length).assertEqual(1)
      expect(db.mediaItemsCalls).assertEqual(1)
      expect(db.episodeEntitiesCalls).assertEqual(1)
    })

    it('matchSeasonEpisodes 在已知 episodeNumber 未命中元数据时不会按索引错配到其他集', 0, async () => {
      const matcher = new EpisodeGroupMatcher()
      const db = new FakeEpisodeGroupMatcherDatabase(
        [
          {
            id: 1, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
            filePath: '/s1e1.mkv', fileName: 's1e1.mkv', seasonNumber: 1, episodeNumber: 1
          },
          {
            id: 3, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
            filePath: '/s1e3.mkv', fileName: 's1e3.mkv', seasonNumber: 1, episodeNumber: 3
          }
        ],
        [
          {
            seriesId: 7, provider: 'tmdb', providerId: 'ep-1', seasonNumber: 1, episodeNumber: 1,
            title: '第一集', scrapedAt: 0
          },
          {
            seriesId: 7, provider: 'tmdb', providerId: 'ep-2', seasonNumber: 1, episodeNumber: 2,
            title: '第二集', scrapedAt: 0, stillUrl: 'https://image.tmdb.org/t/p/w342/ep2.jpg'
          },
          {
            seriesId: 7, provider: 'tmdb', providerId: 'ep-4', seasonNumber: 1, episodeNumber: 4,
            title: '第四集', scrapedAt: 0
          }
        ]
      )

      const result: EpisodeGroupMatchResult = await matcher.matchSeasonEpisodes(
        7,
        1,
        (): Promise<MediaItem[]> => db.getMediaItemsByTvSeriesId(7),
        (): Promise<TvEpisodeEntity[]> => db.getEpisodesBySeriesAndSeason(7, 1)
      )

      expect(result.items.length).assertEqual(2)
      expect(result.items[0].title).assertEqual('第一集')
      expect(result.items[1].title).assertEqual('第3集')
      expect(result.items[1].thumbnailUrl === undefined).assertTrue()
    })
  })
}
