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

/** 排序方式 */
export enum SortType {
  RECENT = 'recent',      // 最近更新
  NAME = 'name',          // 名称
  YEAR = 'year',          // 年份
  RATING = 'rating'       // 评分
}

/** 筛选条件 */
export interface FilterCriteria {
  /** 搜索关键词 */
  searchKeyword: string;
  /** 类型筛选：'all' | 'movie' | 'tv' */
  mediaType: string;
  /** 年份筛选：空字符串表示不限 */
  year: string;
  /** 播放状态：'all' | 'unwatched' | 'watching' */
  watchStatus: string;
  /** 类别筛选：空字符串表示不限 */
  genre: string;
  /** 排序方式 */
  sortType: SortType;
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

  /** 筛选条件 */
  @Trace filterCriteria: FilterCriteria = {
    searchKeyword: '',
    mediaType: 'all',
    year: '',
    watchStatus: 'all',
    genre: '',
    sortType: SortType.RECENT
  };

  /** 筛选后的结果列表 */
  @Trace filteredList: MediaListItem[] = [];

  /** 所有可选的类别列表 */
  @Trace allGenres: string[] = [];

  /** 所有可选的年份列表 */
  @Trace allYears: string[] = [];

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

      // 提取所有类别
      this.allGenres = this.extractAllGenres(all, seriesGroups);

      // 存储所有年份
      this.allYears = years;

      // 初始化筛选结果（默认显示全部）
      this.applyFilters();

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

  /**
   * 提取所有类别
   */
  private extractAllGenres(allVideos: MediaItem[], seriesGroups: SeriesGroup[]): string[] {
    const genreSet = new Set<string>();
    const all: MediaItem[] = [...allVideos];
    for (const sg of seriesGroups) {
      for (const ep of sg.episodes) {
        all.push(ep);
      }
    }
    for (const item of all) {
      if (item.genresJson) {
        try {
          const genres = JSON.parse(item.genresJson) as string[];
          genres.forEach(g => genreSet.add(g));
        } catch (e) {
          // 忽略解析错误
        }
      }
    }
    return Array.from(genreSet).sort();
  }

  /**
   * 应用筛选条件
   */
  applyFilters(): void {
    let result = [...this.recentlyAddedList];

    // 搜索关键词筛选（片名模糊匹配）
    if (this.filterCriteria.searchKeyword.trim().length > 0) {
      const keyword = this.filterCriteria.searchKeyword.toLowerCase();
      result = result.filter((item: MediaListItem) => {
        if (item.kind === 'series') {
          return item.series!.title.toLowerCase().includes(keyword);
        } else {
          const title = item.video!.title || item.video!.fileName;
          return title.toLowerCase().includes(keyword);
        }
      });
    }

    // 类型筛选
    if (this.filterCriteria.mediaType !== 'all') {
      if (this.filterCriteria.mediaType === 'movie') {
        result = result.filter((item: MediaListItem) =>
          item.kind === 'video' && item.video!.mediaType === 'movie'
        );
      } else if (this.filterCriteria.mediaType === 'tv') {
        result = result.filter((item: MediaListItem) =>
          item.kind === 'series' || (item.kind === 'video' && item.video!.mediaType === 'tv')
        );
      }
    }

    // 年份筛选
    if (this.filterCriteria.year.length > 0) {
      result = result.filter((item: MediaListItem) => {
        if (item.kind === 'series') {
          const firstEp = item.series!.episodes[0];
          return firstEp?.releaseDate?.startsWith(this.filterCriteria.year);
        } else {
          return item.video!.releaseDate?.startsWith(this.filterCriteria.year);
        }
      });
    }

    // 类别筛选
    if (this.filterCriteria.genre.length > 0) {
      result = result.filter((item: MediaListItem) => {
        const checkGenres = (genresJson?: string): boolean => {
          if (!genresJson) { return false; }
          try {
            const genres = JSON.parse(genresJson) as string[];
            return genres.includes(this.filterCriteria.genre);
          } catch (e) {
            return false;
          }
        };
        if (item.kind === 'series') {
          const firstEp = item.series!.episodes[0];
          return checkGenres(firstEp?.genresJson);
        } else {
          return checkGenres(item.video!.genresJson);
        }
      });
    }

    // 播放状态筛选（暂时只支持 unwatched，因为播放历史未实现）
    if (this.filterCriteria.watchStatus === 'unwatched') {
      // 当前 unwatchedList = recentlyAddedList，所以不做特殊处理
    }

    // 排序
    this.sortList(result);

    this.filteredList = result;
    console.info(`[MediaLibraryModel] 筛选完成，结果数量: ${result.length}`);
  }

  /**
   * 对列表进行排序
   */
  private sortList(list: MediaListItem[]): void {
    switch (this.filterCriteria.sortType) {
      case SortType.RECENT:
        list.sort((a, b) => b.sortTs - a.sortTs);
        break;
      case SortType.NAME:
        list.sort((a, b) => {
          const nameA = a.kind === 'series' ? a.series!.title : (a.video!.title || a.video!.fileName);
          const nameB = b.kind === 'series' ? b.series!.title : (b.video!.title || b.video!.fileName);
          return nameA.localeCompare(nameB, 'zh-CN');
        });
        break;
      case SortType.YEAR:
        list.sort((a, b) => {
          const getYear = (item: MediaListItem): string => {
            if (item.kind === 'series') {
              return item.series!.episodes[0]?.releaseDate || '';
            } else {
              return item.video!.releaseDate || '';
            }
          };
          return getYear(b).localeCompare(getYear(a));
        });
        break;
      case SortType.RATING:
        list.sort((a, b) => {
          const getRating = (item: MediaListItem): number => {
            if (item.kind === 'series') {
              return item.series!.rating || 0;
            } else {
              return item.video!.rating || 0;
            }
          };
          return getRating(b) - getRating(a);
        });
        break;
    }
  }

  /**
   * 更新筛选条件
   */
  updateFilter(criteria: Partial<FilterCriteria>): void {
    // ArkTS 不支持对象展开运算符，手动复制属性
    if (criteria.searchKeyword !== undefined) {
      this.filterCriteria.searchKeyword = criteria.searchKeyword;
    }
    if (criteria.mediaType !== undefined) {
      this.filterCriteria.mediaType = criteria.mediaType;
    }
    if (criteria.year !== undefined) {
      this.filterCriteria.year = criteria.year;
    }
    if (criteria.watchStatus !== undefined) {
      this.filterCriteria.watchStatus = criteria.watchStatus;
    }
    if (criteria.genre !== undefined) {
      this.filterCriteria.genre = criteria.genre;
    }
    if (criteria.sortType !== undefined) {
      this.filterCriteria.sortType = criteria.sortType;
    }
    this.applyFilters();
  }

  /**
   * 重置筛选条件
   */
  resetFilters(): void {
    this.filterCriteria = {
      searchKeyword: '',
      mediaType: 'all',
      year: '',
      watchStatus: 'all',
      genre: '',
      sortType: SortType.RECENT
    };
    this.applyFilters();
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
