import { ScrapeScope, ScrapeTaskSnapshot, ScrapeTaskStatus, scrapeScopeId } from './ScopedScrapeTypes';

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

  /**
   * 返回所有处于活跃状态（waiting / running / waiting-confirmation）的任务快照。
   * 用于下拉菜单「正在刮削」列表，排除已完成 / 成功 / 失败 / 取消等终态任务。
   * 元素为 @ObservedV2 实例，@Trace 字段变化可精准观测。
   */
  getActiveTasks(): ScrapeTaskSnapshot[] {
    return this.snapshots.filter((task: ScrapeTaskSnapshot): boolean =>
      task.status === 'waiting' || task.status === 'running' || task.status === 'waiting-confirmation'
    );
  }

  /**
   * 返回与指定 scope 指向同一刮削目标、且仍处于活跃状态
   * （waiting / running / waiting-confirmation）的任务快照。
   * 若不存在则返回 undefined。元素为 @ObservedV2 实例，@Trace 字段变化可精准观测。
   */
  getActiveForScope(scope: ScrapeScope): ScrapeTaskSnapshot | undefined {
    const id = scrapeScopeId(scope);
    return this.snapshots.find((task: ScrapeTaskSnapshot): boolean => {
      if (task.status !== 'waiting' && task.status !== 'running' &&
        task.status !== 'waiting-confirmation') {
        return false;
      }
      return scrapeScopeId(task.request.scope) === id;
    });
  }

  /** 返回该 scope 当前活跃任务的进度文案 "18/28"；无活跃任务返回空串。 */
  getProgressText(scope: ScrapeScope): string {
    const task = this.getActiveForScope(scope);
    if (task === undefined) {
      return '';
    }
    return `${task.progress.completed}/${task.progress.total}`;
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
