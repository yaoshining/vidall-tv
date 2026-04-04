import { FileSourceDatabase } from '../../db/files/FileSourceDatabase';
import { MediaProgressEntry, MediaItem, MovieEntity, TvSeriesEntity } from '../../db/models/MediaEntity';
import { FileSourceType, SMBSourceConfig } from '../../db/models/FileSourceEntity';
import { MediaProgressStore } from '../../db/MediaProgressStore';
import { PlayerPage, PlayerPageParam } from '../player/index';
import { WebDAVClient, WebDAVConfig } from '../../lib/WebDAVClient';
import promptAction from '@ohos.promptAction';
import { BusinessError, emitter } from '@kit.BasicServicesKit';
import { PlayerEvents } from '../../components/core/player/Constants';


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

/** showActionMenu 回调数据结构（仅需 index 字段） */
interface ActionMenuSuccessResult {
  index: number;
}

// ─────────────────────────────────────────────
// 工具函数
// ─────────────────────────────────────────────

/**
 * 解析 mediaKey 格式：
 *   media_progress_movie_<providerId>
 *   media_progress_episode_tmdb_<seriesTmdbId>_s<sn>_e<en>  （新集级格式）
 *   media_progress_series_tmdb_<seriesTmdbId>              （旧剧级格式，向后兼容）
 *
 * 返回 providerId：
 *   - 电影：movieProviderId（如 "tmdb_12345"）
 *   - 剧集：seriesTmdbId（如 "1399"）
 */
