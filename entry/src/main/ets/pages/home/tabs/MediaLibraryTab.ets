import { TabBarModel, TabItem } from "../../../stores/tabbar/TabBarModel"
import { TabBarStore } from "../../../stores/tabbar/TabBarStore"
import { VideoScannerUtil, ScanMode } from "../../../utils/VideoScannerUtil"
import { ScrapeClient, parseFileName, TvSeriesScrapeResult } from "../../../lib/ScrapeClient"
import { AppPreferences, PrefKey } from "../../../utils/AppPreferences"
import { MediaItem, MediaStats, SeriesGroup, MediaListItem, ScrapeInfoEntity, MovieEntity, TvSeriesEntity, TvSeasonEntity, TvEpisodeEntity, ContinueWatchingItem } from "../../../db/models/MediaEntity"
import { MediaLibraryModel } from "../../../stores/media/MediaLibraryModel"
import { FileSourceDatabase, MediaFilterOptions } from "../../../db/files/FileSourceDatabase"
import { FileSourceType } from "../../../db/models/FileSourceEntity"
import { ContinueWatchCard } from "../../../components/media/ContinueWatchCard"
import promptAction from '@ohos.promptAction';
import { SeriesDetailPage } from "../../detail/SeriesDetailPage"
import { SeasonDetailPage } from "../../detail/SeasonDetailPage"
import { MovieDetailPage } from "../../detail/MovieDetailPage"
import { FfprobeUtil } from "../../../utils/FfprobeUtil"
import { WebDAVClient, WebDAVConfig } from "../../../lib/WebDAVClient"
import { PlayHistoryPage } from "../../history/PlayHistoryPage"
import { emitter } from "@kit.BasicServicesKit"
import { PlayerEvents } from "../../../components/core/player/Constants"
import { MediaResultPage, MediaResultPageParam } from "../../search/MediaResultPage"

// ─────────────────────────────────────────────
// 常量
// ─────────────────────────────────────────────
const POSTER_WIDTH = 180;
const PORTRAIT_ASPECT_RATIO = 2/3;
const LANDSCAPE_ASPECT_RATIO = 16/9;

const WIDE_WIDTH = 360;
// const WIDE_HEIGHT = 135;
// ─────────────────────────────────────────────
// 工具函数
// ─────────────────────────────────────────────
function displayTitle(item: MediaItem): string {
  return item.title ?? item.fileName;
}
function posterSrc(item: MediaItem): string {
  return item.posterLocalPath ?? item.posterUrl ?? '';
}
function hasPoster(item: MediaItem): boolean {
  return (item.posterLocalPath !== undefined && item.posterLocalPath.length > 0)
    || (item.posterUrl !== undefined && item.posterUrl.length > 0);
}
function ratingText(item: MediaItem): string {
  if (item.rating === undefined) { return ''; }
  return item.rating.toFixed(1);
}
/** 仅返回 '4K' 或 '1080p'，其他分辨率返回空字符串 */
function resolutionLabel(width?: number, height?: number): string {
  if (width === undefined || height === undefined) { return ''; }
  const h = height > width ? width : height; // 取短边（竖向视频兼容）
  if (h >= 2160 || width >= 3840) { return '4K'; }
  if (h >= 1080 || width >= 1920) { return '1080P'; }
  return '';
}
function formatScanTime(ts: number): string {
  if (ts === 0) { return '从未扫描'; }
  const d = new Date(ts);
  const pad = (n: number): string => n < 10 ? '0' + n : String(n);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

interface SourceRuntimeConfig {
  type: FileSourceType;
  configJson: string;
}

// ─────────────────────────────────────────────
// 海报卡片（9:16）
// ─────────────────────────────────────────────
@ComponentV2
struct PosterCard {
  @Require @Param item: MediaItem
  @Local isHovered: boolean = false
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  private getTitle(): string { return displayTitle(this.item); }
  private getPoster(): string { return posterSrc(this.item); }
  private hasPosterImg(): boolean { return hasPoster(this.item); }
  private getRating(): string { return ratingText(this.item); }
  private getResolution(): string { return resolutionLabel(this.item.width, this.item.height); }
  private getCardBorderColor(): string { return this.isHovered ? 'rgba(255, 255, 255, 0.38)' : '#00FFFFFF'; }
  private getCardOverlayColor(): string { return this.isHovered ? 'rgba(0, 0, 0, 0.14)' : '#00000000'; }
  private getCardShadowColor(): string { return this.isHovered ? 'rgba(0, 0, 0, 0.36)' : 'rgba(0, 0, 0, 0.20)'; }

  build() {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        // 海报图 / 占位
        if (this.hasPosterImg()) {
          Image(this.getPoster())
            .width(POSTER_WIDTH)
            .aspectRatio(PORTRAIT_ASPECT_RATIO)
            .hoverEffect(HoverEffect.Highlight)
            .objectFit(ImageFit.Cover)
        } else {
          Column() {
            Text(this.getTitle())
              .fontSize(11).fontColor('#CCCCCC').textAlign(TextAlign.Center)
              .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).padding(8)
          }
          .width(POSTER_WIDTH)
          .aspectRatio(PORTRAIT_ASPECT_RATIO)
          .backgroundColor('#2A2A2A').borderRadius(6).justifyContent(FlexAlign.Center)
        }

        // 底部黑色渐变（覆盖下方 20%）
        if (this.getRating().length > 0) {
          Column()
            .width(POSTER_WIDTH)
            .height("28%")
            .linearGradient({
              angle: 180,
              colors: [['#00000000', 0.0], ['#CC000000', 1.0]]
            })
            .borderRadius({ bottomLeft: 6, bottomRight: 6 })
            .position({ left: 0, bottom: 0 })
        }

        // 右上角分辨率标签
        if (this.getResolution().length > 0) {
          Text(this.getResolution())
            .fontSize(9).fontColor(this.getResolution() === '1080P' ? Color.White : Color.Black)
            .backgroundColor(this.getResolution() === '1080P' ? '#66000000' : '#FFA500')
            .padding({ top: 2, bottom: 2 })
            .borderRadius(4)
            .width("32fp")
            .textAlign(TextAlign.Center)
            .position({ top: 2, right: 2 })
        }

        // 右下角评分（橘黄色，透明背景）
        if (this.getRating().length > 0) {
          Text(this.getRating())
            .fontSize(11).fontColor('#FFA500').fontWeight(FontWeight.Bold)
            .padding({ left: 4, right: 4, bottom: 4 })
            .position({ right: 2, bottom: 2 })
        }

        // 亮色海报上增强 hover 可见性的遮罩层
        Column()
          .width(POSTER_WIDTH)
          .aspectRatio(PORTRAIT_ASPECT_RATIO)
          .backgroundColor(this.getCardOverlayColor())
          .position({ left: 0, top: 0 })
          .hitTestBehavior(HitTestMode.Transparent)
      }
      .borderRadius(6)
      .clip(true)
      .width(POSTER_WIDTH)
      .aspectRatio(PORTRAIT_ASPECT_RATIO)
      .border({ width: 2, color: this.getCardBorderColor() })
      .shadow({ radius: this.isHovered ? 14 : 8, color: this.getCardShadowColor(), offsetX: 0, offsetY: 2 })
      .onHover((isHover: boolean) => { this.isHovered = isHover; })
      .animation({ duration: 140, curve: Curve.EaseInOut })

      Text(this.getTitle())
        .fontSize(16).fontColor('#DDDDDD').maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(POSTER_WIDTH).margin({ top: 4 })
        .textAlign(TextAlign.Center)
    }
    .width(POSTER_WIDTH)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      if (this.item.mediaType === 'movie') {
        this.pageStack.pushPathByName(MovieDetailPage.PAGE_NAME, this.item);
      }
    })
  }
}
// ─────────────────────────────────────────────
@ComponentV2
struct SeriesCard {
  @Require @Param group: SeriesGroup
  /** true = 最近添加/混合列表，显示季海报+季号；false = 电视剧栏，只显剧海报不显季 */
  @Param showSeasonPoster: boolean = false
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  @Local isHovered: boolean = false

