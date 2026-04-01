import { MediaItem, PlayProgressEntity, MovieEntity } from '../../db/models/MediaEntity';
import { PlayerPageParam, PlayerPage } from '../player/index';
import { FileSourceDatabase } from '../../db/files/FileSourceDatabase';
import { FileSourceType, SMBSourceConfig } from '../../db/models/FileSourceEntity';
import { WebDAVClient, WebDAVConfig } from '../../lib/WebDAVClient';
import http from '@ohos.net.http';
import image from '@ohos.multimedia.image';
import effectKit from '@ohos.effectKit';
import { millisecondsToTime } from '../../utils/TimeUtil';

// ─────────────────────────────────────────────
// TMDB 图片 URL 工具
// ─────────────────────────────────────────────

/**
 * 按指定宽度档位构造 TMDB 图片 URL。
 * width 取值：'w185' | 'w300' | 'w342' | 'w500' | 'w780' | 'w1280' | 'original'
 */
function tmdbImageUrl(path: string | undefined, width: string): string {
  if (!path || path.length === 0) { return ''; }
  return 'https://image.tmdb.org/t/p/' + width + path;
}

function formatYear(date: string | undefined): string {
  if (!date || date.length < 4) { return ''; }
  return date.substring(0, 4);
}

function parseGenresArr(json: string | undefined): string[] {
  if (!json) { return []; }
  try { return JSON.parse(json) as string[]; } catch (e) { return []; }
}

/**
 * 将电影时长格式化为 h:mm:ss 字符串。
 * 优先用 runtimeMinutes（TMDB 原始分钟数），其次用 durationMs（本地文件时长）。
 */
function formatMovieDuration(runtimeMinutes: number | undefined, durationMs: number | undefined): string {
  let totalSeconds: number = 0;
  if (runtimeMinutes !== undefined && runtimeMinutes > 0) {
    totalSeconds = runtimeMinutes * 60;
  } else if (durationMs !== undefined && durationMs > 0) {
    totalSeconds = Math.floor(durationMs / 1000);
  } else {
    return '';
  }
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const s = totalSeconds % 60;
  const mm = m.toString().padStart(2, '0');
  const ss = s.toString().padStart(2, '0');
  if (h > 0) {
    return h.toString() + ':' + mm + ':' + ss;
  }
  return '0:' + mm + ':' + ss;
}

// ─────────────────────────────────────────────
// 内部类型定义
// ─────────────────────────────────────────────

/** 演员原始数据结构（来自 movie.cast_json） */
interface CastPerson {
  name: string;
  character?: string;
  profile_path?: string;
}

/** 演职人员统一展示项（导演 + 演员合并列表） */
interface CastCrewItem {
  name: string;
  role?: string;
  profile_path?: string;
}

function parseCastArr(json: string | undefined): CastPerson[] {
  if (!json) { return []; }
  try { return JSON.parse(json) as CastPerson[]; } catch (e) { return []; }
}

function parseDirectorsArr(json: string | undefined): string[] {
  if (!json) { return []; }
  try { return JSON.parse(json) as string[]; } catch (e) { return []; }
}

// ─────────────────────────────────────────────
// 电影详情页
// ─────────────────────────────────────────────

@ComponentV2
export struct MovieDetailPage {
  static readonly PAGE_NAME: string = 'movieDetail';

  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();

  @Local item: MediaItem | undefined = undefined;
  @Local progress: PlayProgressEntity | null = null;
  @Local movieEntity: MovieEntity | null = null;
  /** 从 backdrop 提取的深色背景色，格式 #RRGGBB，提取失败保持默认 */
  @Local dominantBgColor: string = '#111111';
  @Local showOverviewDialog: boolean = false;
  /** 播放按钮焦点/Hover 状态 key */
  @Local focusedActionKey: string = '';
  @Local hoveredActionKey: string = '';

  // ── 属性计算方法 ──────────────────────────────────

  /** 将 #RRGGBB 转为完全不透明的 #FFRRGGBB（ARGB 8位），用于渐变颜色 */
  private toOpaqueColor(hex: string): string {
    return '#FF' + hex.substring(1);
  }

