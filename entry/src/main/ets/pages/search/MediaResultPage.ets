import { FileSourceDatabase, SearchMediaOptions } from '../../db/files/FileSourceDatabase';
import { MediaItem, SeriesGroup } from '../../db/models/MediaEntity';
import { MovieDetailPage } from '../detail/MovieDetailPage';
import { SeriesDetailPage } from '../detail/SeriesDetailPage';

// ─────────────────────────────────────────────────────────────────────────────
// Page param interface (for external route navigation)
// ─────────────────────────────────────────────────────────────────────────────

export interface MediaResultPageParam {
  keyword?: string;
  mediaType?: string;
  genre?: string;
  pageTitle?: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// Filter option types — avoid ArkTS inline-object-literal type errors
// ─────────────────────────────────────────────────────────────────────────────

interface StringOption {
  label: string;
  value: string;
}

interface NumberOption {
  label: string;
  value: number;
}

// ─────────────────────────────────────────────────────────────────────────────
// Filter option constants
// ─────────────────────────────────────────────────────────────────────────────

const SORT_OPTIONS: StringOption[] = [
  { label: '\u7EFC\u5408\u6392\u5E8F', value: 'title' },
  { label: '\u8BC4\u5206\u6700\u9AD8', value: 'rating' },
  { label: '\u6700\u65B0\u4E0A\u6620', value: 'year' },
];

// ─────────────────────────────────────────────────────────────────────────────
// Design Token Constants — strictly follows Pencil vidall_pages.pen
// ─────────────────────────────────────────────────────────────────────────────

const C_PAGE_BG: string = '#232425';
const C_COMPONENT_BG: string = '#2C3138';
const C_SEL_BLUE: string = '#3B77D4';
const C_BORDER: string = '#464E58';
const C_TEXT_TITLE: string = '#EAF3FF';
const C_TEXT_BODY: string = '#DDE4EE';
const C_SECONDARY: string = '#8E96A3';
const C_ICON: string = '#AAB4C3';
const C_CHIP_DEFAULT_TEXT: string = '#E6EDF5';
const C_CHIP_WEAK_TEXT: string = '#B8C1CD';
const TRANSPARENT: string = '#00000000';

// ─────────────────────────────────────────────────────────────────────────────
// Module-level helpers
// ─────────────────────────────────────────────────────────────────────────────

function scoreColor(r: number | undefined): string {
  if (r === undefined || r <= 0) { return '#8E96A3'; }
  if (r >= 8.5) { return '#F7C06C'; }
  if (r >= 8.0) { return '#F6B85F'; }
  if (r >= 7.0) { return '#E6786C'; }
  return '#D0A26B';
}

function itemTitle(item: MediaItem): string {
  return item.title ?? item.fileName ?? '';
}

function itemPosterSrc(item: MediaItem): string {
  if (item.posterLocalPath !== undefined && item.posterLocalPath.length > 0) {
    return 'file://' + item.posterLocalPath;
  }
  return item.posterUrl ?? '';
}

function itemHasPoster(item: MediaItem): boolean {
  return (item.posterLocalPath !== undefined && item.posterLocalPath.length > 0) ||
    (item.posterUrl !== undefined && item.posterUrl.length > 0);
}

function scoreText(r: number | undefined): string {
  if (r === undefined || r <= 0) { return ''; }
  return r.toFixed(1);
}

// ─────────────────────────────────────────────────────────────────────────────
// ResultPosterCard — card for the 6-column result grid
// ─────────────────────────────────────────────────────────────────────────────

@ComponentV2
struct ResultPosterCard {
  @Require @Param item: MediaItem;
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local isFocused: boolean = false;

  private navigateToDetail(): void {
    if (this.item.mediaType === 'tv') {
      const group: SeriesGroup = {
        title: itemTitle(this.item),
        tvSeriesId: this.item.tvSeriesId,
        posterUrl: this.item.posterUrl,
        posterLocalPath: this.item.posterLocalPath,
        backdropUrl: this.item.backdropUrl,
        rating: this.item.rating,
        episodeCount: 0,
        episodes: [this.item],
        latestScannedAt: this.item.scannedAt ?? 0,
      };
      this.pageStack.pushPathByName(SeriesDetailPage.PAGE_NAME, group);
    } else {
      this.pageStack.pushPathByName(MovieDetailPage.PAGE_NAME, this.item);
    }
  }

