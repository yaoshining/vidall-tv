import { AppPreferences, PrefKey } from '../../utils/AppPreferences';
import { ScrapeProgressCallback, ScopedScrapeExecutor, ScopedScrapeService } from './ScopedScrapeService';
import { normalizeScrapeDirectoryPath } from './ScopedScrapeTypes';
import { ScrapeTaskStore } from './ScrapeTaskStore';
import { MediaDataVersionStore } from './MediaDataVersionStore';
import {
  ScopedScrapeRequest,
  ScrapeCandidate,
  ScrapeExecutionOutcome,
  ScrapeGroupSelection,
  ScrapeProgress,
  ScrapeResumeState,
  ScrapeScope,
  ScrapeTaskSnapshot,
  scrapeScopeId
} from './ScopedScrapeTypes';

export class ScrapeTaskQueue {
  private static instance: ScrapeTaskQueue | null = null;
  private tasks: ScrapeTaskSnapshot[] = [];
  private executor: ScopedScrapeExecutor;
  private runningCount: number = 0;
  private sequence: number = 0;
  private maxConcurrent: number = 2;
  private concurrencyLoaded: boolean = false;
  private concurrencyLoading: boolean = false;
  private readonly maxTerminalHistory: number = 30;

  static getInstance(): ScrapeTaskQueue {
    if (ScrapeTaskQueue.instance === null) {
      ScrapeTaskQueue.instance = new ScrapeTaskQueue(new ScopedScrapeService());
    }
    return ScrapeTaskQueue.instance;
  }

  constructor(executor: ScopedScrapeExecutor, maxConcurrent?: number) {
    this.executor = executor;
    if (maxConcurrent !== undefined) {
      this.maxConcurrent = this.clampConcurrency(maxConcurrent);
      this.concurrencyLoaded = true;
    }
  }

  private clampConcurrency(value: number): number {
    return Math.max(1, Math.min(4, Math.floor(value)));
  }

  enqueue(request: ScopedScrapeRequest): string {
    const requestCopy = this.copyRequest(request);
    const activeKey = this.buildActiveKey(requestCopy);
    const existing = this.tasks.find((task: ScrapeTaskSnapshot): boolean =>
      this.isActive(task) && this.buildActiveKey(task.request) === activeKey
    );
    if (existing !== undefined) {
      return existing.id;
    }
    const now = Date.now();
    this.sequence++;
    const task = new ScrapeTaskSnapshot(`${now}-${this.sequence}`, requestCopy, now);
    this.tasks.push(task);
    this.publish();
    this.schedule();
    return task.id;
  }

  cancel(taskId: string): boolean {
    const task = this.findTask(taskId);
    if (task === undefined || task.status !== 'waiting') {
      return false;
    }
    task.status = 'cancelled';
    task.updatedAt = Date.now();
    this.trimHistory();
    this.publish();
    return true;
  }

  confirmCandidate(taskId: string, candidate: ScrapeCandidate): boolean {
    const task = this.findTask(taskId);
    if (task === undefined || task.status !== 'waiting-confirmation' || task.pause === undefined ||
      task.resumeState === undefined || task.pause.reason !== 'candidate-confirmation') {
      return false;
    }
    const pausedGroupKey = task.pause.groupKey;
    const selections = task.resumeState.selections.filter((selection: ScrapeGroupSelection): boolean =>
      selection.groupKey !== pausedGroupKey
    );
    const selection: ScrapeGroupSelection = {
      groupKey: task.pause.groupKey,
      candidate: this.copyCandidate(candidate)
    };
    selections.push(selection);
    task.resumeState.selections = selections;
    task.pause = undefined;
    task.status = 'waiting';
    task.updatedAt = Date.now();
    this.publish();
    this.schedule();
    return true;
  }

  retryCandidateSearch(taskId: string): boolean {
    const task = this.findTask(taskId);
    if (task === undefined || task.status !== 'waiting-confirmation' || task.pause === undefined ||
      task.resumeState === undefined || task.pause.reason !== 'candidate-search-retry') {
      return false;
    }
    task.pause = undefined;
    task.status = 'waiting';
    task.updatedAt = Date.now();
    this.publish();
    this.schedule();
    return true;
  }