  private getTitle(): string { return this.group.title; }

  private getPoster(): string {
    // 最近添加：优先季海报，无则剧海报
    if (this.showSeasonPoster && this.group.seasonPosterUrl !== undefined && this.group.seasonPosterUrl.length > 0) {
      return this.group.seasonPosterUrl;
    }
    return this.group.posterLocalPath ?? this.group.posterUrl ?? '';
  }

  private hasPosterImg(): boolean {
    if (this.showSeasonPoster && this.group.seasonPosterUrl !== undefined && this.group.seasonPosterUrl.length > 0) {
      return true;
    }
    return (this.group.posterLocalPath !== undefined && this.group.posterLocalPath.length > 0)
      || (this.group.posterUrl !== undefined && this.group.posterUrl.length > 0);
  }

  private getRating(): string {
    if (this.group.rating === undefined) { return ''; }
    return this.group.rating.toFixed(1);
  }

  private getResolution(): string {
    const ep = this.group.episodes.length > 0 ? this.group.episodes[0] : undefined;
    if (ep === undefined) { return ''; }
    return resolutionLabel(ep.width, ep.height);
  }

  /** 最近添加时显示「第X季」标签，统一用中文格式 */
  private getSeasonLabel(): string {
    if (!this.showSeasonPoster) { return ''; }
    // 有刮削的季编号 → 第X季（阿拉伯数字）
    if (this.group.seasonNumber !== undefined) {
      return `第${this.group.seasonNumber}季`;
    }
    return this.group.seasonLabel ?? '';
  }
  private getCardBorderColor(): string { return this.isHovered ? 'rgba(255, 255, 255, 0.38)' : '#00FFFFFF'; }
  private getCardOverlayColor(): string { return this.isHovered ? 'rgba(0, 0, 0, 0.14)' : '#00000000'; }
  private getCardShadowColor(): string { return this.isHovered ? 'rgba(0, 0, 0, 0.36)' : 'rgba(0, 0, 0, 0.20)'; }

  build() {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.hasPosterImg()) {
          Image(this.getPoster())
            .width(POSTER_WIDTH)
            .aspectRatio(PORTRAIT_ASPECT_RATIO)
            .hoverEffect(HoverEffect.Highlight)
            .objectFit(ImageFit.Cover)
        } else {
          Column() {
            Text(this.getTitle())
              .fontSize(11).fontColor('#CCCCCC').textAlign(TextAlign.Center)
              .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).padding(8)
          }
          .width(POSTER_WIDTH)
          .aspectRatio(PORTRAIT_ASPECT_RATIO)
          .backgroundColor('#2A2A2A').borderRadius(6).justifyContent(FlexAlign.Center)
        }

        // 底部黑色渐变
        if (this.getRating().length > 0 || this.getSeasonLabel().length > 0) {
          Column()
            .width(POSTER_WIDTH)
            .height("28%")
            .linearGradient({
              angle: 180,
              colors: [['#00000000', 0.0], ['#CC000000', 1.0]]
            })
            .borderRadius({ bottomLeft: 6, bottomRight: 6 })
            .position({ left: 0, bottom: 0 })
        }

        // 右上角分辨率标签
        if (this.getResolution().length > 0) {
          Text(this.getResolution())
            .fontSize(9).fontColor(this.getResolution() === '1080P' ? Color.White : Color.Black)
            .backgroundColor(this.getResolution() === '1080P' ? '#66000000' : '#FFA500')
            .padding({ top: 2, bottom: 2 })
            .borderRadius(4)
            .width('32fp')
            .textAlign(TextAlign.Center)
            .position({ top: 2, right: 2 })
        }

        // 左下角季标签（最近添加时显示）
        if (this.getSeasonLabel().length > 0) {
          Text(this.getSeasonLabel())
            .fontSize(10).fontColor(Color.White).fontWeight(FontWeight.Medium)
            .padding({ left: 4, right: 4, bottom: 4 })
            .position({ left: 2, bottom: 2 })
        }

        // 右下角评分
        if (this.getRating().length > 0) {
          Text(this.getRating())
            .fontSize(11).fontColor('#FFA500').fontWeight(FontWeight.Bold)
            .padding({ left: 4, right: 4, bottom: 4 })
            .position({ right: 2, bottom: 2 })
        }

        // 亮色海报上增强 hover 可见性的遮罩层
        Column()
          .width(POSTER_WIDTH)
          .aspectRatio(PORTRAIT_ASPECT_RATIO)
          .backgroundColor(this.getCardOverlayColor())
          .position({ left: 0, top: 0 })
          .hitTestBehavior(HitTestMode.Transparent)
      }
      .borderRadius(6)
      .clip(true)
      .width(POSTER_WIDTH)
      .aspectRatio(PORTRAIT_ASPECT_RATIO)
      .border({ width: 2, color: this.getCardBorderColor() })
      .shadow({ radius: this.isHovered ? 14 : 8, color: this.getCardShadowColor(), offsetX: 0, offsetY: 2 })
      .onHover((isHover: boolean) => { this.isHovered = isHover; })
      .animation({ duration: 140, curve: Curve.EaseInOut })

      Text(this.getTitle())
        .fontSize(16).fontColor('#DDDDDD').maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width(POSTER_WIDTH)
        .margin({ top: 4 })
    }
    .width(POSTER_WIDTH)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      if (this.showSeasonPoster && this.group.seasonNumber !== undefined && this.group.tvSeriesId !== undefined) {
        // 季卡片 → 跳转季详情页
        this.pageStack.pushPathByName(SeasonDetailPage.PAGE_NAME, this.group);
      } else if (!this.showSeasonPoster && this.group.tvSeriesId !== undefined) {
        // 剧集卡片 → 跳转剧集详情页
        this.pageStack.pushPathByName(SeriesDetailPage.PAGE_NAME, this.group);
      }
    })
  }
}

// ─────────────────────────────────────────────
// 混合卡片（自动选择 PosterCard 或 SeriesCard）
// ─────────────────────────────────────────────
@ComponentV2
struct MixedCard {
  @Require @Param listItem: MediaListItem

  private isSeries(): boolean {
    return this.listItem.kind === 'series';
  }

  private getSeries(): SeriesGroup {
    return this.listItem.series!;
  }

  private getVideo(): MediaItem {
    return this.listItem.video!;
  }

  build() {
    Column() {
      if (this.isSeries()) {
        SeriesCard({ group: this.getSeries(), showSeasonPoster: true })
      } else {
        PosterCard({ item: this.getVideo() })
      }
    }
  }
}

// ─────────────────────────────────────────────
// 通用分组行（横向滚动）
// ─────────────────────────────────────────────
@ComponentV2
struct SectionRow {
  @Require @Param title: string
  @Param showAction: boolean = false
  @Param actionLabel: string = '查看全部 >'
  @Event onAction: () => void = () => {}
  @BuilderParam content: () => void
  @Local isActionFocused: boolean = false

