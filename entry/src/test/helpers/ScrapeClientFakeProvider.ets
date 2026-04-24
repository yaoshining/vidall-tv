
import {
  IScrapeProvider,
  MovieScrapeResult,
  TvEpisodeScrapeResult,
  TvSeasonScrapeResult,
  TvSeriesScrapeResult
} from '../../main/ets/lib/ScrapeClient';

export interface Deferred<T> {
  promise: Promise<T>;
  resolve(value: T): void;
  reject(reason: Error): void;
}

export interface ReturnOutcome<T> {
  kind: 'return';
  value: T;
}

export interface ThrowOutcome {
  kind: 'throw';
  error: string | Error;
}

export interface DeferOutcome<T> {
  kind: 'defer';
  deferred: Deferred<T>;
}

export type ScriptedOutcome<T> = ReturnOutcome<T> | ThrowOutcome | DeferOutcome<T>;

export interface ProviderCallRecord {
  method: string;
  title?: string;
  year?: number;
  language?: string;
  providerId?: string;
  seasonNumber?: number;
  episodeNumber?: number;
}

class DeferredImpl<T> implements Deferred<T> {
  promise: Promise<T>;
  private resolveFn: (value: T) => void = (_value: T): void => {};
  private rejectFn: (reason: Error) => void = (_reason: Error): void => {};

  constructor() {
    this.promise = new Promise<T>((resolve, reject) => {
      this.resolveFn = resolve;
      this.rejectFn = reject;
    });
  }

  resolve(value: T): void {
    this.resolveFn(value);
  }

  reject(reason: Error): void {
    this.rejectFn(reason);
  }
}

class ReturnOutcomeImpl<T> implements ReturnOutcome<T> {
  kind: 'return' = 'return';
  value: T;

  constructor(value: T) {
    this.value = value;
  }
}

class ThrowOutcomeImpl implements ThrowOutcome {
  kind: 'throw' = 'throw';
  error: string | Error;

  constructor(error: string | Error) {
    this.error = error;
  }
}

class DeferOutcomeImpl<T> implements DeferOutcome<T> {
  kind: 'defer' = 'defer';
  deferred: Deferred<T>;

  constructor(deferred: Deferred<T>) {
    this.deferred = deferred;
  }
}

class MovieScrapeResultImpl implements MovieScrapeResult {
  provider: string;
  providerId: string;
  title: string;
  originalTitle?: string;
  overview?: string;
  releaseDate?: string;
  rating?: number;
  voteCount?: number;
  posterPath?: string;
  backdropPath?: string;
  posterUrl?: string;
  backdropUrl?: string;
  genresJson?: string;
  castJson?: string;
  directorsJson?: string;
  runtime?: number;
  originalLanguage?: string;
  originCountryJson?: string;
  rawJson?: string;

  constructor(provider: string, title: string, providerId: string) {
    this.provider = provider;
    this.providerId = providerId;
    this.title = title;
    this.rawJson = JSON.stringify({ provider, providerId, title });
  }
}

class TvSeriesScrapeResultImpl implements TvSeriesScrapeResult {
  provider: string;
  providerId: string;
  title: string;
  originalTitle?: string;
  overview?: string;
  firstAirDate?: string;
  rating?: number;
  voteCount?: number;
  posterPath?: string;
  backdropPath?: string;
  posterUrl?: string;
  backdropUrl?: string;
  genresJson?: string;
  castJson?: string;
  numberOfSeasons?: number;
  originalLanguage?: string;
  originCountryJson?: string;
  rawJson?: string;

  constructor(provider: string, title: string, providerId: string) {
    this.provider = provider;
    this.providerId = providerId;
    this.title = title;
    this.rawJson = JSON.stringify({ provider, providerId, title });
  }
}

class TvSeasonScrapeResultImpl implements TvSeasonScrapeResult {
  provider: string;
  providerId: string;
  seasonNumber: number;
  title?: string;
  overview?: string;
  airDate?: string;
  episodeCount?: number;
  posterPath?: string;
  posterUrl?: string;
  rawJson?: string;

  constructor(provider: string, seasonNumber: number, providerId: string, title?: string) {
    this.provider = provider;
    this.providerId = providerId;
    this.seasonNumber = seasonNumber;
    this.title = title;
    this.rawJson = JSON.stringify({ provider, providerId, seasonNumber, title });
  }
}

class TvEpisodeScrapeResultImpl implements TvEpisodeScrapeResult {
  provider: string;
  providerId: string;
  seasonNumber: number;
  episodeNumber: number;
  title?: string;
  overview?: string;
  airDate?: string;
  runtime?: number;
  rating?: number;
  stillPath?: string;
  stillUrl?: string;
  rawJson?: string;

