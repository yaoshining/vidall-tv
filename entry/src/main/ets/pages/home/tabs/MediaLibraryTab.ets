import { TabBarModel, TabItem } from "../../../stores/tabbar/TabBarModel"
import { TabBarStore } from "../../../stores/tabbar/TabBarStore"
import { VideoScannerUtil } from "../../../utils/VideoScannerUtil"
import { ScrapeClient } from "../../../lib/ScrapeClient"
import { AppPreferences, PrefKey } from "../../../utils/AppPreferences"
import { MediaItem, MediaStats, SeriesGroup, DecadeGroup, MediaListItem } from "../../../db/models/MediaEntity"
import { MediaLibraryModel, RatingLabel } from "../../../stores/media/MediaLibraryModel"
import { FileSourceDatabase } from "../../../db/files/FileSourceDatabase"

// ─────────────────────────────────────────────
// 常量
// ─────────────────────────────────────────────
const POSTER_WIDTH = 180;
const PORTRAIT_ASPECT_RATIO = 2/3;
const LANDSCAPE_ASPECT_RATIO = 16/9;

const WIDE_WIDTH = 360;
// const WIDE_HEIGHT = 135;
/** 评分标签卡片尺寸 */
const RATING_CARD_W = 110;
const RATING_CARD_H = 60;
/** 年代标签卡片尺寸 */
const DECADE_CARD_W = 120;
const DECADE_CARD_H = 60;

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
function genreList(item: MediaItem): string[] {
  if (!item.genresJson) { return []; }
  try { return JSON.parse(item.genresJson) as string[]; } catch { return []; }
}
function formatScanTime(ts: number): string {
  if (ts === 0) { return '从未扫描'; }
  const d = new Date(ts);
  const pad = (n: number): string => n < 10 ? '0' + n : String(n);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

// ─────────────────────────────────────────────
// 海报卡片（9:16）
// ─────────────────────────────────────────────
@ComponentV2
struct PosterCard {
  @Require @Param item: MediaItem
  private getTitle(): string { return displayTitle(this.item); }
  private getPoster(): string { return posterSrc(this.item); }
  private hasPosterImg(): boolean { return hasPoster(this.item); }
  private getRating(): string { return ratingText(this.item); }
  private getResolution(): string { return resolutionLabel(this.item.width, this.item.height); }

  build() {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        // 海报图 / 占位
        if (this.hasPosterImg()) {
          Image(this.getPoster())
            .width(POSTER_WIDTH)
            .aspectRatio(PORTRAIT_ASPECT_RATIO)
            .hoverEffect(HoverEffect.Scale)
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
      }
      .borderRadius(6)
      .clip(true)
      .width(POSTER_WIDTH)
      .aspectRatio(PORTRAIT_ASPECT_RATIO)

      Text(this.getTitle())
        .fontSize(16).fontColor('#DDDDDD').maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(POSTER_WIDTH).margin({ top: 4 })
        .textAlign(TextAlign.Center)
    }
    .width(POSTER_WIDTH)
    .alignItems(HorizontalAlign.Start)
  }
}

// ─────────────────────────────────────────────
// 合集卡片（电视剧/综艺）
// ─────────────────────────────────────────────
@ComponentV2
struct SeriesCard {
  @Require @Param group: SeriesGroup

  private getTitle(): string { return this.group.title; }
  private getPoster(): string {
    return this.group.posterLocalPath ?? this.group.posterUrl ?? '';
  }
  private hasPosterImg(): boolean {
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

  build() {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        // 海报图 / 占位
        if (this.hasPosterImg()) {
          Image(this.getPoster())
            .width(POSTER_WIDTH)
            .aspectRatio(PORTRAIT_ASPECT_RATIO)
            .hoverEffect(HoverEffect.Scale)
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

        // 底部黑色渐变（覆盖下方 28%）
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
            .width('32fp')
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
      }
      .borderRadius(6)
      .clip(true)
      .width(POSTER_WIDTH)
      .aspectRatio(PORTRAIT_ASPECT_RATIO)

      Text(this.getTitle())
        .fontSize(16).fontColor('#DDDDDD').maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width(POSTER_WIDTH)
        .margin({ top: 4 })
    }
    .width(POSTER_WIDTH).alignItems(HorizontalAlign.Start)
  }
}

