import { FileSourceDatabase } from '../../db/files/FileSourceDatabase';
import { MediaItem, MediaStats, SeriesGroup, DecadeGroup, MediaListItem } from '../../db/models/MediaEntity';

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
      const movies: MediaItem[] = await db.getMediaItemsByType('movie');
      const byRating: MediaItem[] = await db.getMediaItemsByRating();
      const years: string[] = await db.getDistinctReleaseYears();
      const stats: MediaStats = await db.getMediaStats();
      const seriesGroups: SeriesGroup[] = await db.getSeriesGroups();
      const latestScanTime: number = await db.getLatestScanTime();

      this.recentlyAdded = all;
      this.movies = movies;
      this.byRating = byRating;
      this.stats = stats;
      this.seriesGroups = seriesGroups;
      this.latestScanTime = latestScanTime;
      this.unwatched = all;

      // 构建混合列表（合集 + 单独视频，按时间倒序）
      this.recentlyAddedList = buildMixedList(all, seriesGroups);
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
        `合集=${seriesGroups.length} 年代组=${this.decadeGroups.length}`
      );
      console.info(`[MediaLibraryModel] seriesGroups 明细: ${seriesGroups.map((g: SeriesGroup) => g.title + '(' + g.episodeCount + ')').join(', ')}`);
    } catch (e) {
      const err = e as Error;
      console.error(`[MediaLibraryModel] 加载失败: ${err.message}`);
    } finally {
      this.isLoading = false;
    }
  }

  async reload(): Promise<void> {
    // 强制重置状态，确保 load() 不会因 isLoading 保护而跳过
    this.isLoading = false;
    this.isLoaded = false;
    console.info('[MediaLibraryModel] reload 触发');
    await this.load();
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