  cancelCandidateGroup(taskId: string): boolean {
    const task = this.findTask(taskId);
    if (task === undefined || task.status !== 'waiting-confirmation' || task.pause === undefined ||
      task.resumeState === undefined || task.pause.reason !== 'candidate-confirmation') {
      return false;
    }
    if (!task.resumeState.cancelledGroupKeys.includes(task.pause.groupKey)) {
      task.resumeState.cancelledGroupKeys.push(task.pause.groupKey);
    }
    task.pause = undefined;
    task.status = 'waiting';
    task.updatedAt = Date.now();
    this.publish();
    this.schedule();
    return true;
  }

  retry(taskId: string): string | null {
    const task = this.findTask(taskId);
    if (task === undefined || (task.status !== 'failed' && task.status !== 'partial-failure')) {
      return null;
    }
    const failedVideoIds = task.result?.failedVideoIds;
    if (failedVideoIds === undefined) {
      return null;
    }
    if (failedVideoIds.length === 0 && task.status !== 'failed') {
      return null;
    }
    const retryRequest: ScopedScrapeRequest = {
      scope: task.request.scope,
      mode: task.request.mode,
      candidateStrategy: task.request.candidateStrategy,
      videoIds: failedVideoIds.length > 0 ? failedVideoIds.slice() : task.request.videoIds
    };
    return this.enqueue(retryRequest);
  }

  clear(taskId: string): boolean {
    const index = this.tasks.findIndex((task: ScrapeTaskSnapshot): boolean => task.id === taskId);
    if (index < 0 || this.isActive(this.tasks[index])) {
      return false;
    }
    this.tasks.splice(index, 1);
    this.publish();
    return true;
  }

  clearTerminal(): void {
    this.tasks = this.tasks.filter((task: ScrapeTaskSnapshot): boolean => this.isActive(task));
    this.publish();
  }

  private schedule(): void {
    if (!this.concurrencyLoaded) {
      this.loadConcurrency();
      return;
    }
    while (this.runningCount < this.maxConcurrent) {
      const next = this.tasks.find((task: ScrapeTaskSnapshot): boolean => task.status === 'waiting');
      if (next === undefined) {
        return;
      }
      this.start(next);
    }
  }

  private loadConcurrency(): void {
    if (this.concurrencyLoading) {
      return;
    }
    this.concurrencyLoading = true;
    AppPreferences.getNumber(PrefKey.SCRAPE_CONCURRENCY, 2)
      .then((value: number): void => {
        this.maxConcurrent = Math.max(1, Math.min(4, Math.floor(value)));
        this.concurrencyLoaded = true;
        this.concurrencyLoading = false;
        this.schedule();
      })
      .catch((): void => {
        this.maxConcurrent = 2;
        this.concurrencyLoaded = true;
        this.concurrencyLoading = false;
        this.schedule();
      });
  }

  private start(task: ScrapeTaskSnapshot): void {
    task.status = 'running';
    task.updatedAt = Date.now();
    this.runningCount++;
    this.publish();
    const onProgress: ScrapeProgressCallback = (progress: ScrapeProgress): void => {
      task.progress = progress;
      task.updatedAt = Date.now();
      this.publish();
    };
    this.executor.execute(task.request, onProgress, task.resumeState)
      .then((outcome: ScrapeExecutionOutcome): void => this.handleOutcome(task, outcome))
      .catch((): void => this.fail(task));
  }

  private handleOutcome(task: ScrapeTaskSnapshot, outcome: ScrapeExecutionOutcome): void {
    this.runningCount--;
    task.updatedAt = Date.now();
    if (outcome.kind === 'paused') {
      task.pause = outcome.pause;
      task.resumeState = outcome.resumeState;
      task.progress = outcome.resumeState.progress;
      task.status = 'waiting-confirmation';
      this.publish();
      this.schedule();
      return;
    }
    task.result = outcome.result;
    task.resumeState = undefined;
    task.status = outcome.result.failed === 0
      ? 'completed'
      : (outcome.result.succeeded > 0 ? 'partial-failure' : 'failed');
    if (outcome.result.succeeded > 0) {
      MediaDataVersionStore.getState().publishSuccessful(
        task.request.scope,
        outcome.result.succeededVideoIds
      ).catch(() => {});
    }
    this.trimHistory();
    this.publish();
    this.schedule();
  }

