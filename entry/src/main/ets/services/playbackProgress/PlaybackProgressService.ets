// filepath: entry/src/main/ets/services/playbackProgress/PlaybackProgressService.ets
//
// PlaybackProgressService - 续播决策 + 持久化编排 façade。
//
// 目标：把 `PlayerPage` 中分散的续播决策（prepared resume、续播弹窗、clear-and-play）与
// 持久化逻辑（定时/切后台/退出/切集）统一收口到 service。
//
// 约束：
// 1. 不修改 `MediaProgressStore` / `FileSourceDatabase` / `VideoPlayerController` 的现有签名。
// 2. 不修改 `PlayerPageParam` 字段，保持现有播放入口契约。
// 3. UI 状态（`showResumeDialog` / `pendingSeekMs` / `savedPositionMs` / `totalDurationMs`）仍由
//    `PlayerPage` 持有，service 仅通过回调 `onResumeDialog` 通知 page 设置。
//
// 设计要点：
// - service 是无状态 façade，副作用通过 `options` 注入：
//   - `controller` 用于读 currentTime / duration / 调 saveProgressNow
//   - `getContext` 用于读当前 mediaKey / season / episode
//   - `emitDiagnostic` / `onResumeDialog` 用于通知 page UI
// - 决策与持久化逻辑完全复用 `PlayerPage.resolveMediaProgressResumeAction` /
//   `resolvePlayProgressResumeAction` / `resolveSavedProgressResumeAction`（这些 pure function
//   仍由 page export，service 通过依赖注入方式调用，避免逻辑重复）。
//
// 行为兼容：
// - 原 `resumePlaybackForParam` 中 `pageParam.startPositionMs > 0` 直接 seek 的逻辑
//   → `decideMediaResume` 返回 `action: 'seek', source: 'pageStartPosition'`
// - 原 `mediaKey` 路径续播弹窗 / clear-and-play 逻辑
//   → `decideMediaResume` 走 `MediaProgressStore.get` 决策
// - 原 `videoId` 路径续播弹窗逻辑
//   → `decidePlayResume` 走 `FileSourceDatabase.getPlayProgress` 决策
// - 原 `persistCurrentPlaybackState` 保存逻辑
//   → `persistNow` 一步完成 `controller.saveProgressNow` + media_progress 落库/清理

import { FileSourceDatabase } from "../../db/files/FileSourceDatabase";
import { MediaProgressStore } from "../../db/MediaProgressStore";
import { MediaProgressEntry, PlayProgressEntity } from "../../db/models/MediaEntity";
import { VideoPlayerController } from "../../components/core/player/VideoPlayerController";
import {
  MediaResumeInput,
  MediaProgressResumeAction,
  PlayResumeInput,
  PlaybackResumeDecision,
  resolveMediaProgressResumeAction,
  resolvePlayProgressResumeAction
} from "./PlaybackResumeDecision";

/**
 * service 配置项。
 *
 * 所有副作用入口都通过 options 注入，service 本身只做决策与编排。
 * 这样 page 仍能：
 * - 持有 UI 状态（`showResumeDialog` / `pendingSeekMs` 等）
 * - 决定何时调用 service（prepared / 切后台 / 退出 / 切集）
 * - 决定诊断日志的输出格式
 */
export interface PlaybackProgressServiceOptions {
  /** 用于读 currentTime / duration / 调 saveProgressNow。 */
  controller: VideoPlayerController;
  /**
   * 当前页面上下文 getter。
   * 每次调用都重新读取，避免在切集后 page 改了 state 但 service 仍持有旧值的歧义。
   */
  getContext: () => PlaybackProgressContext;
  /**
   * 续播弹窗触发回调：当 service 决策 `action: 'dialog'` 时调用。
   * page 端在此设置 `showResumeDialog = true` 与 `pendingSeekMs`。
   */
  onResumeDialog?: (positionMs: number) => void;
}

/**
 * page 提供的当前播放上下文。
 *
 * 与 `PlayerPage` 中 `currentMediaKey` / `currentMediaSeason` / `currentMediaEpisode`
 * 三字段等价；service 通过 `getContext()` 每次重读，避免在切集后不一致。
 */
export interface PlaybackProgressContext {
  mediaKey: string;
  season: number;
  episode: number;
}

