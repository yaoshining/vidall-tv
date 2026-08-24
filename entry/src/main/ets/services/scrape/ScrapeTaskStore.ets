import {
  ScopedScrapeRequest,
  ScrapeCandidate,
  ScrapePause,
  ScrapeGroupSelection,
  ScrapeResult,
  ScrapeResumeState,
  ScrapeScope,
  ScrapeTaskSnapshot,
  ScrapeTaskStatus
} from './ScopedScrapeTypes';

function taskPriority(status: ScrapeTaskStatus): number {
  if (status === 'running' || status === 'waiting-confirmation') {
    return 0;
  }
  if (status === 'waiting') {
    return 1;
  }
  if (status === 'failed' || status === 'partial-failure') {
    return 2;
  }
  return 3;
}

@ObservedV2
export class ScrapeTaskStore {
  private static instance: ScrapeTaskStore | null = null;

  static getState(): ScrapeTaskStore {
    if (ScrapeTaskStore.instance === null) {
      ScrapeTaskStore.instance = new ScrapeTaskStore();
    }
    return ScrapeTaskStore.instance;
  }

  @Trace private snapshots: ScrapeTaskSnapshot[] = [];

  getTasks(): ScrapeTaskSnapshot[] {
    return this.snapshots.map((task: ScrapeTaskSnapshot): ScrapeTaskSnapshot => this.copyTask(task));
  }

  getActiveCount(): number {
    return this.snapshots.filter((task: ScrapeTaskSnapshot): boolean =>
      task.status === 'waiting' || task.status === 'running'
    ).length;
  }

  update(tasks: ScrapeTaskSnapshot[]): void {
    const sorted = tasks.map((task: ScrapeTaskSnapshot): ScrapeTaskSnapshot => this.copyTask(task));
    sorted.sort((left: ScrapeTaskSnapshot, right: ScrapeTaskSnapshot): number => {
      const priorityDiff = taskPriority(left.status) - taskPriority(right.status);
      return priorityDiff !== 0 ? priorityDiff : right.updatedAt - left.updatedAt;
    });
    this.snapshots = sorted;
  }

  private copyTask(task: ScrapeTaskSnapshot): ScrapeTaskSnapshot {
    const request: ScopedScrapeRequest = {
      scope: this.copyScope(task.request.scope),
      mode: task.request.mode,
      candidateStrategy: task.request.candidateStrategy,
      videoIds: task.request.videoIds === undefined ? undefined : task.request.videoIds.slice()
    };
    const copy: ScrapeTaskSnapshot = {
      id: task.id,
      request,
      status: task.status,
      progress: {
        completed: task.progress.completed,
        total: task.progress.total,
        succeeded: task.progress.succeeded,
        failed: task.progress.failed,
        cancelled: task.progress.cancelled
      },
      pause: task.pause === undefined ? undefined : this.copyPause(task.pause),
      result: task.result === undefined ? undefined : this.copyResult(task.result),
      resumeState: task.resumeState === undefined ? undefined : this.copyResumeState(task.resumeState),
      createdAt: task.createdAt,
      updatedAt: task.updatedAt
    };
    return copy;
  }

  private copyScope(scope: ScrapeScope): ScrapeScope {
    if (scope.kind === 'movie') {
      return { kind: 'movie', movieId: scope.movieId, displayName: scope.displayName };
    }
    if (scope.kind === 'series') {
      return { kind: 'series', tvSeriesId: scope.tvSeriesId, displayName: scope.displayName };
    }
    if (scope.kind === 'season') {
      return {
        kind: 'season',
        tvSeriesId: scope.tvSeriesId,
        seasonNumber: scope.seasonNumber,
        displayName: scope.displayName
      };
    }
    if (scope.kind === 'episode') {
      return { kind: 'episode', videoId: scope.videoId, displayName: scope.displayName };
    }
    if (scope.kind === 'folder') {
      return {
        kind: 'folder',
        sourceId: scope.sourceId,
        directoryPath: scope.directoryPath,
        displayName: scope.displayName
      };
    }
    return { kind: 'global', displayName: scope.displayName };
  }

  private copyPause(pause: ScrapePause): ScrapePause {
    const candidates = pause.candidates.map((candidate: ScrapeCandidate): ScrapeCandidate => {
      const copy: ScrapeCandidate = {
        provider: candidate.provider,
        providerId: candidate.providerId,
        title: candidate.title,
        year: candidate.year,
        posterUrl: candidate.posterUrl,
        mediaType: candidate.mediaType
      };
      return copy;
    });
    const copy: ScrapePause = {
      reason: pause.reason,
      groupKey: pause.groupKey,
      candidates
    };
    return copy;
  }

  private copyResumeState(state: ScrapeResumeState): ScrapeResumeState {
    const selections: ScrapeGroupSelection[] = state.selections.map((selection: ScrapeGroupSelection) => {
      const copy: ScrapeGroupSelection = {
        groupKey: selection.groupKey,
        candidate: {
          provider: selection.candidate.provider,
          providerId: selection.candidate.providerId,
          title: selection.candidate.title,
          year: selection.candidate.year,
          posterUrl: selection.candidate.posterUrl,
          mediaType: selection.candidate.mediaType
        }
      };
      return copy;
    });
    return {
      nextIndex: state.nextIndex,
      selections,
      cancelledGroupKeys: state.cancelledGroupKeys.slice(),
      progress: {
        completed: state.progress.completed,
        total: state.progress.total,
        succeeded: state.progress.succeeded,
        failed: state.progress.failed,
        cancelled: state.progress.cancelled
      },
      succeededVideoIds: state.succeededVideoIds.slice(),
      failedVideoIds: state.failedVideoIds.slice()
    };
  }

  private copyResult(result: ScrapeResult): ScrapeResult {
    const copy: ScrapeResult = {
      total: result.total,
      succeeded: result.succeeded,
      failed: result.failed,
      cancelled: result.cancelled,
      succeededVideoIds: result.succeededVideoIds.slice(),
      failedVideoIds: result.failedVideoIds.slice()
    };
    return copy;
  }
}