  private fail(task: ScrapeTaskSnapshot): void {
    const failedVideoIds = this.retryVideoIds(task.request);
    const failedCount = Math.max(task.progress.total, failedVideoIds.length);
    task.result = {
      total: failedCount,
      succeeded: 0,
      failed: failedCount,
      cancelled: 0,
      succeededVideoIds: [],
      failedVideoIds
    };
    task.status = 'failed';
    task.updatedAt = Date.now();
    this.runningCount--;
    this.trimHistory();
    this.publish();
    this.schedule();
  }

  private retryVideoIds(request: ScopedScrapeRequest): number[] {
    if (request.videoIds !== undefined) {
      return request.videoIds.slice();
    }
    if (request.scope.kind === 'episode') {
      return [request.scope.videoId];
    }
    return [];
  }

  private buildActiveKey(request: ScopedScrapeRequest): string {
    const videoKey = request.videoIds === undefined ? '' : request.videoIds.slice()
      .sort((a: number, b: number): number => a - b)
      .join(',');
    return `${scrapeScopeId(request.scope)}|${request.mode}|${request.candidateStrategy}|${videoKey}`;
  }

  private copyRequest(request: ScopedScrapeRequest): ScopedScrapeRequest {
    const copy: ScopedScrapeRequest = {
      scope: this.copyScope(request.scope),
      mode: request.mode,
      candidateStrategy: request.candidateStrategy,
      videoIds: request.videoIds === undefined ? undefined : request.videoIds.slice()
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
        directoryPath: normalizeScrapeDirectoryPath(scope.directoryPath),
        displayName: scope.displayName
      };
    }
    return { kind: 'global', displayName: scope.displayName };
  }

  private copyCandidate(candidate: ScrapeCandidate): ScrapeCandidate {
    const copy: ScrapeCandidate = {
      provider: candidate.provider,
      providerId: candidate.providerId,
      title: candidate.title,
      year: candidate.year,
      posterUrl: candidate.posterUrl,
      mediaType: candidate.mediaType
    };
    return copy;
  }

  private findTask(taskId: string): ScrapeTaskSnapshot | undefined {
    return this.tasks.find((task: ScrapeTaskSnapshot): boolean => task.id === taskId);
  }

  private isActive(task: ScrapeTaskSnapshot): boolean {
    return task.status === 'waiting' || task.status === 'running' || task.status === 'waiting-confirmation';
  }

  private trimHistory(): void {
    const terminal = this.tasks.filter((task: ScrapeTaskSnapshot): boolean => !this.isActive(task));
    if (terminal.length <= this.maxTerminalHistory) {
      return;
    }
    const removable = terminal.filter((task: ScrapeTaskSnapshot): boolean =>
      task.status === 'completed' || task.status === 'cancelled'
    );
    removable.sort((left: ScrapeTaskSnapshot, right: ScrapeTaskSnapshot): number => left.updatedAt - right.updatedAt);
    const fallback = terminal.filter((task: ScrapeTaskSnapshot): boolean =>
      task.status !== 'completed' && task.status !== 'cancelled'
    );
    fallback.sort((left: ScrapeTaskSnapshot, right: ScrapeTaskSnapshot): number => left.updatedAt - right.updatedAt);
    const candidates = removable.concat(fallback);
    const removeCount = terminal.length - this.maxTerminalHistory;
    const removeIds = new Set<string>();
    for (let index = 0; index < removeCount; index++) {
      removeIds.add(candidates[index].id);
    }
    this.tasks = this.tasks.filter((task: ScrapeTaskSnapshot): boolean => !removeIds.has(task.id));
  }

  private publish(): void {
    ScrapeTaskStore.getState().update(this.tasks);
  }
}
