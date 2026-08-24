import { FileSourceDatabase } from '../../db/files/FileSourceDatabase';
import { VideoEntity } from '../../db/models/MediaEntity';
import { FileSource } from '../../db/models/FileSourceEntity';
import {
  MovieScrapeResult,
  parseFileName,
  ScrapeClient,
  TvEpisodeScrapeBundle,
  TvSeasonScrapeResult,
  TvSeriesScrapeResult
} from '../../lib/ScrapeClient';
import { extractSeasonNumberFromDirectoryName, extractSeriesHintFromFilePath } from '../../lib/MediaTypeClassifier';
import { AppPreferences, PrefKey } from '../../utils/AppPreferences';
import {
  applyMovieScrapeResult,
  applyTvEpisodeScrapeResult,
  processVideoScrape
} from '../../utils/VideoScrapeProcessor';
import {
  classifyVideoScrapeTarget,
  extractEpisodeNumberFromWeakSemanticFileName
} from '../../utils/VideoScannerHelpers';
import { VideoFileInfo } from '../../utils/VideoScannerTypes';
import { filterScrapeTargets } from './ScrapeModeFilter';
import { ScrapeScopeResolver } from './ScrapeScopeResolver';
import {
  ScopedScrapeRequest,
  ScopedScrapeVideo,
  ScrapeCandidate,
  ScrapeExecutionCompleted,
  ScrapeExecutionOutcome,
  ScrapeExecutionPaused,
  ScrapeGroupSelection,
  ScrapeProgress,
  ScrapeResult,
  ScrapeResumeState
} from './ScopedScrapeTypes';

export type ScrapeProgressCallback = (progress: ScrapeProgress) => void;

interface ScrapeMediaGroup {
  key: string;
  mediaType: 'movie' | 'tv' | 'unknown';
  targets: ScopedScrapeVideo[];
  searchFileName: string;
  seriesHint?: string;
}

export interface ScopedScrapeExecutor {
  execute(
    request: ScopedScrapeRequest,
    onProgress: ScrapeProgressCallback,
    resumeState?: ScrapeResumeState
  ): Promise<ScrapeExecutionOutcome>;
}

export interface ScopedScrapeDependencies {
  getTmdbApiKey(): Promise<string>;
  createClient(tmdbApiKey: string): ScrapeClient;
  getFileSourceById(sourceId: number): Promise<FileSource | null>;
  loadTarget(video: VideoEntity): Promise<ScopedScrapeVideo>;
  processVideo(
    videoId: number,
    fileName: string,
    client: ScrapeClient,
    mode: 'incremental' | 'fix-missing' | 'overwrite',
    info: VideoFileInfo,
    logPrefix: string
  ): Promise<boolean>;
  applyMovie(videoId: number, movie: MovieScrapeResult, logPrefix: string): Promise<boolean>;
  applyTv(videoId: number, result: TvEpisodeScrapeBundle, logPrefix: string): Promise<boolean>;
}

class DefaultScopedScrapeDependencies implements ScopedScrapeDependencies {
  async getTmdbApiKey(): Promise<string> {
    return await AppPreferences.get(PrefKey.TMDB_API_KEY, '');
  }

  createClient(tmdbApiKey: string): ScrapeClient {
    return new ScrapeClient({ tmdbApiKey });
  }

  async getFileSourceById(sourceId: number): Promise<FileSource | null> {
    return await FileSourceDatabase.getInstance().getFileSourceById(sourceId);
  }

  async loadTarget(video: VideoEntity): Promise<ScopedScrapeVideo> {
    const db = FileSourceDatabase.getInstance();
    const scrapeInfo = video.id === undefined ? null : await db.getScrapeInfoByVideoId(video.id);
    let posterAvailable = false;
    if (scrapeInfo?.movieId !== undefined) {
      const movie = await db.getMovieById(scrapeInfo.movieId);
      posterAvailable = !!(movie?.posterUrl || movie?.posterLocalPath);
    } else if (scrapeInfo?.tvSeriesId !== undefined) {
      const series = await db.getTvSeriesById(scrapeInfo.tvSeriesId);
      posterAvailable = !!(series?.posterUrl || series?.posterLocalPath);
    }
    const target: ScopedScrapeVideo = { video, scrapeInfo: scrapeInfo ?? undefined, posterAvailable };
    return target;
  }

