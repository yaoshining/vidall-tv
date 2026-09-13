import { FileSourceDatabase } from '../../db/files/FileSourceDatabase';
import { MediaItem, MediaStats, SeriesGroup, DecadeGroup, MediaListItem, ContinueWatchingItem, TvSeriesEntity, TvEpisodeEntity, MediaProgressEntry } from '../../db/models/MediaEntity';
import { MediaProgressStore } from '../../db/MediaProgressStore';
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

  @Trace movies: MediaItem[] = [];
  @Trace movieCount: number = 0;
  /** 电视剧合集（多集归并后的组） */
  @Trace seriesGroups: SeriesGroup[] = [];
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
  /** 电影播放进度（providerId → 0~1 进行中比例），用于文件源卡片底部进度条 */
  @Trace movieProgressMap: Map<string, number> = new Map();

  // 每次请求都执行；过期查询可以结束，但无权提交状态。
  private loadVersion: number = 0;
  private continueWatchingVersion: number = 0;

  async load(): Promise<void> {
    const version = ++this.loadVersion;
    ++this.continueWatchingVersion;
    this.isLoading = true;
    const startedAt = Date.now();
    try {
      const db = FileSourceDatabase.getInstance();

      const movies: MediaItem[] = await db.getHomeMovies();
      if (version !== this.loadVersion) { return; }
      const counts = await db.getHomeMediaCounts();
      if (version !== this.loadVersion) { return; }

      const years: string[] = await db.getDistinctReleaseYears(true);
      if (version !== this.loadVersion) { return; }

      const stats: MediaStats = await db.getMediaStats(true);
      if (version !== this.loadVersion) { return; }

      const seriesGroups: SeriesGroup[] = await db.getDistinctTvSeriesGroups(30, true);
      if (version !== this.loadVersion) { return; }

      const latestScanTime: number = await db.getLatestScanTime(true);
      if (version !== this.loadVersion) { return; }

      // 所有查询先暂存；任一查询失败均保留上次完整、有效的快照。
      const recentlyAddedList: MediaListItem[] = await db.getRecentlyAddedList(20, true);
      if (version !== this.loadVersion) { return; }
      const unwatchedItems: MediaItem[] = await db.getHomeUnwatched();
      if (version !== this.loadVersion) { return; }
      const unwatchedMixed: MediaListItem[] = [];
      for (const item of unwatchedItems) {
        const listItem: MediaListItem = {
          kind: 'video',
          video: item,
          sortTs: item.scannedAt
        };
        unwatchedMixed.push(listItem);
      }
      unwatchedMixed.sort((a: MediaListItem, b: MediaListItem): number => b.sortTs - a.sortTs);

      // 评分标签（10→5 逆序，有数量的才显示）
      const ratingBands: RatingLabel[] = [];
      const bands: number[] = [9, 8, 7, 6, 5];
      for (const floor of bands) {
        const count = counts.ratingCounts[floor - 5];
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
      // 以下同步提交之间没有 await，不会暴露混合版本的快照。
      this.movies = movies;
      this.movieCount = counts.movieCount;
      this.stats = stats;
      this.seriesGroups = seriesGroups;
      this.latestScanTime = latestScanTime;
      this.recentlyAddedList = recentlyAddedList;
      this.unwatchedList = unwatchedMixed;
      this.ratingLabels = ratingBands;

      // 年代分组
      this.decadeGroups = buildDecadeGroups(years);

      this.isLoaded = true;
      // 新元数据提交后重新读取进度，也使加载期间使用旧元数据的请求失效。
      this.loadContinueWatching().catch(() => {});
      console.info(
        `[MediaLibraryModel] 加载完成 | 全部=${stats.total} 电影=${movies.length} ` +
        `电视剧=${seriesGroups.length} 年代组=${this.decadeGroups.length} 耗时=${Date.now() - startedAt}ms`
      );

    } catch (e) {
      if (version !== this.loadVersion) { return; }
      const err = e as Error;
      console.error(`[MediaLibraryModel] 加载失败: ${err.message}`);
    } finally {
      if (version === this.loadVersion) {
        this.isLoading = false;
      }
    }
  }

  async reload(): Promise<void> {
    // 与 load 使用同一会话入口，连续刷新不会因 isLoading 丢失。
    console.info('[MediaLibraryModel] reload 触发');
    await this.load();
  }

  /**
   * 读取某部电影的播放进度比例（0~1）。
   * 无进度数据、未在看或已完播均返回 0（不显示进度条）。
   */
  getMovieProgress(providerId?: string): number {
    if (providerId === undefined || providerId.length === 0) {
      return 0;
    }
    return this.movieProgressMap.get(providerId) ?? 0;
  }

  /**
   * 加载「继续播放」栏数据。
   * 从 media_progress 表读取进度，过滤完播项，按键查询全库元数据，
   * 构建 ContinueWatchingItem 列表写入 continueWatchingList。
   */
  async loadContinueWatching(): Promise<void> {
    const version = ++this.continueWatchingVersion;
    const libraryVersion = this.loadVersion;
    try {
      const db = FileSourceDatabase.getInstance();
      const allEntries: MediaProgressEntry[] = await db.getAllMediaProgress();
      if (!this.isCurrentContinueWatching(version, libraryVersion)) { return; }

      // 构建电影播放进度映射（providerId → 进行中比例），供文件源卡片底部进度条使用。
      // 仅记录「进行中」（0 < 比例 且未到完播阈值，与 MediaProgressStore.isNearEnd 保持一致，
      // 即剩余时长 < 60 秒或已播比例 ≥ 95% 视为完播），已完播/未在看不显示进度条。
      const movieProgressMap = new Map<string, number>();
      for (const entry of allEntries) {
        if (!entry.mediaKey.startsWith('media_progress_movie_')) {
          continue;
        }
        if (entry.isWatched === 1) {
          continue;
        }
        const providerId = entry.mediaKey.slice('media_progress_movie_'.length);
        if (providerId.length === 0 || entry.durationMs <= 0) {
          continue;
        }
        const ratio = entry.positionMs / entry.durationMs;
        if (ratio > 0 && !MediaProgressStore.isNearEnd(entry.positionMs, entry.durationMs)) {
          movieProgressMap.set(providerId, ratio);
        }
      }

      // getAllMediaProgress() 已按最近播放倒序返回，直接过滤取前 20 条
      const top20: MediaProgressEntry[] = [];
      for (const entry of allEntries) {
        if (top20.length >= 20) { break; }
        if (entry.durationMs <= 0) { continue; }
        const ratio = entry.positionMs / entry.durationMs;
        // 剧集集级（episode key）允许「未开始」（positionMs == 0）进入列表，
        // 用于把近完播后推进的下一集以 0% 状态展示；电影 / 旧整剧格式仍要求已播放。
        const isEpisodeKey = entry.mediaKey.startsWith('media_progress_episode_tmdb_');
        if (entry.positionMs === 0 && !isEpisodeKey) { continue; }
        if (ratio >= 0.95) { continue; }
        top20.push(entry);
      }

      // 剧集：seriesProviderId → tv_series DB id（缓存，避免重复查询）
      const seriesIdCache = new Map<string, number>();

      const result: ContinueWatchingItem[] = [];
      // 剧集按 seriesProviderId 去重：entries 已按 lastPlayedAt DESC 排序，第一次出现即最近播放集
      const seriesSeenSet = new Set<string>();

      for (const entry of top20) {
        const key = entry.mediaKey;

        if (key.startsWith('media_progress_movie_')) {
          // ── 电影 ──
          const providerId = key.slice('media_progress_movie_'.length);
          const mi = await db.getContinueWatchingMedia(providerId);
          if (!this.isCurrentContinueWatching(version, libraryVersion)) { return; }
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
        } else if (key.startsWith('media_progress_episode_tmdb_')) {
          // ── 集级剧集（新格式）──
          // 格式：media_progress_episode_tmdb_{seriesTmdbId}_s{sn}_e{en}
          const rest = key.slice('media_progress_episode_tmdb_'.length);
          const eIdx = rest.lastIndexOf('_e');
          const sIdx = eIdx >= 0 ? rest.lastIndexOf('_s', eIdx) : -1;
          const seriesProviderId = sIdx >= 0 ? rest.substring(0, sIdx) : rest;
          if (seriesProviderId.length === 0) {
            continue;
          }
          // 每剧只展示最近一集（已按时间倒序，首次出现即最新）
          if (seriesSeenSet.has(seriesProviderId)) {
            continue;
          }
          seriesSeenSet.add(seriesProviderId);

          // 解析 tvSeriesDbId（优先读缓存）
          if (!seriesIdCache.has(seriesProviderId)) {
            const seriesEntity: TvSeriesEntity | null =
              await db.getTvSeriesByProviderId('tmdb', seriesProviderId);
            if (!this.isCurrentContinueWatching(version, libraryVersion)) { return; }
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

          const mi = await db.getContinueWatchingMedia('', tvSeriesDbId, entry.seasonNumber, entry.episodeNumber);
          if (!this.isCurrentContinueWatching(version, libraryVersion)) { return; }
          if (mi !== undefined) {
            const ratio: number = entry.positionMs / entry.durationMs;
            const epEntity: TvEpisodeEntity | null =
              await db.getTvEpisode(tvSeriesDbId, entry.seasonNumber, entry.episodeNumber);
            if (!this.isCurrentContinueWatching(version, libraryVersion)) { return; }
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
              episodeTitle: (epEntity?.title ?? '').trim(),
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
        } else if (key.startsWith('media_progress_series_tmdb_')) {
          // ── 旧剧级格式（向后兼容）──
          const seriesProviderId = key.slice('media_progress_series_tmdb_'.length);
          if (seriesProviderId.length === 0) {
            continue;
          }
          if (seriesSeenSet.has(seriesProviderId)) {
            continue;
          }
          seriesSeenSet.add(seriesProviderId);

          // 解析 tvSeriesDbId（优先读缓存）
          if (!seriesIdCache.has(seriesProviderId)) {
            const seriesEntity: TvSeriesEntity | null =
              await db.getTvSeriesByProviderId('tmdb', seriesProviderId);
            if (!this.isCurrentContinueWatching(version, libraryVersion)) { return; }
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

          const mi = await db.getContinueWatchingMedia('', tvSeriesDbId, entry.seasonNumber, entry.episodeNumber);
          if (!this.isCurrentContinueWatching(version, libraryVersion)) { return; }
          if (mi !== undefined) {
            const ratio: number = entry.positionMs / entry.durationMs;
            const epEntity: TvEpisodeEntity | null =
              await db.getTvEpisode(tvSeriesDbId, entry.seasonNumber, entry.episodeNumber);
            if (!this.isCurrentContinueWatching(version, libraryVersion)) { return; }
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
              episodeTitle: (epEntity?.title ?? '').trim(),
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

      if (!this.isCurrentContinueWatching(version, libraryVersion)) { return; }
      this.movieProgressMap = movieProgressMap;
      this.continueWatchingList = result;
      console.info(`[MediaLibraryModel] loadContinueWatching 完成，共 ${result.length} 条`);
    } catch (e) {
      if (!this.isCurrentContinueWatching(version, libraryVersion)) { return; }
      console.warn('[MediaLibraryModel] loadContinueWatching 失败', JSON.stringify(e));
    }
  }
  private isCurrentContinueWatching(version: number, libraryVersion: number): boolean {
    return version === this.continueWatchingVersion && libraryVersion === this.loadVersion;
  }
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
