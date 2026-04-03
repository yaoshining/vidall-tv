import { FileSourceDatabase } from '../../db/files/FileSourceDatabase';
import { MediaItem, MediaStats, SeriesGroup, DecadeGroup, MediaListItem, ContinueWatchingItem, TvSeriesEntity, MediaProgressEntry } from '../../db/models/MediaEntity';
import { millisecondsToTime } from '../../utils/TimeUtil';

export interface YearGroup {
  year: string;
  items: MediaItem[];
}

/** 评分标签（仅显示分数标签，不展开具体视频） */
export interface RatingLabel {
  /** 显示文字，如 '9分+' */
  label: string;
  /** 最低分（含）*/
  minRating: number;
  /** 最高分（不含）*/
  maxRating: number;
  /** 该区间视频数量 */
  count: number;
}

@ObservedV2
export class MediaLibraryModel {
  private static instance: MediaLibraryModel | null = null;

  static getState(): MediaLibraryModel {
    if (!MediaLibraryModel.instance) {
      MediaLibraryModel.instance = new MediaLibraryModel();
    }
    return MediaLibraryModel.instance;
  }

  @Trace isLoading: boolean = false;
  @Trace isLoaded: boolean = false;

  @Trace recentlyAdded: MediaItem[] = [];
  @Trace movies: MediaItem[] = [];
  /** 电视剧合集（多集归并后的组） */
  @Trace seriesGroups: SeriesGroup[] = [];
  @Trace unwatched: MediaItem[] = [];
  @Trace byRating: MediaItem[] = [];
  /** 最近添加混合列表（合集+单独视频，按时间倒序） */
  @Trace recentlyAddedList: MediaListItem[] = [];
  /** 未观看混合列表（合集+单独视频，按时间倒序） */
  @Trace unwatchedList: MediaListItem[] = [];
  /** 评分标签（5~10分，每分一格） */
  @Trace ratingLabels: RatingLabel[] = [];
  /** 年代分组（今年、2020s、2010s...） */
  @Trace decadeGroups: DecadeGroup[] = [];
  @Trace stats: MediaStats = { total: 0, movies: 0, tv: 0, other: 0 };
  /** 最近扫描时间戳（ms），0 表示未扫描 */
  @Trace latestScanTime: number = 0;
  /** 「继续播放」栏数据，按最近播放时间倒序，最多 20 条 */
  @Trace continueWatchingList: ContinueWatchingItem[] = [];

