import { AppPreferences, PrefKey } from '../../../utils/AppPreferences'

export interface EpisodeAutoplaySettings {
  enabled: boolean;
  countdownSeconds: number;
}

export const DEFAULT_EPISODE_AUTOPLAY_ENABLED: boolean = true
export const DEFAULT_EPISODE_AUTOPLAY_COUNTDOWN_SECONDS: number = 8
const MIN_EPISODE_AUTOPLAY_COUNTDOWN_SECONDS: number = 3
const MAX_EPISODE_AUTOPLAY_COUNTDOWN_SECONDS: number = 10

export function normalizeEpisodeAutoplayCountdownSeconds(value: number): number {
  if (!Number.isFinite(value) || value <= 0) {
    return DEFAULT_EPISODE_AUTOPLAY_COUNTDOWN_SECONDS
  }
  const roundedValue = Math.round(value)
  if (roundedValue < MIN_EPISODE_AUTOPLAY_COUNTDOWN_SECONDS) {
    return MIN_EPISODE_AUTOPLAY_COUNTDOWN_SECONDS
  }
  if (roundedValue > MAX_EPISODE_AUTOPLAY_COUNTDOWN_SECONDS) {
    return MAX_EPISODE_AUTOPLAY_COUNTDOWN_SECONDS
  }
  return roundedValue
}

export async function loadEpisodeAutoplaySettings(): Promise<EpisodeAutoplaySettings> {
  const enabledValue = await AppPreferences.getNumber(
    PrefKey.PLAYER_EPISODE_AUTOPLAY_ENABLED,
    DEFAULT_EPISODE_AUTOPLAY_ENABLED ? 1 : 0
  )
  const countdownValue = await AppPreferences.getNumber(
    PrefKey.PLAYER_EPISODE_AUTOPLAY_COUNTDOWN_SECONDS,
    DEFAULT_EPISODE_AUTOPLAY_COUNTDOWN_SECONDS
  )
  const settings: EpisodeAutoplaySettings = {
    enabled: enabledValue !== 0,
    countdownSeconds: normalizeEpisodeAutoplayCountdownSeconds(countdownValue)
  }
  return settings
}

export async function saveEpisodeAutoplayEnabled(enabled: boolean): Promise<void> {
  await AppPreferences.set(
    PrefKey.PLAYER_EPISODE_AUTOPLAY_ENABLED,
    enabled ? 1 : 0
  )
}

export async function saveEpisodeAutoplayCountdownSeconds(countdownSeconds: number): Promise<void> {
  await AppPreferences.set(
    PrefKey.PLAYER_EPISODE_AUTOPLAY_COUNTDOWN_SECONDS,
    normalizeEpisodeAutoplayCountdownSeconds(countdownSeconds)
  )
}
