import { FileSourceDatabase, SearchMediaOptions } from '../../db/files/FileSourceDatabase';
import { MediaItem, SeriesGroup } from '../../db/models/MediaEntity';
import { MovieDetailPage } from '../detail/MovieDetailPage';
import { SeriesDetailPage } from '../detail/SeriesDetailPage';

// ─────────────────────────────────────────────────────────────────────────────
// 页面参数接口（供外部路由传参）
// ─────────────────────────────────────────────────────────────────────────────

export interface MediaResultPageParam {
  keyword?: string;
  mediaType?: string;
  genre?: string;
  pageTitle?: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// 筛选选项类型（避免 Map<K, 内联接口> 的 ArkTS 告警）
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
// 筛选选项常量
// ─────────────────────────────────────────────────────────────────────────────

const MEDIA_TYPE_OPTIONS: StringOption[] = [
  { label: '全部', value: '' },
  { label: '电影', value: 'movie' },
  { label: '剧集', value: 'tv' },
];

const RATING_OPTIONS: NumberOption[] = [
  { label: '全部', value: 0 },
  { label: '8分+', value: 8 },
  { label: '6分+', value: 6 },
];

const YEAR_OPTIONS: StringOption[] = [
  { label: '全部', value: '' },
  { label: '2020s', value: '2020' },
  { label: '2010s', value: '2010' },
  { label: '2000s', value: '2000' },
  { label: '1990s', value: '1990' },
];

const SORT_OPTIONS: StringOption[] = [
  { label: '默认', value: 'title' },
  { label: '评分最高', value: 'rating' },
  { label: '最新上映', value: 'year' },
];

// ─────────────────────────────────────────────────────────────────────────────
// 模块级辅助函数（避免在 build() 内定义变量或复杂逻辑）
// ─────────────────────────────────────────────────────────────────────────────

function itemTitle(item: MediaItem): string {
  return item.title ?? item.fileName ?? '';
}

function itemHasPoster(item: MediaItem): boolean {
  return (item.posterLocalPath !== undefined && item.posterLocalPath.length > 0) ||
    (item.posterUrl !== undefined && item.posterUrl.length > 0);
}

function itemPosterSrc(item: MediaItem): string {
  if (item.posterLocalPath && item.posterLocalPath.length > 0) {
    return item.posterLocalPath;
  }
  return item.posterUrl ?? '';
}

function itemRatingText(r: number | undefined): string {
  if (r === undefined || r <= 0) {
    return '';
  }
  return r.toFixed(1);
}

function itemRatingColor(r: number | undefined): string {
  if (r === undefined || r <= 0) {
    return '#8F96A3';
  }
  if (r >= 8.0) {
    return '#F7C06C';
  }
  if (r >= 6.0) {
    return '#D0A26B';
  }
  return '#E6786C';
}

// ─────────────────────────────────────────────────────────────────────────────
// 海报卡片（局部组件，不导出）
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
        latestScannedAt: this.item.scannedAt,
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
      .border({ width: this.isFocused ? 2 : 0, color: '#66A9D8FF' })
      .shadow({
        radius: this.isFocused ? 14 : 4,
        color: this.isFocused ? '#553A86FF' : '#33000000',
        offsetX: 0,
        offsetY: this.isFocused ? 0 : 2,
      })
      .scale({ x: this.isFocused ? 1.03 : 1.0, y: this.isFocused ? 1.03 : 1.0 })
      .animation({ duration: 150, curve: Curve.EaseOut })

      Text(itemTitle(this.item))
        .fontSize(22)
        .fontColor('#E3E7ED')
        .fontWeight(FontWeight.Normal)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(180)

