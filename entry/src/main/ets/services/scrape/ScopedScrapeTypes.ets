import { ScrapeInfoEntity, VideoEntity } from '../../db/models/MediaEntity';
import { ScanMode } from '../../utils/VideoScannerTypes';

export type ScrapeScopeKind = 'movie' | 'series' | 'season' | 'episode' | 'folder' | 'global';
export type ScrapeCandidateStrategy = 'automatic' | 'confirm';
export type ScrapeTaskStatus = 'waiting' | 'running' | 'waiting-confirmation' | 'completed' |
  'partial-failure' | 'failed' | 'cancelled';
export type ScrapePauseReason = 'candidate-confirmation' | 'candidate-search-retry';

export interface MovieScrapeScope {
  kind: 'movie';
  movieId: number;
  displayName: string;
}

export interface SeriesScrapeScope {
  kind: 'series';
  tvSeriesId: number;
  displayName: string;
}

export interface SeasonScrapeScope {
  kind: 'season';
  tvSeriesId: number;
  seasonNumber: number;
  displayName: string;
}

export interface EpisodeScrapeScope {
  kind: 'episode';
  videoId: number;
  displayName: string;
}

export interface FolderScrapeScope {
  kind: 'folder';
  sourceId: number;
  directoryPath: string;
  displayName: string;
}

export interface GlobalScrapeScope {
  kind: 'global';
  displayName: string;
}

export type ScrapeScope = MovieScrapeScope | SeriesScrapeScope | SeasonScrapeScope |
  EpisodeScrapeScope | FolderScrapeScope | GlobalScrapeScope;

export interface ScopedScrapeRequest {
  scope: ScrapeScope;
  mode: ScanMode;
  candidateStrategy: ScrapeCandidateStrategy;
  /** 内部精确目标限制，仅用于失败重试。 */
  videoIds?: number[];
}

export interface ScrapeGroupSelection {
  groupKey: string;
  candidate: ScrapeCandidate;
}

export interface ScrapeResumeState {
  nextIndex: number;
  selections: ScrapeGroupSelection[];
  cancelledGroupKeys: string[];
  progress: ScrapeProgress;
  succeededVideoIds: number[];
  failedVideoIds: number[];
}

export interface ScopedScrapeVideo {
  video: VideoEntity;
  scrapeInfo?: ScrapeInfoEntity;
  posterAvailable: boolean;
}

export interface ScrapeCandidate {
  provider: string;
  providerId: string;
  title: string;
  year?: string;
  posterUrl?: string;
  mediaType: 'movie' | 'tv';
}

export interface ScrapeProgress {
  completed: number;
  total: number;
  succeeded: number;
  failed: number;
  cancelled: number;
}

export interface ScrapePause {
  reason: ScrapePauseReason;
  groupKey: string;
  candidates: ScrapeCandidate[];
}

export interface ScrapeResult {
  total: number;
  succeeded: number;
  failed: number;
  cancelled: number;
  succeededVideoIds: number[];
  failedVideoIds: number[];
}

export interface ScrapeExecutionCompleted {
  kind: 'completed';
  result: ScrapeResult;
}

export interface ScrapeExecutionPaused {
  kind: 'paused';
  pause: ScrapePause;
  resumeState: ScrapeResumeState;
}

export type ScrapeExecutionOutcome = ScrapeExecutionCompleted | ScrapeExecutionPaused;

export interface ScrapeTaskSnapshot {
  id: string;
  request: ScopedScrapeRequest;
  status: ScrapeTaskStatus;
  progress: ScrapeProgress;
  pause?: ScrapePause;
  resumeState?: ScrapeResumeState;
  result?: ScrapeResult;
  createdAt: number;
  updatedAt: number;
}
