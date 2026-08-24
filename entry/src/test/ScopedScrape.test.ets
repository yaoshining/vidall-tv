import { describe, it, expect } from '@ohos/hypium';
import { VideoEntity } from '../main/ets/db/models/MediaEntity';
import { FileSource } from '../main/ets/db/models/FileSourceEntity';
import {
  IScrapeProvider,
  MovieScrapeResult,
  ScrapeClient,
  TvEpisodeScrapeBundle,
  TvEpisodeScrapeResult,
  TvSeasonScrapeResult,
  TvSeriesScrapeResult
} from '../main/ets/lib/ScrapeClient';
import { VideoFileInfo } from '../main/ets/utils/VideoScannerTypes';
import {
  normalizeScrapeDirectoryPath,
  ScrapeScopeResolver,
  ScrapeScopeVideoSource
} from '../main/ets/services/scrape/ScrapeScopeResolver';
import { shouldScrapeVideo } from '../main/ets/services/scrape/ScrapeModeFilter';
import { ScrapeTaskQueue } from '../main/ets/services/scrape/ScrapeTaskQueue';
import { ScrapeTaskStore } from '../main/ets/services/scrape/ScrapeTaskStore';
import { MediaDataVersionStore } from '../main/ets/services/scrape/MediaDataVersionStore';
import {
  ScrapeProgressCallback,
  ScopedScrapeDependencies,
  ScopedScrapeExecutor,
  ScopedScrapeService
} from '../main/ets/services/scrape/ScopedScrapeService';
import {
  EpisodeScrapeScope,
  ScopedScrapeRequest,
  ScopedScrapeVideo,
  ScrapeCandidate,
  ScrapeExecutionCompleted,
  ScrapeExecutionOutcome,
  ScrapeExecutionPaused,
  ScrapeGroupSelection,
  ScrapePause,
  ScrapeProgress,
  ScrapeResult,
  ScrapeResumeState,
  ScrapeTaskSnapshot,
  ScrapeTaskStatus
} from '../main/ets/services/scrape/ScopedScrapeTypes';

function createVideo(id: number, sourceId: number, path: string, updated: number = 0): VideoEntity {
  const fileName = path.substring(path.lastIndexOf('/') + 1);
  const video: VideoEntity = {
    id,
    sourceId,
    directoryPath: path.substring(0, path.lastIndexOf('/')),
    filePath: path,
    fileName,
    updatedInLastScan: updated,
    scannedAt: 1
  };
  return video;
}

class FakeScrapeScopeVideoSource implements ScrapeScopeVideoSource {
  videos: VideoEntity[] = [
    createVideo(3, 1, '/movie/sub/c.mkv'),
    createVideo(1, 1, '/movie/a.mkv'),
    createVideo(2, 1, '/movie/b.mkv'),
    createVideo(2, 1, '/movie/b.mkv')
  ];

  getVideoById(videoId: number): Promise<VideoEntity | null> {
    return Promise.resolve(this.videos.find((video: VideoEntity): boolean => video.id === videoId) ?? null);
  }

  getVideosByMovieId(_movieId: number): Promise<VideoEntity[]> {
    return Promise.resolve(this.videos);
  }

  getVideosByTvSeriesId(_tvSeriesId: number): Promise<VideoEntity[]> {
    return Promise.resolve(this.videos);
  }

  getVideosBySeason(_tvSeriesId: number, _seasonNumber: number): Promise<VideoEntity[]> {
    return Promise.resolve(this.videos.slice(0, 2));
  }

  getVideosByDirectoryTree(_sourceId: number, _directoryPath: string): Promise<VideoEntity[]> {
    return Promise.resolve(this.videos);
  }

  getVideosBySourceId(_sourceId: number): Promise<VideoEntity[]> {
    return Promise.resolve(this.videos);
  }

  getAllVideos(): Promise<VideoEntity[]> {
    return Promise.resolve(this.videos);
  }
}


class StaticScrapeScopeVideoSource implements ScrapeScopeVideoSource {
  readonly videos: VideoEntity[];

  constructor(videos: VideoEntity[]) {
    this.videos = videos;
  }

  getVideoById(videoId: number): Promise<VideoEntity | null> {
    return Promise.resolve(this.videos.find((video: VideoEntity): boolean => video.id === videoId) ?? null);
  }

  getVideosByMovieId(_movieId: number): Promise<VideoEntity[]> {
    return Promise.resolve(this.videos);
  }

  getVideosByTvSeriesId(_tvSeriesId: number): Promise<VideoEntity[]> {
    return Promise.resolve(this.videos);
  }

