import { BusinessError } from '@kit.BasicServicesKit';
import { AutoScrapeTrigger } from './AutoScrapeTrigger';
import { ScrapeTaskStore } from './ScrapeTaskStore';
import { DirectedScanRetryContext, ScrapeTaskSnapshot } from './ScopedScrapeTypes';

/**
 * 自动目录扫描任务的专用重试执行器（D7）。
 * 与 ScrapeTaskQueue.retry() 的区别：扫描阶段失败任务的视频可能尚未入库，
 * 重试本质是"重新执行定向扫描 + 刮削"，因此复用 AutoScrapeTrigger 的完整编排
 * （入队 scanning 任务 → 定向扫描 → 按结果推进），而非仅以 preparing 重新入队。
 */
export class AutoScrapeRetryExecutor {
  private static instance: AutoScrapeRetryExecutor | null = null;

  static getInstance(): AutoScrapeRetryExecutor {
    if (AutoScrapeRetryExecutor.instance === null) {
      AutoScrapeRetryExecutor.instance = new AutoScrapeRetryExecutor();
    }
    return AutoScrapeRetryExecutor.instance;
  }

  /**
   * 对携带定向扫描重试上下文的失败/部分失败任务发起重试。
   * 全部失败（failedDirectoryPaths 覆盖 originalDirectoryPaths）时重扫全部原始目录；
   * 部分失败仅重扫失败目录（4.7），不扩大为全库扫描。
   * @returns 是否成功发起新的重试任务
   */
  async retry(taskId: string): Promise<boolean> {
    try {
      const task = this.findTask(taskId);
      if (task === undefined || (task.status !== 'failed' && task.status !== 'partial-failure')) {
        return false;
      }
      const result = task.result;
      const scanContext: DirectedScanRetryContext | undefined = result?.directedScanContext;
      if (scanContext === undefined) {
        return false;
      }
      const retryPaths = this.resolveRetryPaths(scanContext);
      if (retryPaths.length === 0) {
        return false;
      }
      const displayName = this.resolveDisplayName(task);
      await AutoScrapeTrigger.getInstance().startScanTask(scanContext.sourceId, retryPaths, displayName);
      return true;
    } catch (e) {
      const error = e as BusinessError;
      console.error(`[AutoScrapeRetryExecutor] 重试发起失败 taskId=${taskId}: ${error.message}`);
      return false;
    }
  }

  /** 全部失败时重扫全部原始目录；部分失败仅重扫失败目录。 */
  private resolveRetryPaths(scanContext: DirectedScanRetryContext): string[] {
    const allFailed = scanContext.failedDirectoryPaths.length >= scanContext.originalDirectoryPaths.length;
    const paths = allFailed ? scanContext.originalDirectoryPaths : scanContext.failedDirectoryPaths;
    return paths.slice();
  }

  private resolveDisplayName(task: ScrapeTaskSnapshot): string {
    const scope = task.request.scope;
    if (scope.kind === 'folder') {
      return scope.displayName;
    }
    return '新增目录刮削重试';
  }

  private findTask(taskId: string): ScrapeTaskSnapshot | undefined {
    const tasks = ScrapeTaskStore.getState().getTasks();
    return tasks.find((task: ScrapeTaskSnapshot): boolean => task.id === taskId);
  }
}