/**
 * `persistNow` 的可选项。
 *
 * - `forceMediaWrite` = true：即使 controller.duration <= 0 也尝试写 media_progress。
 *   （原 `persistCurrentPlaybackState` 在 `durMs <= 0` 时直接 return，这里保留相同行为，
 *   调用方一般不需要 force。）
 * - `emitSaved` = true：调用方负责在 save 完成后 emit `MEDIA_PROGRESS_SAVED` 事件，
 *   service 自身不发（service 不持有 emitter 引用，避免与 page UI 事件耦合）。
 */
export interface PersistOptions {
  forceMediaWrite?: boolean;
  emitSaved?: boolean;
}

/** `persistNow` 的执行结果，便于 page 决定是否要 emit `MEDIA_PROGRESS_SAVED`。 */
export type PersistOutcome =
  /** mediaKey 为空，无可写目标。page 不 emit。 */
  | 'noop_no_media_key'
  /** durMs <= 0，跳过完播判断避免误清除。page 不 emit。 */
  | 'skipped_no_duration'
  /** posMs = 0（duration 有效），原行为是仍 emit 以通知 ContinueWatchCard 刷新。 */
  | 'noop_position_zero'
  /** near-end 触发 MediaProgressStore.clear。page 应 emit。 */
  | 'cleared'
  /** 正常落库 MediaProgressStore.save。page 应 emit。 */
  | 'saved';

export class PlaybackProgressService {
  private readonly options: PlaybackProgressServiceOptions;

  constructor(options: PlaybackProgressServiceOptions) {
    this.options = options;
  }

  /**
   * 媒体级续播决策（mediaKey 路径）。
   *
   * 与原 `PlayerPage.resumePlaybackForParam` 中 `mediaKey.length > 0` 分支等价：
   * 1. 若 `pageStartPositionMs > 0`，直接 seek。
   * 2. 否则读 `MediaProgressStore.get(mediaKey)` 决策。
   * 3. `clear_and_play` 决策返回时，page 端在 effect 副作用里调 `MediaProgressStore.clear`。
   *
   * 调用方在收到决策后按 `action` 分支执行：
   * - `seek` → `controller.seek(positionMs, 'prepared_resume_seek')`
   * - `play` → `controller.rememberResumeAutoplayDecision(true, ...) + controller.play()`
   * - `clear_and_play` → `MediaProgressStore.clear(mediaKey).catch(()=>{})` 然后 play
   */
  async decideMediaResume(input: MediaResumeInput): Promise<PlaybackResumeDecision> {
    if (input.mediaKey.length === 0) {
      return { action: 'play' };
    }
    if (input.pageStartPositionMs > 0) {
      return {
        action: 'seek',
        positionMs: input.pageStartPositionMs,
        source: 'pageStartPosition'
      };
    }
    let saved: MediaProgressEntry | null = null;
    try {
      saved = await MediaProgressStore.get(input.mediaKey);
    } catch {
      saved = null;
    }
    const resumeAction: MediaProgressResumeAction = resolveMediaProgressResumeAction(
      saved,
      input.currentDurationMs,
      input.currentSeason,
      input.currentEpisode
    );
    if (resumeAction.action === 'seek' && resumeAction.positionMs !== undefined) {
      return {
        action: 'seek',
        positionMs: resumeAction.positionMs,
        source: 'mediaProgress'
      };
    }
    if (resumeAction.action === 'clear_and_play') {
      return {
        action: 'clear_and_play',
        mediaKey: input.mediaKey,
        source: 'mediaProgress'
      };
    }
    return { action: 'play', source: 'mediaProgress' };
  }

