import { KeyCode } from '@kit.InputKit';
import { ScrapeTaskQueue } from '../../services/scrape/ScrapeTaskQueue';
import { ScrapeTaskStore } from '../../services/scrape/ScrapeTaskStore';
import { ScrapeCandidate, ScrapeTaskSnapshot } from '../../services/scrape/ScopedScrapeTypes';
import { ScrapeManagementPage } from '../../pages/scrape/ScrapeManagementPage';

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

@ComponentV2
export struct ScrapeTaskIndicator {
  @Local taskStore: ScrapeTaskStore = ScrapeTaskStore.getState();
  @Local expanded: boolean = false;
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();

  private readonly indicatorFocusId: string = 'scrape_task_indicator';

  private getTasks(): ScrapeTaskSnapshot[] { return this.taskStore.getActiveTasks(); }
  // 角标与下拉列表保持同一口径：waiting/running/waiting-confirmation 都属于活动任务，
  // 避免只剩 waiting-confirmation（等待用户选候选）任务时角标不显示导致任务挂起不可见。
  private getActiveCount(): number { return this.taskStore.getActiveTasks().length; }
  private closeDropdown(): void {
    this.expanded = false;
    setTimeout(() => { focusControl.requestFocus(this.indicatorFocusId); }, 0);
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

  @Builder
  Action(text: string, onClick: () => void) {
    Text(text)
      .fontSize(14).fontColor(Color.White)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor('#334B78A8').borderRadius(8)
      .focusable(true).hoverEffect(HoverEffect.Highlight)
      .onClick(onClick)
  }

  @Builder
  Candidate(task: ScrapeTaskSnapshot, candidate: ScrapeCandidate) {
    Row({ space: 10 }) {
      if (candidate.posterUrl !== undefined && candidate.posterUrl.length > 0) {
        Image(candidate.posterUrl).width(34).height(50).objectFit(ImageFit.Cover).borderRadius(4)
      }
      Column({ space: 3 }) {
        Text(candidate.title).fontSize(15).fontColor(Color.White).maxLines(1)
        Text(candidate.year ?? candidate.provider).fontSize(12).fontColor('#AAB2BF')
      }.alignItems(HorizontalAlign.Start)
    }
    .width('100%').padding(8).borderRadius(8)
    .focusable(true).hoverEffect(HoverEffect.Highlight)
    .onClick(() => { ScrapeTaskQueue.getInstance().confirmCandidate(task.id, candidate); })
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
  TaskItem(task: ScrapeTaskSnapshot) {
    Column({ space: 8 }) {
      Column({ space: 4 }) {
        Text(task.request.scope.displayName).fontSize(16).fontColor(Color.White).fontWeight(FontWeight.Medium)
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
      if (task.status === 'waiting-confirmation' && task.pause !== undefined) {
        if (task.pause.reason === 'candidate-search-retry') {
          Text('匹配结果加载失败或为空').fontSize(13).fontColor('#F1C56A')
          this.Action('重新搜索', () => { ScrapeTaskQueue.getInstance().retryCandidateSearch(task.id); })
        } else {
          Text('请选择匹配结果').fontSize(13).fontColor('#F1C56A')
          ForEach(task.pause.candidates, (candidate: ScrapeCandidate) => {
            this.Candidate(task, candidate)
          }, (candidate: ScrapeCandidate) => `${candidate.provider}:${candidate.providerId}`)
          this.Action('跳过此媒体组', () => { ScrapeTaskQueue.getInstance().cancelCandidateGroup(task.id); })
        }
      }
    }
    .width('100%').padding(12).backgroundColor('#F0181C24').borderRadius(10)
  }

  @Builder
  DropdownBody() {
    Column({ space: 10 }) {
      Row() {
        Text('刮削任务').fontSize(20).fontColor(Color.White).fontWeight(FontWeight.Bold)
        Blank()
        this.Action('关闭', () => { this.closeDropdown(); })
      }.width('100%').alignItems(VerticalAlign.Center)
      if (this.getTasks().length === 0) {
        Text('暂无正在刮削的任务').fontSize(15).fontColor('#AAB2BF').padding(24)
      } else {
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.getTasks(), (task: ScrapeTaskSnapshot) => {
              this.TaskItem(task)
            }, (task: ScrapeTaskSnapshot) => task.id)
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.height(430).scrollBar(BarState.Auto).align(Alignment.Top)
      }
      Row() {
        Blank()
        Button('刮削管理')
          .fontSize(13).fontColor('#66A9D8')
          .backgroundColor('rgba(102,169,216,0.14)')
          .borderRadius(8)
          .focusable(true).hoverEffect(HoverEffect.Highlight)
          .onClick(() => {
            this.closeDropdown();
            this.pageStack.pushPathByName(ScrapeManagementPage.PAGE_NAME, null);
          })
      }.width('100%').alignItems(VerticalAlign.Center)
    }
    .width(430).padding(16)
    .backgroundColor('#FA10141B').borderRadius(14)
    .border({ width: 1, color: '#44516070' }).shadow({ radius: 24, color: '#AA000000' })
    .onKeyEvent((event: KeyEvent) => {
      if (event.keyCode === KeyCode.KEYCODE_BACK) {
        this.closeDropdown();
        event.stopPropagation();
      }
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Text('⇩')
          .id(this.indicatorFocusId)
          .fontSize(24).fontColor(Color.White).width(44).height(40)
          .textAlign(TextAlign.Center).borderRadius(10)
          .focusable(true).hoverEffect(HoverEffect.Highlight)
          .onClick(() => { this.expanded = !this.expanded; })
        if (this.getActiveCount() > 0) {
          Text(this.getActiveCount().toString())
            .fontSize(11).fontColor(Color.White).fontWeight(FontWeight.Bold)
            .width(18).height(18).textAlign(TextAlign.Center)
            .backgroundColor('#E85D4A').borderRadius(9)
        }
      }
      .width(48).height(42)
      // 浮层：锚定在触发图标，独立渲染，不影响右侧时钟/Logo 布局
      .bindPopup(this.expanded, {
        builder: () => { this.DropdownBody() },
        placement: Placement.BottomRight,
        enableArrow: false,
        mask: true,
        autoCancel: true,
        onStateChange: (event: PopupStateChangeParam) => {
          this.expanded = event.isVisible;
        }
      })
    }
  }
}