  getVideosBySeason(_tvSeriesId: number, _seasonNumber: number): Promise<VideoEntity[]> {
    return Promise.resolve(this.videos);
  }

  getVideosByDirectoryTree(_sourceId: number, _directoryPath: string): Promise<VideoEntity[]> {
    return Promise.resolve(this.videos);
  }

  getVideosBySourceId(_sourceId: number): Promise<VideoEntity[]> {
    return Promise.resolve(this.videos);
  }

  getAllVideos(): Promise<VideoEntity[]> {
    return Promise.resolve(this.videos);
  }
}

class TvSearchCall {
  readonly title: string;
  readonly year?: number;

  constructor(title: string, year?: number) {
    this.title = title;
    this.year = year;
  }
}

class FakeScrapeProvider implements IScrapeProvider {
  readonly id: string = 'fake';
  readonly tvSearchCalls: TvSearchCall[] = [];
  tvSearchThrows: boolean = false;
  tvSearchResult: TvSeriesScrapeResult | null = null;
  seriesDetail: TvSeriesScrapeResult | null = null;
  seasonResult: TvSeasonScrapeResult | null = null;
  episodeResult: TvEpisodeScrapeResult | null = null;
  fetchSeasonCount: number = 0;
  fetchEpisodeCount: number = 0;

  isConfigured(): boolean {
    return true;
  }

  searchMovie(_title: string, _year?: number, _language?: string): Promise<MovieScrapeResult[]> {
    return Promise.resolve([]);
  }

  searchTv(title: string, year?: number, _language?: string): Promise<TvSeriesScrapeResult[]> {
    this.tvSearchCalls.push(new TvSearchCall(title, year));
    if (this.tvSearchThrows) {
      return Promise.reject(new Error('search failed'));
    }
    if (year !== undefined || this.tvSearchResult === null) {
      return Promise.resolve([]);
    }
    return Promise.resolve([this.tvSearchResult]);
  }

  fetchMovieDetail(_providerId: string, _language?: string): Promise<MovieScrapeResult | null> {
    return Promise.resolve(null);
  }

  fetchTvSeriesDetail(_providerId: string, _language?: string): Promise<TvSeriesScrapeResult | null> {
    return Promise.resolve(this.seriesDetail);
  }

  fetchSeason(
    _seriesProviderId: string,
    _seasonNumber: number,
    _language?: string
  ): Promise<TvSeasonScrapeResult | null> {
    this.fetchSeasonCount++;
    return Promise.resolve(this.seasonResult);
  }

  fetchEpisode(
    _seriesProviderId: string,
    _seasonNumber: number,
    _episodeNumber: number,
    _language?: string
  ): Promise<TvEpisodeScrapeResult | null> {
    this.fetchEpisodeCount++;
    return Promise.resolve(this.episodeResult);
  }
}

class FakeScopedScrapeDependencies implements ScopedScrapeDependencies {
  readonly client: ScrapeClient;
  applyTvCount: number = 0;

  constructor(client: ScrapeClient) {
    this.client = client;
  }

  getTmdbApiKey(): Promise<string> {
    return Promise.resolve('test-key');
  }

  createClient(_tmdbApiKey: string): ScrapeClient {
    return this.client;
  }

  getFileSourceById(_sourceId: number): Promise<FileSource | null> {
    return Promise.resolve(null);
  }

  loadTarget(video: VideoEntity): Promise<ScopedScrapeVideo> {
    const target: ScopedScrapeVideo = { video, posterAvailable: false };
    return Promise.resolve(target);
  }

  processVideo(
    _videoId: number,
    _fileName: string,
    _client: ScrapeClient,
    _mode: 'incremental' | 'fix-missing' | 'overwrite',
    _info: VideoFileInfo,
    _logPrefix: string
  ): Promise<boolean> {
    return Promise.resolve(false);
  }

  applyMovie(_videoId: number, _movie: MovieScrapeResult, _logPrefix: string): Promise<boolean> {
    return Promise.resolve(true);
  }

  applyTv(_videoId: number, _result: TvEpisodeScrapeBundle, _logPrefix: string): Promise<boolean> {
    this.applyTvCount++;
    return Promise.resolve(true);
  }
}

function createTvSeries(providerId: string = 'series-1'): TvSeriesScrapeResult {
  const result: TvSeriesScrapeResult = {
    provider: 'fake',
    providerId,
    title: 'Example Show',
    firstAirDate: '2024-01-01'
  };
  return result;
}