  build() {
    Column() {
      Row() {
        Text(this.title)
          .fontSize(28)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Bold)
          .padding({ left: 16 })
          .layoutWeight(1)

        if (this.showAction) {
          Text(this.actionLabel)
            .fontSize(18)
            .fontColor(this.isActionFocused ? '#FFFFFF' : '#E29A43')
            .fontWeight(FontWeight.Medium)
            .height(32)
            .padding({ left: 12, right: 16, top: 0, bottom: 0 })
            .backgroundColor(this.isActionFocused ? 'rgba(226,154,67,0.15)' : Color.Transparent)
            .borderRadius(6)
            .border({ width: this.isActionFocused ? 2 : 0, color: '#E29A43' })
            .focusable(true)
            .onFocus(() => { this.isActionFocused = true; })
            .onBlur(() => { this.isActionFocused = false; })
            .onClick(() => { this.onAction(); })
            .animation({ duration: 140, curve: Curve.EaseInOut })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: 44 })
      .margin({ bottom: 8 })

      Scroll() {
        Row({ space: 10 }) {
          this.content()
        }
        .padding({ left: 16, right: 16 })
        .alignItems(VerticalAlign.Top)
      }
      .align(Alignment.Start)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%').alignItems(HorizontalAlign.Start).margin({ bottom: 20 })
  }
}

// ─────────────────────────────────────────────
// 占位卡片（继续播放）
// ─────────────────────────────────────────────
@ComponentV2
struct PlaceholderWideCard {
  @Require @Param label: string
  @Local isHovered: boolean = false
  private getCardBorderColor(): string { return this.isHovered ? 'rgba(255, 255, 255, 0.34)' : '#333355'; }
  private getCardBgColor(): string { return this.isHovered ? '#232338' : '#1A1A2E'; }
  private getCardShadowColor(): string { return this.isHovered ? 'rgba(0, 0, 0, 0.30)' : 'rgba(0, 0, 0, 0.16)'; }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(WIDE_WIDTH)
        .aspectRatio(LANDSCAPE_ASPECT_RATIO)
        .backgroundColor(this.getCardBgColor())
        .border({ width: 2, color: this.getCardBorderColor(), style: BorderStyle.Dashed })
      Column() {
        Text('▶').fontSize(20).fontColor('#555577')
        Text(this.label).fontSize(11).fontColor('#555577').margin({ top: 4 })
      }

      Column()
        .width(WIDE_WIDTH)
        .aspectRatio(LANDSCAPE_ASPECT_RATIO)
        .backgroundColor(this.isHovered ? 'rgba(0, 0, 0, 0.10)' : '#00000000')
        .position({ left: 0, top: 0 })
        .hitTestBehavior(HitTestMode.Transparent)
    }
    .clip(true)
    .borderRadius(6)
    .width(WIDE_WIDTH)
    .aspectRatio(LANDSCAPE_ASPECT_RATIO)
    .shadow({ radius: this.isHovered ? 12 : 6, color: this.getCardShadowColor(), offsetX: 0, offsetY: 2 })
    .onHover((isHover: boolean) => { this.isHovered = isHover; })
    .animation({ duration: 140, curve: Curve.EaseInOut })
  }
}

// ─────────────────────────────────────────────
// 主组件
// ─────────────────────────────────────────────
@ComponentV2
export struct MediaLibraryTab {
  tabBarModel: TabBarModel = TabBarStore.getState()
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  @Require @Param tab: TabItem
  @Local isScanning: boolean = false
  @Local isViewAllFocused: boolean = false
  model: MediaLibraryModel = MediaLibraryModel.getState()

  // ── 筛选/排序状态 ──────────────────────────────
  /** 已选中的类型标签（多选） */
  @Local filterGenres: string[] = []
  /** 已选中的年份（多选） */
  @Local filterYears: number[] = []
  /** 最近播放快捷筛选 */
  @Local filterRecentlyPlayed: boolean = false
  /** 未看完快捷筛选 */
  @Local filterUnwatched: boolean = false
  /** 当前排序方式 */
  @Local filterSortBy: string = 'updated'
  /** 可用类型列表（从 DB 动态加载） */
  @Local availableGenres: string[] = []
  /** 可用年份列表（从 DB 动态加载，降序） */
  @Local availableYears: number[] = []
  /** 当前筛选结果列表 */
  @Local filteredList: MediaListItem[] = []
  /** 筛选结果是否加载中 */
  @Local isFilteredLoading: boolean = false
  /** 是否还有更多筛选结果 */
  @Local filterHasMore: boolean = false
  /** 当前筛选结果分页偏移 */
  @Local filterCurrentOffset: number = 0

  aboutToAppear(): void {
    FileSourceDatabase.onReady(() => {
      this.model.reload().then(() => {
        console.info(`[MediaLibraryTab][DIAG] reload完成:`
          + ` isLoaded=${this.model.isLoaded}`
          + ` recentlyAdded=${this.model.recentlyAdded.length}`
          + ` movies=${this.model.movies.length}`
          + ` seriesGroups=${this.model.seriesGroups.length}`
          + ` recentlyAddedList=${this.model.recentlyAddedList.length}`
          + ` ratingLabels=${this.model.ratingLabels.length}`
          + ` decadeGroups=${this.model.decadeGroups.length}`
        );
        // 诊断 build() 分支判断条件
        console.info(`[MediaLibraryTab][DIAG] build分支: isLoading=${this.model.isLoading}`
          + ` isLoaded=${this.model.isLoaded}`
          + ` recentlyAdded.length=${this.model.recentlyAdded.length}`
          + ` → 显示${this.model.isLoading ? 'Loading' : (!this.model.isLoaded || this.model.recentlyAdded.length === 0) ? 'Empty' : '内容'}`
        );
        if (this.model.seriesGroups.length > 0) {
          const sg = this.model.seriesGroups[0];
          console.info(`[MediaLibraryTab][DIAG] 第一个SeriesGroup: title="${sg.title}" episodeCount=${sg.episodeCount} posterUrl=${sg.posterUrl ?? 'null'} rating=${sg.rating ?? 'null'}`);
        }
        if (this.model.movies.length > 0) {
          const mv = this.model.movies[0];
          console.info(`[MediaLibraryTab][DIAG] 第一个Movie: title="${mv.title ?? 'null'}" posterUrl=${mv.posterUrl ?? 'null'} rating=${mv.rating ?? 'null'}`);
        }
      });
      // 加载可用的筛选选项（类型/年份）
      this.loadAvailableFilters().catch(() => {
        console.warn('[MediaLibraryTab] loadAvailableFilters 失败');
      });
    });
    // 播放器退出时刷新继续播放栏
    emitter.on(PlayerEvents.MEDIA_PROGRESS_SAVED, () => {
      console.info('[MediaLibraryTab][REFRESH] 收到 MEDIA_PROGRESS_SAVED 事件，触发 loadContinueWatching');
      this.model.loadContinueWatching().then(() => {
        console.info(`[MediaLibraryTab][REFRESH] loadContinueWatching 完成，列表长度=${this.model.continueWatchingList.length}`);
      }).catch(() => {
        console.warn('[MediaLibraryTab][REFRESH] loadContinueWatching 失败');
      });
    });
    console.info('[MediaLibraryTab][REFRESH] emitter 订阅已注册 eventId=15');
  }

  aboutToDisappear(): void {
    console.info('[MediaLibraryTab][REFRESH] aboutToDisappear 调用，取消订阅 eventId=15');
    emitter.off(PlayerEvents.MEDIA_PROGRESS_SAVED.eventId);
  }

  private async startIncrementalScan(): Promise<void> {
    await this.runScan('incremental');
  }

  private async startFixMissingScan(): Promise<void> {
    await this.runScan('fix-missing');
  }

