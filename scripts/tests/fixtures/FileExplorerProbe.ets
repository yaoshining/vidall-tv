import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { KeyCode } from '@kit.InputKit';
import { FileThumbnailLease } from '../components/core/file/FileThumbnailLease';
import { FileExplorer } from '../components/core/file/FileExplorer';
import { FileExplorerEager } from '../components/core/file/FileExplorerEager';
import { FileExplorerController, FileExplorerResource } from '../components/core/file/FileExplorerController';
import { FileExplorerProbeMetrics as Metrics } from '../components/core/file/FileExplorerProbeMetrics';

@Entry
@ComponentV2
struct FileExplorerProbe {
  @Local controller: FileExplorerController = new FileExplorerController({ resources: [], currentPath: '/',
    onFolderChange: (path: string) => { this.directory(path); } });
  @Local eager: boolean = false;
  @Local visible: boolean = false;
  @Local status: string = '选择测试目录';
  @Local count: number = 100;
  @Local images: boolean = false;
  private imageLoaded: number = 0;
  private imageReleased: number = 0;
  private imagePending: number = 0;
  private imageFailed: number = 0;
  private imagePeak: number = 0;
  private imageSerial: number = 0;

  private async thumbnail(resource: FileExplorerResource): Promise<FileThumbnailLease> {
    const serial = ++this.imageSerial;
    this.imagePending++;
    this.imagePeak = Math.max(this.imagePeak, this.imagePending);
    const index = Number(resource.key.substring(resource.key.lastIndexOf('-') + 1));
    const path = this.getUIContext().getHostContext()!.tempDir + '/thumb-probe-' + util.generateRandomUUID(true) + '.svg';
    try {
      await new Promise<void>(resolve => { setTimeout(resolve, index % 5 === 2 ? 2500 : 100); });
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      try {
        fileIo.writeSync(file.fd, `<svg xmlns="http://www.w3.org/2000/svg" width="32" height="36"><rect width="32" height="36" fill="${index % 2 === 0 ? '#00ff00' : '#ff0000'}"/></svg>`);
      } finally { fileIo.closeSync(file); }
      if (index % 5 === 1) { this.imageFailed++; throw new Error('controlled failure'); }
      this.imageLoaded++;
      console.info(`[ExplorerImages] loaded serial=${serial} key=${resource.key}`);
      return new FileThumbnailLease('file://' + path, () => {
        fileIo.unlinkSync(path); this.imageReleased++;
        console.info(`[ExplorerImages] released serial=${serial} key=${resource.key}`);
      });
    } catch (error) {
      try { fileIo.unlinkSync(path); } catch {}
      throw new Error((error as Error).message);
    } finally { this.imagePending--; }
  }

  private keys(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) { return false; }
    if (event.keyCode === KeyCode.KEYCODE_F1) { this.controller.sortAscending = !this.controller.sortAscending; }
    else if (event.keyCode === KeyCode.KEYCODE_F2) { this.controller.showHiddenFiles = !this.controller.showHiddenFiles; }
    else if (event.keyCode === KeyCode.KEYCODE_F3) { Metrics.removeFocused(); }
    else if (event.keyCode === KeyCode.KEYCODE_F4) { Metrics.end(); }
    else if (event.keyCode === KeyCode.KEYCODE_F5) { this.controller.handleBack(); }
    else if (event.keyCode === KeyCode.KEYCODE_F6) { this.controller.resources = this.controller.resources.slice(); }
    else { return false; }
    return true;
  }
  private timer: number = -1;

  private resources(path: string, count: number): FileExplorerResource[] {
    const result: FileExplorerResource[] = [];
    for (let i = 0; i < count; i++) {
      result.push({key: path + 'item-' + i, path: path + 'item-' + i,
        name: `${i % 23 === 0 ? '.' : ''}文件${i.toString().padStart(5, '0')}-长文件名走马灯验证-012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789.${this.images ? 'svg' : 'mkv'}`,
        isDirectory: !this.images && i % 19 === 0, isHidden: i % 23 === 0, size: i * 1024, lastModifiedMs: i * 1000000, sourceType: 'smb'});
    }
    return result;
  }

  private directory(path: string): void {
    this.controller.currentPath = path;
    this.controller.resources = this.resources(path === '/' ? '/' : path + '/', this.count);
  }

  private start(count: number, eager: boolean, images: boolean = false): void {
    this.visible = false;
    if (this.timer !== -1) { clearInterval(this.timer); }
    setTimeout(() => {
      this.count = count; this.eager = eager; this.images = images;
      Metrics.reset(`${eager ? 'before' : 'after'}-${count}`);
      this.controller.currentPath = '/';
      this.controller.showHiddenFiles = true;
      this.controller.sortField = 'name'; this.controller.sortAscending = true;
      this.controller.resources = this.resources('/', count);
      this.visible = true;
      this.timer = setInterval(() => { this.status = Metrics.report() + ` images=${this.imageLoaded}/${this.imageReleased} pending=${this.imagePending} peak=${this.imagePeak} failed=${this.imageFailed} files=${fileIo.listFileSync(this.getUIContext().getHostContext()!.tempDir).filter((name: string) => name.startsWith('thumb-probe-')).length}`; console.info('[ExplorerProbe] ' + this.status); }, 1000);
    }, 100);
  }
  aboutToDisappear(): void { if (this.timer !== -1) { clearInterval(this.timer); } }

  build() {
    Column() {
      Row({space: 8}) {
        Button('前100').id('before100').onClick(() => this.start(100, true))
        Button('前1000').id('before1000').onClick(() => this.start(1000, true))
        Button('前10000').id('before10000').onClick(() => this.start(10000, true))
        Button('后100').id('after100').onClick(() => this.start(100, false))
        Button('后1000').id('after1000').onClick(() => this.start(1000, false))
        Button('后10000').id('after10000').onClick(() => this.start(10000, false))
        Button('刷新删项').id('delete').onClick(() => {
          this.controller.resources = this.controller.resources.filter((r: FileExplorerResource) => !r.key.endsWith('item-19'));
        })
      }.height(48)
      Button('图片100').id('images100').height(32).onClick(() => this.start(100, false, true))
      Text(this.status).id('probe-status').fontSize(16).fontColor(Color.White).height(24)
      if (this.visible) {
        if (this.eager) { FileExplorerEager({controller: this.controller}).layoutWeight(1) }
        else { FileExplorer({controller: this.controller, thumbnailLoader: (resource: FileExplorerResource) => this.thumbnail(resource)}).layoutWeight(1) }
      }
    }.width('100%').height('100%').backgroundColor('#191A1C').onKeyEvent((event: KeyEvent) => this.keys(event))
  }
}
