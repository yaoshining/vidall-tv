import { MediaItem, SearchHistoryEntry, SeriesGroup } from '../../db/models/MediaEntity';
import { FileSourceDatabase } from '../../db/files/FileSourceDatabase';

import { SeriesDetailPage } from '../detail/SeriesDetailPage';
import { MovieDetailPage } from '../detail/MovieDetailPage';
import { LengthMetrics } from '@kit.ArkUI';

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
  @Local isHovered: boolean = false;
  @Local isPressed: boolean = false;

  // State priority: Active > Focus > Hover > Default
  private getBgColor(): string {
    if (this.isPressed && this.isFocused) { return '#2C5C96'; }
    if (this.isPressed) { return '#202020'; }
    if (this.isFocused) { return C_SEL_BLUE; }
    if (this.isHovered) { return '#464E58'; }
    return this.kbg;
  }

  private getBorderColor(): string {
    if (this.isPressed && this.isFocused) { return '#76B6FF'; }
    if (this.isPressed) { return '#454545'; }
    if (this.isFocused) { return '#4A9FFF'; }
    if (this.isHovered) { return '#5A5A5A'; }
    return TRANSPARENT;
  }

  private getBorderWidth(): number {
    if (this.isFocused) { return 2; }
    if (this.isPressed || this.isHovered) { return 1; }
    return 0;
  }

  private getScale(): number {
    return this.isPressed ? 0.97 : 1.0;
  }

  build() {
    Text(this.label)
      .fontSize(20)
      .fontWeight(600)
      .fontColor('#FFFFFF')
      .textAlign(TextAlign.Center)
      .width('100%')
      .aspectRatio(112 / 60)
      .borderRadius(10)
      .backgroundColor(this.getBgColor())
      .border({ width: this.getBorderWidth(), color: this.getBorderColor() })
      .scale({ x: this.getScale(), y: this.getScale() })
      .animation({ duration: 100, curve: Curve.EaseOut })
      .focusable(true)
      .onFocus(() => { this.isFocused = true; })
      .onBlur(() => { this.isFocused = false; this.isHovered = false; this.isPressed = false; })
      .onHover((isHover: boolean) => { this.isHovered = isHover; })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.isPressed = true;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.isPressed = false;
        }
      })
      .onClick(() => { this.onPress(); })
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ActionKey — functional key component (clear / backspace / wide keys)
// ─────────────────────────────────────────────────────────────────────────────

@ComponentV2
struct ActionKey {
  @Param label: string = '';
  @Param bgColor: string = C_LETTER_KEY_BG;
  @Param focusBgColor: string = C_SEL_BLUE;
  @Param focusPressBgColor: string = '#2C5C96';
  @Param hoverBgColor: string = '#464E58';
  @Param activeBgColor: string = '#2E3540';
  @Param keyBorderColor: string = '';
  @Param keyFocusColor: string = '#5B9BD5';
  @Param hoverBorderColor: string = '#5A5A5A';
  @Param activeBorderColor: string = '#454545';
  @Param labelColor: string = C_KEY_TEXT;
  @Param labelFontSize: number = 20;
  @Param sublabel: string = '';
  @Param sublabelFontSize: number = 16;
  @Param keyAspect: number = 112 / 60;
  @Event onPress: () => void = () => {};
  @Local isFocused: boolean = false;
  @Local isHovered: boolean = false;
  @Local isPressed: boolean = false;

  // State priority: Active > Focus > Hover > Default
  private getBgColor(): string {
    if (this.isPressed && this.isFocused) { return this.focusPressBgColor; }
    if (this.isPressed) { return this.activeBgColor; }
    if (this.isFocused) { return this.focusBgColor; }
    if (this.isHovered) { return this.hoverBgColor; }
    return this.bgColor;
  }

  private getBorderColor(): string {
    if (this.isPressed && this.isFocused) { return '#76B6FF'; }
    if (this.isPressed) { return this.activeBorderColor; }
    if (this.isFocused) { return this.keyFocusColor; }
    if (this.isHovered) { return this.hoverBorderColor; }
    return this.keyBorderColor.length > 0 ? this.keyBorderColor : TRANSPARENT;
  }