  /**
   * Backdrop URL（高清 w1280）。
   * 优先级：TMDB backdropPath → backdropUrl（movieEntity/item）→ 海报降级
   */
  private getBackdropUrl(): string {
    const path = this.movieEntity?.backdropPath;
    if (path !== undefined && path.length > 0) { return tmdbImageUrl(path, 'w1280'); }
    const url = this.movieEntity?.backdropUrl ?? this.item?.backdropUrl;
    if (url !== undefined && url.length > 0) { return url; }
    return this.item?.posterLocalPath ?? this.item?.posterUrl ?? '';
  }

  /**
   * Backdrop 缩略图 URL（w300，用于 MovieWatchingCard 缩略图）。
   * 与 getBackdropUrl 相同优先级，但尺寸为 w300。
   */
  private getBackdropThumbUrl(): string {
    const path = this.movieEntity?.backdropPath;
    if (path !== undefined && path.length > 0) { return tmdbImageUrl(path, 'w300'); }
    const url = this.movieEntity?.backdropUrl ?? this.item?.backdropUrl;
    if (url !== undefined && url.length > 0) { return url; }
    return this.item?.posterLocalPath ?? this.item?.posterUrl ?? '';
  }

  /** 电影标题 */
  private getTitle(): string {
    return this.movieEntity?.title ?? this.item?.title ?? this.item?.fileName ?? '未知影片';
  }

  /** 上映年份（YYYY） */
  private getYear(): string {
    return formatYear(this.movieEntity?.releaseDate ?? this.item?.releaseDate);
  }

  /** 评分（可能为 undefined） */
  private getRating(): number | undefined {
    return this.movieEntity?.rating ?? this.item?.rating;
  }

  /** 完整简介文本 */
  private getOverview(): string {
    return this.movieEntity?.overview ?? this.item?.overview ?? '';
  }

  /** 简介是否超过 100 字 */
  private isOverviewLong(): boolean { return this.getOverview().length > 100; }

  /** 截断后的简介（前 100 字 + 省略号） */
  private getOverviewShort(): string { return this.getOverview().substring(0, 100) + '...'; }

  /** 类型标签数组 */
  private getGenres(): string[] {
    return parseGenresArr(this.movieEntity?.genresJson ?? this.item?.genresJson);
  }

  /** 类型标签文字，如 "剧情 / 动作" */
  private getGenresText(): string {
    const g = this.getGenres();
    if (g.length === 0) { return ''; }
    return g.slice(0, 3).join(' / ');
  }

  /** 片长文字，如 "2 小时 15 分" */
  private getRuntimeText(): string {
    const rt = this.movieEntity?.runtime;
    if (rt !== undefined && rt > 0) {
      const h = Math.floor(rt / 60);
      const m = rt % 60;
      if (h > 0) { return h.toString() + ' 小时 ' + m.toString() + ' 分'; }
      return m.toString() + ' 分钟';
    }
    const ms = this.item?.durationMs;
    if (ms !== undefined && ms > 0) {
      const totalSeconds = Math.floor(ms / 1000);
      const h2 = Math.floor(totalSeconds / 3600);
      const m2 = Math.floor((totalSeconds % 3600) / 60);
      if (h2 > 0) { return h2.toString() + ' 小时 ' + m2.toString() + ' 分'; }
      return m2.toString() + ' 分钟';
    }
    return '';
  }

  /** 详情弹窗海报 URL */
  private getPosterUrl(): string {
    const path = this.movieEntity?.posterPath;
    if (path !== undefined && path.length > 0) { return tmdbImageUrl(path, 'w342'); }
    return this.movieEntity?.posterUrl ?? this.item?.posterLocalPath ?? this.item?.posterUrl ?? '';
  }

  /** 是否有有效续播进度（大于 5 秒才算） */
  private hasProgress(): boolean {
    const p = this.progress;
    return p !== null && p.positionMs > 5000;
  }

  /** 是否已看完（>= 95%） */
  private isWatched(): boolean {
    const p = this.progress;
    if (p === null || p.durationMs <= 0) { return false; }
    return p.positionMs / p.durationMs >= 0.95;
  }

  /** 播放进度百分比（0~1） */
  private getProgressPercent(): number {
    const p = this.progress;
    if (p === null || p.durationMs <= 0) { return 0; }
    return Math.min(1, p.positionMs / p.durationMs);
  }