function createTvSeason(): TvSeasonScrapeResult {
  const result: TvSeasonScrapeResult = {
    provider: 'fake',
    providerId: 'series-1_s1',
    seasonNumber: 1
  };
  return result;
}

function createTvEpisode(): TvEpisodeScrapeResult {
  const result: TvEpisodeScrapeResult = {
    provider: 'fake',
    providerId: 'episode-1',
    seasonNumber: 1,
    episodeNumber: 1
  };
  return result;
}

function createConfirmRequest(videoIds: number[]): ScopedScrapeRequest {
  const request: ScopedScrapeRequest = {
    scope: { kind: 'folder', sourceId: 1, directoryPath: '/', displayName: 'all' },
    mode: 'incremental',
    candidateStrategy: 'confirm',
    videoIds
  };
  return request;
}

function createConfirmationResume(groupKey: string, candidate: ScrapeCandidate): ScrapeResumeState {
  const selection: ScrapeGroupSelection = { groupKey, candidate };
  const state: ScrapeResumeState = {
    nextIndex: 0,
    selections: [selection],
    cancelledGroupKeys: [],
    progress: { completed: 0, total: 2, succeeded: 0, failed: 0, cancelled: 0 },
    failedVideoIds: []
  };
  return state;
}

class Deferred<T> {
  readonly promise: Promise<T>;
  private resolveValue: (value: T) => void = (_value: T): void => {};
  private rejectValue: (reason: Error) => void = (_reason: Error): void => {};

  constructor() {
    this.promise = new Promise<T>((resolve, reject) => {
      this.resolveValue = resolve;
      this.rejectValue = reject;
    });
  }

  resolve(value: T): void {
    this.resolveValue(value);
  }

  reject(reason: Error): void {
    this.rejectValue(reason);
  }
}

class ScopedExecutionCall {
  readonly request: ScopedScrapeRequest;
  readonly onProgress: ScrapeProgressCallback;
  readonly resumeState?: ScrapeResumeState;
  readonly deferred: Deferred<ScrapeExecutionOutcome> = new Deferred<ScrapeExecutionOutcome>();

  constructor(
    request: ScopedScrapeRequest,
    onProgress: ScrapeProgressCallback,
    resumeState?: ScrapeResumeState
  ) {
    this.request = request;
    this.onProgress = onProgress;
    this.resumeState = resumeState;
  }
}

class ControlledScopedScrapeExecutor implements ScopedScrapeExecutor {
  readonly calls: ScopedExecutionCall[] = [];

  execute(
    request: ScopedScrapeRequest,
    onProgress: ScrapeProgressCallback,
    resumeState?: ScrapeResumeState
  ): Promise<ScrapeExecutionOutcome> {
    const call = new ScopedExecutionCall(request, onProgress, resumeState);
    this.calls.push(call);
    return call.deferred.promise;
  }
}

function createEpisodeRequest(videoId: number, videoIds?: number[]): ScopedScrapeRequest {
  const scope: EpisodeScrapeScope = {
    kind: 'episode',
    videoId,
    displayName: `episode-${videoId}`
  };
  const request: ScopedScrapeRequest = {
    scope,
    mode: 'incremental',
    candidateStrategy: 'automatic',
    videoIds
  };
  return request;
}

function createResult(succeeded: number, failedVideoIds: number[]): ScrapeResult {
  const result: ScrapeResult = {
    total: succeeded + failedVideoIds.length,
    succeeded,
    failed: failedVideoIds.length,
    cancelled: 0,
    failedVideoIds: failedVideoIds.slice()
  };
  return result;
}

function createCompleted(succeeded: number = 1, failedVideoIds: number[] = []): ScrapeExecutionCompleted {
  const completed: ScrapeExecutionCompleted = {
    kind: 'completed',
    result: createResult(succeeded, failedVideoIds)
  };
  return completed;
}

function createCandidate(providerId: string): ScrapeCandidate {
  const candidate: ScrapeCandidate = {
    provider: 'tmdb',
    providerId,
    title: `candidate-${providerId}`,
    year: '2024',
    posterUrl: `poster-${providerId}`,
    mediaType: 'movie'
  };
  return candidate;
}

function createPaused(groupKey: string): ScrapeExecutionPaused {
  const progress: ScrapeProgress = {
    completed: 1,
    total: 2,
    succeeded: 1,
    failed: 0,
    cancelled: 0
  };
  const pause: ScrapePause = {
    reason: 'candidate-confirmation',
    groupKey,
    candidates: [createCandidate('pause')]
  };
  const resumeState: ScrapeResumeState = {
    nextIndex: 1,
    selections: [],
    cancelledGroupKeys: [],
    progress,
    failedVideoIds: []
  };
  const paused: ScrapeExecutionPaused = {
    kind: 'paused',
    pause,
    resumeState
  };
  return paused;
}

