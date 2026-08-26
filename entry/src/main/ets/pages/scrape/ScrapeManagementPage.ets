import { LengthMetrics } from '@kit.ArkUI';
import { ScrapeTaskQueue } from '../../services/scrape/ScrapeTaskQueue';
import { ScrapeTaskStore } from '../../services/scrape/ScrapeTaskStore';
import { ScrapeTaskSnapshot } from '../../services/scrape/ScopedScrapeTypes';
import { ScrapeFailureDetailPage } from './ScrapeFailureDetailPage';

function statusLabel(status: string): string {
  if (status === 'waiting') { return '等待中'; }
  if (status === 'running') { return '进行中'; }
  if (status === 'waiting-confirmation') { return '等待选择'; }
  if (status === 'completed') { return '已完成'; }
  if (status === 'partial-failure') { return '部分失败'; }
  if (status === 'failed') { return '失败'; }
  return '已取消';
}

function modeLabel(mode: string): string {
  if (mode === 'incremental') { return '新增和已修改'; }
  if (mode === 'fix-missing') { return '缺少元数据'; }
  return '覆盖';
}

interface ScrapeTabDef {
  key: number;
  label: string;
}

const SCRAPE_TABS: ScrapeTabDef[] = [
  { key: 0, label: '正在刮削' },
  { key: 1, label: '已完成' },
  { key: 2, label: '失败' },
  { key: 3, label: '已取消' },
];

@ComponentV2
export struct ScrapeManagementPage {
  static readonly PAGE_NAME: string = 'scrapeManagement';

  @Local taskStore: ScrapeTaskStore = ScrapeTaskStore.getState();
  @Local selectedTab: number = 0;
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();

  private filteredTasks(): ScrapeTaskSnapshot[] {
    const all = this.taskStore.getTasks();
    const result: ScrapeTaskSnapshot[] = [];
    for (let i = 0; i < all.length; i++) {
      const task = all[i];
      if (this.selectedTab === 0) {
        if (task.status === 'waiting' || task.status === 'running' || task.status === 'waiting-confirmation') {
          result.push(task);
        }
      } else if (this.selectedTab === 1) {
        if (task.status === 'completed') {
          result.push(task);
        }
      } else if (this.selectedTab === 2) {
        if (task.status === 'failed' || task.status === 'partial-failure') {
          result.push(task);
        }
      } else if (this.selectedTab === 3) {
        if (task.status === 'cancelled') {
          result.push(task);
        }
      }
    }
    return result;
  }

  private progressText(task: ScrapeTaskSnapshot): string {
    return `${task.progress.completed}/${task.progress.total}`;
  }

  private progressValue(task: ScrapeTaskSnapshot): number {
    return task.progress.completed;
  }

  private progressTotal(task: ScrapeTaskSnapshot): number {
    return Math.max(1, task.progress.total);
  }

  private emptyText(): string {
    if (this.selectedTab === 0) { return '暂无正在刮削的任务'; }
    if (this.selectedTab === 1) { return '暂无已完成的任务'; }
    if (this.selectedTab === 2) { return '暂无失败的任务'; }
    return '暂无已取消的任务';
  }

  private openFailureDetail(task: ScrapeTaskSnapshot): void {
    this.pageStack.pushPathByName(ScrapeFailureDetailPage.PAGE_NAME, task.id);
  }

  @Builder
  Action(text: string, onClick: () => void) {
    Text(text)
      .fontSize(13).fontColor(Color.White)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor('#334B78A8').borderRadius(8)
      .focusable(true).hoverEffect(HoverEffect.Highlight)
      .onClick(onClick)
  }

  @Builder
  ProgressRing(task: ScrapeTaskSnapshot) {
    Stack({ alignContent: Alignment.Center }) {
      Progress({
        value: this.progressValue(task),
        total: this.progressTotal(task),
        type: ProgressType.Linear
      })
        .width('100%').height(10)
        .color('#66A9D8')
        .backgroundColor('#334B78A8')
    }
    .width('100%').height(14)
  }

  @Builder
  TaskCard(task: ScrapeTaskSnapshot) {
    Column({ space: 8 }) {
      Column({ space: 4 }) {
        Text(task.request.scope.displayName)
          .fontSize(16).fontColor(Color.White).fontWeight(FontWeight.Medium).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${modeLabel(task.request.mode)} · ${statusLabel(task.status)} · ${this.progressText(task)}`)
          .fontSize(13).fontColor('#AAB2BF')
      }.alignItems(HorizontalAlign.Start).width('100%')

      this.ProgressRing(task)

      Row() {
        Blank()
        if (task.status === 'waiting') {
          this.Action('取消', () => { ScrapeTaskQueue.getInstance().cancel(task.id); })
        } else if (task.status === 'failed' || task.status === 'partial-failure') {
          Row({ space: 8 }) {
            this.Action('重试', () => { ScrapeTaskQueue.getInstance().retry(task.id); })
            this.Action('清除', () => { ScrapeTaskQueue.getInstance().clear(task.id); })
          }
        } else if (task.status === 'completed' || task.status === 'cancelled') {
          this.Action('清除', () => { ScrapeTaskQueue.getInstance().clear(task.id); })
        }
      }.width('100%').alignItems(VerticalAlign.Top)

      if (task.status === 'failed' || task.status === 'partial-failure') {
        Text('点击查看失败详情')
          .fontSize(12).fontColor('#F1C56A').width('100%')
      }
    }
    .width('100%').padding(12).backgroundColor('#F0181C24').borderRadius(10)
    .focusable(true).hoverEffect(HoverEffect.Highlight)
    .onClick(() => {
      if (task.status === 'failed' || task.status === 'partial-failure') {
        this.openFailureDetail(task);
      }
    })
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

          Text('刮削管理')
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

        // ── Tab 行 ────────────────────────────
        Flex({ space: { main: LengthMetrics.vp(10) } }) {
          ForEach(SCRAPE_TABS, (tab: ScrapeTabDef) => {
            Button(tab.label)
              .buttonStyle(this.selectedTab === tab.key ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
              .borderRadius(8)
              .focusable(true)
              .onClick(() => { this.selectedTab = tab.key; })
          })
        }
        .width('100%')
        .padding({ left: 24, right: 24, top: 8, bottom: 20 })

        // ── 任务列表 ──────────────────────────
        if (this.filteredTasks().length === 0) {
          Column() {
            Text('📭').fontSize(56).opacity(0.35)
            Text(this.emptyText()).fontSize(16).fontColor('#666666').margin({ top: 20 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column({ space: 8 }) {
              ForEach(this.filteredTasks(), (task: ScrapeTaskSnapshot) => {
                this.TaskCard(task)
              }, (task: ScrapeTaskSnapshot) => task.id)
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
    .onBackPressed(() => {
      this.pageStack.pop();
      return true;
    })
  }
}
