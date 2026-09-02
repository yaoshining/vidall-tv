import { FileSourceType } from '../db/models/FileSourceEntity';

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

export type ScanProgressCallback = (completed: number, total: number) => void;

export interface ScanOptions {
  maxDepth: number;
  mode: ScanMode;
  onScanProgress?: ScanProgressCallback;
}

export const DEFAULT_SCAN_OPTIONS: ScanOptions = { maxDepth: 5, mode: 'incremental' };

// ─────────────────────────────────────────────
// 适配器接口
// ─────────────────────────────────────────────

export interface ISourceAdapter {
  scan(directoryPath: string, options: ScanOptions): Promise<VideoFileInfo[]>;
}
