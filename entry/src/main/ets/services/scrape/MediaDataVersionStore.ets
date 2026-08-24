import { ScrapeScope } from './ScopedScrapeTypes';

@ObservedV2
export class MediaDataVersionStore {
  private static instance: MediaDataVersionStore | null = null;

  static getState(): MediaDataVersionStore {
    if (MediaDataVersionStore.instance === null) {
      MediaDataVersionStore.instance = new MediaDataVersionStore();
    }
    return MediaDataVersionStore.instance;
  }

  @Trace globalVersion: number = 0;
  @Trace movieVersions: Map<number, number> = new Map();
  @Trace seriesVersions: Map<number, number> = new Map();
  @Trace seasonVersions: Map<string, number> = new Map();
  @Trace videoVersions: Map<number, number> = new Map();

  publish(scope: ScrapeScope): void {
    this.globalVersion++;
    if (scope.kind === 'movie') {
      this.movieVersions = this.incrementNumberKey(this.movieVersions, scope.movieId);
    } else if (scope.kind === 'series') {
      this.seriesVersions = this.incrementNumberKey(this.seriesVersions, scope.tvSeriesId);
    } else if (scope.kind === 'season') {
      this.seriesVersions = this.incrementNumberKey(this.seriesVersions, scope.tvSeriesId);
      this.seasonVersions = this.incrementStringKey(
        this.seasonVersions,
        this.seasonKey(scope.tvSeriesId, scope.seasonNumber)
      );
    } else if (scope.kind === 'episode') {
      this.videoVersions = this.incrementNumberKey(this.videoVersions, scope.videoId);
    }
  }

  publishSuccessful(scope: ScrapeScope, succeededVideoIds: number[]): Promise<void> {
    return Promise.resolve().then((): void => {
      this.publish(scope);
      if (succeededVideoIds.length === 0) {
        return;
      }
      for (const videoId of succeededVideoIds) {
        this.videoVersions = this.incrementNumberKey(this.videoVersions, videoId);
      }
    });
  }

  getMovieVersion(movieId: number): number {
    return this.movieVersions.get(movieId) ?? 0;
  }

  getSeriesVersion(tvSeriesId: number): number {
    return this.seriesVersions.get(tvSeriesId) ?? 0;
  }

  getSeasonVersion(tvSeriesId: number, seasonNumber: number): number {
    return this.seasonVersions.get(this.seasonKey(tvSeriesId, seasonNumber)) ?? 0;
  }

  getVideoVersion(videoId: number): number {
    return this.videoVersions.get(videoId) ?? 0;
  }

  private seasonKey(tvSeriesId: number, seasonNumber: number): string {
    return `${tvSeriesId}:${seasonNumber}`;
  }

  private incrementNumberKey(source: Map<number, number>, key: number): Map<number, number> {
    const next = new Map<number, number>(source);
    next.set(key, (next.get(key) ?? 0) + 1);
    return next;
  }

  private incrementStringKey(source: Map<string, number>, key: string): Map<string, number> {
    const next = new Map<string, number>(source);
    next.set(key, (next.get(key) ?? 0) + 1);
    return next;
  }
}