  constructor(provider: string, seasonNumber: number, episodeNumber: number, providerId: string, title?: string) {
    this.provider = provider;
    this.providerId = providerId;
    this.seasonNumber = seasonNumber;
    this.episodeNumber = episodeNumber;
    this.title = title;
    this.rawJson = JSON.stringify({ provider, providerId, seasonNumber, episodeNumber, title });
  }
}

export function createDeferred<T>(): Deferred<T> {
  return new DeferredImpl<T>();
}

function normalizeError(error: string | Error): Error {
  return typeof error === 'string' ? new Error(error) : error;
}

function returnOutcome<T>(value: T): ScriptedOutcome<T> {
  return new ReturnOutcomeImpl<T>(value);
}

function throwOutcome<T>(error: string | Error): ScriptedOutcome<T> {
  return new ThrowOutcomeImpl(error);
}

function deferOutcome<T>(deferred: Deferred<T>): ScriptedOutcome<T> {
  return new DeferOutcomeImpl<T>(deferred);
}

export function createMovieScrapeResult(provider: string, title: string, providerId: string): MovieScrapeResult {
  return new MovieScrapeResultImpl(provider, title, providerId);
}

export function createTvSeriesScrapeResult(provider: string, title: string, providerId: string): TvSeriesScrapeResult {
  return new TvSeriesScrapeResultImpl(provider, title, providerId);
}

export function createTvSeasonScrapeResult(provider: string, seasonNumber: number, providerId: string, title?: string): TvSeasonScrapeResult {
  return new TvSeasonScrapeResultImpl(provider, seasonNumber, providerId, title);
}

export function createTvEpisodeScrapeResult(provider: string, seasonNumber: number, episodeNumber: number, providerId: string, title?: string): TvEpisodeScrapeResult {
  return new TvEpisodeScrapeResultImpl(provider, seasonNumber, episodeNumber, providerId, title);
}

export class ScriptedFakeScrapeProvider implements IScrapeProvider {
  readonly id: string;
  private configured: boolean = true;
  private callLog: ProviderCallRecord[] = [];
  private searchMovieScript: ScriptedOutcome<MovieScrapeResult[]>[] = [];
  private searchTvScript: ScriptedOutcome<TvSeriesScrapeResult[]>[] = [];
  private fetchMovieDetailScript: ScriptedOutcome<MovieScrapeResult | null>[] = [];
  private fetchTvSeriesDetailScript: ScriptedOutcome<TvSeriesScrapeResult | null>[] = [];
  private fetchSeasonScript: ScriptedOutcome<TvSeasonScrapeResult | null>[] = [];
  private fetchEpisodeScript: ScriptedOutcome<TvEpisodeScrapeResult | null>[] = [];

  constructor(id: string, configured: boolean = true) {
    this.id = id;
    this.configured = configured;
  }

  setConfigured(configured: boolean): ScriptedFakeScrapeProvider {
    this.configured = configured;
    return this;
  }

  enqueueSearchMovieResults(results: MovieScrapeResult[]): ScriptedFakeScrapeProvider {
    this.searchMovieScript.push(returnOutcome(results));
    return this;
  }

  enqueueSearchMovieThrow(error: string | Error): ScriptedFakeScrapeProvider {
    this.searchMovieScript.push(throwOutcome(error));
    return this;
  }

  enqueueSearchMovieDeferred(deferred: Deferred<MovieScrapeResult[]>): ScriptedFakeScrapeProvider {
    this.searchMovieScript.push(deferOutcome(deferred));
    return this;
  }

  enqueueFetchMovieDetailResult(result: MovieScrapeResult | null): ScriptedFakeScrapeProvider {
    this.fetchMovieDetailScript.push(returnOutcome(result));
    return this;
  }

  enqueueFetchMovieDetailThrow(error: string | Error): ScriptedFakeScrapeProvider {
    this.fetchMovieDetailScript.push(throwOutcome(error));
    return this;
  }

  enqueueFetchMovieDetailDeferred(deferred: Deferred<MovieScrapeResult | null>): ScriptedFakeScrapeProvider {
    this.fetchMovieDetailScript.push(deferOutcome(deferred));
    return this;
  }

  enqueueSearchTvResults(results: TvSeriesScrapeResult[]): ScriptedFakeScrapeProvider {
    this.searchTvScript.push(returnOutcome(results));
    return this;
  }

  enqueueSearchTvThrow(error: string | Error): ScriptedFakeScrapeProvider {
    this.searchTvScript.push(throwOutcome(error));
    return this;
  }

  enqueueSearchTvDeferred(deferred: Deferred<TvSeriesScrapeResult[]>): ScriptedFakeScrapeProvider {
    this.searchTvScript.push(deferOutcome(deferred));
    return this;
  }

