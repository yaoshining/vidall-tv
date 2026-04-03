import { FileSourceDatabase } from '../../db/files/FileSourceDatabase';
import { MediaProgressEntry, MediaItem, MovieEntity, TvSeriesEntity } from '../../db/models/MediaEntity';
import { FileSourceType, SMBSourceConfig } from '../../db/models/FileSourceEntity';
import { MediaProgressStore } from '../../db/MediaProgressStore';
import { PlayerPage, PlayerPageParam } from '../player/index';
import { WebDAVClient, WebDAVConfig } from '../../lib/WebDAVClient';
import promptAction from '@ohos.promptAction';

// ─────────────────────────────────────────────
// 数据类型
// ─────────────────────────────────────────────

interface ParsedMediaKey {
  kind: 'movie' | 'series' | 'unknown';
  providerId: string;
}

/**
 * 播放历史显示条目，由 MediaProgressEntry + 元数据 + 视频文件信息聚合而成。
 */
interface HistoryDisplayItem {
  mediaKey: string;
  positionMs: number;
  durationMs: number;
  lastPlayedAt: number;
  episodeNumber: number;
  seasonNumber: number;
  title: string;
  posterLocalPath: string;
  posterUrl: string;
  releaseYear: string;
  kind: 'movie' | 'series' | 'unknown';
  videoId: number;
  sourceId: number;
  filePath: string;
  seriesProviderId: string;
}

interface PlayUrlResult {
  fileUrl: string;
  url: string;
  httpHeader: Record<string, string>;
}

// ─────────────────────────────────────────────
// 工具函数
// ─────────────────────────────────────────────

/**
 * 解析 mediaKey 格式：
 *   media_progress_movie_<providerId>
 *   media_progress_series_tmdb_<seriesProviderId>
 */
function parseMediaKey(mediaKey: string): ParsedMediaKey {
  const MOVIE_PREFIX = 'media_progress_movie_';
  const SERIES_TMDB_PREFIX = 'media_progress_series_tmdb_';
  const SERIES_PREFIX = 'media_progress_series_';

  if (mediaKey.startsWith(MOVIE_PREFIX)) {
    return { kind: 'movie', providerId: mediaKey.substring(MOVIE_PREFIX.length) };
  }
  if (mediaKey.startsWith(SERIES_TMDB_PREFIX)) {
    return { kind: 'series', providerId: mediaKey.substring(SERIES_TMDB_PREFIX.length) };
  }
  if (mediaKey.startsWith(SERIES_PREFIX)) {
    // 其他 provider，格式：media_progress_series_<provider>_<id>
    const rest = mediaKey.substring(SERIES_PREFIX.length);
    const underscoreIdx = rest.indexOf('_');
    if (underscoreIdx >= 0) {
      return { kind: 'series', providerId: rest.substring(underscoreIdx + 1) };
    }
  }
  return { kind: 'unknown', providerId: '' };
}

// ─────────────────────────────────────────────
// 播放历史页面
// ─────────────────────────────────────────────

@ComponentV2
export struct PlayHistoryPage {
  static readonly PAGE_NAME: string = 'PlayHistoryPage';

  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local historyList: HistoryDisplayItem[] = [];
  @Local isLoading: boolean = false;
  /** 主行内容聚焦的行下标（TV遥控器） */
  @Local focusedIndex: number = -1;
  /** 删除按钮聚焦的行下标（TV遥控器） */
  @Local deleteFocusedIndex: number = -1;
  /** 鼠标悬浮的行下标 */
  @Local hoveredIndex: number = -1;

  // ─── 生命周期 ───────────────────────────────

  aboutToAppear(): void {
    this.loadHistoryData().catch((): void => {});
  }

  // ─── 数据加载 ───────────────────────────────

