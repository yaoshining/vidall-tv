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
  private estimatedPositionMs: number = 0
  private lastObservedPositionMs: number = 0
  private lastSyncAtMs: number = 0

  private static readonly POSITION_ROLLBACK_TOLERANCE_MS: number = 1000

  updateSettings(enabled: boolean, countdownSeconds: number): void {
    this.autoplayEnabled = enabled
    this.countdownSeconds = normalizeEpisodeAutoplayCountdownSeconds(countdownSeconds)
  }

  clear(): void {
    this.activeEpisodeKey = ''
    this.suppressedEpisodeKey = ''
    this.resetEstimatedPosition()
  }

  private resetEstimatedPosition(): void {
    this.estimatedPositionMs = 0
    this.lastObservedPositionMs = 0
    this.lastSyncAtMs = 0
  }

  private updateEstimatedPosition(currentTimeMs: number, nowMs: number, isPlaying: boolean): number {
    const safeCurrentTimeMs = Math.max(currentTimeMs, 0)
    if (this.lastSyncAtMs <= 0 ||
      safeCurrentTimeMs + EpisodePlaybackManager.POSITION_ROLLBACK_TOLERANCE_MS < this.lastObservedPositionMs) {
      this.estimatedPositionMs = safeCurrentTimeMs
    } else {
      const elapsedMs = isPlaying ? Math.max(nowMs - this.lastSyncAtMs, 0) : 0
      this.estimatedPositionMs = Math.max(safeCurrentTimeMs, this.estimatedPositionMs + elapsedMs)
    }
    this.lastObservedPositionMs = safeCurrentTimeMs
    this.lastSyncAtMs = nowMs
    return this.estimatedPositionMs
  }

  cancelCurrentEpisode(): void {
    if (this.activeEpisodeKey.length > 0) {
      this.suppressedEpisodeKey = this.activeEpisodeKey
    }
  }

  markAutoplayFailed(): void {
    this.cancelCurrentEpisode()
  }

  sync(
    playbackContext: PlaybackContext | undefined,
    currentTimeMs: number,
    durationMs: number,
    nowMs: number = Date.now(),
    isPlaying: boolean = true
  ): EpisodePlaybackManagerState {
    const context = this.getContextForAutoplay(playbackContext)
    const currentEpisodeKey = this.getCurrentEpisodeKeyFromContext(context)
    if (currentEpisodeKey !== this.activeEpisodeKey) {
      this.activeEpisodeKey = currentEpisodeKey
      this.suppressedEpisodeKey = ''
      this.resetEstimatedPosition()
    }
    if (!this.autoplayEnabled || context === undefined || durationMs <= 0 || currentEpisodeKey.length === 0) {
      this.resetEstimatedPosition()
      return buildIdleEpisodePlaybackManagerState()
    }
    const nextItem = this.getNextItemFromContext(context)
    if (nextItem === null || this.suppressedEpisodeKey === currentEpisodeKey) {
      return buildIdleEpisodePlaybackManagerState()
    }
    const estimatedPositionMs = this.updateEstimatedPosition(currentTimeMs, nowMs, isPlaying)
    const remainingMs = durationMs - estimatedPositionMs
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
    if (playbackContext.contextType === 'media_library' || playbackContext.contextType === 'file_explorer' || playbackContext.contextType === 'server_media_library') {
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