      if (itemRatingText(this.item.rating).length > 0) {
        Text(itemRatingText(this.item.rating))
          .fontSize(20)
          .fontColor(itemRatingColor(this.item.rating))
          .fontWeight(FontWeight.Medium)
      }
    }
    .width(180)
    .alignItems(HorizontalAlign.Start)
    .focusable(true)
    .onFocus(() => {
      this.isFocused = true;
    })
    .onBlur(() => {
      this.isFocused = false;
    })
    .onClick(() => {
      this.navigateToDetail();
    })
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 主页面
// ─────────────────────────────────────────────────────────────────────────────

@ComponentV2
export struct MediaResultPage {
  static readonly PAGE_NAME: string = 'MediaResultPage';

  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();

  // ── 页面状态 ──────────────────────────────────────────────────────────────
  @Local pageTitle: string = '搜索结果';
  @Local keyword: string = '';

  // ── 筛选状态 ──────────────────────────────────────────────────────────────
  @Local filterMediaType: string = '';
  @Local filterGenre: string = '';
  @Local filterRating: number = 0;
  @Local filterYear: string = '';
  @Local filterSort: string = 'title';

  // ── 数据状态 ──────────────────────────────────────────────────────────────
  @Local results: MediaItem[] = [];
  @Local genres: string[] = [];
  @Local isLoading: boolean = false;
  @Local totalCount: number = 0;

  // ── Chip 焦点状态（-1=无，0-4=对应Chip）────────────────────────────────
  @Local focusedChip: number = -1;

  // ── Dropdown 开关（''=关，'mediaType'|'genre'|'rating'|'year'|'sort'=开）
  @Local activeDropdown: string = '';

  private db: FileSourceDatabase = FileSourceDatabase.getInstance();

  // ── 数据加载 ──────────────────────────────────────────────────────────────

  private async loadGenres(): Promise<void> {
    try {
      const rawList: string[] = await this.db.getDistinctGenres();
      this.genres = this.parseGenres(rawList);
    } catch {
      this.genres = [];
    }
  }

  /** 将 getDistinctGenres() 返回的 JSON 字符串数组拍平去重 */
  private parseGenres(rawList: string[]): string[] {
    const seen: string[] = [];
    for (const raw of rawList) {
      try {
        const arr = JSON.parse(raw) as string[];
        for (const g of arr) {
          if (typeof g === 'string' && g.length > 0 && !seen.includes(g)) {
            seen.push(g);
          }
        }
      } catch {
        // 跳过格式异常的记录
      }
    }
    seen.sort();
    return seen;
  }

