import { SeriesGroup, MediaItem, TvSeriesEntity } from '../../db/models/MediaEntity'
import { FileSourceDatabase } from '../../db/files/FileSourceDatabase'

// ─────────────────────────────────────────────
// 内部类型
// ─────────────────────────────────────────────

interface SeasonGroup {
  seasonNumber: number;
  label: string;
  episodes: MediaItem[];
}

// ─────────────────────────────────────────────
// 工具函数
// ─────────────────────────────────────────────

function parseGenres(json: string | undefined): string[] {
  if (!json) { return []; }
  try { return JSON.parse(json) as string[]; } catch { return []; }
}

function formatYear(date: string | undefined): string {
  if (!date || date.length < 4) { return ''; }
  return date.substring(0, 4);
}

// ─────────────────────────────────────────────
// 详情页
// ─────────────────────────────────────────────

@ComponentV2
export struct SeriesDetailPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  @Local group: SeriesGroup | undefined = undefined
  @Local seriesEntity: TvSeriesEntity | undefined = undefined
  @Local episodes: MediaItem[] = []
  @Local selectedSeason: number = 0
  @Local isLoadingEpisodes: boolean = false

  static PAGE_NAME = 'seriesDetail'

  // ── 数据相关 ──────────────────────────────────

  private getTitle(): string {
    return this.group?.title ?? ''
  }

  private getBackdrop(): string {
    return this.group?.backdropUrl
      ?? this.group?.posterUrl
      ?? this.group?.posterLocalPath
      ?? ''
  }

  private getPoster(): string {
    return this.group?.posterLocalPath
      ?? this.group?.posterUrl
      ?? ''
  }

  private getYear(): string {
    return formatYear(this.seriesEntity?.firstAirDate)
  }

  private getRatingText(): string {
    const r = this.group?.rating ?? this.seriesEntity?.rating
    if (r === undefined) { return '' }
    return r.toFixed(1)
  }

  private getOverview(): string {
    return this.seriesEntity?.overview ?? ''
  }

  private getGenres(): string[] {
    return parseGenres(this.seriesEntity?.genresJson)
  }

  private getCast(): string[] {
    if (!this.seriesEntity?.castJson) { return []; }
    try {
      const arr = JSON.parse(this.seriesEntity.castJson) as string[];
      return arr.slice(0, 6);
    } catch { return []; }
  }

  private buildSeasonGroups(): SeasonGroup[] {
    const seasonMap = new Map<number, MediaItem[]>();
    for (const ep of this.episodes) {
      const sn = ep.seasonNumber ?? 0;
      const existing = seasonMap.get(sn);
      if (existing !== undefined) {
        existing.push(ep);
      } else {
        seasonMap.set(sn, [ep]);
      }
    }
    const result: SeasonGroup[] = [];
    seasonMap.forEach((eps: MediaItem[], sn: number) => {
      const label = sn > 0 ? `第 ${sn} 季` : '全部集数';
      const sg: SeasonGroup = { seasonNumber: sn, label, episodes: eps };
      result.push(sg);
    });
    result.sort((a: SeasonGroup, b: SeasonGroup) => a.seasonNumber - b.seasonNumber);
    return result;
  }

  private getSeasonGroups(): SeasonGroup[] {
    return this.buildSeasonGroups();
  }

  private getCurrentEpisodes(): MediaItem[] {
    const groups = this.buildSeasonGroups();
    if (groups.length === 0) { return []; }
    const found = groups.find((g: SeasonGroup) => g.seasonNumber === this.selectedSeason);
    if (found !== undefined) { return found.episodes; }
    return groups[0].episodes;
  }

  private getEpisodeTitle(ep: MediaItem): string {
    const epNum = ep.episodeNumber !== undefined ? `第 ${ep.episodeNumber} 集` : '';
    const title = ep.title ?? '';
    if (epNum.length > 0 && title.length > 0) { return `${epNum}  ${title}`; }
    if (epNum.length > 0) { return epNum; }
    return title;
  }

  // ── 数据加载 ──────────────────────────────────

  private async loadData(seriesId: number): Promise<void> {
    this.isLoadingEpisodes = true;
    try {
      const db = FileSourceDatabase.getInstance();
      const entityResult = await db.getTvSeriesById(seriesId);
      if (entityResult !== null) {
        this.seriesEntity = entityResult;
      }
      const episodeItems = await db.getMediaItemsByTvSeriesId(seriesId);
      this.episodes = episodeItems;
      const groups = this.buildSeasonGroups();
      if (groups.length > 0) {
        this.selectedSeason = groups[0].seasonNumber;
      }
    } catch (e) {
      console.error('[SeriesDetailPage] loadData failed', JSON.stringify(e));
    } finally {
      this.isLoadingEpisodes = false;
    }
  }

  // ── Builders ──────────────────────────────────

  @Builder
  HeroSection() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 背景图 / 纯色占位
      if (this.getBackdrop().length > 0) {
        Image(this.getBackdrop())
          .width('100%')
          .aspectRatio(1.778)
          .objectFit(ImageFit.Cover)
      } else {
        Column()
          .width('100%')
          .aspectRatio(1.778)
          .linearGradient({
            angle: 135,
            colors: [['#1A1A2E', 0.0], ['#16213E', 0.5], ['#0F3460', 1.0]]
          })
      }

      // 底部渐变遮罩
      Column()
        .width('100%')
        .height('60%')
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.0], ['#F0000000', 1.0]]
        })
        .position({ left: 0, bottom: 0 })

      // 左侧渐变遮罩
      Column()
        .width('45%')
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: [['#DD000000', 0.0], ['#00000000', 1.0]]
        })
        .position({ left: 0, top: 0 })

      // 内容层：左下角
      Column({ space: 16 }) {
        // 标题
        Text(this.getTitle())
          .fontSize(52)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Bold)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('55%')
          .textShadow({ radius: 8, color: '#88000000', offsetX: 2, offsetY: 2 })

        // 元信息行：年份 + 评分 + 类型标签
        Row({ space: 12 }) {
          if (this.getYear().length > 0) {
            Text(this.getYear())
              .fontSize(18).fontColor('#CCCCCC').fontWeight(FontWeight.Medium)
          }
          if (this.getRatingText().length > 0) {
            Row({ space: 4 }) {
              Text('★')
                .fontSize(16).fontColor('#FFA500')
              Text(this.getRatingText())
                .fontSize(18).fontColor('#FFA500').fontWeight(FontWeight.Bold)
            }
          }
          ForEach(this.getGenres().slice(0, 3), (genre: string) => {
            Text(genre)
              .fontSize(14)
              .fontColor('#CCCCCC')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(4)
              .border({ width: 1, color: '#55FFFFFF' })
          }, (genre: string) => genre)
        }
        .alignItems(VerticalAlign.Center)

        // 简介
        if (this.getOverview().length > 0) {
          Text(this.getOverview())
            .fontSize(16)
            .fontColor('#CCCCCC')
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(26)
            .width('55%')
        }

        // 演员
        if (this.getCast().length > 0) {
          Row({ space: 8 }) {
            Text('主演：').fontSize(14).fontColor('#888888')
            Text(this.getCast().join(' / '))
              .fontSize(14)
              .fontColor('#AAAAAA')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('55%')
        }
      }
      .padding({ left: 80, bottom: 48 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
  }

  @Builder
  EpisodesSection() {
    Column({ space: 0 }) {
      // 标题 + 加载指示
      Row({ space: 12 }) {
        Text('剧集')
          .fontSize(26)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Bold)
        if (this.isLoadingEpisodes) {
          LoadingProgress()
            .width(24).height(24)
            .color('#AAAAAA')
        }
      }
      .padding({ left: 80, top: 36, bottom: 20 })
      .alignItems(VerticalAlign.Center)

      // 季选项卡（多季时显示）
      if (this.getSeasonGroups().length > 1) {
        Row({ space: 0 }) {
          ForEach(this.getSeasonGroups(), (sg: SeasonGroup) => {
            Text(sg.label)
              .fontSize(16)
              .fontColor(this.selectedSeason === sg.seasonNumber ? Color.White : '#777777')
              .fontWeight(this.selectedSeason === sg.seasonNumber ? FontWeight.Bold : FontWeight.Normal)
              .padding({ left: 20, right: 20, top: 10, bottom: 10 })
              .borderRadius(6)
              .backgroundColor(
                this.selectedSeason === sg.seasonNumber ? '#303030' : Color.Transparent
              )
              .margin({ right: 4 })
              .onClick(() => {
                this.selectedSeason = sg.seasonNumber;
              })
          }, (sg: SeasonGroup) => String(sg.seasonNumber))
        }
        .padding({ left: 76, bottom: 12 })
      }

      // 分割线
      Divider()
        .color('#252525')
        .strokeWidth(1)
        .margin({ left: 80, right: 80, bottom: 8 })

      // 无剧集提示
      if (!this.isLoadingEpisodes && this.getCurrentEpisodes().length === 0) {
        Column() {
          Text('暂无剧集数据')
            .fontSize(16).fontColor('#555555')
        }
        .width('100%').height(200)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      // 集列表
      ForEach(this.getCurrentEpisodes(), (ep: MediaItem) => {
        Row({ space: 20 }) {
          // 集数序号
          Text(String(ep.episodeNumber ?? ''))
            .fontSize(20)
            .fontColor('#555555')
            .fontWeight(FontWeight.Bold)
            .width(40)
            .textAlign(TextAlign.Center)

          // 信息区
          Column({ space: 8 }) {
            // 集标题
            Text(this.getEpisodeTitle(ep))
              .fontSize(18)
              .fontColor(Color.White)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            // 集简介（episode 级别，若无则不显示）
            if (ep.overview !== undefined && ep.overview.length > 0) {
              Text(ep.overview)
                .fontSize(14)
                .fontColor('#888888')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .lineHeight(22)
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ left: 80, right: 80, top: 18, bottom: 18 })
        .hoverEffect(HoverEffect.Highlight)
        .onClick(() => {
          // TODO: 播放该集
        })
      }, (ep: MediaItem) => String(ep.id))

      // 底部留白
      Column().height(60)
    }
    .width('100%')
    .backgroundColor('#111111')
    .alignItems(HorizontalAlign.Start)
  }

  // ── 构建 ──────────────────────────────────────

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 主体滚动内容
        Scroll() {
          Column() {
            this.HeroSection()
            this.EpisodesSection()
          }
          .width('100%')
          .backgroundColor('#000000')
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)

        // 顶部透明导航栏（后退按钮）
        Row() {
          Text('←')
            .fontSize(30)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Bold)
            .textShadow({ radius: 6, color: '#88000000', offsetX: 1, offsetY: 1 })
            .padding(20)
            .onClick(() => {
              this.pageStack.pop();
            })
        }
        .width('100%')
        .padding({ left: 16, top: 8 })
        .linearGradient({
          angle: 180,
          colors: [['#AA000000', 0.0], ['#00000000', 1.0]]
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
    }
    .onReady((context: NavDestinationContext) => {
      const param = context.pathInfo.param as SeriesGroup;
      if (param !== undefined && param !== null) {
        this.group = param;
        if (param.tvSeriesId !== undefined) {
          this.loadData(param.tvSeriesId);
        }
      }
    })
    .hideTitleBar(true)
  }
}