  build() {
    Column({ space: 8 }) {
      Stack() {
        if (itemHasPoster(this.item)) {
          Image(itemPosterSrc(this.item))
            .width(180)
            .height(270)
            .objectFit(ImageFit.Cover)
        } else {
          Column() {
            Text(itemTitle(this.item))
              .fontSize(13)
              .fontColor('#CCCCCC')
              .textAlign(TextAlign.Center)
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding(8)
          }
          .width(180)
          .height(270)
          .backgroundColor('#2A2A2A')
          .justifyContent(FlexAlign.Center)
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
      .animation({ duration: 140, curve: Curve.EaseOut })

      Text(itemTitle(this.item))
        .fontSize(22)
        .fontColor('#E3E7ED')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(180)

      if (scoreText(this.item.rating).length > 0) {
        Text(scoreText(this.item.rating))
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
    .onClick(() => { this.navigateToDetail(); })
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MediaResultPage — generic search result page (TV vertical layout)
// ─────────────────────────────────────────────────────────────────────────────

@ComponentV2
export struct MediaResultPage {
  static readonly PAGE_NAME: string = 'MediaResultPage';

  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();

  // ── Page state ────────────────────────────────────────────────────────────
  @Local pageTitle: string = '\u641C\u7D22\u7ED3\u679C';
  @Local keyword: string = '';

  // ── Filter state ──────────────────────────────────────────────────────────
  @Local filterMediaType: string = '';   // '' | 'movie' | 'tv'
  @Local filterGenre: string = '';
  @Local filterRating: number = 0;       // 0 = none, 7 = 7+, 8 = 8+
  @Local filterYear: string = '';        // '' | '2020' | '2010' | '2000' | '1990'
  @Local filterSort: string = 'title';   // 'title' | 'rating' | 'year'

  // ── Data state ────────────────────────────────────────────────────────────
  @Local results: MediaItem[] = [];
  @Local isLoading: boolean = false;
  @Local totalCount: number = 0;

  private db: FileSourceDatabase = FileSourceDatabase.getInstance();

  // ── Data operations ───────────────────────────────────────────────────────

  private async doSearch(): Promise<void> {
    this.isLoading = true;
    this.results = [];
    try {
      let mt: 'movie' | 'tv' | 'all' | undefined = undefined;
      if (this.filterMediaType === 'movie') { mt = 'movie'; }
      else if (this.filterMediaType === 'tv') { mt = 'tv'; }

      let sb: 'rating' | 'year' | 'title' = 'title';
      if (this.filterSort === 'rating') { sb = 'rating'; }
      else if (this.filterSort === 'year') { sb = 'year'; }

      const yearNum: number | undefined = this.filterYear.length > 0
        ? parseInt(this.filterYear, 10)
        : undefined;

      const options: SearchMediaOptions = {
        mediaType: mt,
        genre: this.filterGenre.length > 0 ? this.filterGenre : undefined,
        minRating: this.filterRating > 0 ? this.filterRating : undefined,
        year: yearNum,
        sortBy: sb,
        limit: 200,
      };

      const items: MediaItem[] = await this.db.searchMediaItems(this.keyword, options);
      this.results = items;
      this.totalCount = items.length;
    } catch {
      this.results = [];
      this.totalCount = 0;
    } finally {
      this.isLoading = false;
    }
  }

  // ── Filter cycle helpers (TV-friendly: no dropdown needed, click to cycle) ─

  private cycleMediaType(): void {
    if (this.filterMediaType === '') { this.filterMediaType = 'movie'; }
    else if (this.filterMediaType === 'movie') { this.filterMediaType = 'tv'; }
    else { this.filterMediaType = ''; }
    this.doSearch().catch((): void => {});
  }

  private cycleRating(): void {
    if (this.filterRating === 0) { this.filterRating = 8; }
    else if (this.filterRating === 8) { this.filterRating = 7; }
    else { this.filterRating = 0; }
    this.doSearch().catch((): void => {});
  }

  private cycleYear(): void {
    const opts: string[] = ['', '2020', '2010', '2000', '1990'];
    const idx: number = opts.indexOf(this.filterYear);
    this.filterYear = opts[(idx + 1) % opts.length];
    this.doSearch().catch((): void => {});
  }

  private cycleSort(): void {
    if (this.filterSort === 'title') { this.filterSort = 'rating'; }
    else if (this.filterSort === 'rating') { this.filterSort = 'year'; }
    else { this.filterSort = 'title'; }
    this.doSearch().catch((): void => {});
  }

  private resetAll(): void {
    this.filterMediaType = '';
    this.filterRating = 0;
    this.filterYear = '';
    this.filterSort = 'title';
    this.doSearch().catch((): void => {});
  }

  // ── Label helpers ─────────────────────────────────────────────────────────

  private mediaTypeLabel(): string {
    if (this.filterMediaType === 'movie') { return '\u7535\u5F71'; }
    if (this.filterMediaType === 'tv') { return '\u5267\u96C6'; }
    return '\u7C7B\u578B';
  }

  private ratingLabel(): string {
    if (this.filterRating === 8) { return '8\u5206+'; }
    if (this.filterRating === 7) { return '7\u5206+'; }
    return '\u8BC4\u5206';
  }

  private yearLabel(): string {
    if (this.filterYear === '2020') { return '2020s'; }
    if (this.filterYear === '2010') { return '2010s'; }
    if (this.filterYear === '2000') { return '2000s'; }
    if (this.filterYear === '1990') { return '1990s'; }
    return '\u5E74\u4EE3';
  }

  private sortLabel(): string {
    const opt: StringOption | undefined = SORT_OPTIONS.find((o: StringOption) => o.value === this.filterSort);
    return opt !== undefined ? opt.label : '\u7EFC\u5408\u6392\u5E8F';
  }

  private summaryText(): string {
    const parts: string[] = ['\u5168\u90E8'];
    if (this.filterMediaType === 'movie') { parts.push('\u7535\u5F71'); }
    else if (this.filterMediaType === 'tv') { parts.push('\u5267\u96C6'); }
    if (this.filterRating > 0) { parts.push(this.filterRating.toString() + '\u5206+'); }
    if (this.filterYear.length > 0) { parts.push(this.filterYear + 's'); }
    return parts.join(' \u00B7 ');
  }

  // ── Chip style helpers ────────────────────────────────────────────────────

  private isAllDefault(): boolean {
    return this.filterMediaType === '' && this.filterRating === 0 && this.filterYear === '';
  }

  private chipBg(key: string): string {
    if (key === 'all') { return this.isAllDefault() ? C_SEL_BLUE : C_COMPONENT_BG; }
    if (key === 'mediaType') { return this.filterMediaType !== '' ? C_SEL_BLUE : C_COMPONENT_BG; }
    if (key === 'rating') { return this.filterRating > 0 ? C_SEL_BLUE : C_COMPONENT_BG; }
    if (key === 'year') { return this.filterYear !== '' ? C_SEL_BLUE : C_COMPONENT_BG; }
    return C_COMPONENT_BG;
  }

  private chipTextColor(key: string): string {
    if (key === 'more') { return C_CHIP_WEAK_TEXT; }
    if (key === 'all') { return this.isAllDefault() ? C_TEXT_TITLE : C_CHIP_DEFAULT_TEXT; }
    if (key === 'mediaType') { return this.filterMediaType !== '' ? C_TEXT_TITLE : C_CHIP_DEFAULT_TEXT; }
    if (key === 'rating') { return this.filterRating > 0 ? C_TEXT_TITLE : C_CHIP_DEFAULT_TEXT; }
    if (key === 'year') { return this.filterYear !== '' ? C_TEXT_TITLE : C_CHIP_DEFAULT_TEXT; }
    return C_CHIP_DEFAULT_TEXT;
  }

  private chipFw(key: string): number {
    if (key === 'more') { return 500; }
    if (key === 'all') { return this.isAllDefault() ? 700 : 600; }
    if (key === 'mediaType') { return this.filterMediaType !== '' ? 700 : 600; }
    if (key === 'rating') { return this.filterRating > 0 ? 700 : 600; }
    if (key === 'year') { return this.filterYear !== '' ? 700 : 600; }
    return 600;
  }

  private chipBorderColor(key: string): string {
    if (key === 'all' && this.isAllDefault()) { return TRANSPARENT; }
    if (key === 'mediaType' && this.filterMediaType !== '') { return TRANSPARENT; }
    if (key === 'rating' && this.filterRating > 0) { return TRANSPARENT; }
    if (key === 'year' && this.filterYear !== '') { return TRANSPARENT; }
    return C_BORDER;
  }

  // ── @Builder sections ─────────────────────────────────────────────────────

  @Builder
  buildBackRow() {
    Row() {
      Row() {
        Text('\u2039')
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
  buildHeader() {
    Row() {
      Column({ space: 8 }) {
        Text(this.pageTitle)
          .fontSize(34)
          .fontWeight(700)
          .fontColor(C_TEXT_TITLE)
        Text('\u5171 ' + this.totalCount.toString() + ' \u90E8\u5185\u5BB9')
          .fontSize(18)
          .fontWeight(500)
          .fontColor(C_SECONDARY)
      }
      .alignItems(HorizontalAlign.Start)

      // Sort box
      Row({ space: 8 }) {
        Text(this.sortLabel())
          .fontSize(18)
          .fontWeight(600)
          .fontColor(C_TEXT_BODY)
        Text('\u2304')
          .fontSize(18)
          .fontColor(C_ICON)
      }
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .backgroundColor(C_COMPONENT_BG)
      .borderRadius(12)
      .border({ width: 1, color: C_BORDER })
      .alignItems(VerticalAlign.Center)
      .focusable(true)
      .onClick(() => { this.cycleSort(); })
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Bottom)
  }

  @Builder
  buildFilterChips() {
    Row({ space: 10 }) {
      // Chip 1: All — resets all filters
      Text('\u5168\u90E8')
        .fontSize(16)
        .fontWeight(this.chipFw('all'))
        .fontColor(this.chipTextColor('all'))
        .height(36)
        .padding({ left: 14, right: 14 })
        .backgroundColor(this.chipBg('all'))
        .borderRadius(999)
        .border({ width: 1, color: this.chipBorderColor('all') })
        .focusable(true)
        .onClick(() => { this.resetAll(); })

      // Chip 2: Media type (cycle: all→movie→tv)
      Text(this.mediaTypeLabel())
        .fontSize(16)
        .fontWeight(this.chipFw('mediaType'))
        .fontColor(this.chipTextColor('mediaType'))
        .height(36)
        .padding({ left: 14, right: 14 })
        .backgroundColor(this.chipBg('mediaType'))
        .borderRadius(999)
        .border({ width: 1, color: this.chipBorderColor('mediaType') })
        .focusable(true)
        .onClick(() => { this.cycleMediaType(); })

      // Chip 3: Rating (cycle: none→8+→7+)
      Text(this.ratingLabel())
        .fontSize(16)
        .fontWeight(this.chipFw('rating'))
        .fontColor(this.chipTextColor('rating'))
        .height(36)
        .padding({ left: 14, right: 14 })
        .backgroundColor(this.chipBg('rating'))
        .borderRadius(999)
        .border({ width: 1, color: this.chipBorderColor('rating') })
        .focusable(true)
        .onClick(() => { this.cycleRating(); })

      // Chip 4: Year (cycle: none→2020→2010→2000→1990)
      Text(this.yearLabel())
        .fontSize(16)
        .fontWeight(this.chipFw('year'))
        .fontColor(this.chipTextColor('year'))
        .height(36)
        .padding({ left: 14, right: 14 })
        .backgroundColor(this.chipBg('year'))
        .borderRadius(999)
        .border({ width: 1, color: this.chipBorderColor('year') })
        .focusable(true)
        .onClick(() => { this.cycleYear(); })

      // Chip 5: More filters (weakened, decorative for now)
      Text('\u66F4\u591A\u7B5B\u9009')
        .fontSize(16)
        .fontWeight(this.chipFw('more'))
        .fontColor(this.chipTextColor('more'))
        .height(36)
        .padding({ left: 14, right: 14 })
        .backgroundColor(C_COMPONENT_BG)
        .borderRadius(999)
        .border({ width: 1, color: C_BORDER })
        .focusable(true)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  buildSummary() {
    Text(this.summaryText())
      .fontSize(16)
      .fontWeight(500)
      .fontColor(C_SECONDARY)
      .width('100%')
  }

  @Builder
  buildResultGrid() {
    if (this.isLoading) {
      Column() {
        Text('\u52A0\u8F7D\u4E2D\u2026')
          .fontSize(18)
          .fontColor(C_SECONDARY)
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else if (this.results.length === 0) {
      Column() {
        Text('\u6682\u65E0\u7ED3\u679C')
          .fontSize(18)
          .fontColor(C_SECONDARY)
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else {
      Grid() {
        ForEach(this.results, (item: MediaItem) => {
          GridItem() {
            ResultPosterCard({ item: item })
          }
        }, (item: MediaItem) => String(item.id))
      }
      .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr')
      .columnsGap(30)
      .rowsGap(30)
      .width('100%')
      .layoutWeight(1)
    }
  }

  build() {
    NavDestination() {
      Column({ space: 26 }) {
        this.buildBackRow()
        this.buildHeader()
        this.buildFilterChips()
        this.buildSummary()
        this.buildResultGrid()
      }
      .width('100%')
      .height('100%')
      .padding(20)
      .backgroundColor(C_PAGE_BG)
    }
    .hideTitleBar(true)
    .onReady((context: NavDestinationContext) => {
      const param = context.pathInfo.param as MediaResultPageParam;
      if (param !== undefined && param !== null) {
        this.pageTitle = param.pageTitle ?? '\u641C\u7D22\u7ED3\u679C';
        this.keyword = param.keyword ?? '';
        this.filterMediaType = param.mediaType ?? '';
        this.filterGenre = param.genre ?? '';
      }
      this.doSearch().catch((): void => {});
    })
    .onBackPressed(() => {
      this.pageStack.pop();
      return true;
    })
  }
}