  private startOverwriteScan(): void {
    if (this.isScanning) { return; }
    AlertDialog.show({
      title: '覆盖所有元数据',
      message: '「覆盖所有元数据」将重新刮削所有视频的信息，覆盖现有海报、评分、分类等数据。确定继续吗？',
      autoCancel: true,
      secondaryButton: {
        value: '取消',
        action: () => {}
      },
      primaryButton: {
        value: '确定覆盖',
        action: () => {
          this.runScan('overwrite');
        }
      }
    });
  }

  private async runScan(mode: ScanMode): Promise<void> {
    if (this.isScanning) { return; }
    this.isScanning = true;
    try {
      const context = this.getUIContext().getHostContext()!;
      const tmdbKey = await AppPreferences.get(PrefKey.TMDB_API_KEY, '');
      const scrapeClient = tmdbKey.length > 0 ? new ScrapeClient({ tmdbApiKey: tmdbKey }) : undefined;

      if (!scrapeClient) {
        promptAction.showToast({
          message: '未配置 TMDB API Key，将跳过刮削'
        });
      }

      const result = await VideoScannerUtil.scan(context, scrapeClient, { mode });
      const scrapeStats = result.scrapeSkippedVideos > 0
        ? `，已跳过 ${result.scrapeSkippedVideos} 个元数据完整的视频`
        : '';
      console.info(
        `[MediaLibraryTab] 扫描(${mode})完成，共 ${result.totalVideos} 个视频，` +
        `处理 ${result.processedVideos} 个，跳过 ${result.skippedVideos} 个，刮削跳过 ${result.scrapeSkippedVideos} 个，耗时 ${result.elapsedMs}ms`
      );
      await this.model.reload();
      promptAction.showToast({
        message: `扫描完成：共 ${result.totalVideos} 个视频${scrapeStats}`
      });
    } catch (e) {
      const err = e as Error;
      console.error(`[MediaLibraryTab] 扫描(${mode})异常: ${err.message}`);
      promptAction.showToast({
        message: `扫描失败: ` + err.message
      });
    } finally {
      this.isScanning = false;
    }
  }

  /**
   * 手动刷新元数据（重新刮削所有视频）
   */
  private async refreshMetadata(): Promise<void> {
    if (this.isScanning) { return; }
    this.isScanning = true;
    try {
      const context = this.getUIContext().getHostContext()!;
      const tmdbKey = await AppPreferences.get(PrefKey.TMDB_API_KEY, '');

      if (!tmdbKey || tmdbKey.length === 0) {
        promptAction.showToast({
          message: '请先配置 TMDB API Key'
        });
        return;
      }

      const scrapeClient = new ScrapeClient({ tmdbApiKey: tmdbKey });
      const db = FileSourceDatabase.getInstance(context);

      const allVideos = await db.getAllVideos();
      console.info(`[MediaLibraryTab] 开始刷新元数据，共 ${allVideos.length} 个视频`);

      let successCount = 0;
      let failedCount = 0;

      for (const video of allVideos) {
        try {
          // 刷新元数据：无论是否已有 scrape_info，都重新刮削并更新
          const parsed = parseFileName(video.fileName);
          if (parsed.mediaType === 'movie') {
            const movie = await scrapeClient.autoScrapeMovie(video.fileName);
            if (!movie) { failedCount++; continue; }

            let movieId: number;
            const existingMovie = await db.getMovieByProviderId(movie.provider, movie.providerId);
            if (existingMovie && existingMovie.id !== undefined) {
              movieId = existingMovie.id;
              // 刷新：始终用最新刮削结果覆盖
              const updateEntity: MovieEntity = {
                id: existingMovie.id,
                provider: movie.provider, providerId: movie.providerId, title: movie.title,
                originalTitle: movie.originalTitle, overview: movie.overview,
                releaseDate: movie.releaseDate, rating: movie.rating, voteCount: movie.voteCount,
                posterPath: movie.posterPath, backdropPath: movie.backdropPath,
                posterUrl: movie.posterUrl, backdropUrl: movie.backdropUrl,
                genresJson: movie.genresJson, castJson: movie.castJson,
                directorsJson: movie.directorsJson, runtime: movie.runtime,
                originalLanguage: movie.originalLanguage, rawJson: movie.rawJson,
                scrapedAt: Date.now()
              };
              await db.upsertMovie(updateEntity);
            } else {
              const movieEntity: MovieEntity = {
                provider: movie.provider, providerId: movie.providerId, title: movie.title,
                originalTitle: movie.originalTitle, overview: movie.overview,
                releaseDate: movie.releaseDate, rating: movie.rating, voteCount: movie.voteCount,
                posterPath: movie.posterPath, backdropPath: movie.backdropPath,
                posterUrl: movie.posterUrl, backdropUrl: movie.backdropUrl,
                genresJson: movie.genresJson, castJson: movie.castJson,
                directorsJson: movie.directorsJson, runtime: movie.runtime,
                originalLanguage: movie.originalLanguage, rawJson: movie.rawJson,
                scrapedAt: Date.now()
              };
              movieId = await db.upsertMovie(movieEntity);
            }
            const scrapeInfo: ScrapeInfoEntity = {
              videoId: video.id!, provider: movie.provider, providerId: movie.providerId,
              mediaType: 'movie', title: movie.title, originalTitle: movie.originalTitle,
              movieId, scrapedAt: Date.now()
            };
            await db.upsertScrapeInfo(scrapeInfo);
            successCount++;
          } else {
            const result = await scrapeClient.autoScrapeTvEpisode(video.fileName);
            if (!result.series) { failedCount++; continue; }
            const series: TvSeriesScrapeResult = result.series!;
            const season = result.season;
            const episode = result.episode;

            let seriesId: number;
            const seriesEntity: TvSeriesEntity = {
              provider: series.provider, providerId: series.providerId, title: series.title,
              originalTitle: series.originalTitle, overview: series.overview,
              firstAirDate: series.firstAirDate, rating: series.rating, voteCount: series.voteCount,
              posterPath: series.posterPath, backdropPath: series.backdropPath,
              posterUrl: series.posterUrl, backdropUrl: series.backdropUrl,
              genresJson: series.genresJson, castJson: series.castJson,
              numberOfSeasons: series.numberOfSeasons,
              originalLanguage: series.originalLanguage, rawJson: series.rawJson,
              scrapedAt: Date.now()
            };
            seriesId = await db.upsertTvSeries(seriesEntity);

            let seasonId: number | undefined;
            if (season) {
              const existingSeason = await db.getTvSeason(seriesId, season.seasonNumber);
              if (existingSeason && existingSeason.id !== undefined) {
                seasonId = existingSeason.id;
              } else {
                const seasonEntity: TvSeasonEntity = {
                  seriesId, provider: season.provider, providerId: season.providerId,
                  seasonNumber: season.seasonNumber, title: season.title,
                  overview: season.overview, airDate: season.airDate,
                  episodeCount: season.episodeCount, posterPath: season.posterPath,
                  posterUrl: season.posterUrl, rawJson: season.rawJson, scrapedAt: Date.now()
                };
                seasonId = await db.upsertTvSeason(seasonEntity);
              }
            }

            let episodeId: number | undefined;
            if (episode) {
              const existingEp = await db.getTvEpisode(seriesId, episode.seasonNumber, episode.episodeNumber);
              if (existingEp && existingEp.id !== undefined) {
                episodeId = existingEp.id;
              } else {
                const epEntity: TvEpisodeEntity = {
                  seriesId, seasonId, provider: episode.provider, providerId: episode.providerId,
                  seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber,
                  title: episode.title, overview: episode.overview, airDate: episode.airDate,
                  runtime: episode.runtime, rating: episode.rating,
                  stillPath: episode.stillPath, stillUrl: episode.stillUrl,
                  rawJson: episode.rawJson, scrapedAt: Date.now()
                };
                episodeId = await db.upsertTvEpisode(epEntity);
              }
            }

            const mediaType = episodeId !== undefined ? 'episode' : 'tv';
            const scrapeInfo: ScrapeInfoEntity = {
              videoId: video.id!, provider: series.provider,
              providerId: episodeId !== undefined ? (episode?.providerId ?? series.providerId) : series.providerId,
              mediaType, title: episode?.title ?? series.title, originalTitle: series.originalTitle,
              tvSeriesId: seriesId, episodeId,
              seasonNumber: parsed.seasonNumber, episodeNumber: parsed.episodeNumber,
              scrapedAt: Date.now()
            };
            await db.upsertScrapeInfo(scrapeInfo);
            successCount++;
          }
          console.info(`[MediaLibraryTab] 刮削成功: ${video.fileName}`);
        } catch (e) {
          failedCount++;
          const err = e as Error;
          console.error(`[MediaLibraryTab] 刮削异常: ${video.fileName}, ${err.message}`);
        }
      }

      await this.model.reload();
      promptAction.showToast({ message: `刷新完成：成功 ${successCount} 个，失败 ${failedCount} 个` });
    } catch (e) {
      const err = e as Error;
      console.error(`[MediaLibraryTab] 刷新元数据异常: ${err.message}`);
      promptAction.showToast({ message: '刷新失败: ' + err.message });
    } finally {
      this.isScanning = false;
    }
  }

