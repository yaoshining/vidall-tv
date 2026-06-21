// filepath: entry/src/main/ets/services/playbackProgress/PlaybackResumeDecision.ets
//
// 续播决策类型契约 + 决策 pure functions。
//
// 背景：原 `PlayerPage` 中持有 4 个 pure function（resolveSavedProgressResumeAction /
// resolveMediaProgressResumeAction / resolvePlayProgressResumeAction）+ 3 个诊断日志事件 +
// `showResumeDialog` 弹窗控制 + `MediaProgressStore.{get, save, clear, isNearEnd}` 的副作用调用。
//
// Module 2 目标：把这些统一收口到 `PlaybackProgressService`，
// `PlayerPage` 仅保留 UI 事件绑定 + 状态字段持有。
//
// 与原 `MediaProgressResumeAction` 的差异：
// - 新增 `action: 'dialog'`（seek 类决策，但要求 page 弹续播弹窗）。
// - 新增 `source` 字段，记录决策来源（pageStartPosition / mediaProgress / playProgress），
//   便于日志与回归定位。
// - 新增 `mediaKey` 字段，clear_and_play 决策时携带，调用方无需自己回查 page state。
//
// 兼容性：
// - 调用方只需在 `PlayerPage` 内做 switch 决策：
//   - `action === 'seek'`：直接 `controller.seek(positionMs, ...)`
//   - `action === 'play'`：直接 `controller.play()`
//   - `action === 'clear_and_play'`：先清 mediaKey 再 play
//   - `action === 'dialog'`：page 设置 `showResumeDialog = true`
// - 原 `PlayerPage` 内的 `MediaProgressResumeAction` / `MediaProgressResumeActionType` /
//   `resolveMediaProgressResumeAction` / `resolvePlayProgressResumeAction` /
//   `resolveSavedProgressResumeAction` 由 player 改用 re-export，保持外部 import 兼容性。

import { MediaProgressEntry, PlayProgressEntity } from "../../db/models/MediaEntity";
import { MediaProgressStore } from "../../db/MediaProgressStore";

/** 续播动作。 */
export type PlaybackResumeAction = 'seek' | 'play' | 'clear_and_play' | 'dialog';

/** 续播决策来源，便于日志与回归定位。 */
export type PlaybackResumeSource = 'pageStartPosition' | 'mediaProgress' | 'playProgress';

/** 续播决策。 */
export interface PlaybackResumeDecision {
  action: PlaybackResumeAction;
  /** 仅 seek / dialog 时使用。 */
  positionMs?: number;
  /** 仅 clear_and_play 时使用。 */
  mediaKey?: string;
  /** 决策来源，供诊断日志使用。 */
  source?: PlaybackResumeSource;
}

/** `decideMediaResume` 的入参。 */
export interface MediaResumeInput {
  mediaKey: string;
  pageStartPositionMs: number;
  currentDurationMs: number;
  currentSeason: number;
  currentEpisode: number;
}

/** `decidePlayResume` 的入参。 */
export interface PlayResumeInput {
  videoId: number;
  currentDurationMs: number;
  pageStartPositionMs: number;
}

// ─────────────────────────────────────────────────────────────────────────────
// 原 `PlayerPage` 顶层 export 的 3 个决策 pure function 迁移至此。
// PlayerPage 通过 re-export 保持对外接口兼容。
// ─────────────────────────────────────────────────────────────────────────────

/** 续播动作类型，与原 `PlayerPage.MediaProgressResumeActionType` 等价。 */
export type MediaProgressResumeActionType = 'seek' | 'play' | 'clear_and_play';

/** 续播决策结果，与原 `PlayerPage.MediaProgressResumeAction` 等价。 */
export interface MediaProgressResumeAction {
  action: MediaProgressResumeActionType;
  positionMs?: number;
}

/**
 * 基础位置 → 续播决策。
 *
 * 行为与原 `PlayerPage.resolveSavedProgressResumeAction` 字节级一致：
 * - positionMs <= 0 → play
 * - isNearEnd → clear_and_play
 * - 否则 → seek
 */
export function resolveSavedProgressResumeAction(
  positionMs: number,
  savedDurationMs: number,
  currentDurationMs: number
): MediaProgressResumeAction {
  if (positionMs <= 0) {
    return { action: 'play' };
  }
  const effectiveDurationMs = currentDurationMs > 0 ? currentDurationMs : savedDurationMs;
  if (MediaProgressStore.isNearEnd(positionMs, effectiveDurationMs)) {
    return { action: 'clear_and_play' };
  }
  return {
    action: 'seek',
    positionMs
  };
}

/**
 * 媒体级（media_progress）续播决策。
 *
 * 行为与原 `PlayerPage.resolveMediaProgressResumeAction` 字节级一致：
 * - 无记录 → play
 * - 季/集不匹配 → play
 * - 命中 → 走 `resolveSavedProgressResumeAction`
 */
export function resolveMediaProgressResumeAction(
  saved: MediaProgressEntry | null,
  currentDurationMs: number,
  currentSeason: number,
  currentEpisode: number
): MediaProgressResumeAction {
  if (saved === null) {
    return { action: 'play' };
  }
  if (saved.seasonNumber !== currentSeason || saved.episodeNumber !== currentEpisode) {
    return { action: 'play' };
  }
  return resolveSavedProgressResumeAction(saved.positionMs, saved.durationMs, currentDurationMs);
}

/**
 * 视频级（play_progress）续播决策。
 *
 * 行为与原 `PlayerPage.resolvePlayProgressResumeAction` 字节级一致。
 */
export function resolvePlayProgressResumeAction(
  saved: PlayProgressEntity | null,
  currentDurationMs: number
): MediaProgressResumeAction {
  if (saved === null) {
    return { action: 'play' };
  }
  return resolveSavedProgressResumeAction(saved.positionMs, saved.durationMs, currentDurationMs);
}