  /**
   * 视频级续播决策（videoId 路径）。
   *
   * 与原 `PlayerPage.registerPreparedResume` 中 prepared 后的逻辑等价：
   * 1. `pageStartPositionMs > 0` → seek
   * 2. 否则读 `FileSourceDatabase.getPlayProgress(videoId)` 决策
   * 3. `clear_and_play` 时 page 端需按 `buildProgressContext(pageParam)` 回写 play_progress
   * 4. `dialog` 时通过 `onResumeDialog` 回调通知 page
   */
  async decidePlayResume(input: PlayResumeInput): Promise<PlaybackResumeDecision> {
    if (input.videoId <= 0) {
      return { action: 'play', source: 'playProgress' };
    }
    if (input.pageStartPositionMs > 0) {
      this.options.onResumeDialog?.(input.pageStartPositionMs);
      return {
        action: 'dialog',
        positionMs: input.pageStartPositionMs,
        source: 'pageStartPosition'
      };
    }
    let saved: PlayProgressEntity | null = null;
    try {
      saved = await FileSourceDatabase.getInstance().getPlayProgress(input.videoId);
    } catch {
      saved = null;
    }
    const resumeAction: MediaProgressResumeAction = resolvePlayProgressResumeAction(
      saved,
      input.currentDurationMs
    );
    if (resumeAction.action === 'seek' && resumeAction.positionMs !== undefined) {
      this.options.onResumeDialog?.(resumeAction.positionMs);
      return {
        action: 'dialog',
        positionMs: resumeAction.positionMs,
        source: 'playProgress'
      };
    }
    if (resumeAction.action === 'clear_and_play') {
      return {
        action: 'clear_and_play',
        source: 'playProgress'
      };
    }
    return { action: 'play', source: 'playProgress' };
  }

  /**
   * 持久化当前播放状态。
   *
   * 调用时机：
   * - 退出播放（aboutToDisappear）
   * - 切后台（onPageHide）
   * - 切集前（handleEpisodeSelect）
   * - 10s 定时（VideoPlayerController.startProgressTimer）
   *
   * 步骤：
   * 1. 调 `controller.saveProgressNow()` 写 play_progress（保留 controller 既有防抖逻辑）。
   * 2. 若 `getContext().mediaKey` 非空、`controller.duration > 0` 且 `controller.currentTime > 0`：
   *    - near-end → `MediaProgressStore.clear(mediaKey)`
   *    - 否则 → `MediaProgressStore.save(...)`
   *
   * 返回 `PersistOutcome` 让 page 决定是否要 emit `MEDIA_PROGRESS_SAVED`：
   * - `'cleared'` / `'saved'` → page 应 emit
   * - `'noop_position_zero'` → page 仍 emit（保持原 `posMs=0` 路径行为兼容）
   * - `'noop_no_media_key'` → page 不 emit
   * - `'skipped_no_duration'` → page 不 emit
   *
   * 与原 `PlayerPage.persistCurrentPlaybackState` 行为字节级一致。
   */
  async persistNow(options?: PersistOptions): Promise<PersistOutcome> {
    this.options.controller.saveProgressNow();
    const ctx = this.options.getContext();
    if (ctx.mediaKey.length === 0) {
      return 'noop_no_media_key';
    }
    const posMs = this.options.controller.currentTime;
    const durMs = this.options.controller.duration;
    if (durMs <= 0) {
      if (options?.forceMediaWrite !== true) {
        return 'skipped_no_duration';
      }
    }
    if (MediaProgressStore.isNearEnd(posMs, durMs)) {
      await MediaProgressStore.clear(ctx.mediaKey).catch(() => {});
      return 'cleared';
    }
    if (posMs > 0 && durMs > 0) {
      await MediaProgressStore.save(
        ctx.mediaKey,
        posMs,
        durMs,
        ctx.season,
        ctx.episode
      ).catch(() => {});
      return 'saved';
    }
    return 'noop_position_zero';
  }
}

/**
 * 默认 service 工厂。
 *
 * 用法（`PlayerPage` 内）：
 * ```typescript
 * private get progressService(): PlaybackProgressService {
 *   if (this._progressService === undefined) {
 *     this._progressService = new PlaybackProgressService({
 *       controller: this.videoPlayerController,
 *       getContext: (): PlaybackProgressContext => ({
 *         mediaKey: this.currentMediaKey,
 *         season: this.currentMediaSeason,
 *         episode: this.currentMediaEpisode
 *       }),
 *       onResumeDialog: (pos: number): void => {
 *         this.pendingSeekMs = pos;
 *         this.showResumeDialog = true;
 *       }
 *     });
 *   }
 *   return this._progressService;
 * }
 * ```
 */
export function buildPlaybackProgressService(
  options: PlaybackProgressServiceOptions
): PlaybackProgressService {
  return new PlaybackProgressService(options);
}
