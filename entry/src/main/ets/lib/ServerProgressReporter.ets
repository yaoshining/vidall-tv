import { JellyfinClient } from './JellyfinClient';
import { PlexClient } from './PlexClient';

/**
 * 单个 playSessionId 的串行队列状态。
 */
interface SessionQueueState {
  /** 当前正在执行的 Promise 链尾部，新任务追加到尾部实现串行化 */
  tail: Promise<void>;
  /** 是否已发出 stopped，stopped 后不再接受新的 progress */
  stopped: boolean;
}

/**
 * 按 playSessionId 串行化服务器上报请求的队列管理器。
 *
 * 保证：
 * - 同一 playSessionId 的 started/progress/stopped 严格按提交顺序串行执行；
 * - started 内部鉴权 + getPlaybackInfo 完成前，后续 progress 排队等待；
 * - stopped 等待此前所有请求完成后执行，并阻止后续 progress 入队；
 * - stopped 完成后清理该会话状态。
 */
class ServerReportQueue {
  private sessions: Map<string, SessionQueueState> = new Map();

  /**
   * 入队一个 started 任务。
   */
  enqueueStarted(
    serverType: string, serverConfigJson: string, itemId: string,
    playSessionId: string, positionMs: number, durationMs: number
  ): Promise<void> {
    if (playSessionId.length === 0) {
      return this.executeStarted(serverType, serverConfigJson, itemId, playSessionId, positionMs, durationMs);
    }
    const state = this.ensureState(playSessionId);
    const next = state.tail.then(() => {
      return this.executeStarted(serverType, serverConfigJson, itemId, playSessionId, positionMs, durationMs);
    }).catch(() => {});
    state.tail = next;
    return next;
  }

  /**
   * 入队一个 progress 任务。
   */
  enqueueProgress(
    serverType: string, serverConfigJson: string, itemId: string,
    playSessionId: string, positionMs: number, durationMs: number
  ): Promise<void> {
    if (playSessionId.length === 0) {
      return this.executeProgress(serverType, serverConfigJson, itemId, playSessionId, positionMs, durationMs);
    }
    const state = this.ensureState(playSessionId);
    if (state.stopped) {
      console.info('[ServerReportQueue] 会话已 stopped，跳过 progress');
      return Promise.resolve();
    }
    const next = state.tail.then(() => {
      return this.executeProgress(serverType, serverConfigJson, itemId, playSessionId, positionMs, durationMs);
    }).catch(() => {});
    state.tail = next;
    return next;
  }

  /**
   * 入队一个 stopped 任务。
   */
  enqueueStopped(
    serverType: string, serverConfigJson: string, itemId: string,
    playSessionId: string, positionMs: number, durationMs: number
  ): Promise<void> {
    if (playSessionId.length === 0) {
      return this.executeStopped(serverType, serverConfigJson, itemId, playSessionId, positionMs, durationMs);
    }
    const state = this.ensureState(playSessionId);
    state.stopped = true;
    const next = state.tail.then(() => {
      return this.executeStopped(serverType, serverConfigJson, itemId, playSessionId, positionMs, durationMs);
    }).then(() => {
      this.sessions.delete(playSessionId);
    }).catch(() => {
      this.sessions.delete(playSessionId);
    });
    state.tail = next;
    return next;
  }

  private ensureState(playSessionId: string): SessionQueueState {
    let state = this.sessions.get(playSessionId);
    if (!state) {
      const initial: SessionQueueState = { tail: Promise.resolve(), stopped: false };
      state = initial;
      this.sessions.set(playSessionId, state);
    }
    return state;
  }

  private async executeStarted(
    serverType: string, serverConfigJson: string, itemId: string,
    playSessionId: string, positionMs: number, durationMs: number
  ): Promise<void> {
    if (serverType === 'plex') {
      await PlexClient.fromConfigJson(serverConfigJson).reportPlaying(itemId, positionMs, durationMs);
    } else {
      const client = JellyfinClient.fromConfigJson(serverConfigJson);
      const mediaSourceId = await client.getPlaybackInfo(itemId);
      await client.reportPlaying(playSessionId, itemId, mediaSourceId, positionMs);
    }
  }

  private async executeProgress(
    serverType: string, serverConfigJson: string, itemId: string,
    playSessionId: string, positionMs: number, durationMs: number
  ): Promise<void> {
    if (serverType === 'plex') {
      await PlexClient.fromConfigJson(serverConfigJson).reportProgress(itemId, positionMs, durationMs);
    } else {
      await JellyfinClient.fromConfigJson(serverConfigJson).reportProgress(playSessionId, itemId, positionMs, false);
    }
  }

  private async executeStopped(
    serverType: string, serverConfigJson: string, itemId: string,
    playSessionId: string, positionMs: number, durationMs: number
  ): Promise<void> {
    if (serverType === 'plex') {
      await PlexClient.fromConfigJson(serverConfigJson).reportStopped(itemId, positionMs, durationMs);
    } else {
      await JellyfinClient.fromConfigJson(serverConfigJson).reportStopped(playSessionId, itemId, positionMs);
    }
  }
}

/** 全局单例队列 */
const globalQueue = new ServerReportQueue();

/**
 * 上报影视服务器播放开始（会话建立）。按 playSessionId 串行化执行。
 * Jellyfin/Emby 需要 playSessionId 关联整个会话；Plex 通过 ratingKey 关联。
 */
export function reportServerPlaybackStarted(
  serverType: string,
  serverConfigJson: string,
  itemId: string,
  playSessionId: string,
  positionMs: number,
  durationMs: number
): Promise<void> {
  return globalQueue.enqueueStarted(serverType, serverConfigJson, itemId, playSessionId, positionMs, durationMs);
}

/**
 * 周期性上报影视服务器播放进度（不结束会话）。按 playSessionId 串行化执行。
 */
export function reportServerPlaybackProgress(
  serverType: string,
  serverConfigJson: string,
  itemId: string,
  playSessionId: string,
  positionMs: number,
  durationMs: number
): Promise<void> {
  return globalQueue.enqueueProgress(serverType, serverConfigJson, itemId, playSessionId, positionMs, durationMs);
}

/**
 * 上报影视服务器播放停止（退出播放器时调用），供服务器「继续观看」续播。
 * 按 playSessionId 串行化执行；stopped 后不再接受该会话的 progress。
 */
export function reportServerPlaybackStopped(
  serverType: string,
  serverConfigJson: string,
  itemId: string,
  playSessionId: string,
  positionMs: number,
  durationMs: number
): Promise<void> {
  return globalQueue.enqueueStopped(serverType, serverConfigJson, itemId, playSessionId, positionMs, durationMs);
}
