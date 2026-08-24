import { ScrapeTaskSnapshot, ScrapeTaskStatus } from './ScopedScrapeTypes';

function taskPriority(status: ScrapeTaskStatus): number {
  if (status === 'running' || status === 'waiting-confirmation') {
    return 0;
  }
  if (status === 'waiting') {
    return 1;
  }
  if (status === 'failed' || status === 'partial-failure') {
    return 2;
  }
  return 3;
}

@ObservedV2
export class ScrapeTaskStore {
  private static instance: ScrapeTaskStore | null = null;

  static getState(): ScrapeTaskStore {
    if (ScrapeTaskStore.instance === null) {
      ScrapeTaskStore.instance = new ScrapeTaskStore();
    }
    return ScrapeTaskStore.instance;
  }

  @Trace private snapshots: ScrapeTaskSnapshot[] = [];

  /**
   * 返回浅拷贝数组，但保留元素引用。元素为 @ObservedV2 实例，
   * 其 @Trace 字段（progress/status/...）变化时 UI 可精准刷新，不被深拷贝截断响应链。
   */
  getTasks(): ScrapeTaskSnapshot[] {
    return this.snapshots.slice();
  }

  getActiveCount(): number {
    return this.snapshots.filter((task: ScrapeTaskSnapshot): boolean =>
      task.status === 'waiting' || task.status === 'running'
    ).length;
  }

  update(tasks: ScrapeTaskSnapshot[]): void {
    const sorted = tasks.slice();
    // 稳定排序：仅状态优先级分组，组内按创建时间升序。不随进度/updatedAt 变化，避免顺序跳变导致闪烁。
    sorted.sort((left: ScrapeTaskSnapshot, right: ScrapeTaskSnapshot): number => {
      const priorityDiff = taskPriority(left.status) - taskPriority(right.status);
      return priorityDiff !== 0 ? priorityDiff : left.createdAt - right.createdAt;
    });
    this.snapshots = sorted;
  }
}
