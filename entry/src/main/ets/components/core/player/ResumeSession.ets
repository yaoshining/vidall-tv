/**
 * 续播（resume）会话对象。
 *
 * 把 VideoPlayerController 中三层续播状态收敛为单一对象：
 * - pending：跨后端/实例保持的续播数据（原 PendingResumeState）
 * - decision：自动播放决策（原 pending/prepared × explicit/has/source 六字段）
 * - seek：续播 seek 事务（原 pendingResumeSeek* + pendingReadyTrackInit* + 超时兜底）
 * - result：续播自动播放执行结果观察上下文
 *
 * 仅承载「纯数据操作」；涉及 controller 其它状态（playbackSessionId / currentTime /
 * backend / play()）的日志与编排逻辑仍留在 VideoPlayerController。
 */

/** 播放后端字面量（与 VideoPlayerController 的 PlayerBackend 结构一致，避免循环依赖） */
export type ResumeBackend = 'avplayer' | 'mpv';

export interface PendingResumeState {
  positionMs: number;
  shouldResumePlay: boolean;
  autoplayDecisionSource: string;
  autoplayDecisionOrigin: string;
  sourceKey: string;
  reason: string;
  captureBackend: ResumeBackend;
}

export interface ResumeAutoplayDecision {
  shouldResumePlay: boolean;
  source: string;
  origin: string;
}

export interface PendingResumeAutoplayResultState {
  resumeSource: string;
  captureBackend: ResumeBackend;
  pendingResumeMs: number;
  effectiveResumeMs: number;
  shouldResumePlay: boolean;
  autoplayDecision: string;
  autoplayDecisionSource: string;
  autoplayDecisionOrigin: string;
}

export class ResumeSession {
  // ── pending 分区（第 1 层：跨后端续播数据）──
  pending: PendingResumeState | null = null;

  // ── decision 分区（第 2 层：自动播放决策）──
  decisionExplicit: boolean = false;
  hasDecisionExplicit: boolean = false;
  decisionSource: string = '';
  preparedExplicit: boolean = false;
  hasPreparedExplicit: boolean = false;
  preparedSource: string = '';
  preserveOnPaused: boolean = false;

  // ── seek 分区（第 3 层：续播 seek 事务 + 超时兜底）──
  seekInFlight: boolean = false;
  seekSource: string = '';
  seekCaptureBackend: ResumeBackend = 'avplayer';
  seekTargetMs: number = -1;
  seekAutoPlay: boolean = false;
  trackInitAfterSeek: boolean = false;
  trackInitResumePlay: boolean = false;
  suppressPlayAfterSeek: boolean = false;
  fallbackTimer?: number;
  fallbackSessionId: number = 0;
  fallbackTriggered: boolean = false;

  // ── result 分区 ──
  result: PendingResumeAutoplayResultState | null = null;

  /** 创建默认 pending 状态（对应原 ensurePendingResumeState） */
  ensurePending(backend: ResumeBackend, sourceKey: string): PendingResumeState {
    if (this.pending === null) {
      this.pending = {
        positionMs: -1,
        shouldResumePlay: false,
        autoplayDecisionSource: 'compat_override',
        autoplayDecisionOrigin: 'compat',
        sourceKey: sourceKey,
        reason: 'compat_override',
        captureBackend: backend
      };
    }
    return this.pending;
  }

  /** 空 pending 则清空（对应原 prunePendingResumeState） */
  prunePending(): void {
    if (this.pending === null) {
      return;
    }
    if (this.pending.positionMs < 0 && !this.pending.shouldResumePlay) {
      this.pending = null;
    }
  }

  /** 取出并清空 pending（对应原 consumePendingResumeState） */
  consumePending(): PendingResumeState | null {
    const pendingState = this.pending;
    this.pending = null;
    return pendingState;
  }

  /** 归一化续播位置（对应原 normalizePendingResumePosition） */
  normalizePosition(positionMs: number, durationMs: number): number {
    let safePosition = positionMs > 0 ? positionMs : 0;
    if (durationMs > 0 && safePosition > durationMs) {
      safePosition = durationMs;
    }
    return safePosition;
  }

