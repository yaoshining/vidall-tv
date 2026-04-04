import { MediaItem, SearchHistoryEntry, SeriesGroup } from '../../db/models/MediaEntity';
import { FileSourceDatabase } from '../../db/files/FileSourceDatabase';
import { MediaResultPage, MediaResultPageParam } from './MediaResultPage';
import { SeriesDetailPage } from '../detail/SeriesDetailPage';
import { MovieDetailPage } from '../detail/MovieDetailPage';

// ─────────────────────────────────────────────────────────────────────────────
// Design Token Constants — strictly follows Pencil vidall_pages.pen
// ─────────────────────────────────────────────────────────────────────────────

const C_PAGE_BG: string = '#232425';
const C_KBD_BG: string = '#1C1E22';
const C_HIST_CHIP_BG: string = '#23272E';
const C_COMPONENT_BG: string = '#2C3138';
const C_LETTER_KEY_BG: string = '#3A3F46';
const C_BKSP_BG: string = '#565D67';
const C_CLEAR_BG: string = '#6B3339';
const C_SEL_BLUE: string = '#3B77D4';
const C_BORDER: string = '#464E58';
const C_HIST_BORDER: string = '#454C55';
const C_CLEAR_BORDER: string = '#B85A64';
const C_TEXT_TITLE: string = '#EAF3FF';
const C_TEXT_BODY: string = '#DDE4EE';
const C_KEY_TEXT: string = '#F3F6FA';
const C_PLACEHOLDER: string = '#C7CED8';
const C_SECONDARY: string = '#8E96A3';
const C_ICON: string = '#AAB4C3';
const C_HIST_TEXT: string = '#E6EDF5';
const C_CLEAR_ICON: string = '#FFD7DB';
const TRANSPARENT: string = '#00000000';

// ─────────────────────────────────────────────────────────────────────────────
// Keyboard layout arrays — row1/row2/row3, left letters + right numbers
// ─────────────────────────────────────────────────────────────────────────────

const KBD_R1_L: string[] = ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'];
const KBD_R1_R: string[] = ['1', '2', '3', '4'];
const KBD_R2_L: string[] = ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'];
const KBD_R2_R: string[] = ['5', '6', '7', '8'];
const KBD_R3_L: string[] = ['Z', 'X', 'C', 'V', 'B', 'N', 'M'];

// ─────────────────────────────────────────────────────────────────────────────
// Module-level helpers (avoid logic in build())
// ─────────────────────────────────────────────────────────────────────────────

function scoreColor(s: number): string {
  if (s >= 8.5) { return '#F7C06C'; }
  if (s >= 8.0) { return '#F6B85F'; }
  if (s >= 7.0) { return '#E6786C'; }
  return '#D0A26B';
}

function posterSrc(item: MediaItem): string {
  if (item.posterLocalPath !== undefined && item.posterLocalPath.length > 0) {
    return 'file://' + item.posterLocalPath;
  }
  if (item.posterUrl !== undefined && item.posterUrl.length > 0) {
    return item.posterUrl;
  }
  return '';
}

// ─────────────────────────────────────────────────────────────────────────────
// KeyButton — single keyboard key component
// ─────────────────────────────────────────────────────────────────────────────

@ComponentV2
struct KeyButton {
  @Param label: string = '';
  @Param kbg: string = C_LETTER_KEY_BG;
  @Event onPress: () => void = () => {};
  @Local isFocused: boolean = false;

