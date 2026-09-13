import { util } from '@kit.ArkTS';
import { KeyCode } from '@kit.InputKit';
import { FileThumbnailLease } from './FileThumbnailLease';
import { FileExplorerToast, FileExplorerToastState } from './FileExplorerToast';
import { FileThumbnail } from './FileThumbnail';
import { FileExplorerController, FileExplorerPathItem, FileExplorerResource } from "./FileExplorerController";

/**
 * 文件点击事件数据
 */
export interface FileClickEvent {
  resource: FileExplorerResource;
  fullPath: string;
}

interface ColorsInterface {
  background: string;
  surface: string;
  surfaceVariant: string;
  primaryText: string;
  secondaryText: string;
  tertiaryText: string;
  accent: string;
  divider: string;
  hover: string;
  button: string;
}

@ComponentV2
export struct FileExplorer {
  @Param @Require controller: FileExplorerController
  @Param thumbnailLoader: (resource: FileExplorerResource) => Promise<FileThumbnailLease> = () => Promise.resolve(new FileThumbnailLease(''))
  @Param toastState: FileExplorerToastState = new FileExplorerToastState()
  @Param isLoading: boolean = false
  @Param errorMessage: string = ''
  @Param emptyText: string = '此文件夹为空'
  @Param showDetailColumns: boolean = true
  @Param disableResourceClick: (resource: FileExplorerResource) => boolean = () => false
  @Param resourceSecondaryText: (resource: FileExplorerResource) => string = () => ''
  @Param showResourceSelection: (resource: FileExplorerResource) => boolean = () => false
  @Param isResourceSelected: (resource: FileExplorerResource) => boolean = () => false
  @Param onResourceSelectionToggle: (resource: FileExplorerResource) => void = () => {}
  @Event onFileClick: (event: FileClickEvent) => void = () => {};
  @BuilderParam toolbarActionsBuilder?: () => void
  @BuilderParam extraTopBuilder?: () => void
  @BuilderParam extraBottomBuilder?: () => void
  @BuilderParam overlayBuilder?: () => void

  @Local focusedKey: string = ''
  @Local hoveredKey: string = ''
  @Local focusedControl: string = ''


  private readonly focusPrefix: string = util.generateRandomUUID(true);
  private scroller: Scroller = new Scroller();
  private anchorKey: string = '';
  private anchorIndex: number = 0;
  private directory: string = '';
  private pendingKey: string = '';
  private focusTimer: number = -1;
  private focusAttempts: number = 0;

  private rowId(key: string): string { return 'explorer-row:' + this.focusPrefix + ':' + key; }

  private controlId(key: string): string { return 'explorer-' + this.focusPrefix + ':' + key; }

  aboutToAppear(): void { this.directory = this.controller.currentPath; }
  aboutToDisappear(): void { this.cancelFocus(); }

  private cancelFocus(): void {
    if (this.focusTimer !== -1) { clearTimeout(this.focusTimer); }
    this.focusTimer = -1;
    this.pendingKey = '';
  }

  private requestRow(index: number): void {
    const resource = this.controller.sortedResources[index];
    if (!resource) { return; }
    this.cancelFocus();
    this.anchorKey = resource.key;
    this.anchorIndex = index;
    this.pendingKey = resource.key;
    this.focusAttempts = 0;
    this.scroller.scrollToIndex(index, false, ScrollAlign.AUTO);
    this.finishFocus();
  }

  private finishFocus(): void {
    if (!this.pendingKey || this.focusTimer !== -1) { return; }
    // 布局完成后按 key 请求；长按只保留最新目标，绝不积累焦点队列。
    this.focusTimer = setTimeout(() => {
      this.focusTimer = -1;
      if (!this.pendingKey) { return; }
      try {
        this.getUIContext().getFocusController().requestFocus(this.rowId(this.pendingKey));
        this.pendingKey = '';
      } catch {
        if (++this.focusAttempts < 8) { this.finishFocus(); }
        // 保留唯一目标，较慢设备后续 onScrollIndex 到达时仍可恢复；不无限轮询。
      }
    }, 16);
  }