  private getBorderWidth(): number {
    if (this.isFocused) { return 2; }
    if (this.isPressed || this.isHovered) { return 1; }
    return this.keyBorderColor.length > 0 ? 1 : 0;
  }

  // Wide keys (aspect > 2) use 0.98 scale to keep press feel proportional
  private getScale(): number {
    if (this.isPressed) {
      return this.keyAspect > 2 ? 0.98 : 0.97;
    }
    return 1.0;
  }

  build() {
    Row() {
      if (this.sublabel.length > 0) {
        Text() {
          Span(this.label)
            .fontSize(this.labelFontSize)
            .fontColor(this.labelColor)
            .lineHeight(24)
          Span('\u2009' + this.sublabel)
            .fontSize(this.sublabelFontSize)
            .fontColor(this.labelColor)
            .lineHeight(24)
        }
        .textAlign(TextAlign.Center)
      } else {
        Text(this.label)
          .fontSize(this.labelFontSize)
          .fontColor(this.labelColor)
          .textAlign(TextAlign.Center)
      }
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .aspectRatio(this.keyAspect)
    .borderRadius(10)
    .backgroundColor(this.getBgColor())
    .border({ width: this.getBorderWidth(), color: this.getBorderColor() })
    .scale({ x: this.getScale(), y: this.getScale() })
    .animation({ duration: 100, curve: Curve.EaseOut })
    .focusable(true)
    .onFocus(() => { this.isFocused = true; })
    .onBlur(() => { this.isFocused = false; this.isHovered = false; this.isPressed = false; })
    .onHover((isHover: boolean) => { this.isHovered = isHover; })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.isPressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.isPressed = false;
      }
    })
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
  @Local isSearchBarFocused: boolean = false;

  private db: FileSourceDatabase | null = null;
  @Local private searchDebounceTimer: number = -1;
  // 竞态保护：快速连续输入时，丢弃旧请求的返回结果
  private searchGeneration: number = 0;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  aboutToAppear(): void {
    try {
      this.db = FileSourceDatabase.getInstance();
      this.loadHistory();
    } catch (e) {
      // Preview 沙箱：native DB 不可用，静默降级
    }
  }

  aboutToDisappear(): void {
    if (this.searchDebounceTimer !== -1) {
      clearTimeout(this.searchDebounceTimer);
    }
  }

  // ── Data helpers ──────────────────────────────────────────────────────────

  private loadHistory(): void {
    if (this.db === null) { return; }
    this.db.getSearchHistory(20)
      .then((list: SearchHistoryEntry[]) => {
        this.historyList = list;
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
      this.executeSearch();
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
      const items: MediaItem[] = await this.db!.searchMediaItems(kw, { limit: 200 });
      if (generation !== this.searchGeneration) { return; }
      // 按 (tvSeriesId, movieId) 去重：同一部剧/电影只保留第一条
      const seen: Set<string> = new Set<string>();
      const deduped: MediaItem[] = [];
      for (const item of items) {
        const key: string = item.tvSeriesId !== undefined
          ? `tv-${item.tvSeriesId}`
          : item.movieId !== undefined
            ? `mv-${item.movieId}`
            : `v-${item.id}`;
        if (!seen.has(key)) {
          seen.add(key);
          deduped.push(item);
        }
      }
      this.searchResults = deduped;
    } catch {
      if (generation !== this.searchGeneration) { return; }
      this.searchResults = [];
    } finally {
      if (generation === this.searchGeneration) {
        this.isSearching = false;
      }
    }
  }

  /** 执行搜索并保存历史 */
  private executeSearchWithHistory(): void {
    const kw: string = this.searchText.trim();
    if (kw.length === 0) { return; }
    if (this.db !== null) {
      this.db.upsertSearchHistory(kw)
        .then(() => { this.loadHistory(); })
        .catch(() => {});
    }
    this.executeSearch();
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
    if (this.db === null) { return; }
    this.db.deleteSearchHistory(keyword)
      .then(() => { this.loadHistory(); })
      .catch(() => {});
  }

  private clearAllHistory(): void {
    if (this.db === null) { return; }
    this.db.clearSearchHistory()
      .then(() => { this.historyList = []; })
      .catch(() => {});
  }

  private navigateToDetail(item: MediaItem): void {
    if (item.tvSeriesId !== undefined) {
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
    .width('70%')
    .height(56)
    .padding({ left: 16, right: 16, bottom: 4 })
    .backgroundColor('transparent')
    .alignSelf(ItemAlign.Center)
    .border({
      width: { bottom: this.isSearchBarFocused ? 2 : 1 },
      color: { bottom: this.isSearchBarFocused ? '#4A9FFF' : C_BORDER },
      style: { bottom: BorderStyle.Solid }
    })
    .animation({ duration: 150, curve: Curve.EaseOut })
    .alignItems(VerticalAlign.Center)
    .defaultFocus(true)
    .focusable(true)
    .onFocus(() => { this.isSearchBarFocused = true; })
    .onBlur(() => { this.isSearchBarFocused = false; })
  }

  @Builder
  buildAlphabetKbd() {
    Grid() {
      ForEach(KBD_R1_L, (key: string) => {
        GridItem() {
          KeyButton({ label: key, onPress: () => { this.appendChar(key); } })
        }
      }, (key: string) => key)

      ForEach(KBD_R2_L, (key: string) => {
        GridItem() {
          KeyButton({ label: key, onPress: () => { this.appendChar(key); } })
        }
      }, (key: string) => key)

      GridItem() {
        ActionKey({
          label: '\uD83D\uDDD1',
          bgColor: '#3A2525',
          focusBgColor: '#356DAE',
          focusPressBgColor: '#2C5C96',
          hoverBgColor: '#4A2F2F',
          activeBgColor: '#2E1E1E',
          keyBorderColor: '#E06070',
          keyFocusColor: '#4A9FFF',
          hoverBorderColor: '#F07B89',
          activeBorderColor: '#C95463',
          labelColor: C_CLEAR_ICON,
          labelFontSize: 22,
          onPress: () => { this.clearSearch(); }
        })
      }

      ForEach(KBD_R3_L, (key: string) => {
        GridItem() {
          KeyButton({ label: key, onPress: () => { this.appendChar(key); } })
        }
      }, (key: string) => key)

      GridItem() {
        ActionKey({
          label: '\u232B',
          sublabel: '退格',
          keyAspect: 352 / 60,
          onPress: () => { this.deleteLastChar(); }
        })
      }
      .columnStart(7)
      .columnEnd(9)
    }
    .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr')
    .columnsGap(8)
    .rowsGap(8)
  }

  @Builder
  buildNumericKbd() {
    Grid() {
      ForEach([...KBD_R1_R, ...KBD_R2_R], (key: string) => {
        GridItem() {
          KeyButton({ label: key, onPress: () => { this.appendChar(key); } })
        }
      })

      GridItem() {
        KeyButton({ label: '9', onPress: () => { this.appendChar('9'); } })
      }

      GridItem() {
        ActionKey({
          label: '0',
          keyAspect: 352 / 60,
          onPress: () => { this.appendChar('0'); }
        })
      }
      .columnStart(1)
      .columnEnd(3)
    }
    .columnsTemplate('1fr 1fr 1fr 1fr')
    .columnsGap(8)
    .rowsGap(8)
    .width("40%")
  }

  @Builder
  buildKeyboard() {
    Flex({ space: {
      main: LengthMetrics.vp(50)
    } }) {
      this.buildAlphabetKbd()
      this.buildNumericKbd()
      // 防抖 800ms 自动触发搜索
    }
    .alignSelf(ItemAlign.Center)
    .width('90%')
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
                this.executeSearchWithHistory();
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
  buildResultsPreview() {
    if (this.searchResults.length > 0) {
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(this.searchResults, (item: MediaItem) => {
          WorkspacePosterCard({
            item: item,
            onPress: () => { this.navigateToDetail(item); }
          })
          .margin({ right: 20, bottom: 20 })
        }, (item: MediaItem) => String(item.id))
      }
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
          this.buildHistory()
          this.buildResultsPreview()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.Start)
        .padding(20)
        .backgroundColor(C_PAGE_BG)
      }
      .scrollable(ScrollDirection.Vertical)
      .width('100%')
      .height('100%')
      .align(Alignment.TopStart)
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