  enqueueFetchTvSeriesDetailResult(result: TvSeriesScrapeResult | null): ScriptedFakeScrapeProvider {
    this.fetchTvSeriesDetailScript.push(returnOutcome(result));
    return this;
  }

  enqueueFetchTvSeriesDetailThrow(error: string | Error): ScriptedFakeScrapeProvider {
    this.fetchTvSeriesDetailScript.push(throwOutcome(error));
    return this;
  }

  enqueueFetchTvSeriesDetailDeferred(deferred: Deferred<TvSeriesScrapeResult | null>): ScriptedFakeScrapeProvider {
    this.fetchTvSeriesDetailScript.push(deferOutcome(deferred));
    return this;
  }

  enqueueFetchSeasonResult(result: TvSeasonScrapeResult | null): ScriptedFakeScrapeProvider {
    this.fetchSeasonScript.push(returnOutcome(result));
    return this;
  }

  enqueueFetchSeasonThrow(error: string | Error): ScriptedFakeScrapeProvider {
    this.fetchSeasonScript.push(throwOutcome(error));
    return this;
  }

  enqueueFetchSeasonDeferred(deferred: Deferred<TvSeasonScrapeResult | null>): ScriptedFakeScrapeProvider {
    this.fetchSeasonScript.push(deferOutcome(deferred));
    return this;
  }

  enqueueFetchEpisodeResult(result: TvEpisodeScrapeResult | null): ScriptedFakeScrapeProvider {
    this.fetchEpisodeScript.push(returnOutcome(result));
    return this;
  }

  enqueueFetchEpisodeThrow(error: string | Error): ScriptedFakeScrapeProvider {
    this.fetchEpisodeScript.push(throwOutcome(error));
    return this;
  }

  enqueueFetchEpisodeDeferred(deferred: Deferred<TvEpisodeScrapeResult | null>): ScriptedFakeScrapeProvider {
    this.fetchEpisodeScript.push(deferOutcome(deferred));
    return this;
  }

  isConfigured(): boolean {
    return this.configured;
  }

  getCallCount(method: string): number {
    return this.callLog.filter((call: ProviderCallRecord) => call.method === method).length;
  }

  getLastCall(method: string): ProviderCallRecord | null {
    for (let index = this.callLog.length - 1; index >= 0; index--) {
      const call = this.callLog[index];
      if (call.method === method) {
        return call;
      }
    }
    return null;
  }

  async searchMovie(title: string, year?: number, language?: string): Promise<MovieScrapeResult[]> {
    this.recordCall({ method: 'searchMovie', title, year, language });
    return await this.runScript('searchMovie', this.searchMovieScript);
  }

  async searchTv(title: string, year?: number, language?: string): Promise<TvSeriesScrapeResult[]> {
    this.recordCall({ method: 'searchTv', title, year, language });
    return await this.runScript('searchTv', this.searchTvScript);
  }

  async fetchMovieDetail(providerId: string, language?: string): Promise<MovieScrapeResult | null> {
    this.recordCall({ method: 'fetchMovieDetail', providerId, language });
    return await this.runScript('fetchMovieDetail', this.fetchMovieDetailScript);
  }

  async fetchTvSeriesDetail(providerId: string, language?: string): Promise<TvSeriesScrapeResult | null> {
    this.recordCall({ method: 'fetchTvSeriesDetail', providerId, language });
    return await this.runScript('fetchTvSeriesDetail', this.fetchTvSeriesDetailScript);
  }

  async fetchSeason(seriesProviderId: string, seasonNumber: number, language?: string): Promise<TvSeasonScrapeResult | null> {
    this.recordCall({ method: 'fetchSeason', providerId: seriesProviderId, seasonNumber, language });
    return await this.runScript('fetchSeason', this.fetchSeasonScript);
  }

  async fetchEpisode(seriesProviderId: string, seasonNumber: number, episodeNumber: number, language?: string): Promise<TvEpisodeScrapeResult | null> {
    this.recordCall({ method: 'fetchEpisode', providerId: seriesProviderId, seasonNumber, episodeNumber, language });
    return await this.runScript('fetchEpisode', this.fetchEpisodeScript);
  }

  private recordCall(call: ProviderCallRecord): void {
    this.callLog.push(call);
  }

  private async runScript<T>(method: string, script: ScriptedOutcome<T>[]): Promise<T> {
    if (!this.configured) {
      throw new Error(`ScriptedFakeScrapeProvider(${this.id}) is not configured for ${method}`);
    }
    const step = script.length > 0 ? script.shift() : undefined;
    if (step === undefined) {
      throw new Error(`ScriptedFakeScrapeProvider(${this.id}) missing ${method} script outcome`);
    }
    if (step.kind === 'return') {
      return step.value;
    }
    if (step.kind === 'throw') {
      throw normalizeError(step.error);
    }
    return await step.deferred.promise;
  }
}
