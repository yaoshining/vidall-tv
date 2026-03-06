import { SeriesGroup, TvSeriesEntity } from '../../db/models/MediaEntity'
import { FileSourceDatabase } from '../../db/files/FileSourceDatabase'
import { ScrapeCredit } from '../../lib/ScrapeClient'
import { AppPreferences, PrefKey } from '../../utils/AppPreferences'
import http from '@ohos.net.http'
import image from '@ohos.multimedia.image'
import effectKit from '@ohos.effectKit'

// ─────────────────────────────────────────────
// TMDB 图片 URL 工具
// ─────────────────────────────────────────────

/**
 * 按指定宽度档位构造 TMDB 图片 URL。
 * width 取值：'w185' | 'w342' | 'w500' | 'w780' | 'w1280' | 'original'
 */
function tmdbImageUrl(path: string | undefined, width: string): string {
  if (!path || path.length === 0) { return ''; }
  return `https://image.tmdb.org/t/p/${width}${path}`;
}

function formatYear(date: string | undefined): string {
  if (!date || date.length < 4) { return ''; }
  return date.substring(0, 4);
}

function parseGenresArr(json: string | undefined): string[] {
  if (!json) { return []; }
  try { return JSON.parse(json) as string[]; } catch (e) { return []; }
}

// ─────────────────────────────────────────────
// 内部类型定义
// ─────────────────────────────────────────────

/** 从 tv_series.raw_json 解析的单季信息 */
interface TmdbRawSeason {
  air_date?: string;
  episode_count?: number;
  id?: number;
  name?: string;
  overview?: string;
  poster_path?: string;
  season_number?: number;
  vote_average?: number;
}

interface TmdbRawDetail {
  seasons?: TmdbRawSeason[];
}

interface TmdbSimilarItem {
  id?: number;
  name?: string;
  poster_path?: string;
  backdrop_path?: string;
  vote_average?: number;
}

interface TmdbSimilarResponse {
  results?: TmdbSimilarItem[];
}

/** 本地库匹配到的相似剧 */
interface SimilarSeriesItem {
  tvSeriesId: number;
  title: string;
  posterUrl?: string;
  posterLocalPath?: string;
  backdropUrl?: string;
  rating?: number;
}

// ─────────────────────────────────────────────
// 详情页
// ─────────────────────────────────────────────

