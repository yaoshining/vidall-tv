import { Context } from '@ohos.abilityAccessCtrl';
import { FileSource, FileSourceDirectory, FileSourceType } from '../db/models/FileSourceEntity';
import { FileSourceDatabase } from '../db/files/FileSourceDatabase';
import { ScrapeClient } from '../lib/ScrapeClient';
import { MetricsService } from '../services/metrics/MetricsService';
import { UmamiAnalyticsService } from '../services/analytics/UmamiAnalyticsService';
import { UmamiEventData } from '../services/analytics/UmamiReporter';
import { VideoEntity, VideoUpsertResult } from '../db/models/MediaEntity';
import { ISourceAdapter, VideoFileInfo, SourceScanStat, ScanResult, ScanOptions, ScanProgressCallback, ScanContextInfo, DEFAULT_SCAN_OPTIONS, DirectedScanResult, FailedDirectory, ErrorInfo, VideoUpsertStrategy, VideoUpsertWithResultProvider } from './VideoScannerTypes';
import { normalizeScrapeDirectoryPath } from '../services/scrape/ScopedScrapeTypes';
import { WebDAVAdapter } from './WebDAVAdapter';
import { SMBAdapter } from './SMBAdapter';

export type { ScanMode } from './VideoScannerTypes';
export type { VideoUpsertStrategy } from './VideoScannerTypes';
export type { VideoUpsertWithResultProvider } from './VideoScannerTypes';

function extractErrorMessage(e: Object): string {
  if (e instanceof Error) {
    return e.message;
  }
  return JSON.stringify(e);
}

export class UnsupportedAdapter implements ISourceAdapter {
  private sourceType: FileSourceType;
  private sourceName: string;

  constructor(sourceName: string, sourceType: FileSourceType) {
    this.sourceName = sourceName;
    this.sourceType = sourceType;
  }

  async scan(directoryPath: string, _options: ScanOptions): Promise<VideoFileInfo[]> {
    console.warn(
      `[VideoScanner][SKIP] 协议 "${this.sourceType}" 暂不支持，` +
      `文件源="${this.sourceName}"，目录="${directoryPath}"，跳过。`
    );
    return [];
  }
}

function createAdapter(fileSource: FileSource, scrapeClient?: ScrapeClient, upsertStrategy?: VideoUpsertStrategy): ISourceAdapter {
  switch (fileSource.type) {
    case FileSourceType.WEBDAV:
      return new WebDAVAdapter(fileSource, scrapeClient, upsertStrategy);
    case FileSourceType.SMB:
      return new SMBAdapter(fileSource, scrapeClient, upsertStrategy);
    default:
      return new UnsupportedAdapter(fileSource.name, fileSource.type);
  }
}

interface SourceScanEntry {
  source: FileSource;
  directories: FileSourceDirectory[];
  adapter: ISourceAdapter;
}

class DatabaseUpsertProvider implements VideoUpsertWithResultProvider {
  private db: FileSourceDatabase;

  constructor(db: FileSourceDatabase) {
    this.db = db;
  }

  async upsertVideoWithResult(entity: VideoEntity): Promise<VideoUpsertResult> {
    return this.db.upsertVideoWithResult(entity);
  }
}

export class DirectedUpsertStrategy implements VideoUpsertStrategy {
  private provider: VideoUpsertWithResultProvider;
  private processedFiles: Map<string, number> = new Map<string, number>();
  private _newlyInsertedVideoIds: number[] = [];
  private _currentDirHasError: boolean = false;
  private _currentDirFirstError: ErrorInfo | null = null;

  constructor(provider: VideoUpsertWithResultProvider) {
    this.provider = provider;
  }

  beginDirectory(): void {
    this._currentDirHasError = false;
    this._currentDirFirstError = null;
  }

  async upsert(entity: VideoEntity): Promise<number> {
    const existingId: number | undefined = this.processedFiles.get(entity.filePath);
    if (existingId !== undefined) {
      return existingId;
    }
    try {
      const result: VideoUpsertResult = await this.provider.upsertVideoWithResult(entity);
      this.processedFiles.set(entity.filePath, result.id);
      if (result.wasNewlyInserted) {
        this._newlyInsertedVideoIds.push(result.id);
      }
      return result.id;
    } catch (e) {
      if (!this._currentDirHasError) {
        this._currentDirFirstError = { message: extractErrorMessage(e) };
      }
      this._currentDirHasError = true;
      throw new Error(extractErrorMessage(e));
    }
  }

