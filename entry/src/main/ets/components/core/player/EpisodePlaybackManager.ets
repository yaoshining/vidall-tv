import { PlaybackContext, PlaybackContextItem } from './PlaybackContext'
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
    const context = this.getContextForAutoplay(playbackContext)
    const currentEpisodeKey = this.getCurrentEpisodeKeyFromContext(context)
    if (currentEpisodeKey !== this.activeEpisodeKey) {
      this.activeEpisodeKey = currentEpisodeKey
      this.suppressedEpisodeKey = ''
    }
    if (!this.autoplayEnabled || context === undefined || durationMs <= 0 || currentEpisodeKey.length === 0) {
      return buildIdleEpisodePlaybackManagerState()
    }
    const nextItem = this.getNextItemFromContext(context)
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

  private getContextForAutoplay(playbackContext: PlaybackContext | undefined): PlaybackContext | undefined {
    if (playbackContext === undefined) {
      return undefined
    }
    if (playbackContext.contextType === 'media_library' || playbackContext.contextType === 'file_explorer') {
      return playbackContext
    }
    return undefined
  }

  private getCurrentEpisodeKeyFromContext(context: PlaybackContext | undefined): string {
    if (context === undefined) {
      return ''
    }
    if (context.currentIndex < 0 || context.currentIndex >= context.items.length) {
      return ''
    }
    const currentItem = context.items[context.currentIndex]
    return currentItem.videoPath
  }

  private getNextItemFromContext(context: PlaybackContext): PlaybackContextItem | null {
    if (!context.hasNext) {
      return null
    }
    const nextIndex = context.currentIndex + 1
    if (nextIndex < 0 || nextIndex >= context.items.length) {
      return null
    }
    return context.items[nextIndex]
  }
}
