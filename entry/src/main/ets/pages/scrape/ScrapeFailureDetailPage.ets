import { ScrapeTaskStore } from '../../services/scrape/ScrapeTaskStore';
import { ScrapeFailureItem, ScrapeTaskSnapshot } from '../../services/scrape/ScopedScrapeTypes';
import { LogTextViewerPage } from './LogTextViewerPage';

@ComponentV2
export struct ScrapeFailureDetailPage {
  static readonly PAGE_NAME: string = 'scrapeFailureDetail';

  @Local taskStore: ScrapeTaskStore = ScrapeTaskStore.getState();
  @Local task: ScrapeTaskSnapshot | undefined = undefined;
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();

  private failureItems(): ScrapeFailureItem[] {
    if (this.task === undefined || this.task.result === undefined) {
      return [];
    }
    return this.task.result.failedItems;
  }

  private openLog(logKey: string): void {
    this.pageStack.pushPathByName(LogTextViewerPage.PAGE_NAME, logKey);
  }

  @Builder
  FailureRow(item: ScrapeFailureItem) {
    Column({ space: 6 }) {
      Text(item.fileName)
        .fontSize(15).fontColor(Color.White).maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(item.path)
        .fontSize(12).fontColor('#8A93A0').maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Row({ space: 12 }) {
        Text(item.category)
          .fontSize(12).fontColor('#F1C56A')
          .backgroundColor('rgba(241,197,106,0.12)')
          .borderRadius(4)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        Blank()
        if (item.logKey !== undefined && item.logKey.length > 0) {
          Button('查看日志')
            .fontSize(12)
            .fontColor('#66A9D8')
            .backgroundColor('rgba(102,169,216,0.12)')
            .borderRadius(6)
            .focusable(true)
            .onClick(() => { this.openLog(item.logKey ?? ''); })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%').padding(12).backgroundColor('#F0181C24').borderRadius(10)
  }

  build() {
    NavDestination() {
      Column() {
        // ── 页头 ──────────────────────────────
        Row() {
          Button('← 返回')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor('rgba(255,255,255,0.08)')
            .borderRadius(6)
            .focusable(true)
            .onClick(() => { this.pageStack.pop(); })

          Text('失败详情')
            .fontSize(22)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)

          Row().width(80).height(36)
        }
        .width('100%')
        .height(72)
        .padding({ left: 24, right: 24 })
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)

        // ── 任务标题 + 失败统计 ────────────────
        if (this.task !== undefined) {
          Column({ space: 6 }) {
            Text(this.task.request.scope.displayName)
              .fontSize(17).fontColor(Color.White).fontWeight(FontWeight.Medium)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            if (this.task.result !== undefined) {
              Text(
                `成功 ${this.task.result.succeeded} · 失败 ${this.task.result.failed}` +
                ` · 取消 ${this.task.result.cancelled}`
              )
                .fontSize(13).fontColor('#AAB2BF').width('100%')
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ left: 24, right: 24, top: 8, bottom: 16 })
        }

        // ── 失败项列表 ──────────────────────────
        if (this.failureItems().length === 0) {
          Column() {
            Text('📭').fontSize(56).opacity(0.35)
            Text('无失败明细').fontSize(16).fontColor('#666666').margin({ top: 20 })
            Text('任务整体异常，未记录到具体失败项目').fontSize(13).fontColor('#444444').margin({ top: 8 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column({ space: 8 }) {
              ForEach(this.failureItems(), (item: ScrapeFailureItem) => {
                this.FailureRow(item)
              }, (item: ScrapeFailureItem) => `${item.videoId}`)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 24, right: 24 })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .align(Alignment.Top)
          .width('100%')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#12151B')
    }
    .hideTitleBar(true)
    .onReady((context: NavDestinationContext) => {
      const taskId = context.pathInfo.param as string;
      if (taskId !== undefined && taskId !== null && taskId.length > 0) {
        const tasks = this.taskStore.getTasks();
        for (let i = 0; i < tasks.length; i++) {
          if (tasks[i].id === taskId) {
            this.task = tasks[i];
            break;
          }
        }
      }
    })
    .onBackPressed(() => {
      this.pageStack.pop();
      return true;
    })
  }
}