// ─────────────────────────────────────────────
// 评分标签卡片（只显示分数段，不显示具体内容）
// ─────────────────────────────────────────────
@ComponentV2
struct RatingLabelCard {
  @Require @Param ratingLabel: RatingLabel

  private getLabelColor(): string {
    if (this.ratingLabel.minRating >= 9) { return '#FFD700'; }
    if (this.ratingLabel.minRating >= 8) { return '#FFA500'; }
    if (this.ratingLabel.minRating >= 7) { return '#90EE90'; }
    if (this.ratingLabel.minRating >= 6) { return '#87CEEB'; }
    return '#AAAAAA';
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(RATING_CARD_W).height(RATING_CARD_H)
        .backgroundColor('#1E1E1E').borderRadius(8)
        .border({ width: 1, color: this.getLabelColor() })
      Column() {
        Text(this.ratingLabel.label)
          .fontSize(16).fontColor(this.getLabelColor()).fontWeight(FontWeight.Bold)
        Text(`${this.ratingLabel.count} 部`)
          .fontSize(10).fontColor('#888888').margin({ top: 2 })
      }
    }
    .width(RATING_CARD_W).height(RATING_CARD_H)
  }
}

// ─────────────────────────────────────────────
// 年代标签卡片（只显示年代标签 + 数量）
// ─────────────────────────────────────────────
@ComponentV2
struct DecadeCard {
  @Require @Param decade: DecadeGroup

  private isCurrentYear(): boolean { return this.decade.label === '今年'; }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(DECADE_CARD_W).height(DECADE_CARD_H)
        .linearGradient(this.isCurrentYear()
          ? { angle: 135, colors: [['#1A3A5C', 0.0], ['#0D7FBF', 1.0]] }
          : { angle: 135, colors: [['#1A1A2E', 0.0], ['#2D2D44', 1.0]] }
        )
        .borderRadius(8)
        .border({ width: 1, color: this.isCurrentYear() ? '#2288CC' : '#333344' })
      Column() {
        Text(this.decade.label)
          .fontSize(16).fontColor(this.isCurrentYear() ? '#66BBFF' : '#AAAACC')
          .fontWeight(FontWeight.Bold)
        Text(`${this.decade.count} 部`)
          .fontSize(10).fontColor('#666688').margin({ top: 2 })
      }
    }
    .width(DECADE_CARD_W).height(DECADE_CARD_H)
  }
}