@ComponentV2
export struct SeriesDetailPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  @Local group: SeriesGroup | undefined = undefined
  @Local seriesEntity: TvSeriesEntity | undefined = undefined
  @Local seasons: TmdbRawSeason[] = []
  @Local cast: ScrapeCredit[] = []
  @Local similarSeries: SimilarSeriesItem[] = []
  @Local isLoading: boolean = false
  @Local showOverviewDialog: boolean = false
  /** 从 backdrop 提取的深色背景色，格式 #RRGGBB，提取失败保持默认 */
  @Local dominantBgColor: string = '#111111'

  static PAGE_NAME = 'seriesDetail'

  // ── 属性计算方法 ──────────────────────────────────

  private getBackdropUrl(): string {
    // backdropPath 是 TMDB 原始路径（无尺寸），优先构造 w1280 高清 URL
    const path = this.seriesEntity?.backdropPath;
    if (path !== undefined && path.length > 0) { return tmdbImageUrl(path, 'w1280'); }
    // 回退：数据库存储的 backdropUrl（旧数据可能是 w500），直接用
    const url = this.seriesEntity?.backdropUrl ?? this.group?.backdropUrl;
    if (url !== undefined && url.length > 0) { return url; }
    // 最后回退到海报
    return this.seriesEntity?.posterUrl ?? this.group?.posterUrl ?? '';
  }

  private getTitle(): string { return this.group?.title ?? ''; }

  private getYear(): string { return formatYear(this.seriesEntity?.firstAirDate); }

  private getRatingText(): string {
    const r = this.group?.rating ?? this.seriesEntity?.rating;
    if (r === undefined) { return ''; }
    return r.toFixed(1);
  }

  private getOverview(): string { return this.seriesEntity?.overview ?? ''; }

  private getGenres(): string[] { return parseGenresArr(this.seriesEntity?.genresJson); }

  private getSeasonPosterUrl(s: TmdbRawSeason): string {
    return tmdbImageUrl(s.poster_path, 'w342');
  }

  /** 第N季 / 特别篇 */
  private getSeasonLabel(s: TmdbRawSeason): string {
    const n = s.season_number ?? 0;
    if (n === 0) { return '特别篇'; }
    return `第 ${n} 季`;
  }

  private getCastProfileUrl(c: ScrapeCredit): string {
    return tmdbImageUrl(c.profilePath, 'w185');
  }

  /** overview 是否超过 100 字 */
  private isOverviewLong(): boolean { return this.getOverview().length > 100; }

  /** 截断后的简介（前100字 + 省略号） */
  private getOverviewShort(): string { return this.getOverview().substring(0, 100) + '...'; }

  /** 将 #RRGGBB 转为完全不透明的 #FFRRGGBB（ARGB 8位），用于渐变颜色 */
  private toOpaqueColor(hex: string): string {
    return '#FF' + hex.substring(1);
  }

  private buildSimilarGroup(item: SimilarSeriesItem): SeriesGroup {
    const g: SeriesGroup = {
      title: item.title,
      tvSeriesId: item.tvSeriesId,
      posterUrl: item.posterUrl,
      posterLocalPath: item.posterLocalPath,
      backdropUrl: item.backdropUrl,
      rating: item.rating,
      episodeCount: 0,
      episodes: [],
      latestScannedAt: 0
    };
    return g;
  }

  // ── 数据加载 ──────────────────────────────────

  private async loadData(seriesId: number): Promise<void> {
    this.isLoading = true;
    try {
      const db = FileSourceDatabase.getInstance();
      const entity = await db.getTvSeriesById(seriesId);
      if (entity === null) { return; }
      this.seriesEntity = entity;

      // 从 raw_json 解析季列表（TMDB 原始响应中的 seasons 数组）
      const rawStr = entity.rawJson;
      if (rawStr !== undefined && rawStr.length > 0) {
        try {
          const detail = JSON.parse(rawStr) as TmdbRawDetail;
          const rawSeasons = detail.seasons ?? [];
          // 排序：正数季号升序，第 0 季（特别篇）置尾
          rawSeasons.sort((a: TmdbRawSeason, b: TmdbRawSeason) => {
            const an = a.season_number ?? 0;
            const bn = b.season_number ?? 0;
            if (an === 0 && bn !== 0) { return 1; }
            if (bn === 0 && an !== 0) { return -1; }
            return an - bn;
          });
          // 仅显示 scrape_info 中已刮削的季
          const scrapedNums = await db.getScrapedSeasonNumbers(seriesId);
          const filteredSeasons: TmdbRawSeason[] = [];
          for (const s of rawSeasons) {
            if (scrapedNums.indexOf(s.season_number ?? -1) >= 0) {
              filteredSeasons.push(s);
            }
          }
          this.seasons = filteredSeasons;
        } catch (e) { this.seasons = []; }
      }

      // 从 castJson 解析演职人员（存储结构为 ScrapeCredit[]）
      const cj = entity.castJson;
      if (cj !== undefined && cj.length > 0) {
        try { this.cast = JSON.parse(cj) as ScrapeCredit[]; } catch (e) { this.cast = []; }
      }

      // 异步提取 backdrop 主色（fire-and-forget）
      const bdUrl = this.getBackdropUrl();
      if (bdUrl.length > 0) { this.extractDominantColor(bdUrl); }

      // 异步加载相似剧（fire-and-forget，不阻塞主流程）
      const pid = entity.providerId;
      const apiKey = await AppPreferences.get(PrefKey.TMDB_API_KEY, '');
      if (pid.length > 0 && apiKey.length > 0) {
        this.loadSimilar(pid, apiKey);
      }
    } catch (e) {
      console.error('[SeriesDetailPage] loadData failed', JSON.stringify(e));
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 下载 backdrop 图片并用 effectKit 提取最暗主色作为页面背景色。
   * 提取失败时静默忽略，保持默认 #111111。
   */
  private async extractDominantColor(url: string): Promise<void> {
    try {
      const req = http.createHttp();
      let buf: ArrayBuffer | undefined;
      try {
        const resp = await req.request(url, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: 8000,
          readTimeout: 8000
        });
        req.destroy();
        if (resp.responseCode !== 200) { return; }
        buf = resp.result as ArrayBuffer;
      } catch (e) {
        req.destroy();
        return;
      }
      if (buf === undefined || buf.byteLength === 0) { return; }

      // 缩小尺寸加速：从 ArrayBuffer 创建 ImageSource，解码为小尺寸 PixelMap
      const imgSrc = image.createImageSource(buf);
      const pixelMap = await imgSrc.createPixelMap({
        desiredSize: { width: 64, height: 36 },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      imgSrc.release();

      // effectKit 提取主色
      const picker = await effectKit.createColorPicker(pixelMap);
      const mainColor = picker.getMainColorSync();
      pixelMap.release();

      // 将 RGB 分量各减暗 40%，保证背景色足够深
      const darken = (v: number): number => Math.round(v * 0.4);
      const toHex = (v: number): string => {
        const h = v.toString(16);
        return h.length < 2 ? '0' + h : h;
      };
      const r = darken(mainColor.red & 0xFF);
      const g = darken(mainColor.green & 0xFF);
      const b = darken(mainColor.blue & 0xFF);
      this.dominantBgColor = '#' + toHex(r) + toHex(g) + toHex(b);
    } catch (e) {
      // 提取失败，保持默认色
      console.warn('[SeriesDetailPage] extractDominantColor failed', JSON.stringify(e));
    }
  }

  private async loadSimilar(providerId: string, apiKey: string): Promise<void> {
    try {
      const url = `https://api.themoviedb.org/3/tv/${providerId}/similar?api_key=${apiKey}&language=zh-CN`;
      const req = http.createHttp();
      let body: string = '';
      try {
        const resp = await req.request(url, {
          method: http.RequestMethod.GET,
          header: { 'Accept': 'application/json' },
          connectTimeout: 10000,
          readTimeout: 10000
        });
        req.destroy();
        if (resp.responseCode !== 200) { return; }
        body = resp.result as string;
      } catch (e) {
        req.destroy();
        return;
      }
      if (body.length === 0) { return; }
      const data = JSON.parse(body) as TmdbSimilarResponse;
      const results = data.results ?? [];
      const db = FileSourceDatabase.getInstance();
      const similar: SimilarSeriesItem[] = [];
      for (const item of results.slice(0, 20)) {
        const itemId = String(item.id ?? 0);
        const local = await db.getTvSeriesByProviderId('tmdb', itemId);
        if (local !== null && local.id !== undefined) {
          const s: SimilarSeriesItem = {
            tvSeriesId: local.id,
            title: local.title,
            posterUrl: local.posterUrl,
            posterLocalPath: local.posterLocalPath,
            backdropUrl: local.backdropUrl,
            rating: local.rating
          };
          similar.push(s);
        }
      }
      this.similarSeries = similar;
    } catch (e) {
      console.error('[SeriesDetailPage] loadSimilar failed', JSON.stringify(e));
    }
  }

  // ── Builders ──────────────────────────────────

  /** 继续播放占位卡片（右下角） */
  @Builder
  ContinueWatchingCard() {
    Column({ space: 0 }) {
      Row({ space: 14 }) {
        // 集缩略图占位
        Column()
          .width(150)
          .height(84)
          .backgroundColor('#1C1C1C')
          .borderRadius(4)
          .border({ width: 1, color: '#2E2E2E' })

        // 信息部分
        Column({ space: 10 }) {
          // 集号标签 + 标题
          Row({ space: 8 }) {
            Text('— —')
              .fontSize(12)
              .fontColor('#1B78F2')
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .backgroundColor('#192840')
              .borderRadius(3)
            Text('暂无播放记录')
              .fontSize(14).fontColor('#CCCCCC').fontWeight(FontWeight.Medium)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .alignItems(VerticalAlign.Center)

          // 进度条（0%）
          Column() {
            Column()
              .width('0%').height('100%')
              .backgroundColor('#1B78F2').borderRadius(2)
          }
          .width('100%').height(4)
          .backgroundColor('#2E2E2E').borderRadius(2)

          // 播放按钮行
          Row({ space: 10 }) {
            Row({ space: 6 }) {
              Text('▶').fontSize(12).fontColor(Color.White)
              Text('继续播放').fontSize(14).fontColor(Color.White).fontWeight(FontWeight.Bold)
            }
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor('#1B78F2').borderRadius(4)

            Text('播放历史即将上线').fontSize(12).fontColor('#505050')
          }
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.SpaceBetween)
        .height(84)
      }
      .alignItems(VerticalAlign.Center)
    }
    .padding({ left: 16, right: 20, top: 14, bottom: 14 })
    .backgroundColor('#18FFFFFF')
    .borderRadius(8)
    .border({ width: 1, color: '#22FFFFFF' })
    .width(500)
  }

  @Builder
  HeroSection() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // ── 背景图（w1280）/ 渐变占位 ─────────────────
      if (this.getBackdropUrl().length > 0) {
        Image(this.getBackdropUrl())
          .width('100%').height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        Column()
          .width('100%').height('100%')
          .linearGradient({
            angle: 135,
            colors: [['#1A1A2E', 0.0], ['#16213E', 0.5], ['#0F3460', 1.0]]
          })
      }

      // ── 底部渐变遮罩 ──────────────────────────────
      Column()
        .width('100%').height('68%')
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.0], [this.toOpaqueColor(this.dominantBgColor), 1.0]]
        })
        .position({ left: 0, bottom: 0 })

      // ── 左侧渐变遮罩 ──────────────────────────────
      Column()
        .width('55%').height('100%')
        .linearGradient({
          angle: 90,
          colors: [[this.toOpaqueColor(this.dominantBgColor), 0.0], ['#00000000', 1.0]]
        })
        .position({ left: 0, top: 0 })

      // ── 底部内容行 ────────────────────────────────
      Row({ space: 40 }) {
        // 左侧：标题 / 元信息 / 简介
        Column({ space: 14 }) {
          Text(this.getTitle())
            .fontSize(52).fontColor(Color.White).fontWeight(FontWeight.Bold)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .textShadow({ radius: 8, color: '#88000000', offsetX: 2, offsetY: 2 })
            .constraintSize({ maxWidth: 720 })

          // 元信息行：年份 + 评分 + 类型标签
          Row({ space: 12 }) {
            if (this.getYear().length > 0) {
              Text(this.getYear())
                .fontSize(18).fontColor('#CCCCCC').fontWeight(FontWeight.Medium)
            }
            if (this.getRatingText().length > 0) {
              Row({ space: 4 }) {
                Text('★').fontSize(16).fontColor('#FFA500')
                Text(this.getRatingText())
                  .fontSize(18).fontColor('#FFA500').fontWeight(FontWeight.Bold)
              }
            }
            ForEach(this.getGenres().slice(0, 3), (genre: string) => {
              Text(genre)
                .fontSize(14).fontColor('#CCCCCC')
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(4)
                .border({ width: 1, color: '#55FFFFFF' })
            }, (genre: string) => genre)
          }
          .alignItems(VerticalAlign.Center)

          // 简介：超100字截断显示 + 「更多」Span，不超出仅显示原文
          if (this.getOverview().length > 0) {
            if (this.isOverviewLong()) {
              Text() {
                Span(this.getOverviewShort())
                  .fontSize(16).fontColor('#BBBBBB').lineHeight(26)
                Span('更多')
                  .fontSize(14).fontColor('#1B78F2')
                  .fontWeight(FontWeight.Medium)
                  .onClick(() => { this.showOverviewDialog = true; })
              }
              .constraintSize({ maxWidth: 700 })
            } else {
              Text(this.getOverview())
                .fontSize(16).fontColor('#BBBBBB').lineHeight(26)
                .constraintSize({ maxWidth: 700 })
            }
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 右侧：继续播放卡片（占位）
        this.ContinueWatchingCard()
      }
      .width('100%')
      .padding({ left: 80, right: 80, bottom: 52 })
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%').aspectRatio(1.778)
  }

  /** 季列表（横向滚动，带海报） */
  @Builder
  SeasonsSection() {
    if (this.seasons.length > 0) {
      Column({ space: 0 }) {
        Text('季')
          .fontSize(26).fontColor(Color.White).fontWeight(FontWeight.Bold)
          .padding({ left: 80, top: 36, bottom: 20 })

        Scroll() {
          Row({ space: 16 }) {
            ForEach(this.seasons, (s: TmdbRawSeason) => {
              Column({ space: 8 }) {
                // 季海报
                if (this.getSeasonPosterUrl(s).length > 0) {
                  Image(this.getSeasonPosterUrl(s))
                    .width(140).aspectRatio(2 / 3)
                    .objectFit(ImageFit.Cover).borderRadius(6)
                    .hoverEffect(HoverEffect.Scale)
                } else {
                  Column() {
                    Text(this.getSeasonLabel(s))
                      .fontSize(14).fontColor('#CCCCCC')
                      .textAlign(TextAlign.Center)
                  }
                  .width(140).aspectRatio(2 / 3)
                  .backgroundColor('#2A2A2A').borderRadius(6)
                  .justifyContent(FlexAlign.Center)
                  .hoverEffect(HoverEffect.Scale)
                }

                // 第N季标签
                Text(this.getSeasonLabel(s))
                  .fontSize(14).fontColor('#CCCCCC')
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width(140)
              }
              .width(140).alignItems(HorizontalAlign.Start)
            }, (s: TmdbRawSeason) => String(s.id ?? s.season_number ?? 0))
          }
          .padding({ left: 80, right: 80 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)

        Column().height(36)
      }
      .width('100%').alignItems(HorizontalAlign.Start)
      .backgroundColor(this.dominantBgColor)
    }
  }

  /** 演职人员横向滚动列表 */
  @Builder
  CastSection() {
    if (this.cast.length > 0) {
      Column({ space: 0 }) {
        Text('演职人员')
          .fontSize(26).fontColor(Color.White).fontWeight(FontWeight.Bold)
          .padding({ left: 80, top: 36, bottom: 20 })

        Scroll() {
          Row({ space: 24 }) {
            ForEach(this.cast.slice(0, 15), (c: ScrapeCredit) => {
              Column({ space: 8 }) {
                // 人物照片（长方形）
                if (this.getCastProfileUrl(c).length > 0) {
                  Image(this.getCastProfileUrl(c))
                    .width(110).aspectRatio(2 / 3)
                    .objectFit(ImageFit.Cover).borderRadius(6)
                    .hoverEffect(HoverEffect.Scale)
                } else {
                  Column() {
                    Text(c.name.length > 0 ? c.name.substring(0, 1) : '?')
                      .fontSize(30).fontColor(Color.White).fontWeight(FontWeight.Bold)
                  }
                  .width(110).aspectRatio(2 / 3).borderRadius(6)
                  .backgroundColor('#2A2A2A')
                  .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                  .hoverEffect(HoverEffect.Scale)
                }
                // 演员名
                Text(c.name)
                  .fontSize(14).fontColor(Color.White)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width(110).textAlign(TextAlign.Center)
                // 饰演角色
                if (c.role !== undefined && c.role.length > 0) {
                  Text(c.role)
                    .fontSize(12).fontColor('#777777')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width(110).textAlign(TextAlign.Center)
                }
              }
              .width(110).alignItems(HorizontalAlign.Center)
            }, (c: ScrapeCredit) => c.name)
          }
          .padding({ left: 80, right: 80 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)

        Column().height(36)
      }
      .width('100%').alignItems(HorizontalAlign.Start)
      .backgroundColor(this.dominantBgColor)
    }
  }

  /** 相似剧横向滚动（0 条时整个 section 不渲染） */
  @Builder
  SimilarSection() {
    if (this.similarSeries.length > 0) {
      Column({ space: 0 }) {
        Text('更多类似')
          .fontSize(26).fontColor(Color.White).fontWeight(FontWeight.Bold)
          .padding({ left: 80, top: 36, bottom: 20 })

        Scroll() {
          Row({ space: 16 }) {
            ForEach(this.similarSeries, (item: SimilarSeriesItem) => {
              Column({ space: 6 }) {
                Stack({ alignContent: Alignment.BottomEnd }) {
                  if (item.posterUrl !== undefined && item.posterUrl.length > 0) {
                    Image(item.posterUrl)
                      .width(160).aspectRatio(2 / 3)
                      .objectFit(ImageFit.Cover).borderRadius(6)
                  } else if (item.posterLocalPath !== undefined && item.posterLocalPath.length > 0) {
                    Image(item.posterLocalPath)
                      .width(160).aspectRatio(2 / 3)
                      .objectFit(ImageFit.Cover).borderRadius(6)
                  } else {
                    Column() {
                      Text(item.title)
                        .fontSize(11).fontColor('#CCCCCC')
                        .textAlign(TextAlign.Center)
                        .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
                        .padding(8)
                    }
                    .width(160).aspectRatio(2 / 3)
                    .backgroundColor('#2A2A2A').borderRadius(6)
                    .justifyContent(FlexAlign.Center)
                  }
                  if (item.rating !== undefined && item.rating > 0) {
                    Text(item.rating.toFixed(1))
                      .fontSize(11).fontColor('#FFA500').fontWeight(FontWeight.Bold)
                      .padding({ left: 4, right: 4, bottom: 4 })
                  }
                }
                .width(160).aspectRatio(2 / 3)
                .borderRadius(6).clip(true)

                Text(item.title)
                  .fontSize(14).fontColor('#DDDDDD')
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width(160).textAlign(TextAlign.Center)
              }
              .width(160)
              .hoverEffect(HoverEffect.Scale)
              .onClick(() => {
                const g: SeriesGroup = this.buildSimilarGroup(item);
                this.pageStack.pushPathByName('seriesDetail', g);
              })
            }, (item: SimilarSeriesItem) => String(item.tvSeriesId))
          }
          .padding({ left: 80, right: 80 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)

        Column().height(36)
      }
      .width('100%').alignItems(HorizontalAlign.Start)
      .backgroundColor(this.dominantBgColor)
    }
  }

  /** 简介全文弹窗覆盖层 */
  @Builder
  OverviewDialog() {
    if (this.showOverviewDialog) {
      Stack({ alignContent: Alignment.Center }) {
        // 半透明遮罩
        Column()
          .width('100%').height('100%')
          .backgroundColor('#CC000000')
          .onClick(() => { this.showOverviewDialog = false; })

        // 弹窗卡片
        Column({ space: 24 }) {
          Row() {
            Text('剧情简介')
              .fontSize(24).fontColor(Color.White).fontWeight(FontWeight.Bold)
              .layoutWeight(1)
            Text('✕')
              .fontSize(24).fontColor('#888888')
              .padding({ left: 16, right: 0, top: 4, bottom: 4 })
              .onClick(() => { this.showOverviewDialog = false; })
          }
          .alignItems(VerticalAlign.Center).width('100%')

          Scroll() {
            Text(this.getOverview())
              .fontSize(18).fontColor('#DDDDDD').lineHeight(32)
              .width('100%')
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Auto)
          .constraintSize({ maxHeight: 440 })
        }
        .padding({ left: 48, right: 48, top: 40, bottom: 40 })
        .backgroundColor('#1E1E1E')
        .borderRadius(12)
        .border({ width: 1, color: '#33FFFFFF' })
        .constraintSize({ maxWidth: 860, minWidth: 500 })
      }
      .width('100%').height('100%')
    }
  }

  // ── 构建 ──────────────────────────────────────

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 主体滚动内容
        Scroll() {
          Column() {
            this.HeroSection()
            this.SeasonsSection()
            this.CastSection()
            this.SimilarSection()
            Column().height(80)
          }
          .width('100%')
          .backgroundColor(this.dominantBgColor)
        }
        .width('100%').height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)

        // 简介全文弹窗
        this.OverviewDialog()

        // 顶部透明导航栏（后退按钮）
        Row() {
          Text('←')
            .fontSize(30).fontColor(Color.White).fontWeight(FontWeight.Bold)
            .textShadow({ radius: 6, color: '#88000000', offsetX: 1, offsetY: 1 })
            .padding(20)
            .onClick(() => { this.pageStack.pop(); })
        }
        .width('100%')
        .padding({ left: 16, top: 8 })
        .linearGradient({
          angle: 180,
          colors: [['#AA000000', 0.0], ['#00000000', 1.0]]
        })
      }
      .width('100%').height('100%')
      .backgroundColor(this.dominantBgColor)
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
    .onBackPressed(() => {
      if (this.showOverviewDialog) {
        this.showOverviewDialog = false;
        return true;
      }
      return false;
    })
    .hideTitleBar(true)
  }
}