  processVideo(
    videoId: number,
    fileName: string,
    client: ScrapeClient,
    mode: 'incremental' | 'fix-missing' | 'overwrite',
    info: VideoFileInfo,
    logPrefix: string
  ): Promise<boolean> {
    return processVideoScrape(videoId, fileName, client, mode, info, logPrefix);
  }

  applyMovie(videoId: number, movie: MovieScrapeResult, logPrefix: string): Promise<boolean> {
    return applyMovieScrapeResult(videoId, movie, logPrefix);
  }

  applyTv(videoId: number, result: TvEpisodeScrapeBundle, logPrefix: string): Promise<boolean> {
    return applyTvEpisodeScrapeResult(videoId, result, logPrefix);
  }
}

export class ScopedScrapeService implements ScopedScrapeExecutor {
  private resolver: ScrapeScopeResolver;
  private dependencies: ScopedScrapeDependencies;

  constructor(resolver?: ScrapeScopeResolver, dependencies?: ScopedScrapeDependencies) {
    this.resolver = resolver ?? new ScrapeScopeResolver();
    this.dependencies = dependencies ?? new DefaultScopedScrapeDependencies();
  }

  async execute(
    request: ScopedScrapeRequest,
    onProgress: ScrapeProgressCallback,
    resumeState?: ScrapeResumeState
  ): Promise<ScrapeExecutionOutcome> {
    if (request.candidateStrategy === 'confirm' && request.scope.kind !== 'global') {
      return await this.executeWithConfirmation(request, onProgress, resumeState);
    }
    const result = await this.executeAutomatic(request, onProgress);
    const completed: ScrapeExecutionCompleted = { kind: 'completed', result };
    return completed;
  }

  private async executeWithConfirmation(
    request: ScopedScrapeRequest,
    onProgress: ScrapeProgressCallback,
    resumeState?: ScrapeResumeState
  ): Promise<ScrapeExecutionOutcome> {
    const resolvedVideos = await this.resolver.resolve(request.scope);
    const videos = this.limitToVideoIds(resolvedVideos, request.videoIds);
    const enriched: ScopedScrapeVideo[] = [];
    for (const video of videos) {
      enriched.push(await this.dependencies.loadTarget(video));
    }
    const targets = filterScrapeTargets(enriched, request.mode);
    const groups = this.buildGroups(targets);
    const progress = resumeState === undefined
      ? this.createProgress(targets.length)
      : this.copyProgress(resumeState.progress);
    const succeededVideoIds = resumeState?.succeededVideoIds.slice() ?? [];
    const failedVideoIds = resumeState?.failedVideoIds.slice() ?? [];
    const selections = resumeState?.selections.slice() ?? [];
    const cancelledGroupKeys = resumeState?.cancelledGroupKeys.slice() ?? [];
    const startIndex = resumeState?.nextIndex ?? 0;
    onProgress(this.copyProgress(progress));

    const tmdbApiKey = await this.dependencies.getTmdbApiKey();
    if (tmdbApiKey.length === 0 && targets.length > progress.completed) {
      this.failRemainingGroups(groups, startIndex, progress, failedVideoIds);
      onProgress(this.copyProgress(progress));
      return this.completed(progress, succeededVideoIds, failedVideoIds);
    }
    const client = this.dependencies.createClient(tmdbApiKey);
    const seasonCache = new Map<string, TvSeasonScrapeResult | null>();
    for (let index = startIndex; index < groups.length; index++) {
      const group = groups[index];
      if (cancelledGroupKeys.includes(group.key)) {
        this.finishCancelledGroup(group, progress);
        onProgress(this.copyProgress(progress));
        continue;
      }
      const selection = this.findSelection(selections, group.key);
      if (selection === undefined) {
        let candidates: ScrapeCandidate[] = [];
        try {
          candidates = await this.searchCandidates(client, group);
        } catch {
          candidates = [];
        }
        if (candidates.length === 0) {
          return this.createCandidateSearchPause(
            group.key,
            index,
            selections,
            cancelledGroupKeys,
            progress,
            succeededVideoIds,
            failedVideoIds
          );
        }
        const paused: ScrapeExecutionPaused = {
          kind: 'paused',
          pause: { reason: 'candidate-confirmation', groupKey: group.key, candidates },
          resumeState: {
            nextIndex: index,
            selections,
            cancelledGroupKeys,
            progress: this.copyProgress(progress),
            succeededVideoIds: succeededVideoIds.slice(),
            failedVideoIds: failedVideoIds.slice()
          }
        };
        return paused;
      }
      await this.processSelectedGroup(
        group,
        selection,
        client,
        seasonCache,
        progress,
        succeededVideoIds,
        failedVideoIds,
        onProgress
      );
    }
    return this.completed(progress, succeededVideoIds, failedVideoIds);
  }