  build() {
    Text(this.label)
      .fontSize(20)
      .fontWeight(600)
      .fontColor(C_KEY_TEXT)
      .textAlign(TextAlign.Center)
      .width('100%')
      .aspectRatio(112 / 60)   // 高度由列宽自动推导，无需硬编码 height
      .borderRadius(10)
      .backgroundColor(this.isFocused ? C_SEL_BLUE : this.kbg)
      .border({ width: this.isFocused ? 2 : 0, color: '#5B9BD5' })
      .animation({ duration: 140, curve: Curve.EaseInOut })
      .focusable(true)
      .onFocus(() => { this.isFocused = true; })
      .onBlur(() => { this.isFocused = false; })
      .onClick(() => { this.onPress(); })
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WorkspacePosterCard — card used in workspace hot-search / results preview
// ─────────────────────────────────────────────────────────────────────────────

@ComponentV2
struct WorkspacePosterCard {
  @Require @Param item: MediaItem;
  @Event onPress: () => void = () => {};
  @Local isFocused: boolean = false;

  build() {
    Column({ space: 8 }) {
      Stack() {
        if (posterSrc(this.item).length > 0) {
          Image(posterSrc(this.item))
            .width(180)
            .height(270)
            .objectFit(ImageFit.Cover)
        } else {
          Column() {
            Text('\u{1F3AC}')
              .fontSize(36)
              .opacity(0.4)
          }
          .width(180)
          .height(270)
          .backgroundColor(C_COMPONENT_BG)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        }
      }
      .width(180)
      .height(270)
      .clip(true)
      .borderRadius(8)
      .border({ width: this.isFocused ? 2 : 0, color: '#FF3B77D4' })
      .shadow({
        radius: this.isFocused ? 12 : 0,
        color: this.isFocused ? '#803B77D4' : TRANSPARENT,
        offsetX: 0,
        offsetY: 0
      })
      .scale({ x: this.isFocused ? 1.04 : 1.0, y: this.isFocused ? 1.04 : 1.0 })
      .animation({ duration: 140, curve: Curve.EaseInOut })

      Text(this.item.title ?? '')
        .fontSize(22)
        .fontColor('#E3E7ED')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(180)

      if (this.item.rating !== undefined && this.item.rating > 0) {
        Text(this.item.rating.toFixed(1))
          .fontSize(20)
          .fontWeight(600)
          .fontColor(scoreColor(this.item.rating))
      }
    }
    .width(180)
    .alignItems(HorizontalAlign.Start)
    .focusable(true)
    .onFocus(() => { this.isFocused = true; })
    .onBlur(() => { this.isFocused = false; })
    .onClick(() => { this.onPress(); })
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SearchWorkspacePage — main search entry page (TV vertical layout)
// ─────────────────────────────────────────────────────────────────────────────

@ComponentV2
struct SearchWorkspacePage {
  static readonly PAGE_NAME: string = 'SearchWorkspacePage';

  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();

  @Local searchText: string = '';
  @Local searchResults: MediaItem[] = [];
  @Local historyList: SearchHistoryEntry[] = [];
  @Local isSearching: boolean = false;
  @Local hotItems: MediaItem[] = [];

  private db: FileSourceDatabase = FileSourceDatabase.getInstance();
  @Local private searchDebounceTimer: number = -1;
  // 竞态保护：快速连续输入时，丢弃旧请求的返回结果
  private searchGeneration: number = 0;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  aboutToAppear(): void {
    this.loadHistory();
    this.loadHotItems();
  }

  aboutToDisappear(): void {
    if (this.searchDebounceTimer !== -1) {
      clearTimeout(this.searchDebounceTimer);
    }
  }

  // ── Data helpers ──────────────────────────────────────────────────────────

  private loadHistory(): void {
    this.db.getSearchHistory(20)
      .then((list: SearchHistoryEntry[]) => {
        this.historyList = list;
      })
      .catch(() => {});
  }

  private loadHotItems(): void {
    this.db.searchMediaItems('', { sortBy: 'rating', limit: 8 })
      .then((items: MediaItem[]) => {
        this.hotItems = items;
      })
      .catch(() => {});
  }

  private scheduleSearch(): void {
    if (this.searchDebounceTimer !== -1) {
      clearTimeout(this.searchDebounceTimer);
      this.searchDebounceTimer = -1;
    }
    if (this.searchText.trim().length === 0) {
      this.searchResults = [];
      return;
    }
    this.searchDebounceTimer = setTimeout(() => {
      this.searchDebounceTimer = -1;
      this.triggerSearchAndNavigate();
    }, 800);
  }

  /** 本地预览搜索（仅实时展示结果，不保存历史、不跳转） */
  private async executeSearch(): Promise<void> {
    const kw: string = this.searchText.trim();
    if (kw.length === 0) {
      this.searchResults = [];
      return;
    }
    const generation = ++this.searchGeneration;
    this.isSearching = true;
    try {
      const items: MediaItem[] = await this.db.searchMediaItems(kw, { limit: 50 });
      if (generation !== this.searchGeneration) { return; } // 丢弃过期结果
      this.searchResults = items;
    } catch {
      if (generation !== this.searchGeneration) { return; }
      this.searchResults = []; // 失败时清空，不保留旧数据
    } finally {
      if (generation === this.searchGeneration) {
        this.isSearching = false;
      }
    }
  }

  /** 确认搜索：保存历史 + 导航到 MediaResultPage（M1 核心路由） */
  private triggerSearchAndNavigate(): void {
    const kw: string = this.searchText.trim();
    if (kw.length === 0) { return; }
    this.db.upsertSearchHistory(kw)
      .then(() => { this.loadHistory(); })
      .catch(() => {});
    const param: MediaResultPageParam = {
      keyword: kw,
      pageTitle: kw,
    };
    this.pageStack.pushPathByName(MediaResultPage.PAGE_NAME, param);
  }

  private appendChar(c: string): void {
    this.searchText += c;
    this.scheduleSearch();
  }

  private deleteLastChar(): void {
    if (this.searchText.length > 0) {
      this.searchText = this.searchText.slice(0, -1);
      this.scheduleSearch();
    }
  }

  private clearSearch(): void {
    this.searchText = '';
    this.searchResults = [];
    this.scheduleSearch();
  }

  private deleteHistory(keyword: string): void {
    this.db.deleteSearchHistory(keyword)
      .then(() => { this.loadHistory(); })
      .catch(() => {});
  }

  private clearAllHistory(): void {
    this.db.clearSearchHistory()
      .then(() => { this.historyList = []; })
      .catch(() => {});
  }

  private navigateToDetail(item: MediaItem): void {
    if (item.mediaType === 'tv') {
      const group: SeriesGroup = {
        title: item.title ?? '',
        tvSeriesId: item.tvSeriesId,
        posterUrl: item.posterUrl,
        posterLocalPath: item.posterLocalPath,
        backdropUrl: item.backdropUrl,
        rating: item.rating,
        episodeCount: 0,
        episodes: [item],
        latestScannedAt: item.scannedAt ?? 0,
      };
      this.pageStack.pushPathByName(SeriesDetailPage.PAGE_NAME, group);
    } else {
      this.pageStack.pushPathByName(MovieDetailPage.PAGE_NAME, item);
    }
  }

  // ── @Builder sections ─────────────────────────────────────────────────────

  @Builder
  buildBackRow() {
    Row() {
      Row() {
        Text('\u{2039}')
          .fontSize(22)
          .fontColor(C_TEXT_BODY)
      }
      .width(48)
      .height(48)
      .borderRadius(24)
      .backgroundColor(C_COMPONENT_BG)
      .border({ width: 1, color: C_BORDER })
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .focusable(true)
      .onClick(() => { this.pageStack.pop(); })
    }
    .width('100%')
    .height(48)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  buildTitleArea() {
    Column({ space: 8 }) {
      Text('\u641c\u7d22')
        .fontSize(34)
        .fontWeight(700)
        .fontColor(C_TEXT_TITLE)
      Text('\u652f\u6301\u9996\u5b57\u6bcd\u3001\u5168\u62fc\u3001\u4e2d\u6587\u7247\u540d\u641c\u7d22')
        .fontSize(18)
        .fontWeight(500)
        .fontColor(C_SECONDARY)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  buildSearchBar() {
    Row({ space: 12 }) {
      Text('\uD83D\uDD0D')
        .fontSize(22)
        .fontColor(C_ICON)
        .width(22)
        .height(22)
      if (this.searchText.length > 0) {
        Text(this.searchText)
          .fontSize(22)
          .fontWeight(500)
          .fontColor(C_TEXT_TITLE)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        Text('\u652f\u6301\u9996\u5b57\u6bcd\u3001\u5168\u62fc\u3001\u4e2d\u6587\u7247\u540d\u641c\u7d22')
          .fontSize(22)
          .fontWeight(500)
          .fontColor(C_PLACEHOLDER)
          .layoutWeight(1)
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .backgroundColor(C_COMPONENT_BG)
    .borderRadius(14)
    .border({ width: 1, color: C_BORDER })
    .alignItems(VerticalAlign.Center)
    .defaultFocus(true)
  }

  // row1: Q-P + 1-4
  @Builder
  buildKbdRow1() {
    Grid() {
      ForEach(KBD_R1_L, (key: string) => {
        GridItem() {
          KeyButton({ label: key, onPress: () => { this.appendChar(key); } })
        }
      }, (key: string) => key)
      ForEach(KBD_R1_R, (key: string) => {
        GridItem() {
          KeyButton({ label: key, onPress: () => { this.appendChar(key); } })
        }
      }, (key: string) => key)
    }
    .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr')
    .columnsGap(8)
    .width('100%')
  }

  // row2: A-L + clear + 5-8
  @Builder
  buildKbdRow2() {
    Grid() {
      ForEach(KBD_R2_L, (key: string) => {
        GridItem() {
          KeyButton({ label: key, onPress: () => { this.appendChar(key); } })
        }
      }, (key: string) => key)
      // Clear key（占 1 列）
      GridItem() {
        Text('\uD83D\uDDD1')
          .fontSize(22)
          .fontColor(C_CLEAR_ICON)
          .textAlign(TextAlign.Center)
          .width('100%')
          .aspectRatio(112 / 60)
          .borderRadius(10)
          .backgroundColor(C_CLEAR_BG)
          .border({ width: 1, color: C_CLEAR_BORDER })
          .focusable(true)
          .onClick(() => { this.clearSearch(); })
      }
      ForEach(KBD_R2_R, (key: string) => {
        GridItem() {
          KeyButton({ label: key, onPress: () => { this.appendChar(key); } })
        }
      }, (key: string) => key)
    }
    .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr')
    .columnsGap(8)
    .width('100%')
  }

  // row3: Z-M + backspace(3cols) + 9 + 0(3cols)
  @Builder
  buildKbdRow3() {
    Grid() {
      ForEach(KBD_R3_L, (key: string, index: number) => {
        GridItem() {
          KeyButton({ label: key, onPress: () => { this.appendChar(key); } })
        }
        .columnStart(index)
        .columnEnd(index)
      }, (key: string) => key)
      // Backspace（跨 3 列：colStart 7-9）
      GridItem() {
        Text('\u232B')
          .fontSize(20)
          .fontWeight(700)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .width('100%')
          .height('100%')
          .borderRadius(10)
          .backgroundColor(C_BKSP_BG)
          .focusable(true)
          .onClick(() => { this.deleteLastChar(); })
      }
      .columnStart(7)
      .columnEnd(9)
      // 9 key（colStart 10）
      GridItem() {
        KeyButton({ label: '9', onPress: () => { this.appendChar('9'); } })
      }
      .columnStart(10)
      .columnEnd(10)
      // 0 key（跨 3 列：colStart 11-13）
      GridItem() {
        Text('0')
          .fontSize(20)
          .fontWeight(600)
          .fontColor(C_KEY_TEXT)
          .textAlign(TextAlign.Center)
          .width('100%')
          .height('100%')
          .borderRadius(10)
          .backgroundColor(C_LETTER_KEY_BG)
          .focusable(true)
          .onClick(() => { this.appendChar('0'); })
      }
      .columnStart(11)
      .columnEnd(13)
    }
    .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr')
    .columnsGap(8)
    .width('100%')
    .height(64)   // 跨列 GridItem 的 height('100%') 需 Grid 有已知高度；64vp ≈ aspectRatio 推算结果
  }

  @Builder
  buildKeyboard() {
    Column({ space: 10 }) {
      this.buildKbdRow1()
      this.buildKbdRow2()
      this.buildKbdRow3()
      // 搜索按钮已移除，改由防抖 800ms 自动触发 triggerSearchAndNavigate
    }
    .width('100%')
    .backgroundColor(C_KBD_BG)
    .borderRadius(14)
    .padding(14)
  }

  @Builder
  buildHistory() {
    if (this.historyList.length > 0) {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.historyList, (entry: SearchHistoryEntry) => {
          // M2：拆成两个独立可聚焦节点，遥控器 D-pad 可分别聚焦到关键词和删除按钮
          Row({ space: 0 }) {
            // 左侧：关键词文字 — 聚焦后 OK 键触发搜索并跳转
            Text(entry.keyword)
              .fontSize(16)
              .fontWeight(500)
              .fontColor(C_HIST_TEXT)
              .padding({ left: 14, right: 6, top: 8, bottom: 8 })
              .focusable(true)
              .onClick(() => {
                this.searchText = entry.keyword;
                this.triggerSearchAndNavigate();
              })
            // 右侧：× 删除按钮 — 聚焦后 OK 键触发删除
            Text('\u00D7')
              .fontSize(14)
              .fontColor(C_SECONDARY)
              .padding({ left: 6, right: 14, top: 8, bottom: 8 })
              .focusable(true)
              .onClick(() => { this.deleteHistory(entry.keyword); })
          }
          .backgroundColor(C_HIST_CHIP_BG)
          .borderRadius(999)
          .border({ width: 1, color: C_HIST_BORDER })
          .margin({ right: 10, bottom: 10 })
        }, (entry: SearchHistoryEntry) => entry.keyword)

        // Clear-all button styled same as chip
        Text('\u5220\u9664\u5386\u53f2')
          .fontSize(16)
          .fontWeight(600)
          .fontColor('#D7DEE7')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor(C_HIST_CHIP_BG)
          .borderRadius(999)
          .border({ width: 1, color: C_HIST_BORDER })
          .margin({ right: 10, bottom: 10 })
          .focusable(true)
          .onClick(() => { this.clearAllHistory(); })
      }
      .width('100%')
    }
  }

  @Builder
  buildHotSearch() {
    if (this.hotItems.length > 0) {
      Column({ space: 16 }) {
        Text('\u5927\u5bb6\u90fd\u5728\u641c')
          .fontSize(24)
          .fontWeight(700)
          .fontColor('#DDE2EA')
          .width('100%')
        Scroll() {
          Row({ space: 30 }) {
            ForEach(this.hotItems, (item: MediaItem) => {
              WorkspacePosterCard({
                item: item,
                onPress: () => { this.navigateToDetail(item); }
              })
            }, (item: MediaItem) => String(item.id))
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  buildResultsPreview() {
    if (this.searchResults.length > 0) {
      Scroll() {
        Row({ space: 30 }) {
          ForEach(this.searchResults, (item: MediaItem) => {
            WorkspacePosterCard({
              item: item,
              onPress: () => { this.navigateToDetail(item); }
            })
          }, (item: MediaItem) => String(item.id))
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .width('100%')
    }
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 20 }) {
          this.buildBackRow()
          this.buildSearchBar()
          this.buildKeyboard()
          // M7：始终显示历史和热搜；本地预览结果只在有内容时附加展示
          this.buildHistory()
          this.buildHotSearch()
          if (this.searchResults.length > 0) {
            this.buildResultsPreview()
          }
        }
        .width('100%')
        .padding(20)
        .backgroundColor(C_PAGE_BG)
      }
      .scrollable(ScrollDirection.Vertical)
      .width('100%')
      .height('100%')
      .backgroundColor(C_PAGE_BG)
    }
    .hideTitleBar(true)
    .onBackPressed(() => {
      this.pageStack.pop();
      return true;
    })
  }
}

export { SearchWorkspacePage };
