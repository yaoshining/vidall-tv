import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ScrapeTaskQueue } from './ScrapeTaskQueue';
import { ScrapeTaskStore } from './ScrapeTaskStore';
import {
  DirectedScanRetryContext,
  FolderScrapeScope,
  ScrapeProgress,
  ScrapeScanContext,
  ScrapeTaskSnapshot,
  ScopedScrapeRequest,
  normalizeScrapeDirectoryPath
} from './ScopedScrapeTypes';
import { VideoScannerUtil } from '../../utils/VideoScannerUtil';
import { DirectedScanResult, ScanContextInfo, ScanOptions } from '../../utils/VideoScannerTypes';
import { FileSourceTypeLabels } from '../../db/models/FileSourceEntity';

/**
 * 目录保存自动刮削触发器：负责"定向扫描任务"的统一编排（D12）——
 * 入队 scanning 阶段任务 → 驱动 VideoScannerUtil.scanDirectories 定向扫描 →
 * 按扫描结果三路推进任务状态。AutoScrapeRetryExecutor 的重试复用本编排，
 * 保证扫描-入队-进度-完成逻辑单一来源。
 */
export class AutoScrapeTrigger {
  private static instance: AutoScrapeTrigger | null = null;

  static getInstance(): AutoScrapeTrigger {
    if (AutoScrapeTrigger.instance === null) {
      AutoScrapeTrigger.instance = new AutoScrapeTrigger();
    }
    return AutoScrapeTrigger.instance;
  }

  /** 由 UI 启动时注入（service 层无法直接获取 UIAbilityContext），与 ScrapeFailureLogStore 同一模式。 */
  private context: common.Context | null = null;

  setContext(context: common.Context): void {
    this.context = context;
  }

  /**
   * 启动一次定向扫描刮削任务。directoryPaths 为待扫描目录路径（内部做规范化）。
   * 编排全程不向上抛异常：失败以日志记录并推进任务到失败态（保存流程与之解耦）。
   */
  async startScanTask(sourceId: number, directoryPaths: string[], displayName: string): Promise<void> {
    const context = this.context;
    if (context === null) {
      console.warn('[AutoScrapeTrigger] context 未注入，跳过自动刮削任务');
      return;
    }
    if (directoryPaths.length === 0) {
      return;
    }
    const paths: string[] = [];
    for (const p of directoryPaths) {
      paths.push(normalizeScrapeDirectoryPath(p));
    }
    const queue = ScrapeTaskQueue.getInstance();
    const scope: FolderScrapeScope = {
      kind: 'folder',
      sourceId: sourceId,
      directoryPath: paths.join(','),
      displayName: displayName,
      autoTriggered: true
    };
    const request: ScopedScrapeRequest = {
      scope: scope,
      mode: 'incremental',
      candidateStrategy: 'automatic'
    };
    const taskId = queue.enqueue(request, { phase: 'scanning' });
    try {
      const scanOptions: Partial<ScanOptions> = {
        onScanProgress: (completed: number, total: number, scanContext?: ScanContextInfo): void => {
          this.handleScanProgress(taskId, completed, total, scanContext);
        }
      };
      const result: DirectedScanResult = await VideoScannerUtil.scanDirectories(context, sourceId, paths, scanOptions);
      this.handleScanComplete(taskId, sourceId, paths, result);
    } catch (e) {
      const error = e as BusinessError;
      console.error(`[AutoScrapeTrigger] 定向扫描异常 sourceId=${sourceId}: ${error.message}`);
      this.markScanError(taskId, sourceId, paths, error.message);
    }
  }

  /**
   * 扫描完成三路判定（D12）：
   * - 无失败：videoIds=本轮首次入库 ID → markTaskReady（零新增也走此路径，execute 解析零目标后自然 completed）
   * - 部分失败：存重试上下文 → videoIds=新增 ID → markTaskReady（刮削完成后由队列判定 partial-failure）
   * - 全部失败：存重试上下文 → markTaskFailed（保留专用重试入口）
   */
  private handleScanComplete(taskId: string, sourceId: number, scannedPaths: string[], result: DirectedScanResult): void {
    if (this.isTaskCancelled(taskId)) {
      // 已取消任务不再推进状态，后续扫描结果整体丢弃
      return;
    }
    const queue = ScrapeTaskQueue.getInstance();
    const failedPaths: string[] = [];
    for (const failed of result.failedDirectories) {
      failedPaths.push(failed.directoryPath);
    }
    if (failedPaths.length === 0) {
      queue.setScanVideoIds(taskId, result.newlyInsertedVideoIds);
      queue.markTaskReady(taskId);
      return;
    }
    const retryContext: DirectedScanRetryContext = {
      sourceId: sourceId,
      originalDirectoryPaths: scannedPaths.slice(),
      failedDirectoryPaths: failedPaths
    };
    if (result.succeededDirectories.length > 0) {
      queue.setScanVideoIds(taskId, result.newlyInsertedVideoIds);
      queue.markTaskReady(taskId, retryContext);
      return;
    }
    queue.markTaskFailed(taskId, retryContext);
  }

  /** 扫描 Promise 异常：全部目录按失败处理并写入重试上下文。 */
  private markScanError(taskId: string, sourceId: number, scannedPaths: string[], message: string): void {
    if (this.isTaskCancelled(taskId)) {
      return;
    }
    const retryContext: DirectedScanRetryContext = {
      sourceId: sourceId,
      originalDirectoryPaths: scannedPaths.slice(),
      failedDirectoryPaths: scannedPaths.slice()
    };
    console.error(`[AutoScrapeTrigger] 扫描整体失败 taskId=${taskId}: ${message}`);
    ScrapeTaskQueue.getInstance().markTaskFailed(taskId, retryContext);
  }

  private handleScanProgress(taskId: string, completed: number, total: number, scanContext?: ScanContextInfo): void {
    if (this.isTaskCancelled(taskId)) {
      // 已取消任务丢弃后续进度更新，也不再调用 markTaskReady
      return;
    }
    const progress: ScrapeProgress = {
      completed: completed,
      total: total,
      succeeded: 0,
      failed: 0,
      cancelled: 0
    };
    let mappedContext: ScrapeScanContext | undefined = undefined;
    if (scanContext !== undefined) {
      const ctx: ScrapeScanContext = {
        sourceTypeLabel: FileSourceTypeLabels.getLabel(scanContext.sourceType),
        sourceName: scanContext.sourceName,
        directoryPath: scanContext.directoryPath,
        currentPath: scanContext.currentPath
      };
      mappedContext = ctx;
    }
    ScrapeTaskQueue.getInstance().updateScanProgress(taskId, progress, mappedContext);
  }

  private isTaskCancelled(taskId: string): boolean {
    const tasks = ScrapeTaskStore.getState().getTasks();
    const found = tasks.find((task: ScrapeTaskSnapshot): boolean => task.id === taskId);
    return found !== undefined && found.status === 'cancelled';
  }
}