  private async doSearch(): Promise<void> {
    this.isLoading = true;
    this.results = [];
    try {
      // 媒体类型映射
      let mediaTypeParam: 'movie' | 'tv' | 'all' | undefined = undefined;
      if (this.filterMediaType === 'movie') {
        mediaTypeParam = 'movie';
      } else if (this.filterMediaType === 'tv') {
        mediaTypeParam = 'tv';
      }

      // 排序方式映射
      let sortByParam: 'rating' | 'year' | 'title' = 'title';
      if (this.filterSort === 'rating') {
        sortByParam = 'rating';
      } else if (this.filterSort === 'year') {
        sortByParam = 'year';
      }

      // 年代字符串转数字
      const yearNum: number | undefined = this.filterYear.length > 0
        ? parseInt(this.filterYear, 10)
        : undefined;

      const options: SearchMediaOptions = {
        mediaType: mediaTypeParam,
        genre: this.filterGenre.length > 0 ? this.filterGenre : undefined,
        minRating: this.filterRating > 0 ? this.filterRating : undefined,
        year: yearNum,
        sortBy: sortByParam,
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

  private resetFilters(): void {
    this.filterMediaType = '';
    this.filterGenre = '';
    this.filterRating = 0;
    this.filterYear = '';
    this.filterSort = 'title';
    this.activeDropdown = '';
    this.doSearch().catch((): void => {});
  }

  // ── 辅助：Chip 显示文案 ──────────────────────────────────────────────────

  private getMediaTypeLabel(): string {
    const opt = MEDIA_TYPE_OPTIONS.find((o: StringOption) => o.value === this.filterMediaType);
    return (opt !== undefined && opt.value !== '') ? `${opt.label}▾` : '媒体类型▾';
  }

  private getGenreLabel(): string {
    return this.filterGenre.length > 0 ? `${this.filterGenre}▾` : '类别▾';
  }

  private getRatingLabel(): string {
    const opt = RATING_OPTIONS.find((o: NumberOption) => o.value === this.filterRating);
    return (opt !== undefined && opt.value > 0) ? `${opt.label}▾` : '评分▾';
  }

  private getYearLabel(): string {
    const opt = YEAR_OPTIONS.find((o: StringOption) => o.value === this.filterYear);
    return (opt !== undefined && opt.value !== '') ? `${opt.label}▾` : '年代▾';
  }

  private getSortLabel(): string {
    const opt = SORT_OPTIONS.find((o: StringOption) => o.value === this.filterSort);
    return (opt !== undefined && opt.value !== 'title') ? `${opt.label}▾` : '排序▾';
  }

  // ── 辅助：Chip 样式计算 ──────────────────────────────────────────────────

  private isChipSelected(key: string): boolean {
    if (key === 'mediaType') {
      return this.filterMediaType !== '';
    }
    if (key === 'genre') {
      return this.filterGenre !== '';
    }
    if (key === 'rating') {
      return this.filterRating > 0;
    }
    if (key === 'year') {
      return this.filterYear !== '';
    }
    if (key === 'sort') {
      return this.filterSort !== 'title';
    }
    return false;
  }

  private chipBg(key: string): string {
    return this.isChipSelected(key) ? '#1D4ED860' : '#33415550';
  }

  private chipText(key: string): string {
    return this.isChipSelected(key) ? '#BFDBFE' : '#CBD5E1';
  }

  private chipBorderColor(key: string, idx: number): string {
    if (this.focusedChip === idx) {
      return '#66A9D8FF';
    }
    return this.isChipSelected(key) ? '#93C5FD99' : '#CBD5E166';
  }

  private chipBorderWidth(idx: number): number {
    return this.focusedChip === idx ? 2 : 1;
  }

  private chipShadowRadius(idx: number): number {
    return this.focusedChip === idx ? 14 : 0;
  }

  // ── @Builder：下拉菜单内容 ────────────────────────────────────────────────

  @Builder
  buildMediaTypeMenu() {
    Column() {
      ForEach(MEDIA_TYPE_OPTIONS, (opt: StringOption) => {
        Text(opt.label)
          .fontSize(14)
          .fontColor(this.filterMediaType === opt.value ? '#BFDBFE' : '#CBD5E1')
          .backgroundColor(this.filterMediaType === opt.value ? '#1D4ED860' : Color.Transparent)
          .padding({ top: 10, bottom: 10, left: 16, right: 16 })
          .width('100%')
          .focusable(true)
          .onClick(() => {
            this.filterMediaType = opt.value;
            this.activeDropdown = '';
            this.doSearch().catch((): void => {});
          })
      }, (opt: StringOption) => opt.value)
    }
    .backgroundColor('#2A2E3A')
    .borderRadius(8)
    .width(160)
  }

  @Builder
  buildGenreMenu() {
    Scroll() {
      Column() {
        Text('全部')
          .fontSize(14)
          .fontColor(this.filterGenre === '' ? '#BFDBFE' : '#CBD5E1')
          .backgroundColor(this.filterGenre === '' ? '#1D4ED860' : Color.Transparent)
          .padding({ top: 10, bottom: 10, left: 16, right: 16 })
          .width('100%')
          .focusable(true)
          .onClick(() => {
            this.filterGenre = '';
            this.activeDropdown = '';
            this.doSearch().catch((): void => {});
          })
        ForEach(this.genres, (g: string) => {
          Text(g)
            .fontSize(14)
            .fontColor(this.filterGenre === g ? '#BFDBFE' : '#CBD5E1')
            .backgroundColor(this.filterGenre === g ? '#1D4ED860' : Color.Transparent)
            .padding({ top: 10, bottom: 10, left: 16, right: 16 })
            .width('100%')
            .focusable(true)
            .onClick(() => {
              this.filterGenre = g;
              this.activeDropdown = '';
              this.doSearch().catch((): void => {});
            })
        }, (g: string) => g)
      }
    }
    .scrollBar(BarState.Off)
    .constraintSize({ maxHeight: 300 })
    .backgroundColor('#2A2E3A')
    .borderRadius(8)
    .width(160)
  }

  @Builder
  buildRatingMenu() {
    Column() {
      ForEach(RATING_OPTIONS, (opt: NumberOption) => {
        Text(opt.label)
          .fontSize(14)
          .fontColor(this.filterRating === opt.value ? '#BFDBFE' : '#CBD5E1')
          .backgroundColor(this.filterRating === opt.value ? '#1D4ED860' : Color.Transparent)
          .padding({ top: 10, bottom: 10, left: 16, right: 16 })
          .width('100%')
          .focusable(true)
          .onClick(() => {
            this.filterRating = opt.value;
            this.activeDropdown = '';
            this.doSearch().catch((): void => {});
          })
      }, (opt: NumberOption) => String(opt.value))
    }
    .backgroundColor('#2A2E3A')
    .borderRadius(8)
    .width(160)
  }

  @Builder
  buildYearMenu() {
    Column() {
      ForEach(YEAR_OPTIONS, (opt: StringOption) => {
        Text(opt.label)
          .fontSize(14)
          .fontColor(this.filterYear === opt.value ? '#BFDBFE' : '#CBD5E1')
          .backgroundColor(this.filterYear === opt.value ? '#1D4ED860' : Color.Transparent)
          .padding({ top: 10, bottom: 10, left: 16, right: 16 })
          .width('100%')
          .focusable(true)
          .onClick(() => {
            this.filterYear = opt.value;
            this.activeDropdown = '';
            this.doSearch().catch((): void => {});
          })
      }, (opt: StringOption) => opt.value)
    }
    .backgroundColor('#2A2E3A')
    .borderRadius(8)
    .width(160)
  }

  @Builder
  buildSortMenu() {
    Column() {
      ForEach(SORT_OPTIONS, (opt: StringOption) => {
        Text(opt.label)
          .fontSize(14)
          .fontColor(this.filterSort === opt.value ? '#BFDBFE' : '#CBD5E1')
          .backgroundColor(this.filterSort === opt.value ? '#1D4ED860' : Color.Transparent)
          .padding({ top: 10, bottom: 10, left: 16, right: 16 })
          .width('100%')
          .focusable(true)
          .onClick(() => {
            this.filterSort = opt.value;
            this.activeDropdown = '';
            this.doSearch().catch((): void => {});
          })
      }, (opt: StringOption) => opt.value)
    }
    .backgroundColor('#2A2E3A')
    .borderRadius(8)
    .width(160)
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  build() {
    NavDestination() {
      Column() {

        // ── Header Bar (72vp) ─────────────────────────────────────────────
        Row() {
          Button('← 返回')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor('#FFFFFF14')
            .borderRadius(0)
            .width(112)
            .height(40)
            .focusable(true)
            .onClick(() => {
              this.pageStack.pop();
            })

          Text(this.pageTitle)
            .fontSize(22)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)

          Text(`共 ${this.totalCount} 项`)
            .fontSize(16)
            .fontColor('#8F96A3')
            .width(112)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .height(72)
        .padding({ left: 64, right: 64 })
        .alignItems(VerticalAlign.Center)

        // ── Filter Bar (72vp) ─────────────────────────────────────────────
        Column() {
          Row({ space: 12 }) {

            // Chip 0：媒体类型
            Row({ space: 6 }) {
              Text(this.getMediaTypeLabel())
                .fontSize(14)
                .fontColor(this.chipText('mediaType'))
                .fontWeight(FontWeight.Medium)
            }
            .height(40)
            .padding({ left: 14, right: 14 })
            .borderRadius(0)
            .backgroundColor(this.chipBg('mediaType'))
            .border({ width: this.chipBorderWidth(0), color: this.chipBorderColor('mediaType', 0) })
            .shadow({
              radius: this.chipShadowRadius(0),
              color: '#553A86FF',
              offsetX: 0,
              offsetY: 0,
            })
            .focusable(true)
            .defaultFocus(true)
            .onFocus(() => {
              this.focusedChip = 0;
            })
            .onBlur(() => {
              if (this.focusedChip === 0) {
                this.focusedChip = -1;
              }
            })
            .bindMenu(this.activeDropdown === 'mediaType', () => {
              this.buildMediaTypeMenu();
            })
            .onClick(() => {
              this.activeDropdown = this.activeDropdown === 'mediaType' ? '' : 'mediaType';
            })

            // Chip 1：类别
            Row({ space: 6 }) {
              Text(this.getGenreLabel())
                .fontSize(14)
                .fontColor(this.chipText('genre'))
                .fontWeight(FontWeight.Medium)
            }
            .height(40)
            .padding({ left: 14, right: 14 })
            .borderRadius(0)
            .backgroundColor(this.chipBg('genre'))
            .border({ width: this.chipBorderWidth(1), color: this.chipBorderColor('genre', 1) })
            .shadow({
              radius: this.chipShadowRadius(1),
              color: '#553A86FF',
              offsetX: 0,
              offsetY: 0,
            })
            .focusable(true)
            .onFocus(() => {
              this.focusedChip = 1;
            })
            .onBlur(() => {
              if (this.focusedChip === 1) {
                this.focusedChip = -1;
              }
            })
            .bindMenu(this.activeDropdown === 'genre', () => {
              this.buildGenreMenu();
            })
            .onClick(() => {
              this.activeDropdown = this.activeDropdown === 'genre' ? '' : 'genre';
            })

            // Chip 2：评分
            Row({ space: 6 }) {
              Text(this.getRatingLabel())
                .fontSize(14)
                .fontColor(this.chipText('rating'))
                .fontWeight(FontWeight.Medium)
            }
            .height(40)
            .padding({ left: 14, right: 14 })
            .borderRadius(0)
            .backgroundColor(this.chipBg('rating'))
            .border({ width: this.chipBorderWidth(2), color: this.chipBorderColor('rating', 2) })
            .shadow({
              radius: this.chipShadowRadius(2),
              color: '#553A86FF',
              offsetX: 0,
              offsetY: 0,
            })
            .focusable(true)
            .onFocus(() => {
              this.focusedChip = 2;
            })
            .onBlur(() => {
              if (this.focusedChip === 2) {
                this.focusedChip = -1;
              }
            })
            .bindMenu(this.activeDropdown === 'rating', () => {
              this.buildRatingMenu();
            })
            .onClick(() => {
              this.activeDropdown = this.activeDropdown === 'rating' ? '' : 'rating';
            })

            // Chip 3：年代
            Row({ space: 6 }) {
              Text(this.getYearLabel())
                .fontSize(14)
                .fontColor(this.chipText('year'))
                .fontWeight(FontWeight.Medium)
            }
            .height(40)
            .padding({ left: 14, right: 14 })
            .borderRadius(0)
            .backgroundColor(this.chipBg('year'))
            .border({ width: this.chipBorderWidth(3), color: this.chipBorderColor('year', 3) })
            .shadow({
              radius: this.chipShadowRadius(3),
              color: '#553A86FF',
              offsetX: 0,
              offsetY: 0,
            })
            .focusable(true)
            .onFocus(() => {
              this.focusedChip = 3;
            })
            .onBlur(() => {
              if (this.focusedChip === 3) {
                this.focusedChip = -1;
              }
            })
            .bindMenu(this.activeDropdown === 'year', () => {
              this.buildYearMenu();
            })
            .onClick(() => {
              this.activeDropdown = this.activeDropdown === 'year' ? '' : 'year';
            })

            // Chip 4：排序
            Row({ space: 6 }) {
              Text(this.getSortLabel())
                .fontSize(14)
                .fontColor(this.chipText('sort'))
                .fontWeight(FontWeight.Medium)
            }
            .height(40)
            .padding({ left: 14, right: 14 })
            .borderRadius(0)
            .backgroundColor(this.chipBg('sort'))
            .border({ width: this.chipBorderWidth(4), color: this.chipBorderColor('sort', 4) })
            .shadow({
              radius: this.chipShadowRadius(4),
              color: '#553A86FF',
              offsetX: 0,
              offsetY: 0,
            })
            .focusable(true)
            .onFocus(() => {
              this.focusedChip = 4;
            })
            .onBlur(() => {
              if (this.focusedChip === 4) {
                this.focusedChip = -1;
              }
            })
            .bindMenu(this.activeDropdown === 'sort', () => {
              this.buildSortMenu();
            })
            .onClick(() => {
              this.activeDropdown = this.activeDropdown === 'sort' ? '' : 'sort';
            })

          }
          .width('100%')
          .height(71)
          .padding({ left: 64, right: 64 })
          .alignItems(VerticalAlign.Center)

          // 底部分割线 1px
          Row()
            .width('100%')
            .height(1)
            .backgroundColor('#ffffff20')
        }
        .width('100%')
        .backgroundColor('#1E1E22')

        // ── 内容区（剩余空间，竖向滚动网格）──────────────────────────────
        if (this.isLoading) {
          Column() {
            LoadingProgress()
              .width(48)
              .height(48)
              .color('#FFFFFF')
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)

        } else if (this.results.length === 0) {
          // 空结果态
          Column({ space: 16 }) {
            Text('📺')
              .fontSize(56)
              .opacity(0.35)
              .fontColor('#FFFFFF')

            Text('没有符合条件的内容')
              .fontSize(18)
              .fontColor('#666666')

            Text('尝试调整筛选条件')
              .fontSize(13)
              .fontColor('#444444')

            Button('重置筛选')
              .width(200)
              .height(44)
              .backgroundColor('#FFFFFF14')
              .fontColor('#FFFFFF')
              .fontSize(14)
              .borderRadius(0)
              .focusable(true)
              .onClick(() => {
                this.resetFilters();
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)

        } else {
          // 9列海报网格
          Grid() {
            ForEach(this.results, (item: MediaItem) => {
              GridItem() {
                ResultPosterCard({ item: item })
              }
            }, (item: MediaItem) => String(item.id))
          }
          .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr')
          .columnsGap(12)
          .rowsGap(24)
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 64, right: 64, top: 24 })
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
          .focusable(true)
        }

      }
      .width('100%')
      .height('100%')
      .backgroundColor('#1A1A1A')
    }
    .hideTitleBar(true)
    .onReady((context: NavDestinationContext) => {
      const param = context.pathInfo.param as MediaResultPageParam;
      if (param !== undefined && param !== null) {
        this.keyword = param.keyword ?? '';
        if (param.mediaType !== undefined) {
          this.filterMediaType = param.mediaType;
        }
        if (param.genre !== undefined) {
          this.filterGenre = param.genre;
        }
        if (param.pageTitle !== undefined && param.pageTitle.length > 0) {
          this.pageTitle = param.pageTitle;
        } else if (param.keyword !== undefined && param.keyword.length > 0) {
          this.pageTitle = `"${param.keyword}" 的搜索结果`;
        } else if (param.genre !== undefined && param.genre.length > 0) {
          this.pageTitle = param.genre;
        } else if (param.mediaType === 'movie') {
          this.pageTitle = '电影';
        } else if (param.mediaType === 'tv') {
          this.pageTitle = '剧集';
        }
      }
      this.loadGenres().catch((): void => {});
      this.doSearch().catch((): void => {});
    })
  }
}
