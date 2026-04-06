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
  minRating?: number;
  decadeYear?: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// Filter option types — avoid ArkTS inline-object-literal type errors
// ─────────────────────────────────────────────────────────────────────────────

interface StringOption {
  label: string;
  value: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// Filter option constants
// ─────────────────────────────────────────────────────────────────────────────

const SORT_OPTIONS: StringOption[] = [
  { label: '综合', value: 'composite' },
  { label: '评分最高', value: 'rating' },
  { label: '首播年份', value: 'year' },
  { label: '名称', value: 'title' },
];

const GENRE_OPTIONS: string[] = ['全部', '古装', '都市', '爱情', '剧情', '悬疑', '喜剧', '动作', '科幻', '奇幻'];

function buildYearOptions(): string[] {
  const opts: string[] = ['全部'];
  const cur = new Date().getFullYear();
  for (let y = cur; y >= 2015; y--) {
    opts.push(y.toString());
  }
  return opts;
}
const YEAR_OPTIONS: string[] = buildYearOptions();

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
const C_ORANGE: string = '#E6892E';
const C_FILTER_BG: string = '#2B2B2B';
const C_CHIP_SEL_BG: string = '#E6892E';
const C_CHIP_SEL_TEXT: string = '#FFFFFF';
const C_LABEL_TEXT: string = '#FFFFFF';

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
  @Local filterMediaType: string = '';    // '' | 'movie' | 'tv'
  @Local filterSort: string = 'composite'; // 'composite' | 'rating' | 'year' | 'title'
  @Local filterGenre: string = '';         // '' 或具体流派
  @Local filterYear: string = '';          // '' 或具体年份如 '2024'

  // ── Data state ────────────────────────────────────────────────────────────
  @Local results: MediaItem[] = [];
  @Local isLoading: boolean = false;
  @Local totalCount: number = 0;

  private db: FileSourceDatabase = FileSourceDatabase.getInstance();
  // 竞态保护：每次发起新请求时递增，回调中比对版本号，过期则丢弃
  private searchGeneration: number = 0;

  // ── Data operations ───────────────────────────────────────────────────────

  private async doSearch(): Promise<void> {
    const generation = ++this.searchGeneration;
    this.isLoading = true;
    try {
      let mt: 'movie' | 'tv' | 'all' | undefined = undefined;
      if (this.filterMediaType === 'movie') { mt = 'movie'; }
      else if (this.filterMediaType === 'tv') { mt = 'tv'; }

      // 排序映射：composite → title（DB 没有单独的 composite 排序，用 title 做默认）
      let sb: 'rating' | 'year' | 'title' = 'title';
      if (this.filterSort === 'rating') { sb = 'rating'; }
      else if (this.filterSort === 'year') { sb = 'year'; }

      // 年份筛选：精确年份（不再是年代区间）
      let yearFrom: number | undefined = undefined;
      let yearTo: number | undefined = undefined;
      if (this.filterYear.length > 0) {
        const y = parseInt(this.filterYear, 10);
        if (!isNaN(y)) { yearFrom = y; yearTo = y; }
      }

      const options: SearchMediaOptions = {
        mediaType: mt,
        genre: this.filterGenre.length > 0 ? this.filterGenre : undefined,
        yearFrom,
        yearTo,
        sortBy: sb,
        limit: 200,
      };

      const items: MediaItem[] = await this.db.searchMediaItems(this.keyword, options);
      if (generation !== this.searchGeneration) { return; } // 丢弃过期结果
      this.results = items;
      this.totalCount = items.length;
    } catch {
      if (generation !== this.searchGeneration) { return; }
      this.results = [];
      this.totalCount = 0;
    } finally {
      if (generation === this.searchGeneration) {
        this.isLoading = false;
      }
    }
  }

  // ── Label helpers ─────────────────────────────────────────────────────────

  private resetAll(): void {
    this.filterMediaType = '';
    this.filterGenre = '';
    this.filterYear = '';
    this.filterSort = 'composite';
    this.doSearch().catch((): void => {});
  }