  /**
   * 仅刷新视频音轨/字幕轨元数据（ffprobe），用于补齐字幕 title/语言信息。
   *
   * 说明：
   * - 目前仅处理 WebDAV 文件源。
   * - 不改 scrape_info/movie/tv_* 数据。
   */
  private async refreshSubtitleTrackMetadata(): Promise<void> {
    if (this.isScanning) { return; }
    this.isScanning = true;
    try {
      const db = FileSourceDatabase.getInstance();
      const videos = await db.getAllVideos();
      if (videos.length === 0) {
        promptAction.showToast({ message: '暂无视频可刷新' });
        return;
      }

      const sources = await db.getAllFileSources();
      const sourceMap = new Map<number, SourceRuntimeConfig>();
      for (const s of sources) {
        if (s.id !== undefined) {
          const sourceConfig: SourceRuntimeConfig = {
            type: s.type,
            configJson: s.configJson
          };
          sourceMap.set(s.id, sourceConfig);
        }
      }

      const clientMap = new Map<number, WebDAVClient>();
      const getClient = (sourceId: number): WebDAVClient | null => {
        const cached = clientMap.get(sourceId);
        if (cached !== undefined) { return cached; }

        const source = sourceMap.get(sourceId);
        if (source === undefined || source.type !== FileSourceType.WEBDAV) {
          return null;
        }

        const config = JSON.parse(source.configJson) as Record<string, string>;
        const protocol = config['protocol'] ?? 'http';
        const host = config['url'] ?? '';
        const port = config['port'] ?? (protocol === 'https' ? '443' : '80');
        const rootPath = (config['rootPath'] ?? '').replace(/\/$/, '');
        const normalizedRoot = rootPath.length > 0
          ? (rootPath.startsWith('/') ? rootPath : '/' + rootPath)
          : '';
        const baseUrl = `${protocol}://${host}:${port}${normalizedRoot}`;

        const webdavConfig: WebDAVConfig = {
          baseUrl,
          username: config['username'] ?? '',
          password: config['password'] ?? '',
          timeout: 30000,
          tlsCertPolicy: config['tlsCertPolicy'] === 'strict' ? 'strict' : 'allow_self_signed'
        };
        const client = new WebDAVClient(webdavConfig);
        clientMap.set(sourceId, client);
        return client;
      };

      let refreshed = 0;
      let skipped = 0;
      let failed = 0;

      for (const video of videos) {
        try {
          const client = getClient(video.sourceId);
          if (client === null) {
            skipped++;
            continue;
          }

          const fullUrl = client.getFullUrl(video.filePath);
          const authHeader = client.getAuthHeaderPublic();
          const headers: Record<string, string> = authHeader ? { 'Authorization': authHeader } : {};
          const probe = await FfprobeUtil.probe(encodeURI(fullUrl), headers, 15000);
          if (!probe.success) {
            failed++;
            console.warn(`[MediaLibraryTab] 刷新轨道失败 file=${video.fileName} err=${probe.errorMessage ?? ''}`);
            continue;
          }

          const mainVideo = probe.videoTracks.length > 0 ? probe.videoTracks[0] : undefined;
          await db.upsertVideo({
            sourceId: video.sourceId,
            directoryPath: video.directoryPath,
            filePath: video.filePath,
            fileName: video.fileName,
            fileSize: video.fileSize,
            lastModified: video.lastModified,
            contentType: video.contentType,
            durationMs: probe.durationMs,
            width: mainVideo?.width,
            height: mainVideo?.height,
            frameRate: mainVideo?.frameRate,
            videoCodec: mainVideo?.codecName,
            audioTracksJson: JSON.stringify(probe.audioTracks),
            subtitleTracksJson: JSON.stringify(probe.subtitleTracks),
            scannedAt: Date.now()
          });
          refreshed++;
        } catch (e) {
          failed++;
          console.warn(`[MediaLibraryTab] 刷新轨道异常 file=${video.fileName} err=${JSON.stringify(e)}`);
        }
      }

      await this.model.reload();
      promptAction.showToast({
        message: `字幕轨刷新完成：成功 ${refreshed}，跳过 ${skipped}，失败 ${failed}`
      });
    } catch (e) {
      const err = e as Error;
      console.error(`[MediaLibraryTab] 刷新字幕轨元数据异常: ${err.message}`);
      promptAction.showToast({ message: '刷新字幕轨失败: ' + err.message });
    } finally {
      this.isScanning = false;
    }
  }

  private showRefreshSubtitleTrackDialog(): void {
    if (this.isScanning) { return; }
    AlertDialog.show({
      title: '刷新字幕轨信息',
      message: '将重新探测媒体库视频的音轨/字幕轨信息（仅 WebDAV），可能耗时较长。是否继续？',
      autoCancel: true,
      secondaryButton: {
        value: '取消',
        action: () => {}
      },
      primaryButton: {
        value: '确认刷新',
        action: () => {
          this.refreshSubtitleTrackMetadata();
        }
      }
    });
  }

  // ─────────────────────────────────────────────
  // 筛选逻辑方法
  // ─────────────────────────────────────────────

  /** 是否有激活的筛选条件（含非默认排序） */
  private isFilteredViewActive(): boolean {
    return this.filterGenres.length > 0
      || this.filterYears.length > 0
      || this.filterRecentlyPlayed
      || this.filterUnwatched
      || this.filterSortBy !== 'updated';
  }

  /** 加载可用的类型/年份选项 */
  private async loadAvailableFilters(): Promise<void> {
    const db = FileSourceDatabase.getInstance();
    const genres = await db.getDistinctGenreNames();
    const years = await db.getDistinctYears();
    this.availableGenres = genres;
    this.availableYears = years;
    console.info(`[MediaLibraryTab][Filter] 类型=${genres.length} 年份=${years.length}`);
  }

