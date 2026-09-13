import { FileExplorerResource } from './FileExplorerController';
import { FileThumbnailLease, FileThumbnailSession, FileThumbnailSlots } from './FileThumbnailLease';

@ComponentV2
export struct FileThumbnail {
  @Param @Require resource: FileExplorerResource;
  @Param loader: (resource: FileExplorerResource) => Promise<FileThumbnailLease> =
    () => Promise.resolve(new FileThumbnailLease(''));
  @Local private source: string = '';
  private requested: boolean = false;
  private visible: boolean = false;
  private active: boolean = false;
  private retryTimer: number = -1;
  private session: FileThumbnailSession = new FileThumbnailSession();

  aboutToAppear(): void { this.active = true; }

  aboutToDisappear(): void {
    this.active = false;
    this.visible = false;
    this.reset();
  }

  @Monitor('resource', 'loader')
  private resourceChanged(): void {
    this.reset();
    if (this.active && this.visible) { this.load(); }
  }

  private reset(): void {
    if (this.retryTimer !== -1) { clearTimeout(this.retryTimer); }
    this.retryTimer = -1;
    this.source = '';
    this.session.reset();
    this.requested = false;
  }

  private load(): void {
    if (!this.active || !this.visible || this.requested || !this.resource.size ||
      this.resource.size > 8 * 1024 * 1024) { return; }
    if (!FileThumbnailSlots.acquire()) {
      // 只有当前可见组件持有一个重试定时器；离屏立即移除，无待下载队列。
      if (this.retryTimer === -1) {
        this.retryTimer = setTimeout(() => { this.retryTimer = -1; this.load(); }, 120);
      }
      return;
    }
    this.requested = true;
    const generation = this.session.reset();
    this.download(generation);
  }

  private async download(generation: number): Promise<void> {
    try {
      const lease = await this.loader(this.resource);
      if (this.session.accept(generation, lease)) { this.source = lease.source; }
    } catch {
      // 失败仅保留图标。不能让旧请求的失败擦除后来成功的图片。
    } finally {
      FileThumbnailSlots.release();
    }
  }

  build() {
    Stack() {
      // 按 source 重建图片节点；旧节点迟到的解码错误不能清除新图片。
      ForEach([this.source], (source: string) => {
        Image(source || $r('app.media.explorer_image'))
          .width(32).height(36).objectFit(ImageFit.Cover).borderRadius(4)
          .onError(() => {
            if (this.source === source) { this.source = ''; this.session.reset(); }
          })
      }, (source: string) => source)
    }
      .width(32).height(36)
      .onVisibleAreaChange([0, 1], (visible: boolean, ratio: number) => {
        const next = visible && ratio > 0;
        if (this.visible === next) { return; }
        this.visible = next;
        if (next) { this.load(); } else { this.reset(); }
      })
  }
}
