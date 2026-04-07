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

const MOVIE_SORT_OPTIONS: StringOption[] = [
  { label: '综合', value: 'composite' },
  { label: '评分最高', value: 'rating' },
  { label: '年份', value: 'year' },
  { label: '名称', value: 'title' },
];
const TV_SORT_OPTIONS: StringOption[] = [
  { label: '综合', value: 'composite' },
  { label: '评分最高', value: 'rating' },
  { label: '首播年份', value: 'year' },
  { label: '名称', value: 'title' },
];


interface YearOption {
  label: string;
  from: number;
  to: number;
}
const DECADE_OPTIONS: YearOption[] = [
  { label: '全部', from: 0, to: 0 },
  { label: '2020s', from: 2020, to: 2029 },
  { label: '2010s', from: 2010, to: 2019 },
  { label: '2000s', from: 2000, to: 2009 },
  { label: '1990s', from: 1990, to: 1999 },
  { label: '更早', from: 1900, to: 1989 },
];

interface RatingOption {
  label: string;
  value: number;
}
const RATING_OPTIONS: RatingOption[] = [
  { label: '全部评分', value: 0 },
  { label: '8分+', value: 8 },
  { label: '7分+', value: 7 },
  { label: '6分+', value: 6 },
];

const MOVIE_PROGRESS_OPTIONS: StringOption[] = [
  { label: '全部进度', value: '' },
  { label: '未看', value: 'unseen' },
  { label: '未看完', value: 'partial' },
  { label: '已看完', value: 'done' },
];

