import { MediaItem, SearchHistoryEntry, SeriesGroup } from '../../db/models/MediaEntity';
import { FileSourceDatabase } from '../../db/files/FileSourceDatabase';
import { SeriesDetailPage } from '../detail/SeriesDetailPage';
import { MovieDetailPage } from '../detail/MovieDetailPage';
import { BusinessError } from '@kit.BasicServicesKit';

// ─────────────────────────────────────────────────────────────────────────────
// Color tokens
// ─────────────────────────────────────────────────────────────────────────────
const PAGE_BG: string = '#1A1A1A';
const KEY_BG: string = '#2D2F33';
const KEY_BG_FOCUS: string = '#3B77D4';
const KEY_BG_PRESS: string = '#4488FF';
const FOCUS_BORDER_CLR: string = '#FF66A9D8';
const FOCUS_SHADOW_CLR: string = '#FF553A86';
const KEY_TEXT_CLR: string = '#E3E7ED';
const PLACEHOLDER_CLR: string = '#97A9CD';
const INPUT_TEXT_CLR: string = '#E8EEFF';
const INPUT_BG: string = '#12FFFFFF';
const INPUT_BORDER: string = '#25FFFFFF';
const SPACE_KEY_BG: string = '#3B3D40';
const CLEAR_KEY_BG: string = '#14FF6B6B';
const CLEAR_KEY_BORDER: string = '#4DFF6B6B';
const SEARCH_KEY_BG: string = '#2F77F5';
const HISTORY_TITLE_CLR: string = '#DDE2EA';
const HISTORY_TAG_CLR: string = '#CBD5E1';
const HISTORY_TAG_BG: string = '#50334155';
const HISTORY_TAG_BORDER: string = '#66CBD5E1';
const CLEAR_ALL_CLR: string = '#FF6B6B';
const CLEAR_ALL_BG: string = '#14FF6B6B';
const CLEAR_ALL_BORDER: string = '#4DFF6B6B';
const RESULT_CNT_CLR: string = '#97A9CD';
const CARD_TITLE_CLR: string = '#E3E7ED';
const TRANSPARENT: string = '#00000000';

// ─────────────────────────────────────────────────────────────────────────────
// Keyboard layout constants
// ─────────────────────────────────────────────────────────────────────────────
const QWERTY_ROW: string[] = ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'];
const ASDFG_ROW: string[] = ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'];
const ZXCVB_ROW: string[] = ['Z', 'X', 'C', 'V', 'B', 'N', 'M'];
const NUM_ROW1: string[] = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'];
const NUM_ROW2: string[] = ['-', '/', ':', ';', '(', ')', '$', '&', '@', '"'];
const NUM_ROW3: string[] = ['.', ',', '?', '!', "'"];

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────
function getRatingColor(rating: number): string {
  if (rating >= 8.0) { return '#F7C06C'; }
  if (rating >= 6.0) { return '#D0A26B'; }
  return '#E6786C';
}

function getPosterSrc(item: MediaItem): string {
  if (item.posterLocalPath !== undefined && item.posterLocalPath.length > 0) {
    return `file://${item.posterLocalPath}`;
  }
  if (item.posterUrl !== undefined && item.posterUrl.length > 0) {
    return item.posterUrl;
  }
  return '';
}

// ─────────────────────────────────────────────────────────────────────────────
// KeyButton — single keyboard key
// ─────────────────────────────────────────────────────────────────────────────
@ComponentV2
struct KeyButton {
  @Param label: string = '';
  @Param kw: number = 60;
  @Param kh: number = 56;
  @Param kbg: string = KEY_BG;
  @Event onPress: () => void = () => {};
  @Local isFocused: boolean = false;