  /** 判断跨后端是否保留续播（对应原 shouldPreservePendingResume 的 sourceKey 比较） */
  shouldPreserve(nextSourceKey: string): boolean {
    if (this.pending === null) {
      return false;
    }
    if (nextSourceKey.length === 0) {
      return false;
    }
    return nextSourceKey === this.pending.sourceKey;
  }

  /** 记录显式自动播放决策（对应原 rememberPendingResumeAutoplayDecision） */
  remember(shouldResumePlay: boolean, source: string): void {
    this.decisionExplicit = shouldResumePlay;
    this.hasDecisionExplicit = true;
    this.decisionSource = source.length > 0 ? source : 'explicit';
  }

  /** 清空当前会话显式决策（对应原 clearPendingResumeAutoplayDecision） */
  clearPendingDecision(): void {
    this.decisionExplicit = false;
    this.hasDecisionExplicit = false;
    this.decisionSource = '';
    this.preserveOnPaused = false;
  }

  /** 预置新媒体初始化链路的自动播放决策（对应原 prepareResumeAutoplayDecision） */
  prepare(shouldResumePlay: boolean, source: string): void {
    this.preparedExplicit = shouldResumePlay;
    this.hasPreparedExplicit = true;
    this.preparedSource = source.length > 0 ? source : 'prepared';
  }

  /** 清空预置决策（对应原 clearPreparedResumeAutoplayDecision） */
  clearPrepared(): void {
    this.preparedExplicit = false;
    this.hasPreparedExplicit = false;
    this.preparedSource = '';
  }

  /** 预置决策转正为当前会话决策（对应原 applyPreparedResumeAutoplayDecision） */
  applyPrepared(): void {
    if (!this.hasPreparedExplicit) {
      return;
    }
    this.remember(this.preparedExplicit, this.preparedSource);
    this.clearPrepared();
  }

  /** 清空整个决策生命周期（对应原 clearResumeAutoplayDecisionLifecycle） */
  clearDecisionLifecycle(): void {
    this.clearPrepared();
    this.clearPendingDecision();
  }

  /** 裁决：显式决策优先，否则 transient 推断（对应原 resolvePendingResumeAutoplayDecision） */
  resolve(inferredShouldResumePlay: boolean, inferredSource: string): ResumeAutoplayDecision {
    if (this.hasDecisionExplicit) {
      return {
        shouldResumePlay: this.decisionExplicit,
        source: this.decisionSource.length > 0 ? this.decisionSource : 'explicit',
        origin: 'explicit'
      };
    }
    return {
      shouldResumePlay: inferredShouldResumePlay,
      source: inferredSource,
      origin: 'transient'
    };
  }

  /** 重置续播 seek 事务（对应原 initPlayer 中的散落 seek 字段重置） */
  resetSeek(): void {
    this.seekInFlight = false;
    this.seekSource = '';
    this.seekCaptureBackend = 'avplayer';
    this.seekTargetMs = -1;
    this.seekAutoPlay = false;
    this.trackInitAfterSeek = false;
    this.trackInitResumePlay = false;
    this.suppressPlayAfterSeek = false;
  }

  /** 开始一次续播 seek（对应原 onPlayerReady 中的 resume seek dispatch 字段赋值） */
  beginResumeSeek(source: string, captureBackend: ResumeBackend, targetMs: number, autoPlay: boolean): void {
    this.suppressPlayAfterSeek = true;
    this.trackInitAfterSeek = true;
    this.trackInitResumePlay = autoPlay;
    this.seekInFlight = true;
    this.seekSource = source;
    this.seekCaptureBackend = captureBackend;
    this.seekTargetMs = targetMs;
    this.seekAutoPlay = autoPlay;
  }

  /** 清空续播 seek 的 dispatch 字段（对应原 continuePendingReadyAfterSeek 中的散落清空） */
  clearSeekDispatch(): void {
    this.seekInFlight = false;
    this.seekSource = '';
    this.seekCaptureBackend = 'avplayer';
    this.seekTargetMs = -1;
    this.seekAutoPlay = false;
  }

  /** 清空结果观察上下文 */
  clearResult(): void {
    this.result = null;
  }
}
