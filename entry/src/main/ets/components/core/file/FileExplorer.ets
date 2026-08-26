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

  // 深色主题颜色定义
  private readonly COLORS: ColorsInterface = {
    background: '#000000',           // 主背景色
    surface: '#1C1C1E',             // 表面色
    surfaceVariant: '#2C2C2E',      // 表面变体色
    primaryText: '#FFFFFF',         // 主文本色
    secondaryText: '#EBEBF5',       // 次要文本色
    tertiaryText: '#98989D',        // 三级文本色
    accent: '#0A84FF',              // 强调色（蓝色）
    divider: '#38383A',             // 分割线色
    hover: '#3A3A3C',               // 悬停色
    button: '#48484A'               // 按钮色
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
    const hours = String(date.getHours()).padStart(2, '0');
    const minutes = String(date.getMinutes()).padStart(2, '0');

    return `${year}-${month}-${day} ${hours}:${minutes}`;
  }

  private getFileIcon(resource: FileExplorerResource): string {
    if (resource.isDirectory) {
      return '📁';
    }

    const fileName = resource.name.toLowerCase();

    if (fileName.endsWith('.jpg') || fileName.endsWith('.jpeg') ||
    fileName.endsWith('.png') || fileName.endsWith('.gif') ||
    fileName.endsWith('.bmp') || fileName.endsWith('.webp')) {
      return '🖼️';
    }

    if (fileName.endsWith('.mp4') || fileName.endsWith('.avi') ||
    fileName.endsWith('.mkv') || fileName.endsWith('.mov')) {
      return '🎬';
    }

    if (fileName.endsWith('.mp3') || fileName.endsWith('.wav') ||
    fileName.endsWith('.flac') || fileName.endsWith('.aac')) {
      return '🎵';
    }

    if (fileName.endsWith('.pdf')) {
      return '📕';
    }

    if (fileName.endsWith('.doc') || fileName.endsWith('.docx') ||
    fileName.endsWith('.txt') || fileName.endsWith('.md')) {
      return '📄';
    }

    if (fileName.endsWith('.xls') || fileName.endsWith('.xlsx') ||
    fileName.endsWith('.csv')) {
      return '📊';
    }

    if (fileName.endsWith('.zip') || fileName.endsWith('.rar') ||
    fileName.endsWith('.7z') || fileName.endsWith('.tar')) {
      return '📦';
    }

    return '📄';
  }

  private getResourceSecondaryText(resource: FileExplorerResource): string {
    return this.resourceSecondaryText(resource);
  }

  build() {
    Stack() {
      Column() {
        // 顶部工具栏
        Row() {
          Button('返回')
            .fontSize(16)
            .height(40)
            .backgroundColor(this.COLORS.button)
            .fontColor(this.COLORS.accent)
            .onClick(() => {
              this.controller.handleBack();
            })
            .margin({ right: 10 })

          Button(this.controller.showHiddenFiles ? '隐藏隐藏文件' : '显示隐藏文件')
            .fontSize(16)
            .height(40)
            .backgroundColor(this.COLORS.button)
            .fontColor(this.controller.showHiddenFiles ? this.COLORS.accent : this.COLORS.secondaryText)
            .onClick(() => {
              this.controller.showHiddenFiles = !this.controller.showHiddenFiles;
            })
            .margin({ right: 10 })

          Text(`文件：${this.controller.sortedResources.length}`)
            .fontSize(14)
            .fontColor(this.COLORS.tertiaryText)
            .layoutWeight(1)

          if (this.toolbarActionsBuilder) {
            this.toolbarActionsBuilder()
          }

          if (this.isLoading) {
            LoadingProgress()
              .width(24)
              .height(24)
              .color(this.COLORS.accent)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .backgroundColor(this.COLORS.surface)

        // 路径导航
        Scroll() {
          Row() {
            ForEach(this.controller.pathItems, (item: FileExplorerPathItem, index: number) => {
              Row() {
                Text(item.name)
                  .fontSize(14)
                  .fontColor(index === this.controller.pathItems.length - 1
                    ? this.COLORS.primaryText
                    : this.COLORS.accent)
                  .fontWeight(index === this.controller.pathItems.length - 1
                    ? FontWeight.Bold
                    : FontWeight.Normal)
                  .onClick(() => {
                    if (index !== this.controller.pathItems.length - 1) {
                      this.handlePathClick(item.path);
                    }
                  })

                if (index < this.controller.pathItems.length - 1) {
                  Text(' / ')
                    .fontSize(14)
                    .fontColor(this.COLORS.tertiaryText)
                    .margin({ left: 4, right: 4 })
                }
              }
            }, (item: FileExplorerPathItem) => item.path)
          }
          .padding({ left: 16, right: 16 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(40)
        .backgroundColor(this.COLORS.surfaceVariant)

        Divider()
          .color(this.COLORS.divider)

        if (this.extraTopBuilder) {
          this.extraTopBuilder()
        }

        // 排序栏
        if (this.showDetailColumns) {
          Row() {
            Row() {
              Text('名称 ' + this.getSortIcon('name'))
                .fontSize(13)
                .fontColor(this.controller.sortField === 'name'
                  ? this.COLORS.accent
                  : this.COLORS.tertiaryText)
                .fontWeight(this.controller.sortField === 'name'
                  ? FontWeight.Medium
                  : FontWeight.Normal)
                .onClick(() => {
                  this.changeSortField('name');
                })
            }
            .layoutWeight(3)

            Row() {
              Text('大小 ' + this.getSortIcon('size'))
                .fontSize(13)
                .fontColor(this.controller.sortField === 'size'
                  ? this.COLORS.accent
                  : this.COLORS.tertiaryText)
                .fontWeight(this.controller.sortField === 'size'
                  ? FontWeight.Medium
                  : FontWeight.Normal)
                .onClick(() => {
                  this.changeSortField('size');
                })
            }
            .layoutWeight(2)
            .justifyContent(FlexAlign.End)

            Row() {
              Text('修改日期 ' + this.getSortIcon('date'))
                .fontSize(13)
                .fontColor(this.controller.sortField === 'date'
                  ? this.COLORS.accent
                  : this.COLORS.tertiaryText)
                .fontWeight(this.controller.sortField === 'date'
                  ? FontWeight.Medium
                  : FontWeight.Normal)
                .onClick(() => {
                  this.changeSortField('date');
                })
            }
            .layoutWeight(2)
            .justifyContent(FlexAlign.End)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor(this.COLORS.surface)

          Divider()
            .color(this.COLORS.divider)
        }

        if (this.errorMessage.length > 0) {
          Row() {
            Text('⚠️  ' + this.errorMessage)
              .fontSize(14)
              .fontColor('#FF6B6B')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          }
          .width('100%')
          .backgroundColor(this.COLORS.surface)
        }

        // 文件列表
        if (this.controller.sortedResources.length === 0 && !this.isLoading) {
          Column() {
            Text('📂')
              .fontSize(48)
              .margin({ bottom: 12 })

            Text(this.emptyText)
              .fontSize(16)
              .fontColor(this.COLORS.tertiaryText)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.COLORS.background)
        } else {
          List({ space: 0 }) {
            ForEach(this.controller.sortedResources, (resource: FileExplorerResource, index: number) => {
              ListItem() {
                Row() {
                  // 图标和名称
                  Row({ space: 12 }) {
                    Text(this.getFileIcon(resource))
                      .fontSize($r('app.float.font_h6_title_large'))

                    Column() {
                      Text(resource.name)
                        .fontSize($r('app.float.font_h7_title_small'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.MARQUEE })
                        .fontColor(resource.isDirectory
                          ? this.COLORS.accent
                          : this.COLORS.primaryText)
                        .width('100%')

                      if (this.getResourceSecondaryText(resource).length > 0) {
                        Text(this.getResourceSecondaryText(resource))
                          .fontSize(12)
                          .fontColor(this.COLORS.tertiaryText)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                          .margin({ top: 4 })
                      }
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                  }
                  .layoutWeight(this.showDetailColumns ? 3 : 1)
                  .alignItems(VerticalAlign.Center)

                  if (this.showDetailColumns) {
                    // 文件大小
                    Text(resource.isDirectory ? '-' : this.formatFileSize(resource.size))
                      .fontSize($r('app.float.font_subtitle_1'))
                      .fontColor(this.COLORS.tertiaryText)
                      .layoutWeight(2)
                      .textAlign(TextAlign.End)
                      .maxLines(1)

                    // 修改日期
                    Text(this.formatDate(resource.lastModifiedMs))
                      .fontSize(13)
                      .fontColor(this.COLORS.tertiaryText)
                      .layoutWeight(2)
                      .textAlign(TextAlign.End)
                      .maxLines(1)
                  }

                  if (this.showResourceSelection(resource)) {
                    Checkbox()
                      .select(this.isResourceSelected(resource))
                      .selectedColor(this.COLORS.accent)
                      .margin({ left: 12 })
                      .onChange(() => {
                        this.onResourceSelectionToggle(resource)
                      })
                  }
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .backgroundColor(index % 2 === 0
                  ? this.COLORS.background
                  : this.COLORS.surface)
                .opacity(this.disableResourceClick(resource) ? 0.5 : 1)
              }
              .onClick(() => {
                this.handleResourceClick(resource);
              })
            }, (resource: FileExplorerResource) => resource.key)
          }
          .width('100%')
          .layoutWeight(1)
          .backgroundColor(this.COLORS.background)
          .divider({
            strokeWidth: 0.5,
            color: this.COLORS.divider,
            startMargin: 16,
            endMargin: 16
          })
        }

        if (this.extraBottomBuilder) {
          this.extraBottomBuilder()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.COLORS.background)

      if (this.overlayBuilder) {
        this.overlayBuilder()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.COLORS.background)
  }
}