  async load(): Promise<void> {
    if (this.isLoading) {
      return;
    }
    this.isLoading = true;
    this.isLoaded = false;
    console.info('[MediaLibraryModel] 开始加载媒体库数据');
    try {
      const db = FileSourceDatabase.getInstance();

      const all: MediaItem[] = await db.getAllMediaItems();
      console.info(`[MediaLibraryModel][DIAG] getAllMediaItems=${all.length}`);

      const movies: MediaItem[] = await db.getMediaItemsByType('movie');
      console.info(`[MediaLibraryModel][DIAG] getMediaItemsByType(movie)=${movies.length}`);

      const byRating: MediaItem[] = await db.getMediaItemsByRating();
      console.info(`[MediaLibraryModel][DIAG] getMediaItemsByRating=${byRating.length}`);

      const years: string[] = await db.getDistinctReleaseYears();
      console.info(`[MediaLibraryModel][DIAG] getDistinctReleaseYears=${years.length} → ${JSON.stringify(years)}`);

      const stats: MediaStats = await db.getMediaStats();
      console.info(`[MediaLibraryModel][DIAG] stats=${JSON.stringify(stats)}`);

      const seriesGroups: SeriesGroup[] = await db.getDistinctTvSeriesGroups();
      console.info(`[MediaLibraryModel][DIAG] getDistinctTvSeriesGroups=${seriesGroups.length} 部`);

      const latestScanTime: number = await db.getLatestScanTime();

      this.recentlyAdded = all;
      this.movies = movies;
      this.byRating = byRating;
      this.stats = stats;
      this.seriesGroups = seriesGroups;
      this.latestScanTime = latestScanTime;
      this.unwatched = all;

      // 构建已已最近添加列表：直接用 DB 查询（电视剧按季分组 + 电影，按 scraped_at 倒序）
      this.recentlyAddedList = await db.getRecentlyAddedList();
      const seriesInList = this.recentlyAddedList.filter((i: MediaListItem) => i.kind === 'series').length;
      const videoInList = this.recentlyAddedList.filter((i: MediaListItem) => i.kind === 'video').length;
      console.info(`[MediaLibraryModel][DIAG] recentlyAddedList=${this.recentlyAddedList.length} (series=${seriesInList} video=${videoInList})`);
      this.unwatchedList = this.recentlyAddedList; // 播放历史未实现时，未观看 = 全部

      // 评分标签（10→5 逆序，有数量的才显示）
      const ratingBands: RatingLabel[] = [];
      const bands: number[] = [9, 8, 7, 6, 5];
      for (const floor of bands) {
        let count = 0;
        for (const item of byRating) {
          const r = item.rating;
          if (r !== undefined && r >= floor && r < floor + 1) {
            count++;
          }
        }
        if (count > 0) {
          const label: RatingLabel = {
            label: `${floor}分+`,
            minRating: floor,
            maxRating: floor + 1,
            count
          };
          ratingBands.push(label);
        }
      }
      this.ratingLabels = ratingBands;

      // 年代分组
      this.decadeGroups = buildDecadeGroups(years);

      this.isLoaded = true;
      console.info(
        `[MediaLibraryModel] 加载完成 | 全部=${all.length} 电影=${movies.length} ` +
        `电视剧=${seriesGroups.length} 年代组=${this.decadeGroups.length}`
      );

    } catch (e) {
      const err = e as Error;
      console.error(`[MediaLibraryModel] 加载失败: ${err.message}`);
    } finally {
      this.isLoading = false;
    }
    // 继续播放栏：在主库加载流程结束后 fire-and-forget，彻底不阻塞主库 isLoading 状态
    this.loadContinueWatching().catch(() => {});
  }

  async reload(): Promise<void> {
    // 强制重置状态，确保 load() 不会因 isLoading 保护而跳过
    this.isLoading = false;
    this.isLoaded = false;
    console.info('[MediaLibraryModel] reload 触发');
    await this.load();
  }

