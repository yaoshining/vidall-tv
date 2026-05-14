import { describe, it, expect } from '@ohos/hypium'
import {
  buildContinueWatchPlayerParam,
  ContinueWatchPlayerParamInput
} from '../main/ets/components/media/ContinueWatchCard'
import { ContinueWatchingItem } from '../main/ets/db/models/MediaEntity'
import { PresetAudioTrack, PresetSubtitleTrack } from '../main/ets/components/core/player/VideoData'
import { PlayerPageParam } from '../main/ets/pages/player/index'

function buildContinueWatchingItem(): ContinueWatchingItem {
  return {
    mediaKey: 'media_progress_movie_tmdb_1',
    title: 'Demo Movie',
    posterLocalPath: '',
    posterUrl: '',
    backdropLocalPath: '',
    backdropUrl: '',
    kind: 'movie',
    progressRatio: 0.5,
    positionFormatted: '00:10:00',
    durationFormatted: '00:20:00',
    lastPlayedAt: 123456789,
    seasonNumber: 0,
    episodeNumber: 0,
    episodeTitle: '',
    videoId: 99,
    tvSeriesId: 0,
    startPositionMs: 600000,
    sourceId: 7,
    filePath: '/library/demo.mkv',
    durationMs: 1000,
    seriesProviderId: ''
  }
}

function buildAudioTracks(): PresetAudioTrack[] {
  return [{
    trackIndex: 2,
    displayName: '国语 (E-AC-3)',
    language: 'chi',
    channels: 6
  }]
}

function buildSubtitleTracks(): PresetSubtitleTrack[] {
  return [{
    trackIndex: 5,
    displayName: 'English (SRT)',
    codecName: 'subrip'
  }]
}

export default function continueWatchCardTest(): void {
  describe('ContinueWatchCard_player_param', () => {
    it('首页继续播放会把数据库缓存的轨道与时长写入播放器参数', 0, () => {
      const httpHeader: Record<string, string> = {
        'Authorization': 'Basic xxx'
      }
      const input: ContinueWatchPlayerParamInput = {
        item: buildContinueWatchingItem(),
        fullUrl: 'https://dav.example.com/media/library/demo.mkv',
        httpHeader,
        title: 'Demo Movie',
        durationHintMs: 543210,
        presetAudioTracks: buildAudioTracks(),
        presetSubtitleTracks: buildSubtitleTracks()
      }

      const param: PlayerPageParam = buildContinueWatchPlayerParam(input)

      expect(param.durationHintMs ?? 0).assertEqual(543210)
      expect(param.presetAudioTracks?.length ?? 0).assertEqual(1)
      expect(param.presetSubtitleTracks?.length ?? 0).assertEqual(1)
      expect(param.presetAudioTracks?.[0].trackIndex ?? -1).assertEqual(2)
      expect(param.presetSubtitleTracks?.[0].trackIndex ?? -1).assertEqual(5)
      expect(param.startPositionMs ?? 0).assertEqual(600000)
      expect(param.mediaKey ?? '').assertEqual('media_progress_movie_tmdb_1')
    })
  })
}