  private async executeAutomatic(
    request: ScopedScrapeRequest,
    onProgress: ScrapeProgressCallback
  ): Promise<ScrapeResult> {
    const resolvedVideos = await this.resolver.resolve(request.scope);
    const videos = this.limitToVideoIds(resolvedVideos, request.videoIds);
    const enriched: ScopedScrapeVideo[] = [];
    for (const video of videos) {
      const target = await this.dependencies.loadTarget(video);
      enriched.push(target);
    }
    const targets = filterScrapeTargets(enriched, request.mode);
    const progress: ScrapeProgress = {
      completed: 0,
      total: targets.length,
      succeeded: 0,
      failed: 0,
      cancelled: 0
    };
    onProgress(progress);

    const tmdbApiKey = await this.dependencies.getTmdbApiKey();
    if (tmdbApiKey.length === 0 && targets.length > 0) {
      return this.allFailed(targets, onProgress);
    }
    const scrapeClient = this.dependencies.createClient(tmdbApiKey);
    const succeededVideoIds: number[] = [];
    const failedVideoIds: number[] = [];
    for (const target of targets) {
      const video = target.video;
      const videoId = video.id;
      if (videoId === undefined) {
        progress.failed++;
      } else {
        try {
          const source = await this.dependencies.getFileSourceById(video.sourceId);
          if (source === null) {
            failedVideoIds.push(videoId);
            progress.failed++;
          } else {
            const succeeded = await this.dependencies.processVideo(
              videoId,
              video.fileName,
              scrapeClient,
              request.mode,
              this.toVideoFileInfo(video, source),
              '[ScopedScrape]'
            );
            if (succeeded) {
              succeededVideoIds.push(videoId);
              progress.succeeded++;
            } else {
              failedVideoIds.push(videoId);
              progress.failed++;
            }
          }
        } catch {
          failedVideoIds.push(videoId);
          progress.failed++;
        }
      }
      progress.completed++;
      onProgress(this.copyProgress(progress));
    }
    const result: ScrapeResult = {
      total: targets.length,
      succeeded: progress.succeeded,
      failed: progress.failed,
      cancelled: 0,
      succeededVideoIds,
      failedVideoIds
    };
    return result;
  }

  private buildGroups(targets: ScopedScrapeVideo[]): ScrapeMediaGroup[] {
    const groups: ScrapeMediaGroup[] = [];
    const groupMap = new Map<string, ScrapeMediaGroup>();
    for (const target of targets) {
      const video = target.video;
      const classification = classifyVideoScrapeTarget(video.fileName, video.filePath);
      const seriesHint = extractSeriesHintFromFilePath(video.filePath);
      const parsed = parseFileName(video.fileName);
      const titleKey = (seriesHint ?? parsed.title).trim().toLowerCase();
      const key = classification.mediaType === 'tv'
        ? `tv:${titleKey}`
        : `${classification.mediaType}:${video.id ?? video.filePath}`;
      const existing = groupMap.get(key);
      if (existing !== undefined) {
        existing.targets.push(target);
      } else {
        const group: ScrapeMediaGroup = {
          key,
          mediaType: classification.mediaType,
          targets: [target],
          searchFileName: video.fileName,
          seriesHint
        };
        groups.push(group);
        groupMap.set(key, group);
      }
    }
    return groups;
  }

  private async searchCandidates(client: ScrapeClient, group: ScrapeMediaGroup): Promise<ScrapeCandidate[]> {
    if (group.mediaType === 'movie') {
      const results = await client.searchMovieCandidates(group.searchFileName);
      return results.map((result: MovieScrapeResult): ScrapeCandidate => this.movieCandidate(result));
    }
    if (group.mediaType === 'tv') {
      const results = await client.searchTvCandidates(group.searchFileName, group.seriesHint);
      return results.map((result: TvSeriesScrapeResult): ScrapeCandidate => this.tvCandidate(result));
    }
    return [];
  }