  hasDirectoryUpsertError(): boolean {
    return this._currentDirHasError;
  }

  getDirectoryFirstError(): ErrorInfo {
    return this._currentDirFirstError ?? { message: 'DB upsert failed' };
  }

  getNewlyInsertedVideoIds(): number[] {
    return this._newlyInsertedVideoIds;
  }
}

export interface DirectedAdapterBundle {
  readonly adapter: ISourceAdapter;
  readonly strategy: DirectedUpsertStrategy;
}

export interface ScanDirectoriesDeps {
  init(): Promise<void>;
  getFileSourceById(sourceId: number): Promise<FileSource | null>;
  createDirectedAdapter(fileSource: FileSource): DirectedAdapterBundle | null;
}

class ProductionScanDirectoriesDeps implements ScanDirectoriesDeps {
  private db: FileSourceDatabase;

  constructor(context: Context) {
    this.db = FileSourceDatabase.getInstance(context);
  }

  async init(): Promise<void> {
    await this.db.init();
  }

  async getFileSourceById(sourceId: number): Promise<FileSource | null> {
    return this.db.getFileSourceById(sourceId);
  }

  createDirectedAdapter(fileSource: FileSource): DirectedAdapterBundle | null {
    if (fileSource.type !== FileSourceType.WEBDAV && fileSource.type !== FileSourceType.SMB) {
      return null;
    }
    const provider: DatabaseUpsertProvider = new DatabaseUpsertProvider(this.db);
    const strategy: DirectedUpsertStrategy = new DirectedUpsertStrategy(provider);
    const adapter: ISourceAdapter = createAdapter(fileSource, undefined, strategy);
    const bundle: DirectedAdapterBundle = { adapter: adapter, strategy: strategy };
    return bundle;
  }
}

function makeAllFailedResult(directoryPaths: string[], errorMessage: string): DirectedScanResult {
  const failedDirectories: FailedDirectory[] = [];
  for (const dirPath of directoryPaths) {
    const normalizedPath = normalizeScrapeDirectoryPath(dirPath);
    const failed: FailedDirectory = { directoryPath: normalizedPath, error: { message: errorMessage } };
    failedDirectories.push(failed);
  }
  const result: DirectedScanResult = {
    succeededDirectories: [],
    failedDirectories: failedDirectories,
    newlyInsertedVideoIds: [],
    totalFilesScanned: 0
  };
  return result;
}

