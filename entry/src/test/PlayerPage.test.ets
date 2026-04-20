import { describe, it, expect } from '@ohos/hypium'
import {
  buildMediaLibraryEpisodeSwitchParam,
  commitMediaLibraryEpisodeSwitch,
  PlayerPageParam,
  ResolvedEpisodePlaybackSource
} from '../main/ets/pages/player/index'
import { MediaLibraryContext, FileExplorerContext, PlaybackContextItem } from '../main/ets/components/core/player/PlaybackContext'

function buildSelectedEpisode(index: number): PlaybackContextItem {
  return {
    index,
    title: `第${index + 1}集`,
    videoPath: `/series/s01e0${index + 1}.mkv`,
    videoId: 100 + index,
    sourceId: 200 + index,
    seasonNumber: 1,
    episodeNumber: index + 1,
    durationMs: 1800000
  }
}

function buildResolvedSource(url: string): ResolvedEpisodePlaybackSource {
  const httpHeader = {} as Record<string, string>
  httpHeader.Authorization = 'Basic token'
  const resolvedSource: ResolvedEpisodePlaybackSource = {
    url,
    httpHeader,
    durationHintMs: 1800000
  }
  return resolvedSource
}

export default function playerPageTest() {
  describe('PlayerPage episode switching', () => {
    it('媒体库选集会生成新的播放参数，并在提交后让 currentIndex 与所选播放源对齐', 0, () => {
      const context = new MediaLibraryContext()
      context.items = [buildSelectedEpisode(0), buildSelectedEpisode(1), buildSelectedEpisode(2)]
      context.currentIndex = 0

      const currentParam: PlayerPageParam = {
        url: 'https://example.com/current.mkv',
        title: '当前播放',
        seriesProviderId: 'tmdb-9527',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: context
      }

      const nextParam = buildMediaLibraryEpisodeSwitchParam(
        currentParam,
        context,
        context.items[2],
        buildResolvedSource('https://example.com/s01e03.mkv')
      )

      expect(nextParam !== null).assertTrue()
      expect(context.currentIndex).assertEqual(0)
      if (nextParam !== null) {
        expect(nextParam.url).assertEqual('https://example.com/s01e03.mkv')
        expect(nextParam.videoId).assertEqual(102)
        expect(nextParam.seasonNumber).assertEqual(1)
        expect(nextParam.episodeNumber).assertEqual(3)
        expect(nextParam.mediaKey).assertEqual('media_progress_episode_tmdb_tmdb-9527_s1_e3')
        expect(nextParam.playbackContext?.currentIndex).assertEqual(0)
      }

      const committedItem = commitMediaLibraryEpisodeSwitch(context, context.items[2])
      expect(committedItem !== null).assertTrue()
      expect(context.currentIndex).assertEqual(2)
    })

    it('非 media_library 场景不会生成播放器切源参数', 0, () => {
      const fileExplorerContext = new FileExplorerContext()
      fileExplorerContext.items = [buildSelectedEpisode(0), buildSelectedEpisode(1)]
      fileExplorerContext.currentIndex = 0

      const currentParam: PlayerPageParam = {
        url: 'https://example.com/current.mkv',
        title: '当前播放',
        seriesProviderId: 'tmdb-9527',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: fileExplorerContext
      }

      const nextParam = buildMediaLibraryEpisodeSwitchParam(
        currentParam,
        fileExplorerContext,
        fileExplorerContext.items[1],
        buildResolvedSource('https://example.com/s01e02.mkv')
      )

      expect(nextParam === null).assertTrue()
      expect(fileExplorerContext.currentIndex).assertEqual(0)
    })
  })
}