  private navigate(event: KeyEvent): boolean {
    this.hoveredKey = '';
    if (event.type !== KeyType.Down ||
      (event.keyCode !== KeyCode.KEYCODE_DPAD_DOWN && event.keyCode !== KeyCode.KEYCODE_DPAD_UP)) { return false; }
    const resources = this.controller.sortedResources;
    const delta = event.keyCode === KeyCode.KEYCODE_DPAD_DOWN ? 1 : -1;
    let index = resources.findIndex((item: FileExplorerResource) => item.key === (this.pendingKey || this.focusedKey));
    if (index < 0) { index = this.anchorIndex; }
    for (index += delta; index >= 0 && index < resources.length; index += delta) {
      if (!this.disableResourceClick(resources[index])) { this.requestRow(index); return true; }
    }
    // 向上允许回到工具栏；末尾向下保持最后一个条目。
    return delta > 0;
  }

  @Monitor('controller.sortedResources', 'controller.currentPath')
  private reconcileFocus(): void {
    const resources = this.controller.sortedResources;
    const oldDirectory = this.directory;
    const changedDirectory = oldDirectory !== this.controller.currentPath;
    const restore = changedDirectory || this.focusedKey.length > 0 || this.pendingKey.length > 0;
    this.directory = this.controller.currentPath;
    this.hoveredKey = '';
    this.cancelFocus();
    if (!restore) { return; }
    let index = changedDirectory
      ? resources.findIndex((item: FileExplorerResource) => item.path === oldDirectory)
      : resources.findIndex((item: FileExplorerResource) => item.key === this.anchorKey);
    if (index < 0) { index = changedDirectory ? 0 : Math.min(this.anchorIndex, resources.length - 1); }
    while (index < resources.length && index >= 0 && this.disableResourceClick(resources[index])) { index++; }
    if (index >= resources.length) {
      index = resources.length - 1;
      while (index >= 0 && this.disableResourceClick(resources[index])) { index--; }
    }
    if (index >= 0) { this.requestRow(index); }
    else { this.focusedKey = ''; this.getUIContext().getFocusController().requestFocus(this.controlId('back')); }
  }

  private readonly COLORS: ColorsInterface = {
    background: '#191A1C', surface: '#303133', surfaceVariant: '#303133',
    primaryText: '#F0F2F5', secondaryText: '#ADB3BC', tertiaryText: '#ADB3BC',
    accent: '#307BF6', divider: '#35383D', hover: '#202F46', button: '#303133'
  };

  private changeSortField(field: 'name' | 'size' | 'date'): void {
    if (this.controller.sortField === field) {
      this.controller.sortAscending = !this.controller.sortAscending;
    } else {
      this.controller.sortField = field;
      this.controller.sortAscending = true;
    }
  }

  private getSortIcon(field: 'name' | 'size' | 'date'): string {
    if (this.controller.sortField !== field) {
      return '';
    }
    return this.controller.sortAscending ? '↑' : '↓';
  }

  private handleResourceClick(resource: FileExplorerResource): void {
    if (this.disableResourceClick(resource)) {
      return;
    }

    if (resource.isDirectory) {
      this.controller.onFolderChange(resource.path);
    } else {
      this.onFileClick({
        resource: resource,
        fullPath: resource.path
      });
    }
  }

  private handlePathClick(path: string): void {
    if (path !== this.controller.currentPath) {
      this.controller.onFolderChange(path);
    }
  }