  /**
   * 加载「继续播放」栏数据。
   * 从 media_progress 表读取进度，过滤完播项，匹配 recentlyAdded 元数据，
   * 构建 ContinueWatchingItem 列表写入 continueWatchingList。
   */
  async loadContinueWatching(): Promise<void> {
    try {
      const db = FileSourceDatabase.getInstance();
      const allEntries: MediaProgressEntry[] = await db.getAllMediaProgress();

      // getAllMediaProgress() 已按最近播放倒序返回，直接过滤取前 20 条
      const top20: MediaProgressEntry[] = [];
      for (const entry of allEntries) {
        if (top20.length >= 20) { break; }
        if (entry.positionMs <= 0 || entry.durationMs <= 0) { continue; }
        if ((entry.positionMs / entry.durationMs) < 0.95) {
          top20.push(entry);
        }
      }

      // 从已加载的 recentlyAdded 构建两张查找 Map
      // movieMap: movie.providerId → MediaItem
      const movieMap = new Map<string, MediaItem>();
      // episodeMap: `${tvSeriesId}_S${season}E${ep}` → MediaItem
      const episodeMap = new Map<string, MediaItem>();

      for (const item of this.recentlyAdded) {
        const pid = item.providerId;
        if (item.mediaType === 'movie' && pid !== undefined && pid.length > 0) {
          movieMap.set(pid, item);
        } else if (
          item.mediaType === 'episode' &&
          item.tvSeriesId !== undefined &&
          item.seasonNumber !== undefined &&
          item.episodeNumber !== undefined
        ) {
          const epKey =
            `${item.tvSeriesId}_S${item.seasonNumber}E${item.episodeNumber}`;
          episodeMap.set(epKey, item);
        }
      }

      // 剧集：seriesProviderId → tv_series DB id（缓存，避免重复查询）
      const seriesIdCache = new Map<string, number>();

      const result: ContinueWatchingItem[] = [];

      for (const entry of top20) {
        const key = entry.mediaKey;

        if (key.startsWith('media_progress_movie_')) {
          // ── 电影 ──
          const providerId = key.slice('media_progress_movie_'.length);
          const mi: MediaItem | undefined = movieMap.get(providerId);
          if (mi !== undefined) {
            const ratio: number = entry.positionMs / entry.durationMs;
            const cwi: ContinueWatchingItem = {
              mediaKey: key,
              title: mi.title ?? mi.fileName,
              posterLocalPath: mi.posterLocalPath ?? '',
              posterUrl: mi.posterUrl ?? '',
              backdropLocalPath: mi.backdropLocalPath ?? '',
              backdropUrl: mi.backdropUrl ?? '',
              kind: 'movie',
              progressRatio: ratio,
              positionFormatted: millisecondsToTime(entry.positionMs),
              durationFormatted: millisecondsToTime(entry.durationMs),
              lastPlayedAt: entry.lastPlayedAt,
              seasonNumber: 0,
              episodeNumber: 0,
              episodeTitle: '',
              videoId: mi.id,
              tvSeriesId: 0,
              startPositionMs: entry.positionMs,
              sourceId: mi.sourceId,
              filePath: mi.filePath,
              durationMs: entry.durationMs,
              seriesProviderId: ''
            };
            result.push(cwi);
          }
        } else if (key.startsWith('media_progress_series_tmdb_')) {
          // ── 剧集 ──
          const seriesProviderId = key.slice('media_progress_series_tmdb_'.length);
          if (seriesProviderId.length === 0) {
            continue;
          }

          // 解析 tvSeriesDbId（优先读缓存）
          if (!seriesIdCache.has(seriesProviderId)) {
            const seriesEntity: TvSeriesEntity | null =
              await db.getTvSeriesByProviderId('tmdb', seriesProviderId);
            if (seriesEntity !== null && seriesEntity.id !== undefined) {
              seriesIdCache.set(seriesProviderId, seriesEntity.id);
            } else {
              seriesIdCache.set(seriesProviderId, -1);
            }
          }
          const tvSeriesDbId: number = seriesIdCache.get(seriesProviderId) ?? -1;
          if (tvSeriesDbId <= 0) {
            continue;
          }

          const epKey =
            `${tvSeriesDbId}_S${entry.seasonNumber}E${entry.episodeNumber}`;
          const mi: MediaItem | undefined = episodeMap.get(epKey);
          if (mi !== undefined) {
            const ratio: number = entry.positionMs / entry.durationMs;
            const cwi: ContinueWatchingItem = {
              mediaKey: key,
              title: mi.title ?? mi.fileName,
              posterLocalPath: mi.posterLocalPath ?? '',
              posterUrl: mi.posterUrl ?? '',
              backdropLocalPath: mi.backdropLocalPath ?? '',
              backdropUrl: mi.backdropUrl ?? '',
              kind: 'series',
              progressRatio: ratio,
              positionFormatted: millisecondsToTime(entry.positionMs),
              durationFormatted: millisecondsToTime(entry.durationMs),
              lastPlayedAt: entry.lastPlayedAt,
              seasonNumber: entry.seasonNumber,
              episodeNumber: entry.episodeNumber,
              episodeTitle: '',
              videoId: mi.id,
              tvSeriesId: tvSeriesDbId,
              startPositionMs: entry.positionMs,
              sourceId: mi.sourceId,
              filePath: mi.filePath,
              durationMs: entry.durationMs,
              seriesProviderId: seriesProviderId
            };
            result.push(cwi);
          }
        }
        // 其他 key 格式（'video' 类）暂不支持，跳过
      }

      this.continueWatchingList = result;
      console.info(`[MediaLibraryModel] loadContinueWatching 完成，共 ${result.length} 条`);
    } catch (e) {
      console.warn('[MediaLibraryModel] loadContinueWatching 失败', JSON.stringify(e));
      this.continueWatchingList = [];
    }
  }
}

