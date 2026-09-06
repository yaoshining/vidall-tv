/** 与数据源无关的请求生命周期；输入意图变化时立即失效，不等待防抖。 */
@ObservedV2
export class SearchSession<T> {
  @Trace results: T[] = [];
  @Trace status: string = 'idle';
  private generation: number = 0;
  private timeout: number = -1;
  private pendingResolve: ((accepted: boolean) => void) | undefined = undefined;

  invalidate(clear: boolean = false): void {
    this.generation++;
    this.finish(false);
    if (clear) { this.results = []; }
    this.status = this.results.length > 0 ? 'results' : 'idle';
  }

  prepare(clear: boolean = false): void {
    this.invalidate(clear);
    this.status = this.results.length > 0 ? 'refreshing' : 'loading';
  }

  async run(loader: () => Promise<T[]>, timeoutMs: number = 15000): Promise<boolean> {
    this.prepare();
    const generation = this.generation;
    return new Promise<boolean>((resolve) => {
      this.pendingResolve = resolve;
      this.timeout = setTimeout(() => {
        if (generation !== this.generation) { return; }
        this.generation++;
        this.status = 'error';
        this.finish(false);
      }, timeoutMs);
      this.load(loader, generation);
    });
  }

  private finish(accepted: boolean): void {
    if (this.timeout !== -1) { clearTimeout(this.timeout); this.timeout = -1; }
    const resolve = this.pendingResolve;
    this.pendingResolve = undefined;
    if (resolve) { resolve(accepted); }
  }

  private async load(loader: () => Promise<T[]>, generation: number): Promise<void> {
    try {
      const items = await loader();
      if (generation !== this.generation) { return; }
      this.results = items;
      this.status = items.length > 0 ? 'results' : 'empty';
      this.finish(true);
    } catch {
      if (generation !== this.generation) { return; }
      // 不展示数据源异常原文，避免泄露凭据或私有地址；迟到异常也在此消费。
      this.status = 'error';
      this.finish(false);
    }
  }
}