export class VideoScannerUtil {
  static async scan(context: Context, scrapeClient?: ScrapeClient, options?: Partial<ScanOptions>): Promise<ScanResult> {
    const onScanProgress: ScanProgressCallback | undefined = options?.onScanProgress;
    const scanOptions: ScanOptions = {
      maxDepth: (options?.maxDepth !== undefined) ? options.maxDepth : DEFAULT_SCAN_OPTIONS.maxDepth,
      mode: (options?.mode !== undefined) ? options.mode : DEFAULT_SCAN_OPTIONS.mode
    };

    const startTime = Date.now();
    console.info(`[VideoScanner] ======== 开始视频扫描 ========`);
    console.info(
      `[VideoScanner] 扫描参数: maxDepth=${scanOptions.maxDepth}, mode=${scanOptions.mode}, 刮削=${scrapeClient ? '开启' : '关闭'}`
    );

    const db = FileSourceDatabase.getInstance(context);
    await db.init();
    await db.resetVideoUpdatedFlags();

    const fileSources = await db.getAllFileSources();
    console.info(`[VideoScanner] 共找到 ${fileSources.length} 个文件源`);

    const overwriteSourceIds: number[] = [];
    if (scanOptions.mode === 'overwrite') {
      for (const source of fileSources) {
        const sourceId = source.id;
        if (sourceId !== undefined && sourceId > 0) {
          overwriteSourceIds.push(sourceId);
        }
      }
    }

    const successfullyScannedSourceIds = new Set<number>();

    const seenPaths = new Set<string>();
    const allVideos: VideoFileInfo[] = [];
    const perSourceStats: SourceScanStat[] = [];

    const sourceEntries: SourceScanEntry[] = [];
    for (const fileSource of fileSources) {
      if (!fileSource.id) {
        continue;
      }
      let directories: FileSourceDirectory[] = [];
      try {
        directories = await db.getDirectoriesBySourceId(fileSource.id);
      } catch (err) {
        console.error(`[VideoScanner][ERROR] 读取文件源 "${fileSource.name}" 目录失败: ${JSON.stringify(err)}`);
        continue;
      }
      let adapter: ISourceAdapter;
      try {
        adapter = createAdapter(fileSource, scrapeClient);
      } catch (err) {
        console.error(`[VideoScanner][ERROR] 创建适配器失败: ${JSON.stringify(err)}`);
        continue;
      }
      const entry: SourceScanEntry = {
        source: fileSource,
        directories,
        adapter
      };
      sourceEntries.push(entry);
    }

    let totalDirectories = 0;
    for (const entry of sourceEntries) {
      totalDirectories += entry.directories.length;
    }
    if (onScanProgress !== undefined) {
      onScanProgress(0, totalDirectories);
    }
    let completedDirectories = 0;

    for (const entry of sourceEntries) {
      const fileSource = entry.source;
      console.info(`[VideoScanner] ──── 文件源: "${fileSource.name}" (${fileSource.type}) ────`);
      console.info(`[VideoScanner] 文件源 "${fileSource.name}" 配置了 ${entry.directories.length} 个目录`);

      const stat: SourceScanStat = {
        sourceId: fileSource.id!,
        sourceName: fileSource.name,
        sourceType: fileSource.type,
        directoriesScanned: 0,
        videosFound: 0
      };

      for (const dir of entry.directories) {
        stat.directoriesScanned++;
        console.info(`[VideoScanner] 准备扫描目录(${stat.directoriesScanned}/${entry.directories.length}): ${dir.directoryPath}`);

        const dirContext: ScanContextInfo = {
          sourceType: fileSource.type,
          sourceName: fileSource.name,
          directoryPath: dir.directoryPath,
          currentPath: dir.directoryPath
        };
        if (onScanProgress !== undefined) {
          onScanProgress(completedDirectories, totalDirectories, dirContext);
        }

        const dirScanOptions: ScanOptions = {
          maxDepth: scanOptions.maxDepth,
          mode: scanOptions.mode,
          onCurrentPath: onScanProgress !== undefined
            ? (currentPath: string): void => {
                const newContext: ScanContextInfo = {
                  sourceType: fileSource.type,
                  sourceName: fileSource.name,
                  directoryPath: dir.directoryPath,
                  currentPath: currentPath
                };
                onScanProgress(completedDirectories, totalDirectories, newContext);
              }
            : undefined
        };

        let found: VideoFileInfo[] = [];
        try {
          found = await entry.adapter.scan(dir.directoryPath, dirScanOptions);
          console.info(`[VideoScanner] 目录 "${dir.directoryPath}" 扫描完毕，找到 ${found.length} 个视频`);
          if (dir.id !== undefined) {
            db.updateDirStatus(dir.id, 'active').catch(() => {});
          }
        } catch (err) {
          const errMsg = (err as Error).message ?? String(err);
          console.error(`[VideoScanner][ERROR] 扫描目录 "${dir.directoryPath}" 异常: ${errMsg}`);
          if (dir.id !== undefined) {
            const isMissing = errMsg.includes('HTTP 404') ||
              errMsg.toLowerCase().includes('not found') ||
              errMsg.includes('404');
            const newStatus = isMissing ? 'missing' : 'unreachable';
            db.updateDirStatus(dir.id, newStatus).catch(() => {});
            console.info(`[VideoScanner] 目录 "${dir.directoryPath}" 状态标记为: ${newStatus}`);
          }
          completedDirectories++;
          if (onScanProgress !== undefined) {
            onScanProgress(completedDirectories, totalDirectories);
          }
          continue;
        }

        for (const video of found) {
          if (!seenPaths.has(video.filePath)) {
            seenPaths.add(video.filePath);
            allVideos.push(video);
            stat.videosFound++;
            if (fileSource.id !== undefined) {
              successfullyScannedSourceIds.add(fileSource.id);
            }
          } else {
            console.info(`[VideoScanner] 重复路径，已跳过: ${video.filePath}`);
          }
        }
        completedDirectories++;
        if (onScanProgress !== undefined) {
          onScanProgress(completedDirectories, totalDirectories);
        }
      }

      perSourceStats.push(stat);
      console.info(`[VideoScanner] 文件源 "${fileSource.name}" 完成，视频=${stat.videosFound} 目录=${stat.directoriesScanned}`);
    }

    const elapsedMs = Date.now() - startTime;
    const processedVideos = allVideos.filter((video: VideoFileInfo) => video.wasProcessed !== false).length;
    const skippedVideos = allVideos.length - processedVideos;
    const scrapeSkippedVideos = allVideos.filter((video: VideoFileInfo) => video.scrapeSkipped === true).length;
    console.info(`[VideoScanner] ======== 扫描完成 ========`);
    console.info(`[VideoScanner][STATS] 总耗时: ${elapsedMs} ms`);
    console.info(`[VideoScanner][STATS] 扫描目录总数: ${totalDirectories}`);
    console.info(`[VideoScanner][STATS] 发现视频总数（去重后）: ${allVideos.length}`);
    console.info(`[VideoScanner][STATS] 本轮处理视频数: ${processedVideos}`);
    console.info(`[VideoScanner][STATS] 本轮跳过未变化视频数: ${skippedVideos}`);
    console.info(`[VideoScanner][STATS] 本轮跳过刮削（元数据完整）: ${scrapeSkippedVideos}`);
    for (const stat of perSourceStats) {
      console.info(
        `[VideoScanner][STATS] 文件源="${stat.sourceName}" (${stat.sourceType}) | ` +
        `目录数=${stat.directoriesScanned} | 视频数=${stat.videosFound}`
      );
    }
    console.info(`[VideoScanner] ===========================`);

    await FileSourceDatabase.getInstance().cleanupOrphanedScrapeInfo();

    if (scanOptions.mode === 'overwrite' && overwriteSourceIds.length > 0) {
      const safeSourceIds = overwriteSourceIds.filter(sid => successfullyScannedSourceIds.has(sid));
      if (safeSourceIds.length > 0) {
        const foundPaths = Array.from(seenPaths);
        await db.deleteGhostVideosForSources(safeSourceIds, foundPaths);
        console.info(`[VideoScanner] 鬼记录清理完成，有效文件源=${safeSourceIds.length} 个，有效路径=${foundPaths.length} 个`);
      } else {
        console.warn(`[VideoScanner] 鬼记录清理跳过：所有文件源均未成功扫到文件`);
      }
    }

    if (MetricsService.isInitialized()) {
      MetricsService.getInstance().recordScanCoverage(processedVideos, allVideos.length);
    }

    if (UmamiAnalyticsService.isInitialized()) {
      const scanData: UmamiEventData = { total_files: allVideos.length, duration_ms: elapsedMs };
      UmamiAnalyticsService.getInstance().trackEvent('scanner', 'scan_completed', scanData);
    }

    return {
      totalDirectories,
      totalVideos: allVideos.length,
      processedVideos,
      skippedVideos,
      scrapeSkippedVideos,
      perSourceStats,
      elapsedMs,
      videos: allVideos
    };
  }

