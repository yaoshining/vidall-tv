import { Context } from '@ohos.abilityAccessCtrl';
import { FileSource, FileSourceDirectory, FileSourceType } from '../db/models/FileSourceEntity';
import { FileSourceDatabase } from '../db/files/FileSourceDatabase';
import { ScrapeClient } from '../lib/ScrapeClient';
import { MetricsService } from '../services/metrics/MetricsService';
import { UmamiAnalyticsService } from '../services/analytics/UmamiAnalyticsService';
import { UmamiEventData } from '../services/analytics/UmamiReporter';
import { ISourceAdapter, VideoFileInfo, SourceScanStat, ScanResult, ScanOptions, DEFAULT_SCAN_OPTIONS } from './VideoScannerTypes';
import { WebDAVAdapter } from './WebDAVAdapter';
import { SMBAdapter } from './SMBAdapter';

export type { ScanMode } from './VideoScannerTypes';

// ─────────────────────────────────────────────
// 不支持协议占位适配器
// ─────────────────────────────────────────────

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

// ─────────────────────────────────────────────
// 适配器工厂
// ─────────────────────────────────────────────

function createAdapter(fileSource: FileSource, scrapeClient?: ScrapeClient): ISourceAdapter {
  switch (fileSource.type) {
    case FileSourceType.WEBDAV:
      return new WebDAVAdapter(fileSource, scrapeClient);
    case FileSourceType.SMB:
      return new SMBAdapter(fileSource, scrapeClient);
    default:
      return new UnsupportedAdapter(fileSource.name, fileSource.type);
  }
}

// ─────────────────────────────────────────────
// 核心扫描工具类
// ─────────────────────────────────────────────

export class VideoScannerUtil {
  /**
   * 扫描所有已配置文件源中的视频文件
   * @param context       鸿蒙 Context
   * @param scrapeClient  刮削客户端（可选，不传则跳过刮削）
   * @param options       扫描选项（可选，默认 maxDepth=5）
   */
  static async scan(context: Context, scrapeClient?: ScrapeClient, options?: Partial<ScanOptions>): Promise<ScanResult> {
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

    // 全量覆盖模式：先清空所有源的 scrape_info，确保重刮前无历史垃圾数据
    // 同时记录哪些文件源参与了本次全量扫描（仅记录 sourceId，实际是否成功扫到由 seenPaths 决定）
    const overwriteSourceIds: number[] = [];
    if (scanOptions.mode === 'overwrite') {
      const sourceIds: number[] = [];
      for (const s of fileSources) {
        const sid = s.id;
        if (sid !== undefined && sid > 0) {
          sourceIds.push(sid);
        }
      }
      if (sourceIds.length > 0) {
        await db.clearScrapeInfoForSources(sourceIds);
        console.info(`[VideoScanner] 全量覆盖预清空完成，已清除 ${sourceIds.length} 个文件源的 scrape_info`);
        for (const sid of sourceIds) {
          overwriteSourceIds.push(sid);
        }
      }
    }

    // 成功扫描到至少一个文件的文件源 ID（用于鬼记录清理，避免扫描失败时误删全部记录）
    const successfullyScannedSourceIds = new Set<number>();

    const seenPaths = new Set<string>();
    const allVideos: VideoFileInfo[] = [];
    const perSourceStats: SourceScanStat[] = [];
    let totalDirectories = 0;

    for (const fileSource of fileSources) {
      if (!fileSource.id) {
        continue;
      }

      console.info(`[VideoScanner] ──── 文件源: "${fileSource.name}" (${fileSource.type}) ────`);

      let directories: FileSourceDirectory[] = [];
      try {
        directories = await db.getDirectoriesBySourceId(fileSource.id);
      } catch (err) {
        console.error(`[VideoScanner][ERROR] 读取文件源 "${fileSource.name}" 目录失败: ${JSON.stringify(err)}`);
        continue;
      }

      console.info(`[VideoScanner] 文件源 "${fileSource.name}" 配置了 ${directories.length} 个目录`);

      let adapter: ISourceAdapter;
      try {
        console.info(`[VideoScanner] 正在创建适配器，协议=${fileSource.type}`);
        adapter = createAdapter(fileSource, scrapeClient);
        console.info(`[VideoScanner] 适配器创建成功`);
      } catch (err) {
        console.error(`[VideoScanner][ERROR] 创建适配器失败: ${JSON.stringify(err)}`);
        continue;
      }

      const stat: SourceScanStat = {
        sourceId: fileSource.id,
        sourceName: fileSource.name,
        sourceType: fileSource.type,
        directoriesScanned: 0,
        videosFound: 0
      };

      for (const dir of directories) {
        totalDirectories++;
        stat.directoriesScanned++;
        console.info(`[VideoScanner] 准备扫描目录(${stat.directoriesScanned}/${directories.length}): ${dir.directoryPath}`);

        let found: VideoFileInfo[] = [];
        try {
          found = await adapter.scan(dir.directoryPath, scanOptions);
          console.info(`[VideoScanner] 目录 "${dir.directoryPath}" 扫描完毕，找到 ${found.length} 个视频`);
          // 扫描成功 → 目录状态恢复为 active
          if (dir.id !== undefined) {
            db.updateDirStatus(dir.id, 'active').catch(() => {});
          }
        } catch (err) {
          const errMsg = (err as Error).message ?? String(err);
          console.error(`[VideoScanner][ERROR] 扫描目录 "${dir.directoryPath}" 异常: ${errMsg}`);
          // 按错误类型写状态：404 → missing；其他（超时/401/网络）→ unreachable
          if (dir.id !== undefined) {
            const isMissing = errMsg.includes('HTTP 404') ||
              errMsg.toLowerCase().includes('not found') ||
              errMsg.includes('404');
            const newStatus = isMissing ? 'missing' : 'unreachable';
            db.updateDirStatus(dir.id, newStatus).catch(() => {});
            console.info(`[VideoScanner] 目录 "${dir.directoryPath}" 状态标记为: ${newStatus}`);
          }
          continue;
        }

        for (const video of found) {
          if (!seenPaths.has(video.filePath)) {
            seenPaths.add(video.filePath);
            allVideos.push(video);
            stat.videosFound++;
            // 标记该文件源已成功扫到文件（用于鬼记录清理保护）
            if (fileSource.id !== undefined) {
              successfullyScannedSourceIds.add(fileSource.id);
            }
          } else {
            console.info(`[VideoScanner] 重复路径，已跳过: ${video.filePath}`);
          }
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

    // 清理孤立 scrape_info（由历史 INSERT OR REPLACE upsertVideo 产生的无效引用）
    await FileSourceDatabase.getInstance().cleanupOrphanedScrapeInfo();

    // 全量覆盖模式：清理鬼记录（本轮未扫到、但仍留在 videos 表中的旧文件记录）
    // 仅清理成功扫描到文件的文件源，避免扫描失败时误删全部记录
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

    // Task 6.4: Record scan coverage at end of scan operation
    // Note: processedVideos represents files processed in this scan run (not total files with metadata).
    // In incremental scans this will be a subset of allVideos.length.
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
}