  private async processSelectedGroup(
    group: ScrapeMediaGroup,
    selection: ScrapeCandidate,
    client: ScrapeClient,
    seasonCache: Map<string, TvSeasonScrapeResult | null>,
    progress: ScrapeProgress,
    succeededVideoIds: number[],
    failedVideoIds: number[],
    onProgress: ScrapeProgressCallback
  ): Promise<void> {
    let movie: MovieScrapeResult | null = null;
    let series: TvSeriesScrapeResult | null = null;
    try {
      if (group.mediaType === 'movie') {
        movie = await client.fetchMovieDetail(selection.providerId, selection.provider);
      } else if (group.mediaType === 'tv') {
        series = await client.fetchTvSeriesDetail(selection.providerId, selection.provider);
      }
    } catch {
      movie = null;
      series = null;
    }
    for (const target of group.targets) {
      const video = target.video;
      const videoId = video.id;
      let succeeded = false;
      if (videoId !== undefined) {
        try {
          if (movie !== null) {
            succeeded = await this.dependencies.applyMovie(videoId, movie, '[ScopedScrape]');
          } else if (series !== null) {
            succeeded = await this.applySelectedSeries(
              videoId,
              video,
              series,
              selection,
              client,
              seasonCache
            );
          }
        } catch {
          succeeded = false;
        }
        if (!succeeded) {
          failedVideoIds.push(videoId);
        }
      }
      if (succeeded) {
        if (videoId !== undefined) {
          succeededVideoIds.push(videoId);
        }
        progress.succeeded++;
      } else {
        progress.failed++;
      }
      progress.completed++;
      onProgress(this.copyProgress(progress));
    }
  }

  private async applySelectedSeries(
    videoId: number,
    video: VideoEntity,
    series: TvSeriesScrapeResult,
    selection: ScrapeCandidate,
    client: ScrapeClient,
    seasonCache: Map<string, TvSeasonScrapeResult | null>
  ): Promise<boolean> {
    const parsed = parseFileName(video.fileName);
    const seasonNumber = parsed.seasonNumber ?? this.extractDirectorySeason(video.filePath) ?? 1;
    const episodeNumber = parsed.episodeNumber ?? extractEpisodeNumberFromWeakSemanticFileName(video.fileName);
    if (episodeNumber === undefined) {
      return false;
    }
    const seasonCacheKey = `${selection.provider}:${series.providerId}:${seasonNumber}`;
    let season = seasonCache.get(seasonCacheKey);
    if (season === undefined && !seasonCache.has(seasonCacheKey)) {
      season = await client.fetchSeason(series.providerId, seasonNumber, selection.provider);
      seasonCache.set(seasonCacheKey, season);
    }
    const episode = await client.fetchEpisode(
      series.providerId,
      seasonNumber,
      episodeNumber,
      selection.provider
    );
    if (episode === null) {
      return false;
    }
    const bundle: TvEpisodeScrapeBundle = { series, season: season ?? null, episode };
    return await this.dependencies.applyTv(videoId, bundle, '[ScopedScrape]');
  }

  private movieCandidate(result: MovieScrapeResult): ScrapeCandidate {
    const candidate: ScrapeCandidate = {
      provider: result.provider,
      providerId: result.providerId,
      title: result.title,
      year: result.releaseDate?.substring(0, 4),
      posterUrl: result.posterUrl,
      mediaType: 'movie'
    };
    return candidate;
  }

  private tvCandidate(result: TvSeriesScrapeResult): ScrapeCandidate {
    const candidate: ScrapeCandidate = {
      provider: result.provider,
      providerId: result.providerId,
      title: result.title,
      year: result.firstAirDate?.substring(0, 4),
      posterUrl: result.posterUrl,
      mediaType: 'tv'
    };
    return candidate;
  }

  private findSelection(selections: ScrapeGroupSelection[], groupKey: string): ScrapeCandidate | undefined {
    const selected = selections.find((item: ScrapeGroupSelection): boolean => item.groupKey === groupKey);
    return selected?.candidate;
  }

