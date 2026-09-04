import { ScrapeInfoEntity, VideoEntity } from '../../db/models/MediaEntity';
import { FileSourceType } from '../../db/models/FileSourceEntity';
import { ScanMode } from '../../utils/VideoScannerTypes';

export type ScrapeScopeKind = 'movie' | 'series' | 'season' | 'episode' | 'folder' | 'global';
export type ScrapeCandidateStrategy = 'automatic' | 'confirm';
export type ScrapeTaskStatus = 'waiting' | 'running' | 'waiting-confirmation' | 'completed' |
  'partial-failure' | 'failed' | 'cancelled';
export type ScrapePauseReason = 'candidate-confirmation' | 'candidate-search-retry';
export type ScrapeTaskPhase = 'scanning' | 'preparing' | 'scraping';

export interface ScrapeScanContext {
  sourceTypeLabel: string;
  sourceName: string;
  directoryPath: string;
  currentPath: string;
}

/** 刮削失败分类（界面展示的简单分类，避免与底层错误文案漂移）。 */
export const FAILURE_CATEGORY_NO_MATCH = '未匹配到结果';
export const FAILURE_CATEGORY_DB_WRITE = '数据库写入失败';
export const FAILURE_CATEGORY_PARSE_EPISODE = '无法解析集号';
export const FAILURE_CATEGORY_SCRAPER_ERROR = '刮削器异常';
export const FAILURE_CATEGORY_SOURCE_MISSING = '文件源不存在';
export const FAILURE_CATEGORY_NO_TMDB_KEY = '缺少 TMDB API Key';

/** 单个视频的刮削失败项，用于失败详情页展示。 */
export interface ScrapeFailureItem {
  videoId: number;
  fileName: string;
  /** 视频完整路径（含目录），用于失败详情页展示定位。 */
  path: string;
  category: string;
  /** 指向临时日志文件条目；无原始错误信息时可省略。 */
  logKey?: string;
}

/** 单个视频的刮削处理结果。 */
export interface ScrapeVideoOutcome {
  success: boolean;
  category?: string;
  detail?: string;
}

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
  /** 目录保存自动触发场景为逗号拼接的多目录路径（规范化后）。 */
  directoryPath: string;
  displayName: string;
  /** 自动刮削触发标记：目录保存后自动创建的任务携带，用于与手动文件夹任务区分身份。 */
  autoTriggered?: true;
}

export interface GlobalScrapeScope {
  kind: 'global';
  displayName: string;
}

export type ScrapeScope = MovieScrapeScope | SeriesScrapeScope | SeasonScrapeScope |
  EpisodeScrapeScope | FolderScrapeScope | GlobalScrapeScope;

/**
 * 规范化刮削目录路径：统一斜杠、去除重复斜杠、保证以 / 开头、去除末尾 /。
 * 根目录返回 '/'。
 */
export function normalizeScrapeDirectoryPath(path: string): string {
  const slashPath = path.trim().replace(/\\/g, '/').replace(/\/{2,}/g, '/');
  if (slashPath.length === 0 || slashPath === '/') {
    return '/';
  }
  const withLeadingSlash = slashPath.startsWith('/') ? slashPath : `/${slashPath}`;
  return withLeadingSlash.replace(/\/+$/g, '');
}

/**
 * 计算刮削范围的稳定身份标识，用于判断两个 scope 是否指向同一刮削目标。
 * 与 ScrapeTaskQueue 内部构建 active key 时的范围部分保持一致。
 */
export function scrapeScopeId(scope: ScrapeScope): string {
  if (scope.kind === 'movie') {
    return `movie:${scope.movieId}`;
  }
  if (scope.kind === 'series') {
    return `series:${scope.tvSeriesId}`;
  }
  if (scope.kind === 'season') {
    return `season:${scope.tvSeriesId}:${scope.seasonNumber}`;
  }
  if (scope.kind === 'episode') {
    return `episode:${scope.videoId}`;
  }
  if (scope.kind === 'folder') {
    const prefix = scope.autoTriggered === true ? 'auto:' : '';
    return `${prefix}folder:${scope.sourceId}:${normalizeScrapeDirectoryPath(scope.directoryPath)}`;
  }
  return 'global';
}

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
  failedItems: ScrapeFailureItem[];
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
  failedItems: ScrapeFailureItem[];
  /** 定向扫描重试上下文：仅自动触发的目录扫描任务在部分/全部扫描失败时写入。 */
  directedScanContext?: DirectedScanRetryContext;
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

export interface DirectoriesSavedEvent {
  sourceId: number;
  fileSourceType: FileSourceType;
  addedDirectoryPaths: string[];
}

/** 定向扫描重试上下文：记录原始新增目录与失败目录，供失败/部分失败任务专用重试使用。 */
export interface DirectedScanRetryContext {
  sourceId: number;
  /** 原始全部新增目录路径（规范化后）。 */
  originalDirectoryPaths: string[];
  /** 重试时仅需重新扫描的失败目录路径（规范化后）。 */
  failedDirectoryPaths: string[];
}

/**
 * 计算保存前后的规范化目录路径差集，返回新增路径集合。
 * 仅基于路径判等，customName 变更不影响结果。
 */
export function computeDirectoryPathDiff(
  beforePaths: string[],
  afterPaths: string[]
): string[] {
  const beforeNormalized: Set<string> = new Set<string>();
  beforePaths.forEach((p: string) => beforeNormalized.add(normalizeScrapeDirectoryPath(p)));
  const afterNormalized: Set<string> = new Set<string>();
  afterPaths.forEach((p: string) => afterNormalized.add(normalizeScrapeDirectoryPath(p)));
  const added: string[] = [];
  afterNormalized.forEach((p: string) => {
    if (!beforeNormalized.has(p)) {
      added.push(p);
    }
  });
  return added;
}

/**
 * 刮削任务的 UI 快照。作为 @ObservedV2 类持有可变字段的 @Trace 注解，
 * 使进度/状态变化能被 ScrapeTaskIndicator 精准观测，避免整列重建闪烁。
 */
@ObservedV2
export class ScrapeTaskSnapshot {
  readonly id: string;
  readonly request: ScopedScrapeRequest;
  @Trace status: ScrapeTaskStatus;
  @Trace progress: ScrapeProgress;
  @Trace pause: ScrapePause | undefined;
  @Trace resumeState: ScrapeResumeState | undefined;
  @Trace result: ScrapeResult | undefined;
  @Trace phase: ScrapeTaskPhase;
  @Trace scanContext: ScrapeScanContext | undefined;
  readonly createdAt: number;
  @Trace updatedAt: number;

  constructor(id: string, request: ScopedScrapeRequest, createdAt: number) {
    this.id = id;
    this.request = request;
    this.status = 'waiting';
    this.progress = { completed: 0, total: 0, succeeded: 0, failed: 0, cancelled: 0 };
    this.pause = undefined;
    this.resumeState = undefined;
    this.result = undefined;
    this.phase = 'preparing';
    this.scanContext = undefined;
    this.createdAt = createdAt;
    this.updatedAt = createdAt;
  }
}