  /**
   * 加载筛选结果列表。
   * @param resetPage true = 重置分页（筛选条件变化时），false = 追加下一页
   */
  private async loadFilteredList(resetPage: boolean): Promise<void> {
    if (resetPage) {
      this.filterCurrentOffset = 0;
      this.filteredList = [];
    }
    this.isFilteredLoading = true;
    try {
      const db = FileSourceDatabase.getInstance();
      const PAGE_SIZE = 20;
      // ArkTS 约束：对象字面量不能直接作为泛型类型参数内联，先声明显式类型变量
      const opts: MediaFilterOptions = {
        genres: this.filterGenres.length > 0 ? this.filterGenres : undefined,
        years: this.filterYears.length > 0 ? this.filterYears : undefined,
        recentlyPlayed: this.filterRecentlyPlayed ? true : undefined,
        unwatched: this.filterUnwatched ? true : undefined,
        sortBy: this.filterSortBy === 'name' ? 'name'
          : this.filterSortBy === 'year' ? 'year'
          : 'updated',
      };
      // 多取 1 条用于判断是否有下一页
      const items = await db.getFilteredMediaList(opts, this.filterCurrentOffset, PAGE_SIZE + 1);
      this.filterHasMore = items.length > PAGE_SIZE;
      const pageItems = items.slice(0, PAGE_SIZE);
      if (resetPage) {
        this.filteredList = pageItems;
      } else {
        // 追加模式：构建新数组避免直接 push 触发不了响应式
        const newList: MediaListItem[] = [];
        for (const it of this.filteredList) { newList.push(it); }
        for (const it of pageItems) { newList.push(it); }
        this.filteredList = newList;
      }
      this.filterCurrentOffset = this.filterCurrentOffset + pageItems.length;
      console.info(
        `[MediaLibraryTab][Filter] 结果数=${this.filteredList.length}` +
        ` hasMore=${this.filterHasMore} offset=${this.filterCurrentOffset}`
      );
    } catch (e) {
      console.error('[MediaLibraryTab][Filter] loadFilteredList 失败', JSON.stringify(e));
    } finally {
      this.isFilteredLoading = false;
    }
  }

  /** 加载下一页筛选结果 */
  private loadMoreFiltered(): void {
    if (this.filterHasMore && !this.isFilteredLoading) {
      this.loadFilteredList(false).catch(() => {});
    }
  }

  /** 切换类型筛选 */
  private toggleGenre(genre: string): void {
    if (this.filterGenres.indexOf(genre) >= 0) {
      this.filterGenres = this.filterGenres.filter((g: string): boolean => g !== genre);
    } else {
      const next: string[] = [...this.filterGenres, genre];
      this.filterGenres = next;
    }
    this.loadFilteredList(true).catch(() => {});
  }

  /** 切换年份筛选 */
  private toggleYear(year: number): void {
    if (this.filterYears.indexOf(year) >= 0) {
      this.filterYears = this.filterYears.filter((y: number): boolean => y !== year);
    } else {
      const next: number[] = [...this.filterYears, year];
      this.filterYears = next;
    }
    this.loadFilteredList(true).catch(() => {});
  }

  /** 切换「最近播放」快速筛选 */
  private toggleRecentlyPlayed(): void {
    this.filterRecentlyPlayed = !this.filterRecentlyPlayed;
    if (this.filterUnwatched && this.filterRecentlyPlayed) {
      // 两者互斥，激活「最近播放」时关闭「未看完」
      this.filterUnwatched = false;
    }
    this.loadFilteredList(true).catch(() => {});
  }

  /** 切换「未看完」快速筛选 */
  private toggleUnwatched(): void {
    this.filterUnwatched = !this.filterUnwatched;
    if (this.filterRecentlyPlayed && this.filterUnwatched) {
      // 两者互斥，激活「未看完」时关闭「最近播放」
      this.filterRecentlyPlayed = false;
    }
    this.loadFilteredList(true).catch(() => {});
  }

  /** 设置排序方式 */
  private setSortBy(sort: string): void {
    if (this.filterSortBy === sort) { return; }
    this.filterSortBy = sort;
    this.loadFilteredList(true).catch(() => {});
  }

  /** 清除所有筛选条件，恢复默认视图 */
  private clearAllFilters(): void {
    this.filterGenres = [];
    this.filterYears = [];
    this.filterRecentlyPlayed = false;
    this.filterUnwatched = false;
    this.filterSortBy = 'updated';
    this.filteredList = [];
    this.filterCurrentOffset = 0;
    this.filterHasMore = false;
  }

  private getStatsText(): string {
    const s = this.model.stats;
    return `共 ${s.total} 个视频 · 电影 ${s.movies} 部 · 电视剧 ${s.tv} 部 · 其他 ${s.other} 个`;
  }

  private getLastScanText(): string {
    return `上次扫描：${formatScanTime(this.model.latestScanTime)}`;
  }

  // ── Builders ──────────────────────────────────