// ─────────────────────────────────────────────
// 混合列表构建工具函数
// ─────────────────────────────────────────────

/**
 * 把平铺的视频列表与合集归并，生成混合列表
 * - 属于某个合集的视频：用合集代替（同一合集只出现一次，取最新 scannedAt）
 * - 不属于任何合集的视频：直接作为单独视频
 * 最终按 sortTs 倒序排列
 */
function buildMixedList(allVideos: MediaItem[], seriesGroups: SeriesGroup[]): MediaListItem[] {
  // 收集所有属于合集的 filePath 集合
  const seriesFilePathSet = new Set<string>();
  for (const sg of seriesGroups) {
    for (const ep of sg.episodes) {
      seriesFilePathSet.add(ep.filePath);
    }
  }

  const result: MediaListItem[] = [];

  // 添加合集（每个合集只添加一次）
  for (const sg of seriesGroups) {
    const item: MediaListItem = {
      kind: 'series',
      series: sg,
      sortTs: sg.latestScannedAt
    };
    result.push(item);
  }

  // 添加不属于任何合集的单独视频
  for (const video of allVideos) {
    if (!seriesFilePathSet.has(video.filePath)) {
      const item: MediaListItem = {
        kind: 'video',
        video: video,
        sortTs: video.scannedAt
      };
      result.push(item);
    }
  }

  // 按 sortTs 倒序
  result.sort((a: MediaListItem, b: MediaListItem) => b.sortTs - a.sortTs);
  return result;
}

// ─────────────────────────────────────────────
// 年代分组工具函数
// ─────────────────────────────────────────────

/**
 * 将年份列表归并为年代分组
 * 今年单独一组；其余按十年为一档（2020s、2010s ... 1950s），无视频的档不生成
 */
function buildDecadeGroups(years: string[]): DecadeGroup[] {
  if (years.length === 0) {
    return [];
  }

  const currentYear = new Date().getFullYear();
  const currentYearStr = String(currentYear);

  const todayGroup: DecadeGroup = { label: '今年', years: [], count: 0 };
  const decadeMap = new Map<number, DecadeGroup>();

  for (const y of years) {
    if (y === currentYearStr) {
      todayGroup.years.push(y);
      todayGroup.count++;
      continue;
    }
    const yi = parseInt(y);
    if (isNaN(yi)) {
      continue;
    }
    const decadeStart = Math.floor(yi / 10) * 10;
    // 只显示到 1950s
    if (decadeStart < 1950) {
      continue;
    }
    let group = decadeMap.get(decadeStart);
    if (!group) {
      const newGroup: DecadeGroup = {
        label: `${decadeStart}s`,
        years: [],
        count: 0
      };
      decadeMap.set(decadeStart, newGroup);
      group = newGroup;
    }
    group.years.push(y);
    group.count++;
  }

  const result: DecadeGroup[] = [];
  if (todayGroup.count > 0) {
    result.push(todayGroup);
  }

  // 按年代倒序排列
  const decadeKeys: number[] = [];
  decadeMap.forEach((_v, k) => {
    decadeKeys.push(k);
  });
  decadeKeys.sort((a, b) => b - a);
  for (const k of decadeKeys) {
    const g = decadeMap.get(k);
    if (g) {
      result.push(g);
    }
  }
  return result;
}