const TV_PROGRESS_OPTIONS: StringOption[] = [
  { label: '全部进度', value: '' },
  { label: '未看', value: 'unseen' },
  { label: '追更中', value: 'partial' },
  { label: '已看完', value: 'done' },
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
    if (this.item.tvSeriesId !== undefined) {
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
// FilterChip — focusable filter chip with selected/focused visual states
// ─────────────────────────────────────────────────────────────────────────────

@ComponentV2
struct FilterChip {
  @Param label: string = '';
  @Param selected: boolean = false;
  @Event onPress: () => void = () => {};
  @Local isFocused: boolean = false;

  build() {
    Text(this.label)
      .fontSize(16)
      .fontWeight(this.selected ? 700 : 500)
      .fontColor(this.selected ? C_CHIP_SEL_TEXT : '#E6EDF5')
      .height(32)
      .padding({ left: 14, right: 14 })
      .backgroundColor(this.selected ? C_CHIP_SEL_BG : (this.isFocused ? '#353D4A' : C_COMPONENT_BG))
      .borderRadius(999)
      .border(this.isFocused ? { width: 2, color: C_SEL_BLUE } : { width: this.selected ? 0 : 1, color: C_BORDER })
      .animation({ duration: 140, curve: Curve.EaseInOut })
      .focusable(true)
      .onFocus(() => { this.isFocused = true; })
      .onBlur(() => { this.isFocused = false; })
      .onClick(() => { this.onPress(); })
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
  @Local filterYearLabel: string = '';     // '' | '2020s' | '2010s' | '2000s' | '1990s' | '更早'
  @Local filterRating: number = 0;         // 0 = 全部，6/7/8 = 对应最低分
  @Local filterProgress: string = '';      // '' | 'unseen' | 'partial' | 'done'
  @Local genreOptions: string[] = [];      // 从库中动态加载

  // ── Data state ────────────────────────────────────────────────────────────
  @Local results: MediaItem[] = [];
  @Local isLoading: boolean = false;
  @Local totalCount: number = 0;

  private db: FileSourceDatabase = FileSourceDatabase.getInstance();
  // 竞态保护：每次发起新请求时递增，回调中比对版本号，过期则丢弃
  private searchGeneration: number = 0;
  // 路由初始参数，用于 resetAll() 恢复入口语义
  private initialMediaType: string = '';
  private initialGenre: string = '';
  private initialPageTitle: string = '搜索结果';

  private getWatchProgressFilter(): 'unseen' | 'partial' | 'done' | undefined {
    if (this.filterProgress === 'unseen') { return 'unseen'; }
    if (this.filterProgress === 'partial') { return 'partial'; }
    if (this.filterProgress === 'done') { return 'done'; }
    return undefined;
  }

  /** 计算 Grid 高度，用于 Scroll 内 Grid 无法使用 layoutWeight 时的替代方案 */
  private calcGridHeight(): number {
    if (this.results.length === 0) { return 300; }
    const cols = 6;
    const rows = Math.ceil(this.results.length / cols);
    // ResultPosterCard: poster(270) + space(8) + title(~26) + score(~26) ≈ 330
    // rowsGap: 30
    return rows * (330 + 30) + 60;
  }

  // ── Data operations ───────────────────────────────────────────────────────

  private async doSearch(): Promise<void> {
    const generation = ++this.searchGeneration;
    this.isLoading = true;
    try {
      let mt: 'movie' | 'tv' | 'all' | undefined = undefined;
      if (this.filterMediaType === 'movie') { mt = 'movie'; }
      else if (this.filterMediaType === 'tv') { mt = 'tv'; }

      // 排序映射：composite → rating（综合排序以评分为主）
      let sb: 'rating' | 'year' | 'title' = 'rating';
      if (this.filterSort === 'rating') { sb = 'rating'; }
      else if (this.filterSort === 'year') { sb = 'year'; }
      else if (this.filterSort === 'title') { sb = 'title'; }

      // 年份筛选：年代区间
      let yearFrom: number | undefined = undefined;
      let yearTo: number | undefined = undefined;
      const decade = DECADE_OPTIONS.find(d => d.label === this.filterYearLabel);
      if (decade !== undefined && decade.from > 0) {
        yearFrom = decade.from;
        yearTo = decade.to;
      }

      const options: SearchMediaOptions = {
        mediaType: mt,
        genre: this.filterGenre.length > 0 ? this.filterGenre : undefined,
        yearFrom,
        yearTo,
        sortBy: sb,
        limit: 200,
        minRating: this.filterRating > 0 ? this.filterRating : undefined,
        watchProgress: this.getWatchProgressFilter(),
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

  // ── Filter option getters ─────────────────────────────────────────────────

  private async loadGenreOptions(): Promise<void> {
    let mt: 'movie' | 'tv' | undefined = undefined;
    if (this.filterMediaType === 'movie') { mt = 'movie'; }
    else if (this.filterMediaType === 'tv') { mt = 'tv'; }
    const names = await this.db.getDistinctGenreNames(mt);
    this.genreOptions = names;
  }

  private getGenreList(): string[] {
    const list: string[] = ['全部'];
    for (const g of this.genreOptions) {
      list.push(g);
    }
    return list;
  }

  private getSortOptions(): StringOption[] {
    return this.filterMediaType === 'tv' ? TV_SORT_OPTIONS : MOVIE_SORT_OPTIONS;
  }

  // ── Label helpers ─────────────────────────────────────────────────────────

  private resetAll(): void {
    this.filterMediaType = this.initialMediaType;
    this.filterGenre = this.initialGenre;
    this.filterYearLabel = '';
    this.filterRating = 0;
    this.filterProgress = '';
    this.filterSort = 'composite';
    this.pageTitle = this.initialPageTitle;
    this.doSearch().catch((): void => {});
  }

  private summaryText(): string {
    const parts: string[] = [];
    if (this.filterMediaType === 'movie') { parts.push('电影'); }
    else if (this.filterMediaType === 'tv') { parts.push('电视剧'); }
    if (this.filterGenre.length > 0) { parts.push(this.filterGenre); }
    if (this.filterYearLabel.length > 0) { parts.push(this.filterYearLabel); }
    if (this.filterRating > 0) { parts.push(this.filterRating.toString() + '分+'); }
    if (this.filterProgress === 'unseen') { parts.push('未看'); }
    else if (this.filterProgress === 'partial') { parts.push(this.filterMediaType === 'tv' ? '追更中' : '未看完'); }
    else if (this.filterProgress === 'done') { parts.push('已看完'); }
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
  buildFilterPanel() {
    Column({ space: 0 }) {
      // 行1：内容类型
      Row() {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(['', 'movie', 'tv'], (val: string) => {
              FilterChip({
                label: val === '' ? '全部内容' : (val === 'movie' ? '电影' : '电视剧'),
                selected: this.filterMediaType === val,
                onPress: () => {
                  this.filterMediaType = val;
                  this.filterGenre = '';
                  this.filterProgress = '';
                  if (val === 'movie') { this.pageTitle = '全部电影'; }
                  else if (val === 'tv') { this.pageTitle = '全部电视剧'; }
                  else { this.pageTitle = '全部内容'; }
                  this.loadGenreOptions().catch((): void => {});
                  this.doSearch().catch((): void => {});
                }
              })
            }, (val: string) => 'ct_' + val + '_' + this.filterMediaType)
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
            ForEach(this.getSortOptions(), (opt: StringOption) => {
              FilterChip({
                label: opt.label,
                selected: this.filterSort === opt.value,
                onPress: () => {
                  this.filterSort = opt.value;
                  this.doSearch().catch((): void => {});
                }
              })
            }, (opt: StringOption) => 'sort_' + opt.value + '_' + this.filterSort + '_' + this.filterMediaType)
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
            ForEach(this.getGenreList(), (g: string) => {
              FilterChip({
                label: g === '全部' ? '全部类型' : g,
                selected: g === '全部' ? this.filterGenre === '' : this.filterGenre === g,
                onPress: () => {
                  this.filterGenre = (g === '全部') ? '' : g;
                  this.doSearch().catch((): void => {});
                }
              })
            }, (g: string) => 'genre_' + g + '_' + this.filterGenre + '_' + this.filterMediaType)
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

      // 行4：年代区间
      Row() {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(DECADE_OPTIONS, (d: YearOption) => {
              FilterChip({
                label: d.label === '全部' ? '全部年份' : d.label,
                selected: this.filterYearLabel === d.label || (d.label === '全部' && this.filterYearLabel === ''),
                onPress: () => {
                  this.filterYearLabel = d.label === '全部' ? '' : d.label;
                  this.doSearch().catch((): void => {});
                }
              })
            }, (d: YearOption) => 'year_' + d.label + '_' + this.filterYearLabel)
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

      // 行5：评分筛选
      Row() {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(RATING_OPTIONS, (r: RatingOption) => {
              FilterChip({
                label: r.label,
                selected: this.filterRating === r.value,
                onPress: () => {
                  this.filterRating = r.value;
                  this.doSearch().catch((): void => {});
                }
              })
            }, (r: RatingOption) => 'rating_' + r.value.toString() + '_' + this.filterRating.toString())
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

      // 行6：观看进度（仅当 filterMediaType !== '' 时显示）
      if (this.filterMediaType !== '') {
        Divider().color('#3A3A3A').height(1)

        Row() {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(
                this.filterMediaType === 'movie' ? MOVIE_PROGRESS_OPTIONS : TV_PROGRESS_OPTIONS,
                (opt: StringOption) => {
                  FilterChip({
                    label: opt.label,
                    selected: this.filterProgress === opt.value,
                    onPress: () => {
                      this.filterProgress = opt.value;
                      this.doSearch().catch((): void => {});
                    }
                  })
                },
                (opt: StringOption) => 'prog_' + opt.value + '_' + this.filterProgress + '_' + this.filterMediaType
              )
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
      .width('100%')
      .height(300)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else if (this.results.length === 0) {
      Column() {
        Text('\u6682\u65E0\u7ED3\u679C')
          .fontSize(18)
          .fontColor(C_SECONDARY)
      }
      .width('100%')
      .height(300)
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
      .height(this.calcGridHeight())
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    }
  }

  build() {
    NavDestination() {
      Column() {
        // 标题栏固定，不随内容滚动
        this.buildHeader()

        // FilterPanel + 结果列表整体滚动
        Scroll() {
          Column({ space: 20 }) {
            this.buildFilterPanel()
            // summary：有筛选条件时显示当前条件
            if (this.filterMediaType !== '' || this.filterGenre !== '' || this.filterYearLabel !== '' || this.filterRating > 0 || this.filterProgress !== '') {
              Text(this.summaryText())
                .fontSize(16)
                .fontColor(C_SECONDARY)
                .width('100%')
            }
            this.buildResultGrid()
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
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
        // 保存入口初始值，resetAll() 时恢复入口语义而非全部清空
        this.initialMediaType = this.filterMediaType;
        this.initialGenre = this.filterGenre;
        this.initialPageTitle = this.pageTitle;
      }
      this.loadGenreOptions().catch((): void => {});
      this.doSearch().catch((): void => {});
    })
    .hideTitleBar(true)
    .onBackPressed(() => {
      this.pageStack.pop();
      return true;
    })
  }
}
