import { fileIo } from '@kit.CoreFileKit';
import { FileExplorerResource } from './FileExplorerController';

@ComponentV2
export struct FileThumbnail {
  @Param @Require resource: FileExplorerResource;
  @Param loader: (resource: FileExplorerResource) => Promise<string> = () => Promise.resolve('');
  @Local private source: string = '';
  private requested: boolean = false;
  private active: boolean = true;

  aboutToDisappear(): void {
    this.active = false;
    this.release(this.source);
  }

  private release(path: string): void {
    if (!path.startsWith('file://') || !path.includes('/thumb-')) { return; }
    fileIo.unlink(path.substring(7)).catch(() => {});
  }

  private load(): void {
    // 只下载可见的小图片；大图、未知大小或失败时使用图片图标。
    if (this.requested || !this.resource.size || this.resource.size > 8 * 1024 * 1024) { return; }
    this.requested = true;
    this.loader(this.resource).then((path: string) => {
      if (this.active) { this.source = path; }
      else { this.release(path); }
    }).catch(() => { this.source = ''; });
  }

  build() {
    Image(this.source || $r('app.media.explorer_image'))
      .width(32).height(36).objectFit(ImageFit.Cover).borderRadius(4)
      .onError(() => { this.release(this.source); this.source = ''; })
      .onVisibleAreaChange([0, 1], (visible: boolean) => { if (visible) { this.load(); } })
  }
}