  private formatFileSize(bytes?: number): string {
    if (bytes === undefined) return '-';

    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(2)} KB`;
    if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(2)} MB`;
    return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }

  private formatDate(dateMs?: number): string {
    if (dateMs === undefined) return '-';
    const date = new Date(dateMs);
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
  }

  private extension(resource: FileExplorerResource): string {
    const dot = resource.name.lastIndexOf('.');
    return dot > 0 ? resource.name.substring(dot + 1).toLowerCase() : '';
  }

  private isVideo(resource: FileExplorerResource): boolean {
    return !resource.isDirectory && ['mp4', 'mkv', 'avi', 'mov', 'm4v', 'ts', 'm2ts', 'wmv', 'webm'].includes(this.extension(resource));
  }

  private isImage(resource: FileExplorerResource): boolean {
    return !resource.isDirectory && ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg', 'tiff'].includes(this.extension(resource));
  }

  private isSubtitle(resource: FileExplorerResource): boolean {
    return !resource.isDirectory && ['srt', 'ass', 'ssa', 'vtt', 'sub'].includes(this.extension(resource));
  }

  private fileTypeColor(resource: FileExplorerResource): string {
    if (resource.isDirectory) { return '#F3CB3B'; }
    if (this.isVideo(resource)) { return '#6AA7FF'; }
    if (this.isSubtitle(resource)) { return '#65C9BD'; }
    return this.COLORS.secondaryText;
  }

  private getFileIcon(resource: FileExplorerResource): Resource {
    if (resource.isDirectory) { return $r('app.media.explorer_folder'); }
    if (this.isVideo(resource)) { return $r('app.media.explorer_video'); }
    if (this.isSubtitle(resource)) { return $r('app.media.explorer_subtitle'); }
    return $r('app.media.explorer_document');
  }

  private getResourceSecondaryText(resource: FileExplorerResource): string {
    const custom = this.resourceSecondaryText(resource);
    if (custom.length > 0) { return custom; }
    if (resource.isDirectory) { return '文件夹'; }
    const ext = this.extension(resource);
    let type = '文件';
    if (this.isVideo(resource)) { type = '视频'; }
    else if (['srt', 'ass', 'ssa', 'vtt', 'sub'].includes(ext)) { type = '字幕'; }
    else if (['mp3', 'wav', 'flac', 'aac', 'm4a'].includes(ext)) { type = '音频'; }
    else if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].includes(ext)) { type = '图片'; }
    return ext.length > 0 ? `${type} · ${ext.toUpperCase()}` : type;
  }

  private isHighlighted(key: string): boolean {
    return key === (this.hoveredKey || this.focusedKey);
  }

  private positionText(): string {
    const resources = this.controller.sortedResources;
    const index = resources.findIndex((resource: FileExplorerResource) => resource.key === (this.hoveredKey || this.focusedKey));
    return index >= 0 ? `${index + 1} / ${resources.length}` : `${resources.length} 个项目`;
  }

  @Builder
  ToolbarButton(label: string, key: string, action: () => void) {
    Button(label, { type: ButtonType.Normal })
      .id(this.controlId(key))
      .height(40)
      .fontSize(16)
      .fontColor(this.COLORS.primaryText)
      .backgroundColor(this.focusedControl === key ? this.COLORS.hover : this.COLORS.button)
      .borderRadius(8)
      .border({ width: 1.5, color: this.focusedControl === key ? this.COLORS.accent : '#48535F' })
      .padding({ left: 18, right: 18 })
      .onFocus(() => { this.hoveredKey = ''; this.cancelFocus(); this.focusedControl = key; })
      .onBlur(() => { this.focusedControl = ''; })
      .onClick(action)
  }

  @Builder
  SortButton(label: string, field: 'name' | 'size' | 'date') {
    Button(label + ' ' + this.getSortIcon(field), { type: ButtonType.Normal })
      .fontSize(15)
      .fontColor(this.controller.sortField === field ? '#6AA7FF' : this.COLORS.secondaryText)
      .backgroundColor(this.focusedControl === field ? this.COLORS.hover : Color.Transparent)
      .borderRadius(6)
      .border({ width: 1.5, color: this.focusedControl === field ? this.COLORS.accent : Color.Transparent })
      .height(36)
      .padding({ left: 8, right: 8 })
      .onFocus(() => { this.hoveredKey = ''; this.cancelFocus(); this.focusedControl = field; })
      .onBlur(() => { this.focusedControl = ''; })
      .onClick(() => { this.changeSortField(field); })
  }

  @Builder
  KeyHint(key: string, label: string) {
    Row({ space: 8 }) {
      Text(key).fontSize(14).fontColor(this.COLORS.primaryText)
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .backgroundColor(key === 'OK' ? this.COLORS.accent : this.COLORS.surface).borderRadius(6)
        .border({ width: 1, color: '#48535F' })
      Text(label).fontSize(14).fontColor(this.COLORS.secondaryText)
    }
  }

  build() {
    Stack() {
      Column() {
        Row({ space: 16 }) {
          this.ToolbarButton('‹  返回', 'back', () => { this.controller.handleBack(); })
          Text('文件浏览').fontSize(28).fontWeight(FontWeight.Bold)
            .fontColor(this.COLORS.primaryText).layoutWeight(1)
          this.ToolbarButton(this.controller.showHiddenFiles ? '隐藏文件：已显示' : '显示隐藏文件',
            'hidden', () => { this.controller.showHiddenFiles = !this.controller.showHiddenFiles; })
          if (this.toolbarActionsBuilder) { this.toolbarActionsBuilder() }
          if (this.isLoading) {
            LoadingProgress().width(24).height(24).color(this.COLORS.accent)
          }
        }
        .width('100%').padding({ top: 24, bottom: 18 })

        Row({ space: 16 }) {
          Image($r('app.media.explorer_folder')).width(30).height(30).objectFit(ImageFit.Contain)
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.controller.pathItems, (item: FileExplorerPathItem, index: number) => {
                if (index > 0) {
                  Text('/').fontSize(18).fontColor(this.COLORS.tertiaryText)
                }
                Button(item.name, { type: ButtonType.Normal })
                  .fontSize(18)
                  .fontWeight(index === this.controller.pathItems.length - 1 ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(index === this.controller.pathItems.length - 1 ? this.COLORS.primaryText : '#6AA7FF')
                  .backgroundColor(this.focusedControl === 'path:' + item.path ? this.COLORS.hover : Color.Transparent)
                  .borderRadius(6)
                  .border({ width: 1.5, color: this.focusedControl === 'path:' + item.path ? this.COLORS.accent : Color.Transparent })
                  .padding({ left: 4, right: 4 }).height(36)
                  .focusable(index < this.controller.pathItems.length - 1)
                  .onFocus(() => { this.hoveredKey = ''; this.cancelFocus(); this.focusedControl = 'path:' + item.path; })
                  .onBlur(() => { this.focusedControl = ''; })
                  .onClick(() => { this.handlePathClick(item.path); })
              }, (item: FileExplorerPathItem) => item.path)
            }
          }
          .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
          .align(Alignment.Start).layoutWeight(1)
          Text(`${this.controller.sortedResources.length} 个项目`)
            .fontSize(16).fontColor(this.COLORS.secondaryText)
        }
        .width('100%').padding({ bottom: 16 })
        Divider().color(this.COLORS.divider)
        if (this.extraTopBuilder) { this.extraTopBuilder() }

        if (this.showDetailColumns) {
          Row() {
            Row() { this.SortButton('名称', 'name') }.layoutWeight(1)
            Row() { this.SortButton('大小', 'size') }.width(110).justifyContent(FlexAlign.End)
            Row() { this.SortButton('修改日期', 'date') }.width(170).justifyContent(FlexAlign.End)
          }
          .width('100%').padding({ left: 12, right: 20, top: 8, bottom: 4 })
        }
        if (this.errorMessage.length > 0) {
          Text(this.errorMessage).fontSize(16).fontColor('#F1A6A6')
            .width('100%').padding(12).backgroundColor(this.COLORS.surface)
        }

        if (this.controller.sortedResources.length === 0) {
          Column({ space: 16 }) {
            if (this.isLoading) {
              LoadingProgress().width(40).height(40).color(this.COLORS.accent)
              Text('正在读取文件…').fontSize(18).fontColor(this.COLORS.secondaryText)
            } else {
              Image($r('app.media.explorer_folder')).width(48).height(48)
              Text(this.errorMessage.length > 0 ? '暂时无法显示文件' : this.emptyText)
                .fontSize(18).fontColor(this.COLORS.secondaryText)
            }
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          List({ space: 2, scroller: this.scroller }) {
            Repeat<FileExplorerResource>(this.controller.sortedResources)
              .each((item: RepeatItem<FileExplorerResource>) => {
              ListItem() {
                Row({ space: 0 }) {
                  Row({ space: 20 }) {
                    if (this.isImage(item.item)) {
                      FileThumbnail({ resource: item.item, loader: this.thumbnailLoader })
                    } else {
                      Image(this.getFileIcon(item.item)).width(32).height(36).objectFit(ImageFit.Contain)
                    }
                    Column({ space: 5 }) {
                      Text(item.item.name).fontSize(20).fontWeight(FontWeight.Medium)
                        .id(this.rowId(item.item.key))
                        .focusable(!this.disableResourceClick(item.item))
                        .onKeyEvent((event: KeyEvent) => {
                          if (event.type === KeyType.Down && (event.keyCode === KeyCode.KEYCODE_ENTER ||
                            event.keyCode === KeyCode.KEYCODE_DPAD_CENTER)) {
                            this.handleResourceClick(item.item); return true;
                          }
                          return false;
                        })
                        .fontColor(this.COLORS.primaryText).maxLines(1)
                        .textOverflow({ overflow: this.isHighlighted(item.item.key) ? TextOverflow.MARQUEE : TextOverflow.Ellipsis })
                        .width('100%')
                      Text() {
                        if (this.resourceSecondaryText(item.item).length > 0 || item.item.isDirectory || this.extension(item.item).length === 0) {
                          Span(this.getResourceSecondaryText(item.item))
                        } else {
                          Span(this.getResourceSecondaryText(item.item).split(' · ')[0] + ' · ')
                          Span(this.extension(item.item).toUpperCase()).fontColor(this.fileTypeColor(item.item))
                        }
                      }.fontSize(14)
                        .fontColor(this.COLORS.secondaryText).maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                    }
                    .alignItems(HorizontalAlign.Start).layoutWeight(1)
                  }
                  .layoutWeight(1)
                  if (this.showDetailColumns) {
                    Text(item.item.isDirectory ? '—' : this.formatFileSize(item.item.size))
                      .fontSize(17).fontColor(this.COLORS.secondaryText).width(110)
                      .textAlign(TextAlign.End).maxLines(1)
                    Text(this.formatDate(item.item.lastModifiedMs))
                      .fontSize(16).fontColor(this.COLORS.secondaryText).width(170)
                      .textAlign(TextAlign.End).maxLines(1)
                  }
                  if (this.showResourceSelection(item.item)) {
                    Checkbox().select(this.isResourceSelected(item.item)).selectedColor(this.COLORS.accent)
                      .margin({ left: 12 })
                      .onChange(() => { this.onResourceSelectionToggle(item.item); })
                  }
                }
                .width('100%').height(72).padding({ left: 20, right: 20 })
                .opacity(this.disableResourceClick(item.item) ? 0.5 : 1)
              }
              .borderRadius(8)
              .backgroundColor(this.isHighlighted(item.item.key) ? this.COLORS.hover : Color.Transparent)
              .border({ width: 1.5, color: this.isHighlighted(item.item.key) ? this.COLORS.accent : Color.Transparent })
              .focusable(!this.disableResourceClick(item.item))
              .onHover((hovered: boolean) => {
                if (hovered && !this.disableResourceClick(item.item)) { this.hoveredKey = item.item.key; }
                else if (this.hoveredKey === item.item.key) { this.hoveredKey = ''; }
              })
              .onFocus(() => { this.hoveredKey = ''; this.focusedKey = item.item.key; this.anchorKey = item.item.key; this.anchorIndex = item.index; })
              .onBlur(() => { if (this.focusedKey === item.item.key) { this.focusedKey = ''; } })
              .onKeyEvent((event: KeyEvent) => this.navigate(event))
              .onClick(() => { this.handleResourceClick(item.item); })
            })
              .key((resource: FileExplorerResource) => resource.key)
              .virtualScroll({ reusable: false })
          }
          .cachedCount(2)
          .onScrollIndex(() => { this.finishFocus(); })
          .onScrollStart(() => { this.hoveredKey = ''; })
          .width('100%').layoutWeight(1).scrollBar(BarState.Auto)
          .divider({ strokeWidth: 0.5, color: this.COLORS.divider, startMargin: 12, endMargin: 12 })
        }
        if (this.extraBottomBuilder) { this.extraBottomBuilder() }
        Divider().color(this.COLORS.divider).margin({ top: 10 })
        Row({ space: 22 }) {
          this.KeyHint('↑ ↓', '选择')
          this.KeyHint('OK', '打开')
          this.KeyHint('返回', this.controller.currentPath === this.controller.rootPath ? '退出' : '上一级')
          Blank()
          Text(this.positionText()).fontSize(14).fontColor(this.COLORS.secondaryText)
        }
        .width('100%').padding({ top: 14, bottom: 20 })
      }
      .width('100%').height('100%').padding({ left: 40, right: 40 })
      .backgroundColor(this.COLORS.background)
      FileExplorerToast({ state: this.toastState })
        .align(Alignment.BottomEnd).margin({ right: 40, bottom: 80 })
      if (this.overlayBuilder) { this.overlayBuilder() }
    }
    .width('100%').height('100%').backgroundColor(this.COLORS.background)
  }
}