  build() {
    Text(this.label)
      .fontSize(22)
      .fontWeight(600)
      .fontColor(KEY_TEXT_CLR)
      .textAlign(TextAlign.Center)
      .width(this.kw)
      .height(this.kh)
      .borderRadius(8)
      .backgroundColor(this.isFocused ? KEY_BG_FOCUS : this.kbg)
      .border({ width: this.isFocused ? 2 : 0, color: FOCUS_BORDER_CLR })
      .shadow(this.isFocused
        ? { radius: 14, color: FOCUS_SHADOW_CLR, offsetX: 0, offsetY: 0 }
        : { radius: 0, color: TRANSPARENT, offsetX: 0, offsetY: 0 })
      .animation({ duration: 140, curve: Curve.EaseInOut })
      .focusable(true)
      .onFocus(() => { this.isFocused = true; })
      .onBlur(() => { this.isFocused = false; })
      .onClick(() => { this.onPress(); })
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HistoryTag — single search history entry
// ─────────────────────────────────────────────────────────────────────────────
@ComponentV2
struct HistoryTag {
  @Param keyword: string = '';
  @Event onSearch: () => void = () => {};
  @Event onDelete: () => void = () => {};
  @Local isFocused: boolean = false;

  build() {
    Row({ space: 4 }) {
      Text(this.keyword)
        .fontSize(16)
        .fontColor(this.isFocused ? '#BFDBFE' : HISTORY_TAG_CLR)
        .padding({ left: 16, right: 4 })
      Text('×')
        .fontSize(13)
        .fontColor(this.isFocused ? '#80BFDBFE' : '#60CBD5E1')
        .padding({ right: 12 })
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => { this.onDelete(); })
    }
    .height(38)
    .backgroundColor(this.isFocused ? '#601D4ED8' : HISTORY_TAG_BG)
    .borderRadius(19)
    .border({ width: this.isFocused ? 2 : 1, color: this.isFocused ? FOCUS_BORDER_CLR : HISTORY_TAG_BORDER })
    .animation({ duration: 140, curve: Curve.EaseInOut })
    .focusable(true)
    .onFocus(() => { this.isFocused = true; })
    .onBlur(() => { this.isFocused = false; })
    .onClick(() => { this.onSearch(); })
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PosterCard — search result card
// ─────────────────────────────────────────────────────────────────────────────
@ComponentV2
struct PosterCard {
  @Require @Param item: MediaItem;
  @Event onPress: () => void = () => {};
  @Local isFocused: boolean = false;

  build() {
    Column({ space: 6 }) {
      if (getPosterSrc(this.item).length > 0) {
        Image(getPosterSrc(this.item))
          .width(180)
          .height(270)
          .borderRadius(8)
          .objectFit(ImageFit.Cover)
      } else {
        Column() {
          Text('🎬')
            .fontSize(36)
            .opacity(0.4)
        }
        .width(180)
        .height(270)
        .backgroundColor(KEY_BG)
        .borderRadius(8)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
      Text(this.item.title ?? '')
        .fontSize(22)
        .fontColor(CARD_TITLE_CLR)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(180)
      if (this.item.rating !== undefined && this.item.rating > 0) {
        Text(this.item.rating.toFixed(1))
          .fontSize(20)
          .fontWeight(600)
          .fontColor(getRatingColor(this.item.rating))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding(4)
    .border({ width: this.isFocused ? 2 : 0, color: FOCUS_BORDER_CLR })
    .borderRadius(10)
    .shadow(this.isFocused
      ? { radius: 14, color: FOCUS_SHADOW_CLR, offsetX: 0, offsetY: 0 }
      : { radius: 0, color: TRANSPARENT, offsetX: 0, offsetY: 0 })
    .scale(this.isFocused ? { x: 1.03, y: 1.03 } : { x: 1.0, y: 1.0 })
    .animation({ duration: 140, curve: Curve.EaseInOut })
    .focusable(true)
    .onFocus(() => { this.isFocused = true; })
    .onBlur(() => { this.isFocused = false; })
    .onClick(() => { this.onPress(); })
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SearchWorkspacePage — main page
// ─────────────────────────────────────────────────────────────────────────────
@ComponentV2
struct SearchWorkspacePage {
  static readonly PAGE_NAME: string = 'SearchWorkspacePage';

  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();

  @Local searchText: string = '';
  @Local isNumericMode: boolean = false;
  @Local searchResults: MediaItem[] = [];
  @Local historyList: SearchHistoryEntry[] = [];
  @Local isSearching: boolean = false;

  private db: FileSourceDatabase = FileSourceDatabase.getInstance();

  aboutToAppear(): void {
    this.loadHistory();
  }

  // ─── Data operations ────────────────────────────────────────────────────────

  private loadHistory(): void {
    this.db.getSearchHistory(15)
      .then((list: SearchHistoryEntry[]) => {
        this.historyList = list;
      })
      .catch(() => {});
  }

  private executeSearch(): void {
    const kw = this.searchText.trim();
    if (kw.length === 0) { return; }
    this.isSearching = true;
    this.db.searchMediaItems(kw, { limit: 50 })
      .then((results: MediaItem[]) => {
        this.searchResults = results;
        this.isSearching = false;
      })
      .catch(() => {
        this.isSearching = false;
      });
    this.db.upsertSearchHistory(kw)
      .then(() => { this.loadHistory(); })
      .catch(() => {});
  }

  private appendChar(char: string): void {
    this.searchText += char;
  }

  private deleteLastChar(): void {
    if (this.searchText.length > 0) {
      this.searchText = this.searchText.slice(0, -1);
    }
  }

  private clearSearch(): void {
    this.searchText = '';
    this.searchResults = [];
  }

  private deleteHistory(keyword: string): void {
    this.db.deleteSearchHistory(keyword)
      .then(() => { this.loadHistory(); })
      .catch(() => {});
  }

  private clearAllHistory(): void {
    this.db.clearSearchHistory()
      .then(() => {
        this.historyList = [];
      })
      .catch(() => {});
  }

  private navigateToDetail(item: MediaItem): void {
    if (item.mediaType === 'tv') {
      const group: SeriesGroup = {
        title: item.title ?? '',
        tvSeriesId: item.tvSeriesId,
        posterUrl: item.posterUrl,
        posterLocalPath: item.posterLocalPath,
        rating: item.rating,
        episodeCount: 0,
        episodes: [],
        latestScannedAt: 0,
      };
      this.pageStack.pushPathByName(SeriesDetailPage.PAGE_NAME, group);
    } else {
      this.pageStack.pushPathByName(MovieDetailPage.PAGE_NAME, item);
    }
  }

  // ─── Builders ────────────────────────────────────────────────────────────────

  @Builder
  headerBar() {
    Row() {
      // Back button
      Row({ space: 8 }) {
        Text('←')
          .fontSize(20)
          .fontColor('#FFFFFF')
        Text('返回')
          .fontSize(16)
          .fontColor('#FFFFFF')
      }
      .width(112)
      .height(40)
      .backgroundColor('#14FFFFFF')
      .borderRadius(8)
      .justifyContent(FlexAlign.Center)
      .focusable(true)
      .onClick(() => { this.pageStack.pop(); })

      // Title
      Text('搜索')
        .fontSize(22)
        .fontWeight(700)
        .fontColor('#FFFFFF')
        .layoutWeight(1)
        .textAlign(TextAlign.Center)

      // Placeholder
      Row()
        .width(112)
        .height(40)
    }
    .width('100%')
    .height(72)
    .padding({ left: 48, right: 64 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(PAGE_BG)
  }

  @Builder
  searchInputBar() {
    Row({ space: 0 }) {
      // Search icon
      Text('🔍')
        .fontSize(20)
        .fontColor(PLACEHOLDER_CLR)
        .padding({ left: 16, right: 8 })

      // Search text or placeholder
      if (this.searchText.length > 0) {
        Text(this.searchText)
          .fontSize(18)
          .fontColor(INPUT_TEXT_CLR)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        Text('搜索电影、剧集、演员…')
          .fontSize(18)
          .fontColor(PLACEHOLDER_CLR)
          .layoutWeight(1)
      }

      // Clear button
      if (this.searchText.length > 0) {
        Text('✕')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .width(28)
          .height(28)
          .borderRadius(14)
          .backgroundColor('#25FFFFFF')
          .margin({ right: 12 })
          .focusable(true)
          .onClick(() => { this.clearSearch(); })
      }
    }
    .width('100%')
    .height(66)
    .borderRadius(8)
    .backgroundColor(INPUT_BG)
    .border({ width: 1, color: INPUT_BORDER })
    .alignItems(VerticalAlign.Center)
    .defaultFocus(true)
  }

  @Builder
  keyboardRow(keys: string[]) {
    Row({ space: 8 }) {
      ForEach(keys, (key: string) => {
        KeyButton({
          label: key,
          kw: 60,
          kh: 56,
          kbg: KEY_BG,
          onPress: () => { this.appendChar(key); }
        })
      }, (key: string) => key)
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
  }

  @Builder
  keyboardZxcvbRow() {
    Row({ space: 8 }) {
      ForEach(ZXCVB_ROW, (key: string) => {
        KeyButton({
          label: key,
          kw: 60,
          kh: 56,
          kbg: KEY_BG,
          onPress: () => { this.appendChar(key); }
        })
      }, (key: string) => key)
      // Backspace key
      KeyButton({
        label: '⌫',
        kw: 100,
        kh: 56,
        kbg: KEY_BG,
        onPress: () => { this.deleteLastChar(); }
      })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
  }

  @Builder
  keyboardFuncRow() {
    Row({ space: 8 }) {
      // Mode toggle
      KeyButton({
        label: this.isNumericMode ? 'ABC' : '123',
        kw: 96,
        kh: 56,
        kbg: KEY_BG,
        onPress: () => { this.isNumericMode = !this.isNumericMode; }
      })
      // Space
      KeyButton({
        label: '空格',
        kw: 220,
        kh: 56,
        kbg: SPACE_KEY_BG,
        onPress: () => { this.appendChar(' '); }
      })
      // Clear
      KeyButton({
        label: '× 清空',
        kw: 96,
        kh: 56,
        kbg: CLEAR_KEY_BG,
        onPress: () => { this.clearSearch(); }
      })
      // Search
      KeyButton({
        label: '🔍搜索',
        kw: 128,
        kh: 56,
        kbg: SEARCH_KEY_BG,
        onPress: () => { this.executeSearch(); }
      })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
  }

  @Builder
  softKeyboard() {
    Column({ space: 8 }) {
      if (this.isNumericMode) {
        // Numeric mode rows
        this.keyboardRow(NUM_ROW1)
        this.keyboardRow(NUM_ROW2)
        Row({ space: 8 }) {
          ForEach(NUM_ROW3, (key: string) => {
            KeyButton({
              label: key,
              kw: 60,
              kh: 56,
              kbg: KEY_BG,
              onPress: () => { this.appendChar(key); }
            })
          }, (key: string) => key)
          KeyButton({
            label: '⌫',
            kw: 100,
            kh: 56,
            kbg: KEY_BG,
            onPress: () => { this.deleteLastChar(); }
          })
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
      } else {
        // QWERTY mode rows
        this.keyboardRow(QWERTY_ROW)
        this.keyboardRow(ASDFG_ROW)
        this.keyboardZxcvbRow()
      }
      // Function row (shared)
      this.keyboardFuncRow()
    }
    .width(680)
    .height(560)
    .margin({ top: 16 })
  }

  @Builder
  leftPanel() {
    Column() {
      this.searchInputBar()
      this.softKeyboard()
    }
    .width(760)
    .height(1008)
    .padding({ left: 48, right: 32, top: 32 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(PAGE_BG)
  }

  @Builder
  historyArea() {
    Column({ space: 16 }) {
      if (this.historyList.length > 0) {
        // Title row
        Row() {
          Text('搜索历史')
            .fontSize(16)
            .fontWeight(600)
            .fontColor(HISTORY_TITLE_CLR)
          Blank()
          Text('全部清除')
            .fontSize(13)
            .fontColor(CLEAR_ALL_CLR)
            .width(80)
            .height(32)
            .textAlign(TextAlign.Center)
            .backgroundColor(CLEAR_ALL_BG)
            .borderRadius(6)
            .border({ width: 1, color: CLEAR_ALL_BORDER })
            .focusable(true)
            .onClick(() => { this.clearAllHistory(); })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // History tags
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.historyList, (entry: SearchHistoryEntry) => {
            HistoryTag({
              keyword: entry.keyword,
              onSearch: () => {
                this.searchText = entry.keyword;
                this.executeSearch();
              },
              onDelete: () => { this.deleteHistory(entry.keyword); }
            })
            .margin({ right: 10, bottom: 10 })
          }, (entry: SearchHistoryEntry) => entry.keyword)
        }
        .width('100%')
      } else {
        // Empty state
        Column({ space: 16 }) {
          Text('🔍')
            .fontSize(48)
            .opacity(0.25)
          Text('暂无搜索记录')
            .fontSize(18)
            .fontColor('#666666')
          Text('输入关键词开始搜索')
            .fontSize(13)
            .fontColor('#444444')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  resultsArea() {
    Column({ space: 16 }) {
      // Result count
      Text(`找到 ${this.searchResults.length} 个结果`)
        .fontSize(16)
        .fontColor(RESULT_CNT_CLR)

      // Results grid
      Grid() {
        ForEach(this.searchResults, (item: MediaItem) => {
          GridItem() {
            PosterCard({
              item: item,
              onPress: () => { this.navigateToDetail(item); }
            })
          }
        }, (item: MediaItem) => `${item.id}`)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
      .columnsGap(16)
      .rowsGap(20)
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  rightPanel() {
    Column() {
      if (this.searchText.trim().length === 0) {
        this.historyArea()
      } else {
        this.resultsArea()
      }
    }
    .width(1160)
    .height(1008)
    .padding({ left: 48, right: 64, top: 32 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(PAGE_BG)
  }

  build() {
    NavDestination() {
      Column() {
        // Header
        this.headerBar()

        // Body: left panel + right panel
        Row() {
          this.leftPanel()
          this.rightPanel()
        }
        .width('100%')
        .height(1008)
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(PAGE_BG)
    }
    .hideTitleBar(true)
    .onBackPressed(() => {
      this.pageStack.pop();
      return true;
    })
  }
}

export { SearchWorkspacePage };