  private extractDirectorySeason(filePath: string): number | undefined {
    const segments = filePath.replace(/\\/g, '/').split('/').filter((segment: string): boolean => segment.length > 0);
    if (segments.length < 2) {
      return undefined;
    }
    return extractSeasonNumberFromDirectoryName(segments[segments.length - 2]);
  }

  private finishCancelledGroup(group: ScrapeMediaGroup, progress: ScrapeProgress): void {
    progress.cancelled += group.targets.length;
    progress.completed += group.targets.length;
  }

  private failGroup(group: ScrapeMediaGroup, progress: ScrapeProgress, failedVideoIds: number[]): void {
    for (const target of group.targets) {
      if (target.video.id !== undefined) {
        failedVideoIds.push(target.video.id);
      }
      progress.failed++;
      progress.completed++;
    }
  }

  private failRemainingGroups(
    groups: ScrapeMediaGroup[],
    startIndex: number,
    progress: ScrapeProgress,
    failedVideoIds: number[]
  ): void {
    for (let index = startIndex; index < groups.length; index++) {
      this.failGroup(groups[index], progress, failedVideoIds);
    }
  }

  private createCandidateSearchPause(
    groupKey: string,
    nextIndex: number,
    selections: ScrapeGroupSelection[],
    cancelledGroupKeys: string[],
    progress: ScrapeProgress,
    succeededVideoIds: number[],
    failedVideoIds: number[]
  ): ScrapeExecutionPaused {
    const paused: ScrapeExecutionPaused = {
      kind: 'paused',
      pause: { reason: 'candidate-search-retry', groupKey, candidates: [] },
      resumeState: {
        nextIndex,
        selections: selections.slice(),
        cancelledGroupKeys: cancelledGroupKeys.slice(),
        progress: this.copyProgress(progress),
        succeededVideoIds: succeededVideoIds.slice(),
        failedVideoIds: failedVideoIds.slice()
      }
    };
    return paused;
  }

  private createProgress(total: number): ScrapeProgress {
    const progress: ScrapeProgress = { completed: 0, total, succeeded: 0, failed: 0, cancelled: 0 };
    return progress;
  }

  private completed(
    progress: ScrapeProgress,
    succeededVideoIds: number[],
    failedVideoIds: number[]
  ): ScrapeExecutionCompleted {
    const result: ScrapeResult = {
      total: progress.total,
      succeeded: progress.succeeded,
      failed: progress.failed,
      cancelled: progress.cancelled,
      succeededVideoIds,
      failedVideoIds
    };
    const completed: ScrapeExecutionCompleted = { kind: 'completed', result };
    return completed;
  }

  private toVideoFileInfo(video: VideoEntity, source: FileSource): VideoFileInfo {
    const info: VideoFileInfo = {
      sourceId: video.sourceId,
      sourceName: source.name,
      sourceType: source.type,
      directoryPath: video.directoryPath,
      filePath: video.filePath,
      fileName: video.fileName,
      fileSize: video.fileSize,
      lastModified: video.lastModified,
      contentType: video.contentType,
      wasProcessed: true
    };
    return info;
  }

  private limitToVideoIds(videos: VideoEntity[], videoIds?: number[]): VideoEntity[] {
    if (videoIds === undefined) {
      return videos;
    }
    const allowedIds = new Set<number>(videoIds);
    return videos.filter((video: VideoEntity): boolean => video.id !== undefined && allowedIds.has(video.id));
  }

  private allFailed(targets: ScopedScrapeVideo[], onProgress: ScrapeProgressCallback): ScrapeResult {
    const failedVideoIds: number[] = [];
    for (const target of targets) {
      if (target.video.id !== undefined) {
        failedVideoIds.push(target.video.id);
      }
    }
    const progress: ScrapeProgress = {
      completed: targets.length,
      total: targets.length,
      succeeded: 0,
      failed: targets.length,
      cancelled: 0
    };
    onProgress(progress);
    const result: ScrapeResult = {
      total: targets.length,
      succeeded: 0,
      failed: targets.length,
      cancelled: 0,
      succeededVideoIds: [],
      failedVideoIds
    };
    return result;
  }

  private copyProgress(progress: ScrapeProgress): ScrapeProgress {
    const copy: ScrapeProgress = {
      completed: progress.completed,
      total: progress.total,
      succeeded: progress.succeeded,
      failed: progress.failed,
      cancelled: progress.cancelled
    };
    return copy;
  }
}