  private async loadHistoryData(): Promise<void> {
    this.isLoading = true;
    const db = FileSourceDatabase.getInstance();
    try {
      const entries = await db.getAllMediaProgress();
      if (entries.length === 0) {
        this.historyList = [];
        this.isLoading = false;
        return;
      }
      // 一次性加载所有视频 MediaItem，用于跨表匹配文件路径
      const allVideos = await db.getAllMediaItems();
      const items: HistoryDisplayItem[] = [];

      for (let i = 0; i < entries.length; i++) {
        const entry = entries[i];
        const parsed = parseMediaKey(entry.mediaKey);
        if (parsed.kind === 'unknown') {
          continue;
        }

        let title: string = '';
        let posterLocalPath: string = '';
        let posterUrl: string = '';
        let releaseYear: string = '';
        let videoId: number = 0;
        let sourceId: number = 0;
        let filePath: string = '';
        let seriesProviderId: string = '';

        if (parsed.kind === 'movie') {
          const movie: MovieEntity | null = await db.getMovieByProviderId('tmdb', parsed.providerId);
          if (movie !== null) {
            title = movie.title;
            posterLocalPath = movie.posterLocalPath ?? '';
            posterUrl = movie.posterUrl ?? '';
            const rd = movie.releaseDate ?? '';
            releaseYear = rd.length >= 4 ? rd.substring(0, 4) : '';
            const movieDbId = movie.id ?? 0;
            if (movieDbId > 0) {
              const matched = allVideos.find((v: MediaItem): boolean =>
                v.movieId !== undefined && v.movieId === movieDbId
              );
              if (matched !== undefined) {
                videoId = matched.id;
                sourceId = matched.sourceId;
                filePath = matched.filePath;
              }
            }
          }
        } else {
          // series
          seriesProviderId = parsed.providerId;
          const series: TvSeriesEntity | null = await db.getTvSeriesByProviderId('tmdb', parsed.providerId);
          if (series !== null) {
            title = series.title;
            posterLocalPath = series.posterLocalPath ?? '';
            posterUrl = series.posterUrl ?? '';
            const seriesDbId = series.id ?? 0;
            if (seriesDbId > 0) {
              const sn = entry.seasonNumber;
              const en = entry.episodeNumber;
              const matched = allVideos.find((v: MediaItem): boolean =>
                v.tvSeriesId !== undefined && v.tvSeriesId === seriesDbId &&
                (v.seasonNumber ?? -1) === sn &&
                (v.episodeNumber ?? -1) === en
              );
              if (matched !== undefined) {
                videoId = matched.id;
                sourceId = matched.sourceId;
                filePath = matched.filePath;
              }
            }
          }
        }

        const item: HistoryDisplayItem = {
          mediaKey: entry.mediaKey,
          positionMs: entry.positionMs,
          durationMs: entry.durationMs,
          lastPlayedAt: entry.lastPlayedAt,
          episodeNumber: entry.episodeNumber,
          seasonNumber: entry.seasonNumber,
          title,
          posterLocalPath,
          posterUrl,
          releaseYear,
          kind: parsed.kind,
          videoId,
          sourceId,
          filePath,
          seriesProviderId,
        };
        items.push(item);
      }
      this.historyList = items;
    } catch (e) {
      // 静默失败，保持列表为空
    }
    this.isLoading = false;
  }

  // ─── 播放 ────────────────────────────────────

