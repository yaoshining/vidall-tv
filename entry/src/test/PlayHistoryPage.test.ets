import { describe, it, expect } from '@ohos/hypium'
import { FfprobeTrack } from '../main/ets/utils/FfprobeUtil'
import { VideoEntity } from '../main/ets/db/models/MediaEntity'
import { resolvePlaybackTrackPresetFromDb } from '../main/ets/utils/PlaybackTrackPresetHelper'

function buildAudioTrackFixture(): FfprobeTrack[] {
  const track: FfprobeTrack = {
    index: 2,
    type: 'audio',
    codecName: 'eac3',
    codecLongName: 'E-AC-3',
    language: 'chi',
    title: '国语',
    channels: 6,
    channelLayout: '5.1'
  }
  return [track]
}

function buildSubtitleTrackFixture(): FfprobeTrack[] {
  const track: FfprobeTrack = {
    index: 5,
    type: 'subtitle',
    codecName: 'subrip',
    codecLongName: 'SubRip subtitle',
    language: 'eng',
    title: 'English'
  }
  return [track]
}

function buildVideoEntity(): VideoEntity {
  return {
    sourceId: 7,
    directoryPath: '/video',
    filePath: '/video/demo.mkv',
    fileName: 'demo.mkv',
    durationMs: 543210,
    audioTracksJson: JSON.stringify(buildAudioTrackFixture()),
    subtitleTracksJson: JSON.stringify(buildSubtitleTrackFixture()),
    scannedAt: 123456789
  }
}

export default function playHistoryPageTest(): void {
  describe('PlayHistoryPage_track_preset_resolution', () => {
    it('fills player presets from database cached tracks', 0, async () => {
      const result = await resolvePlaybackTrackPresetFromDb(
        '/video/demo.mkv',
        120000,
        async (_filePath: string): Promise<VideoEntity | null> => buildVideoEntity()
      )

      expect(result.durationHintMs ?? 0).assertEqual(543210)
      expect(result.presetAudioTracks?.length ?? 0).assertEqual(1)
      expect(result.presetSubtitleTracks?.length ?? 0).assertEqual(1)
      expect(result.presetAudioTracks?.[0].trackIndex ?? -1).assertEqual(2)
      expect(result.presetSubtitleTracks?.[0].trackIndex ?? -1).assertEqual(5)
    })

    it('keeps playback fallback when database lookup fails', 0, async () => {
      const result = await resolvePlaybackTrackPresetFromDb(
        '/video/demo.mkv',
        246800,
        async (_filePath: string): Promise<VideoEntity | null> => {
          throw new Error('db failed')
        }
      )

      expect(result.durationHintMs ?? 0).assertEqual(246800)
      expect(result.presetAudioTracks === undefined).assertTrue()
      expect(result.presetSubtitleTracks === undefined).assertTrue()
    })
  })
}