function createCandidateSearchPaused(groupKey: string): ScrapeExecutionPaused {
  const progress: ScrapeProgress = {
    completed: 0,
    total: 1,
    succeeded: 0,
    failed: 0,
    cancelled: 0
  };
  const pause: ScrapePause = {
    reason: 'candidate-search-retry',
    groupKey,
    candidates: []
  };
  const resumeState: ScrapeResumeState = {
    nextIndex: 0,
    selections: [],
    cancelledGroupKeys: [],
    progress,
    failedVideoIds: []
  };
  const paused: ScrapeExecutionPaused = { kind: 'paused', pause, resumeState };
  return paused;
}

async function flushMicrotasks(rounds: number = 6): Promise<void> {
  for (let index = 0; index < rounds; index++) {
    await Promise.resolve();
  }
}

function findTask(store: ScrapeTaskStore, taskId: string): ScrapeTaskSnapshot | undefined {
  return store.getTasks().find((task: ScrapeTaskSnapshot): boolean => task.id === taskId);
}

function createStoreSnapshot(id: string, status: ScrapeTaskStatus): ScrapeTaskSnapshot {
  const snapshot = new ScrapeTaskSnapshot(id, createEpisodeRequest(40, [40, 41]), 10);
  snapshot.status = status;
  snapshot.updatedAt = 20;
  const progress: ScrapeProgress = {
    completed: 1,
    total: 4,
    succeeded: 1,
    failed: 0,
    cancelled: 0
  };
  const pause: ScrapePause = {
    reason: 'candidate-confirmation',
    groupKey: 'group-a',
    candidates: [createCandidate('original')]
  };
  const selection: ScrapeGroupSelection = {
    groupKey: 'selected-a',
    candidate: createCandidate('selected-original')
  };
  const resumeState: ScrapeResumeState = {
    nextIndex: 2,
    selections: [selection],
    cancelledGroupKeys: ['cancelled-a'],
    progress,
    failedVideoIds: [41]
  };
  snapshot.progress = progress;
  snapshot.pause = pause;
  snapshot.resumeState = resumeState;
  snapshot.result = createResult(1, [41]);
  return snapshot;
}

