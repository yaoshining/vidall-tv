import { AppPreferences, PrefKey } from '../../utils/AppPreferences';
import { ScanMode } from '../../utils/VideoScannerTypes';
import { ScrapeTaskQueue } from '../../services/scrape/ScrapeTaskQueue';
import { ScopedScrapeRequest, ScrapeScope } from '../../services/scrape/ScopedScrapeTypes';

interface ScrapeModeOption {
  mode: ScanMode;
  title: string;
  description: string;
}

const SCRAPE_MODE_OPTIONS: ScrapeModeOption[] = [
  { mode: 'incremental', title: '新增和已修改', description: '处理新增、已修改或关联不完整的内容' },
  { mode: 'fix-missing', title: '缺少元数据', description: '补全缺少关联、海报或必要信息的内容' },
  { mode: 'overwrite', title: '覆盖', description: '重新刮削此范围内的全部内容' }
];

@ComponentV2
export struct ScrapeModePanel {
  @Require @Param visible: boolean;
  @Param scope: ScrapeScope | undefined = undefined;
  @Event onClose: () => void = () => {};
  @Local confirmOverwrite: boolean = false;
  @Local focusedMode: string = '';

  private chooseMode(mode: ScanMode): void {
    if (mode === 'overwrite') {
      this.confirmOverwrite = true;
      return;
    }
    this.enqueue(mode);
  }

  private enqueue(mode: ScanMode): void {
    const target = this.scope;
    if (target === undefined) {
      return;
    }
    AppPreferences.getNumber(PrefKey.LOCAL_SCRAPE_CONFIRM_CANDIDATE, 0)
      .then((value: number): void => {
        const request: ScopedScrapeRequest = {
          scope: target,
          mode,
          candidateStrategy: target.kind === 'global' || value !== 1 ? 'automatic' : 'confirm'
        };
        ScrapeTaskQueue.getInstance().enqueue(request);
        this.confirmOverwrite = false;
        this.onClose();
      })
      .catch((): void => {
        const request: ScopedScrapeRequest = {
          scope: target,
          mode,
          candidateStrategy: 'automatic'
        };
        ScrapeTaskQueue.getInstance().enqueue(request);
        this.confirmOverwrite = false;
        this.onClose();
      });
  }

  private close(): void {
    this.confirmOverwrite = false;
    this.onClose();
  }

  private optionBackground(mode: ScanMode): string {
    return this.focusedMode === mode ? '#243F66' : '#25282D';
  }

  build() {
    if (this.visible && this.scope !== undefined) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%').height('100%')
          .backgroundColor('#99000000')
          .onClick(() => { this.close(); })

        Column({ space: 18 }) {
          Text(this.confirmOverwrite ? '确认覆盖刮削' : '选择刮削方式')
            .fontSize(28).fontWeight(FontWeight.Bold).fontColor(Color.White)
          Text(this.confirmOverwrite
            ? `将重新刮削「${this.scope?.displayName ?? ''}」范围内的全部内容。已有元数据可能被替换。`
            : `目标：${this.scope?.displayName ?? ''}`)
            .fontSize(16).fontColor('#AEB5C0').lineHeight(24)

          if (this.confirmOverwrite) {
            Row({ space: 16 }) {
              Button('取消')
                .width(160).height(52)
                .fontSize(18).fontColor(Color.White)
                .backgroundColor('#34383F')
                .onClick(() => { this.confirmOverwrite = false; })
              Button('确认覆盖')
                .width(180).height(52)
                .fontSize(18).fontColor(Color.White)
                .backgroundColor('#C43D3D')
                .onClick(() => { this.enqueue('overwrite'); })
            }
          } else {
            ForEach(SCRAPE_MODE_OPTIONS, (option: ScrapeModeOption) => {
              Row() {
                Column({ space: 5 }) {
                  Text(option.title).fontSize(19).fontWeight(FontWeight.Medium).fontColor(Color.White)
                  Text(option.description).fontSize(14).fontColor('#9098A4')
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1)
                Text('›').fontSize(24).fontColor('#7D8794')
              }
              .width('100%').height(76)
              .padding({ left: 20, right: 20 })
              .borderRadius(8)
              .backgroundColor(this.optionBackground(option.mode))
              .border({ width: this.focusedMode === option.mode ? 2 : 0, color: '#66A9D8FF' })
              .focusable(true)
              .onFocus(() => { this.focusedMode = option.mode; })
              .onBlur(() => { if (this.focusedMode === option.mode) { this.focusedMode = ''; } })
              .onClick(() => { this.chooseMode(option.mode); })
            }, (option: ScrapeModeOption) => option.mode)
          }
        }
        .width(560)
        .padding(28)
        .borderRadius(14)
        .backgroundColor('#181B20')
        .border({ width: 1, color: '#3A4049' })
      }
      .width('100%').height('100%')
      .zIndex(100)
    }
  }
}