// ─────────────────────────────────────────────
// 分类卡片（16:9 渐变）
// ─────────────────────────────────────────────
@ComponentV2
struct GenreCard {
  @Require @Param genre: string
  @Require @Param count: number

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(WIDE_WIDTH)
        .aspectRatio(LANDSCAPE_ASPECT_RATIO)
        .linearGradient({ angle: 135, colors: [['#3A1C71', 0.0], ['#D76D77', 0.5], ['#FFAF7B', 1.0]] })
        .borderRadius(6)
      Column() {
        Text(this.genre).fontSize(14).fontColor(Color.White).fontWeight(FontWeight.Bold)
        Text(`${this.count} 部`).fontSize(11).fontColor('#DDDDDD').margin({ top: 4 })
      }
    }
    .width(WIDE_WIDTH)
    .aspectRatio(LANDSCAPE_ASPECT_RATIO)
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
        SeriesCard({ group: this.getSeries() })
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
  @BuilderParam content: () => void

  build() {
    Column() {
      Text(this.title)
        .fontSize(14).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
        .padding({ left: 16, bottom: 8 })
      Scroll() {
        Row({ space: 10 })
        {
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

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(WIDE_WIDTH)
        .aspectRatio(LANDSCAPE_ASPECT_RATIO)
        .backgroundColor('#1A1A2E')
        .hoverEffect(HoverEffect.Scale)
        .border({ width: 1, color: '#333355', style: BorderStyle.Dashed })
      Column() {
        Text('▶').fontSize(20).fontColor('#555577')
        Text(this.label).fontSize(11).fontColor('#555577').margin({ top: 4 })
      }
    }
    .clip(true)
    .borderRadius(6)
    .width(WIDE_WIDTH)
    .aspectRatio(LANDSCAPE_ASPECT_RATIO)
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
  model: MediaLibraryModel = MediaLibraryModel.getState()

  aboutToAppear(): void {
    FileSourceDatabase.onReady(() => {
      // 每次进入页面都重新加载，确保数据最新
      this.model.reload();
    });
  }

  private async startScan(): Promise<void> {
    if (this.isScanning) { return; }
    this.isScanning = true;
    try {
      const context = this.getUIContext().getHostContext()!;
      const tmdbKey = await AppPreferences.get(PrefKey.TMDB_API_KEY, '');
      const scrapeClient = tmdbKey.length > 0 ? new ScrapeClient({ tmdbApiKey: tmdbKey }) : undefined;
      const result = await VideoScannerUtil.scan(context, scrapeClient);
      console.info(`[MediaLibraryTab] 扫描完成，共 ${result.totalVideos} 个视频，耗时 ${result.elapsedMs}ms`);
      await this.model.reload();
    } catch (e) {
      const err = e as Error;
      console.error(`[MediaLibraryTab] 扫描异常: ${err.message}`);
    } finally {
      this.isScanning = false;
    }
  }

  // ── 类别统计 ─────────────────────────────────
  private getGenreMap(): Map<string, number> {
    const map = new Map<string, number>();
    const all: MediaItem[] = [];
    for (const m of this.model.movies) { all.push(m); }
    for (const sg of this.model.seriesGroups) {
      for (const ep of sg.episodes) { all.push(ep); }
    }
    for (const item of all) {
      for (const g of genreList(item)) {
        map.set(g, (map.get(g) ?? 0) + 1);
      }
    }
    return map;
  }

  private getGenreKeys(): string[] {
    const keys: string[] = [];
    this.getGenreMap().forEach((_v, k) => { keys.push(k); });
    return keys;
  }

  private getGenreCount(genre: string): number {
    return this.getGenreMap().get(genre) ?? 0;
  }

  private getStatsText(): string {
    const s = this.model.stats;
    return `共 ${s.total} 个视频 · 电影 ${s.movies} 部 · 电视剧 ${s.tv} 部 · 其他 ${s.other} 个`;
  }

  private getLastScanText(): string {
    return `上次扫描：${formatScanTime(this.model.latestScanTime)}`;
  }

  // ── Builders ──────────────────────────────────
  @Builder
  ContinueWatchingSection() {
    SectionRow({ title: '继续播放' }) {
      PlaceholderWideCard({ label: '暂无播放记录' })
      PlaceholderWideCard({ label: '播放历史功能即将上线' })
    }
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
      SectionRow({ title: `电影  (${this.model.movies.length})` }) {
        ForEach(this.model.movies.slice(0, 30), (item: MediaItem) => {
          PosterCard({ item })
        })
      }
    }
  }

  @Builder
  TvShowsSection() {
    if (this.model.seriesGroups.length > 0) {
      SectionRow({ title: `电视剧  (${this.model.seriesGroups.length} 部)` }) {
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
  GenreSection() {
    if (this.getGenreKeys().length > 0) {
      SectionRow({ title: '类别' }) {
        ForEach(this.getGenreKeys(), (genre: string) => {
          GenreCard({ genre, count: this.getGenreCount(genre) })
        })
      }
    }
  }

  @Builder
  RatingSection() {
    if (this.model.ratingLabels.length > 0) {
      SectionRow({ title: '高分推荐' }) {
        ForEach(this.model.ratingLabels, (rl: RatingLabel) => {
          RatingLabelCard({ ratingLabel: rl })
        })
      }
    }
  }

  @Builder
  DecadeSection() {
    if (this.model.decadeGroups.length > 0) {
      SectionRow({ title: '上映年代' }) {
        ForEach(this.model.decadeGroups, (decade: DecadeGroup) => {
          DecadeCard({ decade })
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

      Button(this.isScanning ? '扫描中...' : '重新扫描')
        .width(200).height(40).fontSize(14)
        .enabled(!this.isScanning)
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
        .onClick(() => { this.startScan(); })
        .margin({ bottom: 40 })
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
      Text('请先配置文件源并点击"重新扫描"')
        .fontSize(12).fontColor('#444444').margin({ top: 8 })
    }
    .width('100%').height(300).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }

  build() {
    Column() {
      if (this.model.isLoading) {
        this.LoadingView()
      } else if (!this.model.isLoaded || this.model.recentlyAdded.length === 0) {
        this.EmptyView()
        this.StatsAndScan()
      } else {
        this.ContinueWatchingSection()
        this.RecentlyAddedSection()
        this.MoviesSection()
        this.TvShowsSection()
        this.UnwatchedSection()
        this.GenreSection()
        this.RatingSection()
        this.DecadeSection()
        this.StatsAndScan()
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }
}