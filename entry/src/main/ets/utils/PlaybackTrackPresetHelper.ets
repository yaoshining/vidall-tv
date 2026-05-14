import { VideoEntity } from '../db/models/MediaEntity'
import { PresetAudioTrack, PresetSubtitleTrack } from '../components/core/player/VideoData'
import { FfprobeUtil, FfprobeTrack } from './FfprobeUtil'

export interface PlaybackTrackPresetResult {
  durationHintMs?: number
  presetAudioTracks?: PresetAudioTrack[]
  presetSubtitleTracks?: PresetSubtitleTrack[]
}

export type PlaybackTrackVideoLoader = (filePath: string) => Promise<VideoEntity | null>

export async function resolvePlaybackTrackPresetFromDb(
  filePath: string,
  fallbackDurationMs: number,
  loadVideoByPath: PlaybackTrackVideoLoader
): Promise<PlaybackTrackPresetResult> {
  let durationHintMs: number | undefined = fallbackDurationMs > 0 ? fallbackDurationMs : undefined
  let presetAudioTracks: PresetAudioTrack[] | undefined = undefined
  let presetSubtitleTracks: PresetSubtitleTrack[] | undefined = undefined

  try {
    const videoEntity = await loadVideoByPath(filePath)
    if (videoEntity !== null) {
      if (videoEntity.durationMs !== undefined && videoEntity.durationMs !== null && videoEntity.durationMs > 0) {
        durationHintMs = videoEntity.durationMs
      }
      if (videoEntity.audioTracksJson !== undefined && videoEntity.audioTracksJson !== null &&
        videoEntity.audioTracksJson.length > 0) {
        const tracks = JSON.parse(videoEntity.audioTracksJson) as FfprobeTrack[]
        const resolvedTracks = FfprobeUtil.toPresetAudioTracks(tracks)
        if (resolvedTracks.length > 0) {
          presetAudioTracks = resolvedTracks
        }
      }
      if (videoEntity.subtitleTracksJson !== undefined && videoEntity.subtitleTracksJson !== null &&
        videoEntity.subtitleTracksJson.length > 0) {
        const tracks = JSON.parse(videoEntity.subtitleTracksJson) as FfprobeTrack[]
        const resolvedTracks = FfprobeUtil.toPresetSubtitleTracks(tracks)
        if (resolvedTracks.length > 0) {
          presetSubtitleTracks = resolvedTracks
        }
      }
    }
  } catch (_e) {
  }

  const result: PlaybackTrackPresetResult = {}
  if (durationHintMs !== undefined && durationHintMs > 0) {
    result.durationHintMs = durationHintMs
  }
  if (presetAudioTracks !== undefined && presetAudioTracks.length > 0) {
    result.presetAudioTracks = presetAudioTracks
  }
  if (presetSubtitleTracks !== undefined && presetSubtitleTracks.length > 0) {
    result.presetSubtitleTracks = presetSubtitleTracks
  }
  return result
}