  private summaryText(): string {
    const parts: string[] = [];
    if (this.filterMediaType === 'movie') { parts.push('电影'); }
    else if (this.filterMediaType === 'tv') { parts.push('电视剧'); }
    if (this.filterGenre.length > 0) { parts.push(this.filterGenre); }
    if (this.filterYear.length > 0) { parts.push(this.filterYear); }
    if (parts.length === 0) { return ''; }
    return '当前条件：' + parts.join(' / ');
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
          .fontSize(36)
          .fontWeight(700)
          .fontColor(C_TEXT_TITLE)
        Text('共 ' + this.totalCount.toString() + ' 项，可按类型、年份继续缩小范围')
          .fontSize(18)
          .fontWeight(500)
          .fontColor(C_SECONDARY)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 重置筛选 badge
      Text('重置筛选')
        .fontSize(16)
        .fontColor('#FFFFFF')
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .backgroundColor(C_ORANGE)
        .borderRadius(8)
        .focusable(true)
        .onClick(() => { this.resetAll(); })
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  buildChip(label: string, isSelected: boolean, onTap: () => void) {
    Text(label)
      .fontSize(16)
      .fontWeight(isSelected ? 700 : 500)
      .fontColor(isSelected ? C_CHIP_SEL_TEXT : '#E6EDF5')
      .height(32)
      .padding({ left: 14, right: 14 })
      .backgroundColor(isSelected ? C_CHIP_SEL_BG : C_COMPONENT_BG)
      .borderRadius(999)
      .border({ width: isSelected ? 0 : 1, color: C_BORDER })
      .focusable(true)
      .onClick(onTap)
  }

  @Builder
  buildFilterPanel() {
    Column({ space: 0 }) {
      // 行1：内容类型
      Row() {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(['', 'movie', 'tv'], (val: string) => {
              this.buildChip(
                val === '' ? '全部内容' : (val === 'movie' ? '电影' : '电视剧'),
                this.filterMediaType === val,
                () => {
                  this.filterMediaType = val;
                  this.doSearch().catch((): void => {});
                }
              )
            }, (val: string) => 'ct_' + val)
          }
          .padding({ left: 12, right: 12 })
          .justifyContent(FlexAlign.Start)
          .alignItems(VerticalAlign.Center)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .height(48)
        .align(Alignment.Start)
      }
      .width('100%')
      .height(48)
      .alignItems(VerticalAlign.Center)

      Divider().color('#3A3A3A').height(1)

      // 行2：排序
      Row() {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(SORT_OPTIONS, (opt: StringOption) => {
              this.buildChip(opt.label, this.filterSort === opt.value, () => {
                this.filterSort = opt.value;
                this.doSearch().catch((): void => {});
              })
            }, (opt: StringOption) => 'sort_' + opt.value)
          }
          .padding({ left: 12, right: 12 })
          .justifyContent(FlexAlign.Start)
          .alignItems(VerticalAlign.Center)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .height(48)
        .align(Alignment.Start)
      }
      .width('100%')
      .height(48)
      .alignItems(VerticalAlign.Center)

      Divider().color('#3A3A3A').height(1)

      // 行3：类型（流派）
      Row() {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(GENRE_OPTIONS, (g: string) => {
              this.buildChip(g === '全部' ? '全部类型' : g, (g === '全部' ? this.filterGenre === '' : this.filterGenre === g), () => {
                this.filterGenre = (g === '全部') ? '' : g;
                this.doSearch().catch((): void => {});
              })
            }, (g: string) => 'genre_' + g)
          }
          .padding({ left: 12, right: 12 })
          .justifyContent(FlexAlign.Start)
          .alignItems(VerticalAlign.Center)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .height(48)
        .align(Alignment.Start)
      }
      .width('100%')
      .height(48)
      .alignItems(VerticalAlign.Center)

      Divider().color('#3A3A3A').height(1)

      // 行4：年份
      Row() {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(YEAR_OPTIONS, (y: string) => {
              this.buildChip(y === '全部' ? '全部年份' : y, (y === '全部' ? this.filterYear === '' : this.filterYear === y), () => {
                this.filterYear = (y === '全部') ? '' : y;
                this.doSearch().catch((): void => {});
              })
            }, (y: string) => 'year_' + y)
          }
          .padding({ left: 12, right: 12 })
          .justifyContent(FlexAlign.Start)
          .alignItems(VerticalAlign.Center)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .height(48)
        .align(Alignment.Start)
      }
      .width('100%')
      .height(48)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor(C_FILTER_BG)
    .borderRadius(12)
    .clip(true)
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
      Column({ space: 20 }) {
        this.buildBackRow()
        this.buildHeader()
        this.buildFilterPanel()
        // summary 可简化为一行文字（当有筛选时显示当前条件）
        if (this.filterMediaType !== '' || this.filterGenre !== '' || this.filterYear !== '') {
          Text(this.summaryText())
            .fontSize(16)
            .fontColor(C_SECONDARY)
            .width('100%')
        }
        this.buildResultGrid()
      }
      .width('100%')
      .height('100%')
      .padding(20)
      .backgroundColor(C_PAGE_BG)
    }
    .onReady((context: NavDestinationContext) => {
      const param = context.pathInfo.param as MediaResultPageParam;
      if (param !== undefined && param !== null) {
        this.pageTitle = param.pageTitle ?? '搜索结果';
        this.keyword = param.keyword ?? '';
        this.filterMediaType = param.mediaType ?? '';
        this.filterGenre = param.genre ?? '';
      }
      this.doSearch().catch((): void => {});
    })
    .hideTitleBar(true)
    .onBackPressed(() => {
      this.pageStack.pop();
      return true;
    })
  }
}
