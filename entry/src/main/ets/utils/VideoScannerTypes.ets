import { FileSourceType } from '../db/models/FileSourceEntity';
import { VideoEntity, VideoUpsertResult } from '../db/models/MediaEntity';

// ─────────────────────────────────────────────
// 数据结构
// ─────────────────────────────────────────────

/** 扫描到的单个视频文件信息 */
export interface VideoFileInfo {
  sourceId: number;
  sourceName: string;
  sourceType: FileSourceType;
  directoryPath: string;
  filePath: string;
  fileName: string;
  fileSize?: number;
  lastModified?: string;
  contentType?: string;
  wasProcessed?: boolean;
  scrapeSkipped?: boolean;
  seasonSiblingDetected?: boolean;
  seriesHint?: string;
}

export interface VideoScrapeContext {
  seasonSiblingDetected?: boolean;
  seriesHint?: string;
  explicitEpisodeNumber?: number;
  explicitSeasonNumber?: number;
}

export interface SourceScanStat {
  sourceId: number;
  sourceName: string;
  sourceType: FileSourceType;
  directoriesScanned: number;
  videosFound: number;
}

export interface ScanResult {
  totalDirectories: number;
  totalVideos: number;
  processedVideos: number;
  skippedVideos: number;
  scrapeSkippedVideos: number;
  perSourceStats: SourceScanStat[];
  elapsedMs: number;
  videos: VideoFileInfo[];
}

export type ScanMode = 'incremental' | 'fix-missing' | 'overwrite';

export interface ScanContextInfo {
  sourceType: FileSourceType;
  sourceName: string;
  directoryPath: string;
  currentPath: string;
}

export type ScanProgressCallback = (completed: number, total: number, context?: ScanContextInfo) => void;

export interface ScanOptions {
  maxDepth: number;
  mode: ScanMode;
  onScanProgress?: ScanProgressCallback;
  onCurrentPath?: (currentPath: string) => void;
}

/** 扫描失败时的错误摘要信息，与 design D5 一致 */
export interface ErrorInfo {
  message: string;
  code?: string;
}

/** 扫描失败的单个目录及其失败上下文 */
export interface FailedDirectory {
  directoryPath: string;
  error: ErrorInfo;
}

/** 定向扫描结果：仅包含成功/失败的目录以及新增视频 id */
export interface DirectedScanResult {
  succeededDirectories: string[];
  failedDirectories: FailedDirectory[];
  newlyInsertedVideoIds: number[];
  totalFilesScanned: number;
}

export const DEFAULT_SCAN_OPTIONS: ScanOptions = { maxDepth: 5, mode: 'incremental', onCurrentPath: undefined };

// ─────────────────────────────────────────────
// 适配器接口
// ─────────────────────────────────────────────

export interface ISourceAdapter {
  scan(directoryPath: string, options: ScanOptions): Promise<VideoFileInfo[]>;
}

export interface VideoUpsertStrategy {
  upsert(entity: VideoEntity): Promise<number>;
}

export interface VideoUpsertWithResultProvider {
  upsertVideoWithResult(entity: VideoEntity): Promise<VideoUpsertResult>;
}
