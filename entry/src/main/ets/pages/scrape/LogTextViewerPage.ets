import { pasteboard } from '@kit.BasicServicesKit';
import { ScrapeFailureLogStore } from '../../services/scrape/ScrapeFailureLogStore';

@ComponentV2
export struct LogTextViewerPage {
  static readonly PAGE_NAME: string = 'scrapeLogViewer';

  @Local logKey: string = '';
  @Local logContent: string = '';
  @Local loading: boolean = true;
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();

  private doCopy(): void {
    if (this.logContent.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '暂无内容可复制' });
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.logContent);
      pasteboard.getSystemPasteboard().setData(data).then((): void => {
        this.getUIContext().getPromptAction().showToast({ message: '已复制' });
      }).catch((): void => {});
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '复制失败' });
    }
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

          Text('日志查看')
            .fontSize(22)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)

          Button('复制')
            .fontSize(13)
            .fontColor('#66A9D8')
            .backgroundColor('rgba(102,169,216,0.12)')
            .borderRadius(6)
            .focusable(true)
            .onClick(() => { this.doCopy(); })
        }
        .width('100%')
        .height(72)
        .padding({ left: 24, right: 24 })
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)

        // ── 日志内容 ──────────────────────────
        if (this.loading) {
          Column() {
            LoadingProgress().width(48).height(48).color('#66A9D8')
            Text('加载中...').fontSize(14).fontColor('#666666').margin({ top: 16 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.logContent.length === 0) {
          Column() {
            Text('📭').fontSize(56).opacity(0.35)
            Text('暂无日志内容').fontSize(16).fontColor('#666666').margin({ top: 20 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Text(this.logContent)
              .fontSize(13)
              .fontColor('#D6DCE4')
              .fontFamily('monospace')
              .lineHeight(20)
              .width('100%')
              .padding({ left: 24, right: 24, top: 8, bottom: 24 })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .align(Alignment.TopStart)
          .width('100%')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#12151B')
    }
    .hideTitleBar(true)
    .onReady((context: NavDestinationContext) => {
      const key = context.pathInfo.param as string;
      if (key !== undefined && key !== null && key.length > 0) {
        this.logKey = key;
        this.loadLog();
      } else {
        this.loading = false;
      }
    })
    .onBackPressed(() => {
      this.pageStack.pop();
      return true;
    })
  }

  private loadLog(): void {
    this.loading = true;
    ScrapeFailureLogStore.readLog(this.logKey).then((content: string): void => {
      this.logContent = content;
      this.loading = false;
    }).catch((): void => {
      this.logContent = '';
      this.loading = false;
    });
  }
}