  // ─────────────────────────────────────────────
  // 筛选栏 FilterBar
  // ─────────────────────────────────────────────
  @Builder
  FilterBar() {
    Column({ space: 0 }) {
      // ── 第一行：排序 + 快速筛选 ──
      Scroll() {
        Row({ space: 8 }) {
          // 排序标签
          Text('排序:')
            .fontSize(12).fontColor('rgba(255,255,255,0.45)')
            .padding({ right: 4 })

          // 排序按钮：最近添加
          Text('最近添加')
            .fontSize(13)
            .fontColor(this.filterSortBy === 'updated' ? '#000000' : 'rgba(255,255,255,0.80)')
            .fontWeight(this.filterSortBy === 'updated' ? FontWeight.Bold : FontWeight.Normal)
            .backgroundColor(this.filterSortBy === 'updated' ? '#FFFFFF' : 'rgba(255,255,255,0.10)')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(16)
            .focusable(true)
            .focusOnTouch(true)
            .border({
              width: 2,
              color: this.filterSortBy === 'updated' ? '#FFFFFF' : 'rgba(255,255,255,0.0)'
            })
            .animation({ duration: 120, curve: Curve.EaseInOut })
            .onClick(() => { this.setSortBy('updated'); })

          // 排序按钮：名称
          Text('名称')
            .fontSize(13)
            .fontColor(this.filterSortBy === 'name' ? '#000000' : 'rgba(255,255,255,0.80)')
            .fontWeight(this.filterSortBy === 'name' ? FontWeight.Bold : FontWeight.Normal)
            .backgroundColor(this.filterSortBy === 'name' ? '#FFFFFF' : 'rgba(255,255,255,0.10)')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(16)
            .focusable(true)
            .focusOnTouch(true)
            .border({
              width: 2,
              color: this.filterSortBy === 'name' ? '#FFFFFF' : 'rgba(255,255,255,0.0)'
            })
            .animation({ duration: 120, curve: Curve.EaseInOut })
            .onClick(() => { this.setSortBy('name'); })

          // 排序按钮：年份
          Text('年份')
            .fontSize(13)
            .fontColor(this.filterSortBy === 'year' ? '#000000' : 'rgba(255,255,255,0.80)')
            .fontWeight(this.filterSortBy === 'year' ? FontWeight.Bold : FontWeight.Normal)
            .backgroundColor(this.filterSortBy === 'year' ? '#FFFFFF' : 'rgba(255,255,255,0.10)')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(16)
            .focusable(true)
            .focusOnTouch(true)
            .border({
              width: 2,
              color: this.filterSortBy === 'year' ? '#FFFFFF' : 'rgba(255,255,255,0.0)'
            })
            .animation({ duration: 120, curve: Curve.EaseInOut })
            .onClick(() => { this.setSortBy('year'); })

          // 分隔线
          Divider().vertical(true).height(18).color('rgba(255,255,255,0.20)').strokeWidth(1)

          // 快速筛选：最近播放
          Text('▶ 最近播放')
            .fontSize(13)
            .fontColor(this.filterRecentlyPlayed ? '#000000' : 'rgba(255,255,255,0.80)')
            .fontWeight(this.filterRecentlyPlayed ? FontWeight.Bold : FontWeight.Normal)
            .backgroundColor(this.filterRecentlyPlayed ? '#4A9FFF' : 'rgba(255,255,255,0.10)')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(16)
            .focusable(true)
            .focusOnTouch(true)
            .border({
              width: 2,
              color: this.filterRecentlyPlayed ? '#4A9FFF' : 'rgba(255,255,255,0.0)'
            })
            .animation({ duration: 120, curve: Curve.EaseInOut })
            .onClick(() => { this.toggleRecentlyPlayed(); })

          // 快速筛选：未看完
          Text('⏸ 未看完')
            .fontSize(13)
            .fontColor(this.filterUnwatched ? '#000000' : 'rgba(255,255,255,0.80)')
            .fontWeight(this.filterUnwatched ? FontWeight.Bold : FontWeight.Normal)
            .backgroundColor(this.filterUnwatched ? '#52C41A' : 'rgba(255,255,255,0.10)')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(16)
            .focusable(true)
            .focusOnTouch(true)
            .border({
              width: 2,
              color: this.filterUnwatched ? '#52C41A' : 'rgba(255,255,255,0.0)'
            })
            .animation({ duration: 120, curve: Curve.EaseInOut })
            .onClick(() => { this.toggleUnwatched(); })

          // 清除全部筛选按钮（仅筛选激活时显示）
          if (this.isFilteredViewActive()) {
            Text('× 清除')
              .fontSize(13)
              .fontColor('#FF6B6B')
              .backgroundColor('rgba(255,107,107,0.12)')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(16)
              .focusable(true)
              .focusOnTouch(true)
              .border({ width: 2, color: 'rgba(255,107,107,0.0)' })
              .animation({ duration: 120, curve: Curve.EaseInOut })
              .onClick(() => { this.clearAllFilters(); })
          }
        }
        .padding({ left: 16, right: 16 })
        .alignItems(VerticalAlign.Center)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ top: 4, bottom: 4 })

      // ── 第二行：类型筛选 chips（有类型时才显示）──
      if (this.availableGenres.length > 0) {
        Scroll() {
          Row({ space: 6 }) {
            Text('类型:')
              .fontSize(12).fontColor('rgba(255,255,255,0.45)')
              .padding({ right: 2 })

            ForEach(this.availableGenres.slice(0, 12), (genre: string) => {
              Text(genre)
                .fontSize(12)
                .fontColor(this.filterGenres.indexOf(genre) >= 0 ? '#000000' : 'rgba(255,255,255,0.75)')
                .fontWeight(this.filterGenres.indexOf(genre) >= 0 ? FontWeight.Bold : FontWeight.Normal)
                .backgroundColor(
                  this.filterGenres.indexOf(genre) >= 0 ? '#FFA500' : 'rgba(255,255,255,0.08)'
                )
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .borderRadius(14)
                .focusable(true)
                .focusOnTouch(true)
                .border({
                  width: 1.5,
                  color: this.filterGenres.indexOf(genre) >= 0 ? '#FFA500' : 'rgba(255,255,255,0.15)'
                })
                .animation({ duration: 120, curve: Curve.EaseInOut })
                .onClick(() => { this.toggleGenre(genre); })
            }, (genre: string) => `genre_${genre}`)
          }
          .padding({ left: 16, right: 16 })
          .alignItems(VerticalAlign.Center)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .margin({ bottom: 4 })
      }

      // ── 第三行：年份筛选 chips（有年份时才显示）──
      if (this.availableYears.length > 0) {
        Scroll() {
          Row({ space: 6 }) {
            Text('年份:')
              .fontSize(12).fontColor('rgba(255,255,255,0.45)')
              .padding({ right: 2 })

            ForEach(this.availableYears.slice(0, 15), (year: number) => {
              Text(String(year))
                .fontSize(12)
                .fontColor(this.filterYears.indexOf(year) >= 0 ? '#000000' : 'rgba(255,255,255,0.75)')
                .fontWeight(this.filterYears.indexOf(year) >= 0 ? FontWeight.Bold : FontWeight.Normal)
                .backgroundColor(
                  this.filterYears.indexOf(year) >= 0 ? '#8B5CF6' : 'rgba(255,255,255,0.08)'
                )
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .borderRadius(14)
                .focusable(true)
                .focusOnTouch(true)
                .border({
                  width: 1.5,
                  color: this.filterYears.indexOf(year) >= 0 ? '#8B5CF6' : 'rgba(255,255,255,0.15)'
                })
                .animation({ duration: 120, curve: Curve.EaseInOut })
                .onClick(() => { this.toggleYear(year); })
            }, (year: number) => `year_${year}`)
          }
          .padding({ left: 16, right: 16 })
          .alignItems(VerticalAlign.Center)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .margin({ bottom: 6 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor('rgba(0,0,0,0.25)')
    .padding({ top: 8, bottom: 8 })
    .margin({ bottom: 8 })
  }

  // ─────────────────────────────────────────────
  // 筛选结果内容区
  // ─────────────────────────────────────────────
  @Builder
  FilteredContent() {
    Column() {
      // 结果统计行
      Row({ space: 8 }) {
        Text(`筛选结果  ${this.filteredList.length}${this.filterHasMore ? '+' : ''} 项`)
          .fontSize(13)
          .fontColor('rgba(255,255,255,0.55)')
          .padding({ left: 16 })
          .layoutWeight(1)

        if (this.isFilteredLoading) {
          LoadingProgress()
            .width(18).height(18).color('#AAAAAA')
            .margin({ right: 16 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 12 })

      if (this.isFilteredLoading && this.filteredList.length === 0) {
        // 首次加载中
        Column() {
          LoadingProgress().width(36).height(36).color('#AAAAAA')
          Text('筛选中...').fontSize(13).fontColor('#888888').margin({ top: 10 })
        }
        .width('100%').height(240)
        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else if (this.filteredList.length === 0) {
        // 空态
        Column() {
          Text('🔍').fontSize(36).margin({ bottom: 12 })
          Text('没有符合条件的媒体').fontSize(15).fontColor('#666666')
          Text('请尝试修改或清除筛选条件').fontSize(12).fontColor('#444444').margin({ top: 6 })
        }
        .width('100%').height(240)
        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else {
        // 筛选结果网格（海报卡片自动换行）
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Start }) {
          ForEach(
            this.filteredList,
            (listItem: MediaListItem) => {
              MixedCard({ listItem })
            },
            (listItem: MediaListItem, idx: number) => {
              if (listItem.kind === 'series' && listItem.series !== undefined) {
                return 'series_' + listItem.series.tvSeriesId + '_' + idx;
              }
              if (listItem.kind === 'video' && listItem.video !== undefined) {
                return 'video_' + (listItem.video.id ?? idx) + '_' + idx;
              }
              return 'item_' + idx;
            }
          )
        }
        .padding({ left: 16, right: 16 })
        .width('100%')

        // 加载更多按钮
        if (this.filterHasMore) {
          Button('加载更多', { type: ButtonType.Normal, stateEffect: true })
            .fontSize(14)
            .fontColor('#4A9FFF')
            .backgroundColor('rgba(74,159,255,0.12)')
            .borderRadius(8)
            .padding({ left: 24, right: 24, top: 10, bottom: 10 })
            .border({ width: 1, color: 'rgba(74,159,255,0.30)' })
            .margin({ top: 16, bottom: 16 })
            .focusable(true)
            .enabled(!this.isFilteredLoading)
            .onClick(() => { this.loadMoreFiltered(); })
            .alignSelf(ItemAlign.Center)
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ContinueWatchingSection() {
    Column() {
      Row() {
        Text('继续播放')
          .fontSize(14)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Bold)
          .padding({ left: 16 })
          .layoutWeight(1)

        Text('查看全部 →')
          .fontSize(13)
          .fontColor(this.isViewAllFocused ? '#FFFFFF' : 'rgba(255,255,255,0.55)')
          .fontWeight(FontWeight.Medium)
          .padding({ left: 12, right: 16, top: 6, bottom: 6 })
          .backgroundColor(this.isViewAllFocused ? 'rgba(255,255,255,0.12)' : Color.Transparent)
          .borderRadius(6)
          .border({ width: this.isViewAllFocused ? 2 : 0, color: '#FFFFFF' })
          .focusable(true)
          .onFocus(() => { this.isViewAllFocused = true })
          .onBlur(() => { this.isViewAllFocused = false })
          .onClick(() => {
            this.pageStack.pushPathByName(PlayHistoryPage.PAGE_NAME, null)
          })
          .animation({ duration: 140, curve: Curve.EaseInOut })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: 44 })
      .margin({ bottom: 8 })

      Scroll() {
        Row({ space: 10 }) {
          if (this.model.continueWatchingList.length > 0) {
            ForEach(
              this.model.continueWatchingList,
              (item: ContinueWatchingItem) => {
                ContinueWatchCard({ item })
              },
              (item: ContinueWatchingItem) => `${item.mediaKey}_${item.startPositionMs}`
            )
          } else {
            PlaceholderWideCard({ label: '暂无播放记录' })
          }
        }
        .padding({ left: 16, right: 16 })
        .alignItems(VerticalAlign.Top)
      }
      .align(Alignment.Start)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%').alignItems(HorizontalAlign.Start).margin({ bottom: 20 })
  }

  @Builder
  RecentlyAddedSection() {
    if (this.model.recentlyAddedList.length > 0) {
      SectionRow({ title: '最近添加' }) {
        ForEach(this.model.recentlyAddedList.slice(0, 20), (listItem: MediaListItem) => {
          MixedCard({ listItem })
        })
      }
    }
  }

  @Builder
  MoviesSection() {
    if (this.model.movies.length > 0) {
      SectionRow({
        title: `电影片库  (${this.model.movies.length})`,
        showAction: true,
        actionLabel: '查看全部 >',
        onAction: () => {
          const param: MediaResultPageParam = { pageTitle: '全部电影', mediaType: 'movie' };
          this.pageStack.pushPathByName(MediaResultPage.PAGE_NAME, param);
        }
      }) {
        ForEach(this.model.movies.slice(0, 30), (item: MediaItem) => {
          PosterCard({ item })
        })
      }
    }
  }

  @Builder
  TvShowsSection() {
    if (this.model.seriesGroups.length > 0) {
      SectionRow({
        title: `电视剧片库  (${this.model.seriesGroups.length} 部)`,
        showAction: true,
        actionLabel: '查看全部 >',
        onAction: () => {
          const param: MediaResultPageParam = { pageTitle: '全部电视剧', mediaType: 'tv' };
          this.pageStack.pushPathByName(MediaResultPage.PAGE_NAME, param);
        }
      }) {
        ForEach(this.model.seriesGroups.slice(0, 30), (group: SeriesGroup) => {
          SeriesCard({ group })
        })
      }
    }
  }

  @Builder
  UnwatchedSection() {
    if (this.model.unwatchedList.length > 0) {
      SectionRow({ title: '未观看' }) {
        ForEach(this.model.unwatchedList.slice(0, 20), (listItem: MediaListItem) => {
          MixedCard({ listItem })
        })
      }
    }
  }

  @Builder
  StatsAndScan() {
    Column() {
      Divider().color('#333333').margin({ bottom: 12 })

      Text(this.getStatsText())
        .fontSize(12).fontColor('#888888').textAlign(TextAlign.Center).width('100%').margin({ bottom: 8 })

      Text(this.getLastScanText())
        .fontSize(11).fontColor('#555555').textAlign(TextAlign.Center).width('100%').margin({ bottom: 16 })

      Column({ space: 10 }) {
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          Column({ space: 5 }) {
            Text(this.isScanning ? '扫描中...' : '扫描新增和已修改的文件')
              .fontSize(15).fontColor(this.isScanning ? '#555555' : '#4A9FFF')
              .fontWeight(FontWeight.Medium).width('100%').textAlign(TextAlign.Start)
            Text('仅处理新增或已改动的文件，已有元数据不受影响')
              .fontSize(12).fontColor('#AAAAAA').width('100%').textAlign(TextAlign.Start)
          }
          .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%').backgroundColor('#1C1C1C').borderRadius(10)
        .enabled(!this.isScanning)
        .onClick(() => { this.startIncrementalScan(); })

        Button({ type: ButtonType.Normal, stateEffect: true }) {
          Column({ space: 5 }) {
            Text(this.isScanning ? '扫描中...' : '补全缺少的元数据')
              .fontSize(15).fontColor(this.isScanning ? '#555555' : '#52C41A')
              .fontWeight(FontWeight.Medium).width('100%').textAlign(TextAlign.Start)
            Text('为缺少海报或信息的视频重新补全，已完整的跳过')
              .fontSize(12).fontColor('#AAAAAA').width('100%').textAlign(TextAlign.Start)
          }
          .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%').backgroundColor('#1C1C1C').borderRadius(10)
        .enabled(!this.isScanning)
        .onClick(() => { this.startFixMissingScan(); })

        Button({ type: ButtonType.Normal, stateEffect: true }) {
          Column({ space: 5 }) {
            Text(this.isScanning ? '扫描中...' : '覆盖所有元数据')
              .fontSize(15).fontColor(this.isScanning ? '#555555' : '#FF8C4A')
              .fontWeight(FontWeight.Medium).width('100%').textAlign(TextAlign.Start)
            Text('重新刮削全部视频，覆盖现有海报、评分和分类')
              .fontSize(12).fontColor('#AAAAAA').width('100%').textAlign(TextAlign.Start)
          }
          .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%').backgroundColor('#1C1C1C').borderRadius(10)
        .enabled(!this.isScanning)
        .onClick(() => { this.startOverwriteScan(); })
      }
      .width('100%').margin({ bottom: 40 })
    }
    .width('100%').alignItems(HorizontalAlign.Center).padding({ left: 16, right: 16 })
  }

  @Builder
  LoadingView() {
    Column() {
      LoadingProgress().width(40).height(40).color('#AAAAAA')
      Text('加载中...').fontSize(13).fontColor('#888888').margin({ top: 12 })
    }
    .width('100%').height(300).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }

  @Builder
  EmptyView() {
    Column() {
      Text('暂无媒体').fontSize(16).fontColor('#666666')
      Text('请先配置文件源并点击"扫描新的和有修改的文件"')
        .fontSize(12).fontColor('#444444').margin({ top: 8 })
    }
    .width('100%').height(300).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }

  build() {
    Column() {
      // 筛选栏（始终显示）
      this.FilterBar()

      if (this.isFilteredViewActive()) {
        // 筛选/排序激活时：显示筛选结果视图
        this.FilteredContent()
      } else if (this.model.isLoading) {
        this.ContinueWatchingSection()
        this.LoadingView()
      } else if (!this.model.isLoaded || this.model.recentlyAdded.length === 0) {
        this.ContinueWatchingSection()
        this.EmptyView()
        this.StatsAndScan()
      } else {
        this.ContinueWatchingSection()
        this.RecentlyAddedSection()
        this.MoviesSection()
        this.TvShowsSection()
        this.UnwatchedSection()
        this.StatsAndScan()
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }
}