  /** 按钮背景色（焦点 > Hover > 默认） */
  private getButtonBgColor(key: string): string {
    if (this.focusedActionKey === key) { return '#3C8FF6'; }
    if (this.hoveredActionKey === key) { return '#2E82EA'; }
    return '#1B78F2';
  }

  /** 按钮边框色（焦点 > Hover > 透明） */
  private getButtonBorderColor(key: string): string {
    if (this.focusedActionKey === key) { return '#66A9D8FF'; }
    if (this.hoveredActionKey === key) { return '#7FB7F4'; }
    return '#00FFFFFF';
  }

  /**
   * 构建导演 + 演员合并列表（导演在前，演员在后）。
   * 用于 CastSection 渲染，最多取 15 人。
   */
  private buildCastCrewList(): CastCrewItem[] {
    const result: CastCrewItem[] = [];
    const directors = parseDirectorsArr(this.movieEntity?.directorsJson);
    for (const d of directors) {
      const ci: CastCrewItem = { name: d, role: '导演' };
      result.push(ci);
    }
    const castList = parseCastArr(this.movieEntity?.castJson);
    for (const c of castList) {
      const ci: CastCrewItem = { name: c.name, role: c.character, profile_path: c.profile_path };
      result.push(ci);
    }
    return result;
  }