function parseMediaKey(mediaKey: string): ParsedMediaKey {
  const MOVIE_PREFIX = 'media_progress_movie_';
  const EPISODE_TMDB_PREFIX = 'media_progress_episode_tmdb_';
  const SERIES_TMDB_PREFIX = 'media_progress_series_tmdb_';
  const SERIES_PREFIX = 'media_progress_series_';

  if (mediaKey.startsWith(MOVIE_PREFIX)) {
    return { kind: 'movie', providerId: mediaKey.substring(MOVIE_PREFIX.length) };
  }
  if (mediaKey.startsWith(EPISODE_TMDB_PREFIX)) {
    // 格式：media_progress_episode_tmdb_{seriesTmdbId}_s{sn}_e{en}
    const rest = mediaKey.slice(EPISODE_TMDB_PREFIX.length);
    // 从尾部找 _e{digits} 再找 _s{digits}，以提取 seriesTmdbId
    const eIdx = rest.lastIndexOf('_e');
    const sIdx = eIdx >= 0 ? rest.lastIndexOf('_s', eIdx) : -1;
    const seriesProviderId = sIdx >= 0 ? rest.substring(0, sIdx) : rest;
    return { kind: 'series', providerId: seriesProviderId };
  }
  // 向后兼容：旧剧级 key
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
      const entries = await db.getAllMediaProgress(200);
      if (entries.length === 0) {
        this.historyList = [];
        return;
      }

      // 批量加载所有数据，消除 N+1 查询
      const allVideos = await db.getAllMediaItems();
      const allMovies = await db.getAllMovies();
      const allSeriesList = await db.getAllTvSeries();

      // 构建查找 Map，O(1) 替代 Array.find()
      const movieMap = new Map<string, MovieEntity>();
      for (let i = 0; i < allMovies.length; i++) {
        const m = allMovies[i];
        if (m.providerId !== undefined) {
          movieMap.set(m.providerId, m);
        }
      }
      const seriesMap = new Map<string, TvSeriesEntity>();
      for (let i = 0; i < allSeriesList.length; i++) {
        const s = allSeriesList[i];
        if (s.providerId !== undefined) {
          seriesMap.set(s.providerId, s);
        }
      }
      // 电影视频 Map: key = "movie_<movieId>"
      const movieVideoMap = new Map<string, MediaItem>();
      // 剧集视频 Map: key = "series_<seriesId>_<sn>_<en>"
      const seriesVideoMap = new Map<string, MediaItem>();
      for (let i = 0; i < allVideos.length; i++) {
        const v = allVideos[i];
        if (v.movieId !== undefined) {
          const key = 'movie_' + v.movieId.toString();
          if (!movieVideoMap.has(key)) {
            movieVideoMap.set(key, v);
          }
        }
        if (v.tvSeriesId !== undefined &&
            v.seasonNumber !== undefined &&
            v.episodeNumber !== undefined) {
          const key = 'series_' + v.tvSeriesId.toString() +
            '_' + v.seasonNumber.toString() +
            '_' + v.episodeNumber.toString();
          if (!seriesVideoMap.has(key)) {
            seriesVideoMap.set(key, v);
          }
        }
      }

      const items: HistoryDisplayItem[] = [];
      // 剧集按 seriesProviderId 聚合，entries 已按 lastPlayedAt DESC 排序，第一次出现即最近播放集
      const seriesSeenSet = new Set<string>();
      for (let i = 0; i < entries.length; i++) {
        const entry = entries[i];
        const parsed = parseMediaKey(entry.mediaKey);
        if (parsed.kind === 'unknown') {
          continue;
        }

        // 剧集去重：每个 seriesProviderId 只取最近一条
        if (parsed.kind === 'series') {
          if (seriesSeenSet.has(parsed.providerId)) {
            continue;
          }
          // 不在此处 add，需等确认找到 metadata 后才标记，避免 metadata 缺失时跳过后续更完整的条目
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
          const movie = movieMap.get(parsed.providerId);
          if (movie !== undefined) {
            title = movie.title;
            posterLocalPath = movie.posterLocalPath ?? '';
            posterUrl = movie.posterUrl ?? '';
            const rd = movie.releaseDate ?? '';
            releaseYear = rd.length >= 4 ? rd.substring(0, 4) : '';
            const movieDbId = movie.id ?? 0;
            if (movieDbId > 0) {
              const matched = movieVideoMap.get('movie_' + movieDbId.toString());
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
          const series = seriesMap.get(parsed.providerId);
          if (series !== undefined) {
            title = series.title;
            posterLocalPath = series.posterLocalPath ?? '';
            posterUrl = series.posterUrl ?? '';
            const seriesDbId = series.id ?? 0;
            if (seriesDbId > 0) {
              const sn = entry.seasonNumber;
              const en = entry.episodeNumber;
              const matched = seriesVideoMap.get(
                'series_' + seriesDbId.toString() +
                '_' + sn.toString() +
                '_' + en.toString()
              );
              if (matched !== undefined) {
                videoId = matched.id;
                sourceId = matched.sourceId;
                filePath = matched.filePath;
              }
            }
            // 确认找到 series metadata 后才标记已处理，未找到则跳过让后续条目尝试
            seriesSeenSet.add(parsed.providerId);
          } else {
            continue;
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
      const err = e as BusinessError;
      console.warn(`[PlayHistory] loadHistoryData 失败 code=${err.code} msg=${err.message}`);
    } finally {
      this.isLoading = false;
    }
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
        const rawRootPath = (config['rootPath'] ?? '').replace(/\/$/, '');
        // 确保前导 / 避免拼出错误路径（Thread 7）
        const rootPath = rawRootPath.length > 0 && !rawRootPath.startsWith('/')
          ? '/' + rawRootPath
          : rawRootPath;
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
      startPositionMs: fromStart ? 0 : (item.positionMs > 0 ? item.positionMs : undefined),
    };
    this.pageStack.pushPathByName(PlayerPage.PAGE_NAME, param);
  }

  // ─── 删除 ────────────────────────────────────

  /**
   * 弹出 AlertDialog 确认后删除单条记录。
   */
  private confirmDeleteItem(item: HistoryDisplayItem): void {
    const message = item.kind === 'series'
      ? `确定删除《${item.title}》的播放记录吗？\n这将清除该剧全部集数的播放进度，此操作无法撤销。`
      : `确定删除《${item.title}》的播放记录吗？此操作无法撤销。`;
    AlertDialog.show({
      title: '删除播放记录',
      message,
      primaryButton: {
        value: '取消',
        action: () => {},
      },
      secondaryButton: {
        value: '确定删除',
        fontColor: '#FF6B6B',
        action: () => {
          this.doDeleteItem(item);
        },
      },
      autoCancel: true,
    });
  }

  private doDeleteItem(item: HistoryDisplayItem): void {
    this.doDeleteItemAsync(item).catch((): void => {});
  }

  private async doDeleteItemAsync(item: HistoryDisplayItem): Promise<void> {
    try {
      if (item.kind === 'series' && item.seriesProviderId.length > 0) {
        // 按剧删除：清除该剧所有集的进度记录
        await FileSourceDatabase.getInstance().clearAllMediaProgressBySeries(item.seriesProviderId);
      } else {
        await FileSourceDatabase.getInstance().clearMediaProgress(item.mediaKey);
      }
      // DB 成功后才更新 UI，确保原子性
      if (item.kind === 'series') {
        // 同时清理 play_progress 表（按 series_provider_id）
        if (item.seriesProviderId.length > 0) {
          await FileSourceDatabase.getInstance().clearPlayProgressBySeries(item.seriesProviderId);
        }
        // 按剧删除：过滤掉该剧的全部聚合条目
        this.historyList = this.historyList.filter(
          (i: HistoryDisplayItem): boolean => i.seriesProviderId !== item.seriesProviderId
        );
      } else {
        this.historyList = this.historyList.filter(
          (i: HistoryDisplayItem): boolean => i.mediaKey !== item.mediaKey
        );
      }
      emitter.emit(PlayerEvents.MEDIA_PROGRESS_SAVED);
      promptAction.showToast({ message: '已删除播放记录' });
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[PlayHistory] 删除失败 code=${err.code} msg=${err.message}`);
      promptAction.showToast({ message: '删除失败，请重试' });
    }
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
        value: '取消',
        action: () => {},
      },
      secondaryButton: {
        value: '全部清除',
        fontColor: '#FF6B6B',
        action: () => {
          this.doClearAll();
        },
      },
      autoCancel: true,
    });
  }

  private doClearAll(): void {
    this.doClearAllAsync().catch((): void => {});
  }

  private async doClearAllAsync(): Promise<void> {
    const db = FileSourceDatabase.getInstance();
    let failCount = 0;
    const deletedSeriesIds = new Set<string>();
    for (let i = 0; i < this.historyList.length; i++) {
      const item = this.historyList[i];
      try {
        if (item.kind === 'series' && item.seriesProviderId.length > 0) {
          if (!deletedSeriesIds.has(item.seriesProviderId)) {
            await db.clearAllMediaProgressBySeries(item.seriesProviderId);
            deletedSeriesIds.add(item.seriesProviderId);
          }
        } else {
          await db.clearMediaProgress(item.mediaKey);
        }
      } catch (e) {
        failCount++;
      }
    }
    this.historyList = [];
    emitter.emit(PlayerEvents.MEDIA_PROGRESS_SAVED);
    await FileSourceDatabase.getInstance().clearAllPlayProgress();
    if (failCount > 0) {
      promptAction.showToast({ message: `清除完成，${failCount} 条删除失败` });
    } else {
      promptAction.showToast({ message: '已清除全部播放记录' });
    }
  }

  // ─── 工具方法 ─────────────────────────────────

  /** ActionSheet 选项处理（从 showActionMenu 回调中提取，避免 ArkTS 内联类型推断问题） */
  private handleHistoryActionMenu(item: HistoryDisplayItem, index: number): void {
    if (index === 0) {
      this.playItemSync(item, true);
    } else if (index === 1) {
      this.confirmDeleteItem(item);
    }
  }

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
            .width(156)
            .height(88)
            .objectFit(ImageFit.Cover)
            .borderRadius(8)
        } else {
          Column() {
            Text('🎬')
              .fontSize(24)
          }
          .width(156)
          .height(88)
          .backgroundColor('#2A2A2A')
          .justifyContent(FlexAlign.Center)
          .borderRadius(8)
        }

        // 进度条：背景轨道 + 填充层叠
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width(156)
            .height(4)
            .backgroundColor('#333333')
            .borderRadius(2)
          Row()
            .width(
              MediaProgressStore.isNearEnd(item.positionMs, item.durationMs)
                ? '100%'
                : `${item.durationMs > 0 ? Math.min(100, item.positionMs / item.durationMs * 100) : 0}%`
            )
            .height(4)
            .backgroundColor(
              MediaProgressStore.isNearEnd(item.positionMs, item.durationMs)
                ? '#66DD88' : '#4488FF'
            )
            .borderRadius(2)
        }
        .width(156)
        .height(4)
        .margin({ top: 4 })
      }
      .width(156)
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

        // 副标题：剧集显示「第S季第E集 · X分钟」，电影显示年份
        Text(
          item.kind === 'series' && item.episodeNumber > 0
            ? `第${item.seasonNumber}季第${item.episodeNumber}集 · ${Math.floor(item.positionMs / 60000).toString()}分钟`
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
          .width(60)
          .height(40)
          .fontSize(12)
          .fontColor('#FF6B6B')
          .backgroundColor('rgba(255,107,107,0.12)')
          .border({ width: 1, color: 'rgba(255,107,107,0.30)' })
          .borderRadius(6)
          .id('delete_btn_' + index.toString())
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
          .onKeyEvent((event: KeyEvent) => {
            if (event.type === KeyType.Down && event.keyCode === 2012) { // ← 键：返回行焦点
              focusControl.requestFocus('history_row_' + index.toString());
            }
          })
      }
      .width(72)
      .alignItems(HorizontalAlign.End)
      .justifyContent(FlexAlign.Center)
      .opacity(
        this.focusedIndex === index ||
        this.deleteFocusedIndex === index ||
        this.hoveredIndex === index ? 1 : 0.18
      )
      .animation({ duration: 140, curve: Curve.Linear })
    }
    .width('100%')
    .height(120)
    .padding({ left: 24, right: 24, top: 10, bottom: 10 })
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
    .id('history_row_' + index.toString())
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
      // 菜单键（2067）：弹出操作菜单（showActionMenu 支持 color 字段）
      if (event.keyCode === 2067) {
        promptAction.showActionMenu({
          title: '操作',
          buttons: [
            { text: '从头播放', color: '#FFFFFF' },
            { text: '删除此条记录', color: '#FF6B6B' },
          ],
        }).then((data: ActionMenuSuccessResult): void => {
          this.handleHistoryActionMenu(item, data.index);
        }).catch((): void => {});
      } else if (event.keyCode === 2014) { // → 键：将焦点移至删除按钮
        focusControl.requestFocus('delete_btn_' + index.toString());
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
        if (this.historyList.length === 0 && !this.isLoading) {
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