  static async scanDirectories(
    context: Context,
    sourceId: number,
    directoryPaths: string[],
    options?: Partial<ScanOptions>
  ): Promise<DirectedScanResult> {
    const deps: ScanDirectoriesDeps = new ProductionScanDirectoriesDeps(context);
    return VideoScannerUtil.scanDirectoriesWithDeps(deps, sourceId, directoryPaths, options);
  }

  static async scanDirectoriesWithDeps(
    deps: ScanDirectoriesDeps,
    sourceId: number,
    directoryPaths: string[],
    options?: Partial<ScanOptions>
  ): Promise<DirectedScanResult> {
    const onScanProgress: ScanProgressCallback | undefined = options?.onScanProgress;
    const scanOptions: ScanOptions = {
      maxDepth: (options?.maxDepth !== undefined) ? options.maxDepth : DEFAULT_SCAN_OPTIONS.maxDepth,
      mode: (options?.mode !== undefined) ? options.mode : DEFAULT_SCAN_OPTIONS.mode,
      onScanProgress: onScanProgress,
      onCurrentPath: options?.onCurrentPath
    };

    const succeededDirectories: string[] = [];
    const failedDirectories: FailedDirectory[] = [];
    let totalFilesScanned: number = 0;

    try {
      await deps.init();
    } catch (e) {
      return makeAllFailedResult(directoryPaths, `DB init failed: ${extractErrorMessage(e)}`);
    }

    let fileSource: FileSource | null = null;
    try {
      fileSource = await deps.getFileSourceById(sourceId);
    } catch (e) {
      return makeAllFailedResult(directoryPaths, `Failed to load file source id=${sourceId}: ${extractErrorMessage(e)}`);
    }

    if (fileSource === null) {
      return makeAllFailedResult(directoryPaths, `File source not found: id=${sourceId}`);
    }

    let bundle: DirectedAdapterBundle | null = null;
    try {
      bundle = deps.createDirectedAdapter(fileSource);
    } catch (e) {
      return makeAllFailedResult(directoryPaths, `Failed to create adapter for source id=${sourceId}: ${extractErrorMessage(e)}`);
    }

    if (bundle === null) {
      return makeAllFailedResult(directoryPaths, `Source type "${fileSource.type}" is not supported for directed scan`);
    }

    const adapter: ISourceAdapter = bundle.adapter;
    const strategy: DirectedUpsertStrategy = bundle.strategy;

    const sourceType: FileSourceType = fileSource.type;
    const sourceName: string = fileSource.name;

    const totalDirs: number = directoryPaths.length;
    let completedDirs: number = 0;

    if (onScanProgress !== undefined) {
      onScanProgress(0, totalDirs);
    }

    for (const dirPath of directoryPaths) {
      const normalizedPath = normalizeScrapeDirectoryPath(dirPath);

      const dirContext: ScanContextInfo = {
        sourceType: sourceType,
        sourceName: sourceName,
        directoryPath: dirPath,
        currentPath: dirPath
      };
      if (onScanProgress !== undefined) {
        onScanProgress(completedDirs, totalDirs, dirContext);
      }

      const dirScanOptions: ScanOptions = {
        maxDepth: scanOptions.maxDepth,
        mode: scanOptions.mode,
        onCurrentPath: onScanProgress !== undefined
          ? (currentPath: string): void => {
              const newContext: ScanContextInfo = {
                sourceType: sourceType,
                sourceName: sourceName,
                directoryPath: dirPath,
                currentPath: currentPath
              };
              onScanProgress(completedDirs, totalDirs, newContext);
            }
          : undefined
      };

      strategy.beginDirectory();
      try {
        const found: VideoFileInfo[] = await adapter.scan(dirPath, dirScanOptions);
        totalFilesScanned += found.length;

        if (strategy.hasDirectoryUpsertError()) {
          const error: ErrorInfo = strategy.getDirectoryFirstError();
          const failed: FailedDirectory = { directoryPath: normalizedPath, error: error };
          failedDirectories.push(failed);
          console.error(`[VideoScanner][scanDirectories] Directory "${normalizedPath}" had upsert errors, marking as failed`);
        } else {
          succeededDirectories.push(normalizedPath);
        }
      } catch (e) {
        const errInfo: ErrorInfo = { message: extractErrorMessage(e) };
        const failed: FailedDirectory = { directoryPath: normalizedPath, error: errInfo };
        failedDirectories.push(failed);
        console.error(`[VideoScanner][scanDirectories] Directory scan failed: "${normalizedPath}" - ${errInfo.message}`);
      }

      completedDirs++;
      if (onScanProgress !== undefined) {
        onScanProgress(completedDirs, totalDirs);
      }
    }

    const newlyInsertedVideoIds: number[] = strategy.getNewlyInsertedVideoIds();

    console.info(
      `[VideoScanner][scanDirectories] Completed: succeeded=${succeededDirectories.length}, ` +
      `failed=${failedDirectories.length}, newlyInserted=${newlyInsertedVideoIds.length}, ` +
      `totalFilesScanned=${totalFilesScanned}`
    );

    const result: DirectedScanResult = {
      succeededDirectories,
      failedDirectories,
      newlyInsertedVideoIds,
      totalFilesScanned
    };
    return result;
  }
}