  /**
   * 构建播放 URL。支持 SMB 和 WebDAV 两种文件源类型。
   */
  private async buildPlayUrl(sourceId: number, filePath: string): Promise<PlayUrlResult | null> {
    const db = FileSourceDatabase.getInstance();
    try {
      const fileSource = await db.getFileSourceById(sourceId);
      if (fileSource === null) {
        return null;
      }
      if (fileSource.type === FileSourceType.SMB) {
        const smbConfig = JSON.parse(fileSource.configJson) as SMBSourceConfig;
        const port = smbConfig.port ?? 445;
        const user = encodeURIComponent(smbConfig.username);
        const pass = encodeURIComponent(smbConfig.password);
        const encodedPath = filePath.split('/').map((seg: string): string => {
          if (seg.length === 0) {
            return '';
          }
          let decoded: string = seg;
          try {
            decoded = decodeURIComponent(seg);
          } catch {
            decoded = seg;
          }
          return encodeURIComponent(decoded);
        }).join('/');
        const fullUrl = 'smb://' + user + ':' + pass + '@' + smbConfig.host + ':' + port.toString() + encodedPath;
        const result: PlayUrlResult = { fileUrl: '', url: fullUrl, httpHeader: {} };
        return result;
      } else if (fileSource.type === FileSourceType.WEBDAV) {
        const config = JSON.parse(fileSource.configJson) as Record<string, string>;
        const protocol = config['protocol'] ?? 'http';
        const host = config['url'] ?? '';
        const webdavPort = config['port'] ?? (protocol === 'https' ? '443' : '80');
        const rootPath = (config['rootPath'] ?? '').replace(/\/$/, '');
        const baseUrl = protocol + '://' + host + ':' + webdavPort + rootPath;
        const webdavConfig: WebDAVConfig = {
          baseUrl,
          username: config['username'] ?? '',
          password: config['password'] ?? '',
          timeout: 30000,
        };
        const client = new WebDAVClient(webdavConfig);
        const fullUrl = client.getFullUrl(filePath);
        const authHeader = client.getAuthHeaderPublic();
        const httpHeader: Record<string, string> =
          authHeader.length > 0 ? { 'Authorization': authHeader } : {};
        const result: PlayUrlResult = { fileUrl: '', url: fullUrl, httpHeader };
        return result;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /**
   * 跳转播放器。fromStart=true 时不传 mediaKey/startPositionMs，
   * 播放器会走 play_progress 续播弹窗路径（或直接从头播）。
   */
  private playItemSync(item: HistoryDisplayItem, fromStart: boolean = false): void {
    this.playItemAsync(item, fromStart).catch((): void => {});
  }

  private async playItemAsync(item: HistoryDisplayItem, fromStart: boolean): Promise<void> {
    if (item.videoId === 0 || item.sourceId === 0) {
      promptAction.showToast({ message: '无法找到对应视频文件' });
      return;
    }
    const urlResult = await this.buildPlayUrl(item.sourceId, item.filePath);
    if (urlResult === null) {
      promptAction.showToast({ message: '无法构建播放地址' });
      return;
    }
    const param: PlayerPageParam = {
      url: urlResult.url.length > 0 ? urlResult.url : undefined,
      fileUrl: urlResult.fileUrl.length > 0 ? urlResult.fileUrl : undefined,
      httpHeader: urlResult.httpHeader,
      title: item.title,
      videoId: item.videoId,
      seriesProviderId: item.seriesProviderId,
      seasonNumber: item.episodeNumber > 0 ? item.seasonNumber : 0,
      episodeNumber: item.episodeNumber > 0 ? item.episodeNumber : 0,
      mediaKey: fromStart ? undefined : item.mediaKey,
      startPositionMs: fromStart ? undefined : (item.positionMs > 0 ? item.positionMs : undefined),
    };
    this.pageStack.pushPathByName(PlayerPage.PAGE_NAME, param);
  }

  // ─── 删除 ────────────────────────────────────

  /**
   * 弹出 AlertDialog 确认后删除单条记录。
   */
  private confirmDeleteItem(item: HistoryDisplayItem): void {
    AlertDialog.show({
      title: '删除播放记录',
      message: `确定删除《${item.title}》的播放记录吗？此操作无法撤销。`,
      primaryButton: {
        value: '确定删除',
        fontColor: '#FF6B6B',
        action: () => {
          this.doDeleteItem(item);
        },
      },
      secondaryButton: {
        value: '取消',
        action: () => {},
      },
      autoCancel: true,
    });
  }

  private doDeleteItem(item: HistoryDisplayItem): void {
    this.doDeleteItemAsync(item).catch((): void => {});
  }

  private async doDeleteItemAsync(item: HistoryDisplayItem): Promise<void> {
    await FileSourceDatabase.getInstance().clearMediaProgress(item.mediaKey);
    this.historyList = this.historyList.filter(
      (i: HistoryDisplayItem): boolean => i.mediaKey !== item.mediaKey
    );
    promptAction.showToast({ message: '已删除播放记录' });
  }

  /**
   * 弹出 AlertDialog 确认后清除全部记录。
   */
  private confirmClearAll(): void {
    if (this.historyList.length === 0) {
      return;
    }
    AlertDialog.show({
      title: '清除全部记录',
      message: '确定清除所有播放历史记录吗？此操作无法撤销。',
      primaryButton: {
        value: '全部清除',
        fontColor: '#FF6B6B',
        action: () => {
          this.doClearAll();
        },
      },
      secondaryButton: {
        value: '取消',
        action: () => {},
      },
      autoCancel: true,
    });
  }

  private doClearAll(): void {
    this.doClearAllAsync().catch((): void => {});
  }

  private async doClearAllAsync(): Promise<void> {
    const db = FileSourceDatabase.getInstance();
    const keys = this.historyList.map((i: HistoryDisplayItem): string => i.mediaKey);
    for (let i = 0; i < keys.length; i++) {
      try {
        await db.clearMediaProgress(keys[i]);
      } catch (e) {
        // 单条失败不阻断后续
      }
    }
    this.historyList = [];
    promptAction.showToast({ message: '已清除全部播放记录' });
  }

  // ─── 工具方法 ─────────────────────────────────

  private formatRelativeTime(lastPlayedAt: number): string {
    const diff = Date.now() - lastPlayedAt;
    const minutes = Math.floor(diff / 60000);
    const hours = Math.floor(diff / 3600000);
    const days = Math.floor(diff / 86400000);
    if (diff < 60000) {
      return '刚刚';
    }
    if (minutes < 60) {
      return `${minutes}分钟前`;
    }
    if (hours < 24) {
      return `${hours}小时前`;
    }
    if (days === 1) {
      return '昨天';
    }
    if (days < 30) {
      return `${days}天前`;
    }
    const d = new Date(lastPlayedAt);
    return `${d.getMonth() + 1}月${d.getDate()}日`;
  }

  private formatDuration(ms: number): string {
    const s = Math.floor(ms / 1000);
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    if (h > 0) {
      return `${h}:${m.toString().padStart(2, '0')}:${sec.toString().padStart(2, '0')}`;
    }
    return `${m}:${sec.toString().padStart(2, '0')}`;
  }

  // ─── Builder：历史条目卡片 ─────────────────────

  @Builder
  HistoryListCard(item: HistoryDisplayItem, index: number) {
    Row() {
      // ── 左：缩略图 + 进度条 ──────────────────
      Column() {
        // 缩略图
        if (item.posterLocalPath.length > 0 || item.posterUrl.length > 0) {
          Image(item.posterLocalPath.length > 0 ? item.posterLocalPath : item.posterUrl)
            .width(120)
            .height(68)
            .objectFit(ImageFit.Cover)
            .borderRadius(6)
        } else {
          Column() {
            Text('🎬')
              .fontSize(24)
          }
          .width(120)
          .height(68)
          .backgroundColor('#2A2A2A')
          .justifyContent(FlexAlign.Center)
          .borderRadius(6)
        }

        // 进度条：背景轨道 + 填充层叠
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width(120)
            .height(3)
            .backgroundColor('#333333')
            .borderRadius(1.5)
          Row()
            .width(
              MediaProgressStore.isNearEnd(item.positionMs, item.durationMs)
                ? '100%'
                : `${item.durationMs > 0 ? Math.min(100, item.positionMs / item.durationMs * 100) : 0}%`
            )
            .height(3)
            .backgroundColor(
              MediaProgressStore.isNearEnd(item.positionMs, item.durationMs)
                ? '#66DD88' : '#4488FF'
            )
            .borderRadius(1.5)
        }
        .width(120)
        .height(3)
        .margin({ top: 4 })
      }
      .width(120)
      .alignItems(HorizontalAlign.Start)

      // ── 中：文字信息区 ───────────────────────
      Column() {
        // 标题行 + 完播标签
        Row() {
          Text(item.title)
            .fontSize(16)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (MediaProgressStore.isNearEnd(item.positionMs, item.durationMs)) {
            Text('已看完')
              .fontSize(10)
              .fontColor('#66DD88')
              .backgroundColor('rgba(102,221,136,0.12)')
              .border({ width: 1, color: 'rgba(102,221,136,0.35)' })
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 2, bottom: 2 })
              .margin({ left: 6 })
          }
        }
        .width('100%')

        // 副标题：剧集显示「第S季 第E集」，电影显示年份
        Text(
          item.kind === 'series' && item.episodeNumber > 0
            ? `第${item.seasonNumber}季 第${item.episodeNumber}集`
            : item.releaseYear
        )
          .fontSize(12)
          .fontColor('rgba(255,255,255,0.55)')
          .margin({ top: 4 })
          .width('100%')

        // 进度文字：「已播 / 总时长 · 相对时间」
        Text(
          `${this.formatDuration(item.positionMs)} / ${this.formatDuration(item.durationMs)}` +
          ` · ${this.formatRelativeTime(item.lastPlayedAt)}`
        )
          .fontSize(11)
          .fontColor('rgba(255,255,255,0.40)')
          .margin({ top: 4 })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16 })

      // ── 右：删除按钮（聚焦时可见）────────────
      Column() {
        Button('删除')
          .width(48)
          .height(40)
          .fontSize(12)
          .fontColor('#FF6B6B')
          .backgroundColor('rgba(255,107,107,0.12)')
          .border({ width: 1, color: 'rgba(255,107,107,0.30)' })
          .borderRadius(6)
          .focusable(true)
          .onFocus(() => {
            this.deleteFocusedIndex = index;
            this.focusedIndex = -1;
          })
          .onBlur(() => {
            this.deleteFocusedIndex = -1;
          })
          .onClick(() => {
            this.confirmDeleteItem(item);
          })
      }
      .width(60)
      .justifyContent(FlexAlign.Center)
      .opacity(
        this.focusedIndex === index ||
        this.deleteFocusedIndex === index ||
        this.hoveredIndex === index ? 1 : 0
      )
      .animation({ duration: 140, curve: Curve.Linear })
    }
    .width('100%')
    .height(100)
    .padding({ left: 24, right: 24, top: 8, bottom: 8 })
    .backgroundColor(
      this.focusedIndex === index ||
      this.deleteFocusedIndex === index ||
      this.hoveredIndex === index
        ? 'rgba(255,255,255,0.06)' : Color.Transparent
    )
    .border(
      this.focusedIndex === index ||
      this.deleteFocusedIndex === index ||
      this.hoveredIndex === index
        ? { width: { left: 3, top: 0, right: 0, bottom: 0 }, color: 'rgba(255,255,255,0.30)' }
        : { width: 0 }
    )
    .focusable(true)
    .onFocus(() => {
      this.focusedIndex = index;
      this.deleteFocusedIndex = -1;
    })
    .onBlur(() => {
      this.focusedIndex = -1;
    })
    .onHover((hover: boolean) => {
      this.hoveredIndex = hover ? index : -1;
    })
    .onClick(() => {
      this.playItemSync(item);
    })
    .onKeyEvent((event: KeyEvent) => {
      if (event.type !== KeyType.Down) {
        return;
      }
      // 菜单键（2067）：弹出 ActionSheet
      if (event.keyCode === 2067) {
        ActionSheet.show({
          title: '操作',
          message: '',
          sheets: [
            {
              title: '从头播放',
              action: () => {
                this.playItemSync(item, true);
              },
            },
            {
              title: '删除此条记录',
              action: () => {
                this.confirmDeleteItem(item);
              },
            },
          ],
        });
      }
    })
  }

  // ─── Builder：空态 ────────────────────────────

  @Builder
  EmptyView() {
    Column() {
      Text('📺')
        .fontSize(56)
        .opacity(0.35)
      Text('暂无播放记录')
        .fontSize(18)
        .fontColor('#666666')
        .margin({ top: 24 })
      Text('开始播放后，历史将显示在这里')
        .fontSize(13)
        .fontColor('#444444')
        .margin({ top: 8 })
      Button('去浏览媒体库')
        .onClick(() => {
          this.pageStack.pop();
        })
        .width(200)
        .height(44)
        .margin({ top: 32 })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 120 })
  }

  // ─── build ────────────────────────────────────

  build() {
    NavDestination() {
      Column() {
        // ── 页头 ──────────────────────────────
        Row() {
          Button('← 返回')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor('rgba(255,255,255,0.08)')
            .borderRadius(6)
            .focusable(true)
            .onClick(() => {
              this.pageStack.pop();
            })

          Text('播放历史')
            .fontSize(22)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)

          if (this.historyList.length > 0) {
            Button('全部清除')
              .fontSize(13)
              .fontColor('#FF6B6B')
              .backgroundColor('rgba(255,107,107,0.08)')
              .borderRadius(6)
              .focusable(true)
              .onClick(() => {
                this.confirmClearAll();
              })
          } else {
            // 占位，保持标题居中
            Row().width(80).height(36)
          }
        }
        .width('100%')
        .height(72)
        .padding({ left: 24, right: 24 })
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)

        // ── 内容区 ────────────────────────────
        if (this.historyList.length === 0) {
          this.EmptyView()
        } else {
          List({ space: 0 }) {
            ForEach(
              this.historyList,
              (item: HistoryDisplayItem, index: number) => {
                ListItem() {
                  this.HistoryListCard(item, index)
                }
              },
              (item: HistoryDisplayItem) => item.mediaKey
            )
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#1A1A1A')
    }
    .hideTitleBar(true)
    .onShown(() => {
      // 每次页面显示时刷新（从播放器返回后可能有新记录）
      this.loadHistoryData().catch((): void => {});
    })
  }
}
