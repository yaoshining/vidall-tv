/** Source-independent request lifecycle. Invalidate at intent time, before debounce. */
@ObservedV2
export class SearchSession<T> {
  @Trace results: T[] = [];
  @Trace status: string = 'idle';
  private generation: number = 0;
  private timeout: number = -1;

  invalidate(clear: boolean = false): void {
    this.generation++;
    if (this.timeout !== -1) { clearTimeout(this.timeout); this.timeout = -1; }
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
    this.timeout = setTimeout(() => {
      if (generation !== this.generation) { return; }
      this.generation++;
      this.timeout = -1;
      this.status = 'error';
    }, timeoutMs);
    try {
      const items = await loader();
      if (generation !== this.generation) { return false; }
      this.results = items;
      this.status = items.length > 0 ? 'results' : 'empty';
      return true;
    } catch {
      if (generation !== this.generation) { return false; }
      // Never render provider errors: they may contain credentials or private URLs.
      this.status = 'error';
      return false;
    } finally {
      if (generation === this.generation && this.timeout !== -1) {
        clearTimeout(this.timeout);
        this.timeout = -1;
      }
    }
  }
}
