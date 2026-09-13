/** loader 成功时移交独占资源；失败时 loader 负责删除未完成文件。 */
export class FileThumbnailLease {
  readonly source: string;
  private dispose: () => void;
  private released: boolean = false;

  constructor(source: string, dispose: () => void = () => {}) {
    this.source = source;
    this.dispose = dispose;
  }

  release(): void {
    if (this.released) { return; }
    this.released = true;
    this.dispose();
  }
}

/** 全应用最多四个在途缩略图，不缓存、不排队；迟到请求完成前仍占用名额。 */
export class FileThumbnailSlots {
  private static active: number = 0;
  static acquire(): boolean {
    if (FileThumbnailSlots.active >= 4) { return false; }
    FileThumbnailSlots.active++;
    return true;
  }
  static release(): void { FileThumbnailSlots.active--; }
}

/** 与 ArkUI 解耦的所有权状态机，代际失效不会释放其他组件持有的资源。 */
export class FileThumbnailSession {
  private generation: number = 0;
  private lease?: FileThumbnailLease;

  reset(): number {
    this.generation++;
    this.lease?.release();
    this.lease = undefined;
    return this.generation;
  }

  accept(generation: number, lease: FileThumbnailLease): boolean {
    if (generation !== this.generation) { lease.release(); return false; }
    this.lease?.release();
    this.lease = lease;
    return true;
  }
}