  // ── 数据加载 ──────────────────────────────────

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
      console.warn('[MovieDetailPage] extractDominantColor failed', JSON.stringify(e));
    }
  }

  private loadAuxData(item: MediaItem): void {
    const db = FileSourceDatabase.getInstance();
    // 并行加载续播进度
    db.getPlayProgress(item.id).then((p: PlayProgressEntity | null) => {
      this.progress = p;
    }).catch(() => {});

    const provider = item.provider;
    const providerId = item.providerId;
    if (provider !== undefined && provider.length > 0 &&
        providerId !== undefined && providerId.length > 0) {
      db.getMovieByProviderId(provider, providerId).then((m: MovieEntity | null) => {
        this.movieEntity = m;
        // movieEntity 加载后提取背景色
        const backdropUrl = this.getBackdropUrl();
        if (backdropUrl.length > 0) { this.extractDominantColor(backdropUrl); }
      }).catch(() => {});
    } else {
      // 无刮削数据时直接尝试用 item.backdropUrl 提取
      const backdropUrl = this.getBackdropUrl();
      if (backdropUrl.length > 0) { this.extractDominantColor(backdropUrl); }
    }
  }

  /** 返回播放器后刷新进度 */
  private refreshProgress(item: MediaItem): void {
    FileSourceDatabase.getInstance()
      .getPlayProgress(item.id)
      .then((p: PlayProgressEntity | null) => { this.progress = p; })
      .catch(() => {});
  }

  /** 构建播放 URL 并跳转播放器 */
  private async play(): Promise<void> {
    const item = this.item;
    if (item === undefined) { return; }
    try {
      const db = FileSourceDatabase.getInstance();
      const fileSource = await db.getFileSourceById(item.sourceId);
      if (fileSource === null) {
        console.warn('[MovieDetailPage] 找不到文件源 sourceId=' + item.sourceId.toString());
        return;
      }
      const config = JSON.parse(fileSource.configJson) as Record<string, string>;
      let fullUrl: string;
      let httpHeader: Record<string, string>;

      if (fileSource.type === FileSourceType.SMB) {
        const smbConfig = JSON.parse(fileSource.configJson) as SMBSourceConfig;
        const port = smbConfig.port ?? 445;
        const user = encodeURIComponent(smbConfig.username);
        const pass = encodeURIComponent(smbConfig.password);
        const encodedPath = item.filePath.split('/').map((seg: string): string => {
          if (seg.length === 0) { return ''; }
          let decoded: string = seg;
          try { decoded = decodeURIComponent(seg); } catch { decoded = seg; }
          return encodeURIComponent(decoded);
        }).join('/');
        fullUrl = 'smb://' + user + ':' + pass + '@' + smbConfig.host + ':' + port.toString() + encodedPath;
        httpHeader = {};
      } else {
        const protocol = config['protocol'] ?? 'http';
        const host = config['url'] ?? '';
        const port = config['port'] ?? (protocol === 'https' ? '443' : '80');
        const rootPath = (config['rootPath'] ?? '').replace(/\/$/, '');
        const baseUrl = protocol + '://' + host + ':' + port + rootPath;
        const webdavConfig: WebDAVConfig = {
          baseUrl,
          username: config['username'] ?? '',
          password: config['password'] ?? '',
          timeout: 30000
        };
        const client = new WebDAVClient(webdavConfig);
        fullUrl = client.getFullUrl(item.filePath);
        const authHeader = client.getAuthHeaderPublic();
        httpHeader = authHeader.length > 0 ? { 'Authorization': authHeader } : {};
      }

      const param: PlayerPageParam = {
        videoId: item.id,
        url: fullUrl,
        httpHeader,
        title: this.getTitle(),
        durationHintMs: item.durationMs,
        seriesProviderId: '',
        seasonNumber: 0,
        episodeNumber: 0
      };
      this.pageStack.pushPathByName(PlayerPage.PAGE_NAME, param);
    } catch (e) {
      console.error('[MovieDetailPage] play() 构建播放 URL 失败');
    }
  }

  // ── Builders ──────────────────────────────────

  /** 电影版续播卡片（右侧，显示 backdrop 缩略图 + 进度 + 播放按钮） */
  @Builder
  MovieWatchingCard() {
    Column() {
      Row({ space: 14 }) {
        // 左：Backdrop 缩略图 150x84（优先 w300 backdrop，降级海报，再降级占位深色块）
        if (this.getBackdropThumbUrl().length > 0) {
          Image(this.getBackdropThumbUrl())
            .width(150).height(84)
            .borderRadius(4)
            .objectFit(ImageFit.Cover)
            .border({ width: 1, color: '#2E2E2E' })
        } else {
          Column()
            .width(150).height(84)
            .backgroundColor('#1C1C1C')
            .borderRadius(4)
            .border({ width: 1, color: '#2E2E2E' })
        }

        // 右：信息区
        if (this.hasProgress() && this.progress !== null) {
          // ── 有续播进度 ────────────────────────────────
          Column({ space: 10 }) {
            // 时长标签 + 电影标题
            Row({ space: 8 }) {
              Text(formatMovieDuration(this.movieEntity?.runtime, this.item?.durationMs))
                .fontSize(12)
                .fontColor('#1B78F2')
                .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                .backgroundColor('#192840')
                .borderRadius(3)
              Text(this.getTitle())
                .fontSize(14).fontColor('#CCCCCC').fontWeight(FontWeight.Medium)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .alignItems(VerticalAlign.Center)

            // 进度条
            Column() {
              Column()
                .width(Math.round(this.getProgressPercent() * 100).toString() + '%')
                .height('100%')
                .backgroundColor('#1B78F2').borderRadius(2)
                .alignSelf(ItemAlign.Start)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%').height(4)
            .backgroundColor('#2E2E2E').borderRadius(2)

            // 播放按钮行
            Row({ space: 10 }) {
              Row({ space: 6 }) {
                Text('▶').fontSize(12).fontColor(Color.White)
                Text(this.isWatched() ? '重新播放' : '继续播放')
                  .fontSize(14).fontColor(Color.White).fontWeight(FontWeight.Bold)
              }
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.getButtonBgColor('resume')).borderRadius(4)
              .border({ width: 2, color: this.getButtonBorderColor('resume') })
              .focusable(true)
              .onFocus(() => { this.focusedActionKey = 'resume'; })
              .onBlur(() => { if (this.focusedActionKey === 'resume') { this.focusedActionKey = ''; } })
              .onHover((isHover: boolean) => {
                if (isHover) { this.hoveredActionKey = 'resume'; }
                else { if (this.hoveredActionKey === 'resume') { this.hoveredActionKey = ''; } }
              })
              .onClick(() => { this.play(); })

              Text(millisecondsToTime(this.progress.positionMs))
                .fontSize(12).fontColor('#888888')
            }
            .alignItems(VerticalAlign.Center)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.SpaceBetween)
          .height(84)
        } else {
          // ── 无续播进度，显示立即播放 ────────────────────────────────
          Column({ space: 10 }) {
            Row({ space: 8 }) {
              Text(this.getTitle())
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
                .alignSelf(ItemAlign.Start)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%').height(4)
            .backgroundColor('#2E2E2E').borderRadius(2)

            Row({ space: 6 }) {
              Text('▶').fontSize(12).fontColor(Color.White)
              Text('立即播放').fontSize(14).fontColor(Color.White).fontWeight(FontWeight.Bold)
            }
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.getButtonBgColor('start')).borderRadius(4)
            .border({ width: 2, color: this.getButtonBorderColor('start') })
            .focusable(true)
            .onFocus(() => { this.focusedActionKey = 'start'; })
            .onBlur(() => { if (this.focusedActionKey === 'start') { this.focusedActionKey = ''; } })
            .onHover((isHover: boolean) => {
              if (isHover) { this.hoveredActionKey = 'start'; }
              else { if (this.hoveredActionKey === 'start') { this.hoveredActionKey = ''; } }
            })
            .onClick(() => { this.play(); })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.SpaceBetween)
          .height(84)
        }
      }
      .alignItems(VerticalAlign.Center)
    }
    .padding({ left: 16, right: 20, top: 14, bottom: 14 })
    .backgroundColor('#18FFFFFF')
    .borderRadius(8)
    .border({ width: 1, color: '#22FFFFFF' })
    .width(500)
  }

  /** Hero 区域：全屏 backdrop + 双渐变遮罩 + 标题/元信息/简介 + 续播卡片 */
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
        .hitTestBehavior(HitTestMode.Transparent)

      // ── 左侧渐变遮罩 ──────────────────────────────
      Column()
        .width('55%').height('100%')
        .linearGradient({
          angle: 90,
          colors: [[this.toOpaqueColor(this.dominantBgColor), 0.0], ['#00000000', 1.0]]
        })
        .position({ left: 0, top: 0 })
        .hitTestBehavior(HitTestMode.Transparent)

      // ── 底部内容行 ────────────────────────────────
      Row({ space: 40 }) {
        // 左侧：标题 / 元信息 / 简介
        Column({ space: 14 }) {
          Text(this.getTitle())
            .fontSize(52).fontColor(Color.White).fontWeight(FontWeight.Bold)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .textShadow({ radius: 8, color: '#88000000', offsetX: 2, offsetY: 2 })
            .constraintSize({ maxWidth: 720 })

          // 元信息行：年份 + 时长 + 评分 + 类型标签（同行）
          Row({ space: 12 }) {
            if (this.getYear().length > 0) {
              Text(this.getYear())
                .fontSize(18).fontColor('#CCCCCC').fontWeight(FontWeight.Medium)
            }
            if (this.getRuntimeText().length > 0) {
              Text(this.getRuntimeText())
                .fontSize(18).fontColor('#CCCCCC').fontWeight(FontWeight.Medium)
            }
            if (this.getRating() !== undefined) {
              Row({ space: 4 }) {
                Text('★').fontSize(16).fontColor('#FFA500')
                Text((this.getRating() as number).toFixed(1))
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

          // 简介：超 100 字截断显示 + 「更多」Span，不超出仅显示原文
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

        // 右侧：电影版续播卡片
        this.MovieWatchingCard()
      }
      .width('100%')
      .padding({ left: 80, right: 80, bottom: 52 })
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%').aspectRatio(1.778)
  }

  /** 演职人员横向滚动列表（导演在前，演员在后，最多 15 人） */
  @Builder
  CastSection() {
    if (this.buildCastCrewList().length > 0) {
      Column({ space: 0 }) {
        Text('演职人员')
          .fontSize(26).fontColor(Color.White).fontWeight(FontWeight.Bold)
          .padding({ left: 80, top: 36, bottom: 20 })

        Scroll() {
          Row({ space: 24 }) {
            ForEach(this.buildCastCrewList().slice(0, 15), (c: CastCrewItem) => {
              Column({ space: 8 }) {
                // 人物照片（长方形）
                if (c.profile_path !== undefined && c.profile_path.length > 0) {
                  Image(tmdbImageUrl(c.profile_path, 'w185'))
                    .width(110).aspectRatio(2 / 3)
                    .objectFit(ImageFit.Cover).borderRadius(6)
                    .hoverEffect(HoverEffect.Scale)
                } else {
                  Column() {
                    Text((c.name != null && c.name.length > 0) ? c.name.substring(0, 1) : '?')
                      .fontSize(30).fontColor(Color.White).fontWeight(FontWeight.Bold)
                  }
                  .width(110).aspectRatio(2 / 3).borderRadius(6)
                  .backgroundColor('#2A2A2A')
                  .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                  .hoverEffect(HoverEffect.Scale)
                }
                // 姓名
                Text(c.name ?? '')
                  .fontSize(14).fontColor(Color.White)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width(110).textAlign(TextAlign.Center)
                // 角色 / 职位
                if (c.role !== undefined && c.role.length > 0) {
                  Text(c.role)
                    .fontSize(12).fontColor('#777777')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width(110).textAlign(TextAlign.Center)
                }
              }
              .width(110).alignItems(HorizontalAlign.Center)
            }, (c: CastCrewItem) => c.name ?? '')
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

  /** 简介全文弹窗覆盖层（点击「更多」时展开，双面板布局） */
  @Builder
  OverviewDialog() {
    if (this.showOverviewDialog) {
      Stack({ alignContent: Alignment.Center }) {
        // 半透明遮罩
        Column()
          .width('100%').height('100%')
          .backgroundColor('#BB000000')
          .onClick(() => { this.showOverviewDialog = false; })

        // 卡片主体
        Column() {
          // ── 标题栏 ──────────────────────────────
          Row() {
            Text('简介')
              .fontSize(26).fontColor('#F0F0F0').fontWeight(FontWeight.Bold)
              .layoutWeight(1).textAlign(TextAlign.Center)
            Text('✕')
              .fontSize(20).fontColor('#888892')
              .width(48).height(48)
              .textAlign(TextAlign.Center)
              .borderRadius(24)
              .backgroundColor('#2A2A2E')
              .onClick(() => { this.showOverviewDialog = false; })
          }
          .alignItems(VerticalAlign.Center)
          .padding({ left: 24, right: 24, top: 0, bottom: 0 })
          .height(80)
          .width('100%')
          .backgroundColor('#1E1E22')

          // 分隔线
          Divider().color('#2E2E34').strokeWidth(1)

          // ── 内容区（左右双面板）────────────────────
          Row() {
            // 左面板：海报 + 元数据
            Column({ space: 20 }) {
              Image(this.getPosterUrl())
                .width(124).height(174)
                .borderRadius(6)
                .objectFit(ImageFit.Cover)
                .backgroundColor('#2A2A2E')

              Text(this.getTitle())
                .fontSize(22).fontWeight(FontWeight.Bold).fontColor('#F0F0F0')
                .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
                .lineHeight(32)
                .width('100%')

              Column({ space: 8 }) {
                if (this.getGenresText().length > 0) {
                  Text('风格：' + this.getGenresText())
                    .fontSize(18).fontColor('#AAAAAA')
                }
                if (this.getRuntimeText().length > 0) {
                  Text('片长：' + this.getRuntimeText())
                    .fontSize(18).fontColor('#AAAAAA')
                }
                if (this.getYear().length > 0) {
                  Text(this.getYear())
                    .fontSize(18).fontColor('#AAAAAA')
                }
              }
              .alignItems(HorizontalAlign.Start).width('100%')
            }
            .width('28%')
            .padding({ left: 48, right: 32, top: 48, bottom: 48 })
            .alignItems(HorizontalAlign.Start)

            // 垂直分隔线
            Divider().vertical(true).color('#2A2A2E').strokeWidth(1).height('100%')

            // 右面板：全文简介
            Scroll() {
              Text(this.getOverview())
                .fontSize(20).fontColor('#C8C8D0').lineHeight(36)
                .width('100%')
            }
            .scrollable(ScrollDirection.Vertical)
            .scrollBar(BarState.Auto)
            .scrollBarColor('#555560')
            .layoutWeight(1)
            .padding({ left: 40, right: 40, top: 48, bottom: 48 })
          }
          .alignItems(VerticalAlign.Top)
          .layoutWeight(1)
        }
        .width('85%').height('88%')
        .backgroundColor('#18181C')
        .borderRadius(16)
        .border({ width: 1, color: '#2A2A2E' })
        .clip(true)
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
            // 无 SeasonsSection（电影无季集结构）
            this.CastSection()
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

        // 顶部浮动返回按钮
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
      const param = context.pathInfo.param as MediaItem;
      if (param !== undefined && param !== null) {
        this.item = param;
        this.loadAuxData(param);
      }
    })
    .onShown(() => {
      if (this.item !== undefined) { this.refreshProgress(this.item); }
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