export default function scopedScrapeTest() {
  describe('ScopedScrape', () => {
    it('normalizes folder paths and resolves stable unique videos', 0, async () => {
      expect(normalizeScrapeDirectoryPath(' movie\\sub// ')).assertEqual('/movie/sub');
      const resolver = new ScrapeScopeResolver(new FakeScrapeScopeVideoSource());
      const videos = await resolver.resolve({ kind: 'movie', movieId: 9, displayName: '电影' });
      expect(videos.length).assertEqual(3);
      expect(videos[0].id).assertEqual(1);
      expect(videos[2].id).assertEqual(3);
    });



    it('enforces the concurrency limit and starts waiting tasks in FIFO order', 0, async () => {
      const executor = new ControlledScopedScrapeExecutor();
      const queue = new ScrapeTaskQueue(executor, 2);
      const firstId = queue.enqueue(createEpisodeRequest(101));
      const secondId = queue.enqueue(createEpisodeRequest(102));
      const thirdId = queue.enqueue(createEpisodeRequest(103));

      expect(executor.calls.length).assertEqual(2);
      expect(executor.calls[0].request.scope.kind).assertEqual('episode');
      expect(executor.calls[1].request.scope.kind).assertEqual('episode');
      expect(findTask(ScrapeTaskStore.getState(), firstId)?.status).assertEqual('running');
      expect(findTask(ScrapeTaskStore.getState(), secondId)?.status).assertEqual('running');
      expect(findTask(ScrapeTaskStore.getState(), thirdId)?.status).assertEqual('waiting');

      executor.calls[0].deferred.resolve(createCompleted());
      await flushMicrotasks();
      expect(executor.calls.length).assertEqual(3);
      expect(executor.calls[2].request.scope.kind).assertEqual('episode');
      if (executor.calls[2].request.scope.kind === 'episode') {
        expect(executor.calls[2].request.scope.videoId).assertEqual(103);
      }
      executor.calls[1].deferred.resolve(createCompleted());
      executor.calls[2].deferred.resolve(createCompleted());
      await flushMicrotasks();
    });

    it('releases a running slot while a task waits for candidate confirmation', 0, async () => {
      const executor = new ControlledScopedScrapeExecutor();
      const queue = new ScrapeTaskQueue(executor, 1);
      const pausedId = queue.enqueue(createEpisodeRequest(201));
      const nextId = queue.enqueue(createEpisodeRequest(202));

      executor.calls[0].deferred.resolve(createPaused('movie-group'));
      await flushMicrotasks();
      expect(executor.calls.length).assertEqual(2);
      expect(findTask(ScrapeTaskStore.getState(), pausedId)?.status).assertEqual('waiting-confirmation');
      expect(findTask(ScrapeTaskStore.getState(), nextId)?.status).assertEqual('running');

      executor.calls[1].deferred.resolve(createCompleted());
      await flushMicrotasks();
      expect(queue.confirmCandidate(pausedId, createCandidate('selected'))).assertTrue();
      expect(executor.calls.length).assertEqual(3);
      const resumedState = executor.calls[2].resumeState;
      expect(resumedState?.selections.length).assertEqual(1);
      if (resumedState !== undefined) {
        expect(resumedState.selections[0].groupKey).assertEqual('movie-group');
      }
      executor.calls[2].deferred.resolve(createCompleted());
      await flushMicrotasks();
    });

    it('retries candidate search without advancing the paused group', 0, async () => {
      const executor = new ControlledScopedScrapeExecutor();
      const queue = new ScrapeTaskQueue(executor, 1);
      const taskId = queue.enqueue(createEpisodeRequest(250));

      executor.calls[0].deferred.resolve(createCandidateSearchPaused('tv-group'));
      await flushMicrotasks();
      const pausedTask = findTask(ScrapeTaskStore.getState(), taskId);
      expect(pausedTask?.status).assertEqual('waiting-confirmation');
      expect(queue.confirmCandidate(taskId, createCandidate('invalid'))).assertFalse();
      expect(queue.cancelCandidateGroup(taskId)).assertFalse();
      expect(queue.retryCandidateSearch(taskId)).assertTrue();
      expect(executor.calls.length).assertEqual(2);
      expect(executor.calls[1].resumeState?.nextIndex).assertEqual(0);
      executor.calls[1].deferred.resolve(createCompleted());
      await flushMicrotasks();
    });

    it('deduplicates active keys when videoIds differ only by order', 0, async () => {
      const executor = new ControlledScopedScrapeExecutor();
      const queue = new ScrapeTaskQueue(executor, 1);
      const firstId = queue.enqueue(createEpisodeRequest(301, [3, 1, 2]));
      const duplicateId = queue.enqueue(createEpisodeRequest(301, [2, 3, 1]));

      expect(duplicateId).assertEqual(firstId);
      expect(executor.calls.length).assertEqual(1);
      expect(ScrapeTaskStore.getState().getTasks().length).assertEqual(1);
      executor.calls[0].deferred.resolve(createCompleted());
      await flushMicrotasks();
    });

    it('cancels only waiting tasks and refuses to cancel running tasks', 0, async () => {
      const executor = new ControlledScopedScrapeExecutor();
      const queue = new ScrapeTaskQueue(executor, 1);
      const runningId = queue.enqueue(createEpisodeRequest(401));
      const waitingId = queue.enqueue(createEpisodeRequest(402));

      expect(queue.cancel(runningId)).assertFalse();
      expect(queue.cancel(waitingId)).assertTrue();
      expect(findTask(ScrapeTaskStore.getState(), runningId)?.status).assertEqual('running');
      expect(findTask(ScrapeTaskStore.getState(), waitingId)?.status).assertEqual('cancelled');
      expect(executor.calls.length).assertEqual(1);
      executor.calls[0].deferred.resolve(createCompleted());
      await flushMicrotasks();
    });

    it('retries exactly the failed video ids from a partial failure', 0, async () => {
      const executor = new ControlledScopedScrapeExecutor();
      const queue = new ScrapeTaskQueue(executor, 1);
      const failedId = queue.enqueue(createEpisodeRequest(501, [4, 7, 9]));

      executor.calls[0].deferred.resolve(createCompleted(1, [9, 4]));
      await flushMicrotasks();
      expect(findTask(ScrapeTaskStore.getState(), failedId)?.status).assertEqual('partial-failure');
      const retryId = queue.retry(failedId);
      expect(retryId === null).assertFalse();
      expect(executor.calls.length).assertEqual(2);
      const retryVideoIds = executor.calls[1].request.videoIds;
      expect(retryVideoIds === undefined).assertFalse();
      if (retryVideoIds !== undefined) {
        expect(retryVideoIds.length).assertEqual(2);
        expect(retryVideoIds[0]).assertEqual(9);
        expect(retryVideoIds[1]).assertEqual(4);
      }
      executor.calls[1].deferred.resolve(createCompleted(2));
      await flushMicrotasks();
    });

    it('keeps all requested video ids retryable when the executor rejects', 0, async () => {
      const executor = new ControlledScopedScrapeExecutor();
      const queue = new ScrapeTaskQueue(executor, 1);
      const failedId = queue.enqueue(createEpisodeRequest(601, [8, 5]));

      executor.calls[0].deferred.reject(new Error('executor failed'));
      await flushMicrotasks();
      const failedTask = findTask(ScrapeTaskStore.getState(), failedId);
      expect(failedTask?.status).assertEqual('failed');
      expect(failedTask?.result?.failedVideoIds.length).assertEqual(2);
      const retryId = queue.retry(failedId);
      expect(retryId === null).assertFalse();
      expect(executor.calls.length).assertEqual(2);
      const retryVideoIds = executor.calls[1].request.videoIds;
      expect(retryVideoIds === undefined).assertFalse();
      if (retryVideoIds !== undefined) {
        expect(retryVideoIds[0]).assertEqual(8);
        expect(retryVideoIds[1]).assertEqual(5);
      }
      executor.calls[1].deferred.resolve(createCompleted(2));
      await flushMicrotasks();
    });

    it('retries a rejected broad scope even when target ids were not pre-resolved', 0, async () => {
      const executor = new ControlledScopedScrapeExecutor();
      const queue = new ScrapeTaskQueue(executor, 1);
      const request: ScopedScrapeRequest = {
        scope: { kind: 'folder', sourceId: 1, directoryPath: '/Shows', displayName: 'Shows' },
        mode: 'incremental',
        candidateStrategy: 'automatic'
      };
      const failedId = queue.enqueue(request);

      executor.calls[0].deferred.reject(new Error('executor failed'));
      await flushMicrotasks();
      expect(findTask(ScrapeTaskStore.getState(), failedId)?.status).assertEqual('failed');
      const retryId = queue.retry(failedId);
      expect(retryId === null).assertFalse();
      expect(executor.calls.length).assertEqual(2);
      expect(executor.calls[1].request.videoIds === undefined).assertTrue();
      executor.calls[1].deferred.resolve(createCompleted());
      await flushMicrotasks();
    });

    it('holds observable task references and counts only waiting and running tasks as active', 0, () => {
      const store = new ScrapeTaskStore();
      const waiting = createStoreSnapshot('waiting', 'waiting');
      const running = createStoreSnapshot('running', 'running');
      const confirming = createStoreSnapshot('confirming', 'waiting-confirmation');
      store.update([waiting, running, confirming]);

      // 引用共享：getTasks 返回的元素与输入是同一实例，保证 @Trace 字段精准更新。
      const tasks = store.getTasks();
      const storedWaiting = tasks.find((task: ScrapeTaskSnapshot): boolean => task.id === 'waiting');
      expect(storedWaiting === waiting).assertTrue();
      expect(storedWaiting?.progress.completed).assertEqual(1);

      // 状态排序：running/waiting-confirmation 优先于 waiting。
      expect(tasks[tasks.length - 1].id).assertEqual('waiting');

      // 活动计数仅统计 waiting + running。
      expect(store.getActiveCount()).assertEqual(2);
    });

    it('publishes only successful task outcomes to the media data version store', 0, async () => {
      const versionStore = MediaDataVersionStore.getState();
      const initialVersion = versionStore.globalVersion;
      const initialVideoVersion = versionStore.getVideoVersion(702);
      const executor = new ControlledScopedScrapeExecutor();
      const queue = new ScrapeTaskQueue(executor, 1);

      queue.enqueue(createEpisodeRequest(701));
      executor.calls[0].deferred.resolve(createCompleted(0, [701]));
      await flushMicrotasks();
      expect(versionStore.globalVersion).assertEqual(initialVersion);

      queue.enqueue(createEpisodeRequest(702));
      executor.calls[1].deferred.resolve(createCompleted(1));
      await flushMicrotasks();
      expect(versionStore.globalVersion).assertEqual(initialVersion + 1);
      expect(versionStore.getVideoVersion(702)).assertEqual(initialVideoVersion + 1);
    });

    it('tracks scoped media versions without contaminating unrelated targets', 0, () => {
      const versionStore = new MediaDataVersionStore();
      versionStore.publish({ kind: 'movie', movieId: 11, displayName: 'movie' });
      versionStore.publish({ kind: 'series', tvSeriesId: 21, displayName: 'series' });
      versionStore.publish({ kind: 'season', tvSeriesId: 21, seasonNumber: 2, displayName: 'season' });
      versionStore.publish({ kind: 'episode', videoId: 31, displayName: 'episode' });

      expect(versionStore.globalVersion).assertEqual(4);
      expect(versionStore.getMovieVersion(11)).assertEqual(1);
      expect(versionStore.getMovieVersion(12)).assertEqual(0);
      expect(versionStore.getSeriesVersion(21)).assertEqual(2);
      expect(versionStore.getSeriesVersion(22)).assertEqual(0);
      expect(versionStore.getSeasonVersion(21, 2)).assertEqual(1);
      expect(versionStore.getSeasonVersion(21, 3)).assertEqual(0);
      expect(versionStore.getVideoVersion(31)).assertEqual(1);
      expect(versionStore.getVideoVersion(32)).assertEqual(0);
    });

    it('falls back to a yearless TV search after a year-scoped miss', 0, async () => {
      const provider = new FakeScrapeProvider();
      provider.tvSearchResult = createTvSeries();
      const client = new ScrapeClient({ scrapeConcurrency: 1 });
      client.registerProvider(provider);

      const results = await client.searchTvCandidates('Example.Show.2024.S01E01.mkv');
      expect(results.length).assertEqual(1);
      expect(provider.tvSearchCalls.length).assertEqual(2);
      expect(provider.tvSearchCalls[0].year).assertEqual(2024);
      expect(provider.tvSearchCalls[1].year === undefined).assertTrue();
    });

    it('caches TV seasons across automatic episode scrapes in one client session', 0, async () => {
      const provider = new FakeScrapeProvider();
      provider.tvSearchResult = createTvSeries();
      provider.seriesDetail = createTvSeries();
      provider.seasonResult = createTvSeason();
      provider.episodeResult = createTvEpisode();
      const client = new ScrapeClient({ scrapeConcurrency: 1 });
      client.registerProvider(provider);

      await client.autoScrapeTvEpisode('Example.Show.S01E01.mkv', 'Example Show', 'tv');
      await client.autoScrapeTvEpisode('Example.Show.S01E02.mkv', 'Example Show', 'tv');
      expect(provider.fetchSeasonCount).assertEqual(1);
      expect(provider.fetchEpisodeCount).assertEqual(2);
    });

    it('pauses candidate search without advancing when providers return no candidates', 0, async () => {
      const provider = new FakeScrapeProvider();
      const client = new ScrapeClient({ scrapeConcurrency: 1 });
      client.registerProvider(provider);
      const videos: VideoEntity[] = [createVideo(701, 1, '/Shows/Example Show/Example.Show.S01E01.mkv')];
      const resolver = new ScrapeScopeResolver(new StaticScrapeScopeVideoSource(videos));
      const service = new ScopedScrapeService(resolver, new FakeScopedScrapeDependencies(client));

      const outcome = await service.execute(createConfirmRequest([701]), (_progress: ScrapeProgress): void => {});
      expect(outcome.kind).assertEqual('paused');
      if (outcome.kind === 'paused') {
        expect(outcome.pause.reason).assertEqual('candidate-search-retry');
        expect(outcome.resumeState.nextIndex).assertEqual(0);
        expect(outcome.resumeState.progress.completed).assertEqual(0);
        expect(outcome.resumeState.failedVideoIds.length).assertEqual(0);
      }
    });

    it('pauses candidate search when providers throw', 0, async () => {
      const provider = new FakeScrapeProvider();
      provider.tvSearchThrows = true;
      const client = new ScrapeClient({ scrapeConcurrency: 1 });
      client.registerProvider(provider);
      const videos: VideoEntity[] = [createVideo(702, 1, '/Shows/Example Show/Example.Show.S01E01.mkv')];
      const resolver = new ScrapeScopeResolver(new StaticScrapeScopeVideoSource(videos));
      const service = new ScopedScrapeService(resolver, new FakeScopedScrapeDependencies(client));

      const outcome = await service.execute(createConfirmRequest([702]), (_progress: ScrapeProgress): void => {});
      expect(outcome.kind).assertEqual('paused');
      if (outcome.kind === 'paused') {
        expect(outcome.pause.reason).assertEqual('candidate-search-retry');
        expect(outcome.resumeState.nextIndex).assertEqual(0);
        expect(outcome.resumeState.progress.failed).assertEqual(0);
      }
    });

    it('caches a TV season once per selected series and season', 0, async () => {
      const provider = new FakeScrapeProvider();
      provider.seriesDetail = createTvSeries();
      provider.seasonResult = createTvSeason();
      provider.episodeResult = createTvEpisode();
      const client = new ScrapeClient({ scrapeConcurrency: 1 });
      client.registerProvider(provider);
      const videos: VideoEntity[] = [
        createVideo(711, 1, '/Shows/Example Show/Season 1/Example.Show.S01E01.mkv'),
        createVideo(712, 1, '/Shows/Example Show/Season 1/Example.Show.S01E02.mkv')
      ];
      const resolver = new ScrapeScopeResolver(new StaticScrapeScopeVideoSource(videos));
      const dependencies = new FakeScopedScrapeDependencies(client);
      const service = new ScopedScrapeService(resolver, dependencies);
      const candidate: ScrapeCandidate = {
        provider: 'fake',
        providerId: 'series-1',
        title: 'Example Show',
        mediaType: 'tv'
      };
      const resumeState = createConfirmationResume('tv:example show', candidate);

      const outcome = await service.execute(
        createConfirmRequest([711, 712]),
        (_progress: ScrapeProgress): void => {},
        resumeState
      );
      expect(outcome.kind).assertEqual('completed');
      expect(provider.fetchSeasonCount).assertEqual(1);
      expect(provider.fetchEpisodeCount).assertEqual(2);
      expect(dependencies.applyTvCount).assertEqual(2);
    });

    it('fails TV targets without an episode number before fetch or persistence', 0, async () => {
      const provider = new FakeScrapeProvider();
      provider.seriesDetail = createTvSeries();
      provider.seasonResult = createTvSeason();
      provider.episodeResult = createTvEpisode();
      const client = new ScrapeClient({ scrapeConcurrency: 1 });
      client.registerProvider(provider);
      const videos: VideoEntity[] = [createVideo(721, 1, '/Shows/Example Show/Season 1/trailer.mkv')];
      const resolver = new ScrapeScopeResolver(new StaticScrapeScopeVideoSource(videos));
      const dependencies = new FakeScopedScrapeDependencies(client);
      const service = new ScopedScrapeService(resolver, dependencies);
      const candidate: ScrapeCandidate = {
        provider: 'fake',
        providerId: 'series-1',
        title: 'Example Show',
        mediaType: 'tv'
      };
      const resumeState = createConfirmationResume('tv:example show', candidate);

      const outcome = await service.execute(
        createConfirmRequest([721]),
        (_progress: ScrapeProgress): void => {},
        resumeState
      );
      expect(outcome.kind).assertEqual('completed');
      if (outcome.kind === 'completed') {
        expect(outcome.result.failed).assertEqual(1);
        expect(outcome.result.failedVideoIds[0]).assertEqual(721);
      }
      expect(provider.fetchSeasonCount).assertEqual(0);
      expect(provider.fetchEpisodeCount).assertEqual(0);
      expect(dependencies.applyTvCount).assertEqual(0);
    });

    it('filters all three scrape modes consistently', 0, () => {
      const missing: ScopedScrapeVideo = {
        video: createVideo(1, 1, '/movie/a.mkv'),
        posterAvailable: false
      };
      const complete: ScopedScrapeVideo = {
        video: createVideo(2, 1, '/movie/b.mkv'),
        scrapeInfo: {
          videoId: 2,
          provider: 'tmdb',
          providerId: '20',
          mediaType: 'movie',
          title: 'B',
          movieId: 20,
          scrapedAt: 1
        },
        posterAvailable: true
      };
      const changed: ScopedScrapeVideo = {
        video: createVideo(3, 1, '/movie/c.mkv', 1),
        scrapeInfo: complete.scrapeInfo,
        posterAvailable: true
      };
      expect(shouldScrapeVideo(missing, 'incremental')).assertTrue();
      expect(shouldScrapeVideo(complete, 'incremental')).assertFalse();
      expect(shouldScrapeVideo(changed, 'incremental')).assertTrue();
      expect(shouldScrapeVideo(missing, 'fix-missing')).assertTrue();
      expect(shouldScrapeVideo(complete, 'fix-missing')).assertFalse();
      expect(shouldScrapeVideo(complete, 'overwrite')).assertTrue();
    });
  });
}
