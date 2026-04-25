import { MediaLibraryContext, PlaybackContext, PlaybackContextItem } from './PlaybackContext'
import {
  DEFAULT_EPISODE_AUTOPLAY_COUNTDOWN_SECONDS,
  DEFAULT_EPISODE_AUTOPLAY_ENABLED,
  normalizeEpisodeAutoplayCountdownSeconds
} from './EpisodeAutoplayPreferences'

export interface EpisodePlaybackManagerState {
  visible: boolean;
  remainingSeconds: number;
  nextItem: PlaybackContextItem | null;
  shouldPlayNext: boolean;
}

function buildIdleEpisodePlaybackManagerState(): EpisodePlaybackManagerState {
  const state: EpisodePlaybackManagerState = {
    visible: false,
    remainingSeconds: 0,
    nextItem: null,
    shouldPlayNext: false
  }
  return state
}

export class EpisodePlaybackManager {
  private autoplayEnabled: boolean = DEFAULT_EPISODE_AUTOPLAY_ENABLED
  private countdownSeconds: number = DEFAULT_EPISODE_AUTOPLAY_COUNTDOWN_SECONDS
  private activeEpisodeKey: string = ''
  private suppressedEpisodeKey: string = ''

  updateSettings(enabled: boolean, countdownSeconds: number): void {
    this.autoplayEnabled = enabled
    this.countdownSeconds = normalizeEpisodeAutoplayCountdownSeconds(countdownSeconds)
  }

  clear(): void {
    this.activeEpisodeKey = ''
    this.suppressedEpisodeKey = ''
  }

  cancelCurrentEpisode(): void {
    if (this.activeEpisodeKey.length > 0) {
      this.suppressedEpisodeKey = this.activeEpisodeKey
    }
  }

  markAutoplayFailed(): void {
    this.cancelCurrentEpisode()
  }

  sync(playbackContext: PlaybackContext | undefined, currentTimeMs: number, durationMs: number): EpisodePlaybackManagerState {
    const mediaLibraryContext = this.getMediaLibraryContext(playbackContext)
    const currentEpisodeKey = this.getCurrentEpisodeKey(mediaLibraryContext)
    if (currentEpisodeKey !== this.activeEpisodeKey) {
      this.activeEpisodeKey = currentEpisodeKey
      this.suppressedEpisodeKey = ''
    }
    if (!this.autoplayEnabled || mediaLibraryContext === undefined || durationMs <= 0 || currentEpisodeKey.length === 0) {
      return buildIdleEpisodePlaybackManagerState()
    }
    const nextItem = this.getNextItem(mediaLibraryContext)
    if (nextItem === null || this.suppressedEpisodeKey === currentEpisodeKey) {
      return buildIdleEpisodePlaybackManagerState()
    }
    const remainingMs = durationMs - Math.max(currentTimeMs, 0)
    if (remainingMs > this.countdownSeconds * 1000) {
      return buildIdleEpisodePlaybackManagerState()
    }
    if (remainingMs <= 0) {
      const state: EpisodePlaybackManagerState = {
        visible: false,
        remainingSeconds: 0,
        nextItem,
        shouldPlayNext: true
      }
      return state
    }
    const state: EpisodePlaybackManagerState = {
      visible: true,
      remainingSeconds: Math.ceil(remainingMs / 1000),
      nextItem,
      shouldPlayNext: false
    }
    return state
  }

  private getMediaLibraryContext(playbackContext: PlaybackContext | undefined): MediaLibraryContext | undefined {
    if (playbackContext === undefined || playbackContext.contextType !== 'media_library') {
      return undefined
    }
    return playbackContext as MediaLibraryContext
  }

  private getCurrentEpisodeKey(playbackContext: MediaLibraryContext | undefined): string {
    if (playbackContext === undefined) {
      return ''
    }
    if (playbackContext.currentIndex < 0 || playbackContext.currentIndex >= playbackContext.items.length) {
      return ''
    }
    const currentItem = playbackContext.items[playbackContext.currentIndex]
    return currentItem.videoPath
  }

  private getNextItem(playbackContext: MediaLibraryContext): PlaybackContextItem | null {
    if (!playbackContext.hasNext) {
      return null
    }
    const nextIndex = playbackContext.currentIndex + 1
    if (nextIndex < 0 || nextIndex >= playbackContext.items.length) {
      return null
    }
    return playbackContext.items[nextIndex]
  }
}
