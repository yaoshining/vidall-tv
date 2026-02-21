/**
 * 媒体相关实体定义（对应 DB v2 新增三张表）
 */

/** 视频文件实体（对应 videos 表） */
export interface VideoEntity {
  id?: number;
  /** 所属文件源 ID，关联 file_sources.id */
  sourceId: number;
  /** 扫描起始目录（对应 file_source_directories.directory_path）*/
  directoryPath: string;
  /** 完整文件路径，作为 upsert 唯一键 */
  filePath: string;
  fileName: string;
  fileSize?: number;
  lastModified?: string;
  contentType?: string;
  durationMs?: number;
  width?: number;
  height?: number;
  frameRate?: number;
  videoCodec?: string;
  /** JSON 序列化的 TrackInfo[] */
  audioTracksJson?: string;
  /** JSON 序列化的 TrackInfo[] */
  subtitleTracksJson?: string;
  /** 扫描时间戳（ms） */
  scannedAt: number;
}

/** 刮削信息实体（对应 scrape_info 表，与 videos 一对一） */
export interface ScrapeInfoEntity {
  id?: number;
  /** 关联 videos.id */
  videoId: number;
  /** 数据来源，如 'tmdb'、'douban' */
  provider: string;
  /** 资源在该数据源的唯一 ID */
  providerId: string;
  /** 'movie' | 'tv' | 'episode' */
  mediaType: string;
  title: string;
  originalTitle?: string;
  overview?: string;
  /** 上映日期，YYYY-MM-DD */
  releaseDate?: string;
  /** 评分 0-10 */
  rating?: number;
  /** JSON 序列化的 string[] */
  genresJson?: string;
  /** JSON 序列化的 ScrapeCredit[]（最多 20 位演员） */
  castJson?: string;
  /** JSON 序列化的 ScrapeCredit[] */
  directorsJson?: string;
  /** 海报远程 URL（懒加载时使用） */
  posterUrl?: string;
  /** 背景图远程 URL */
  backdropUrl?: string;
  /** 海报本地缓存路径（懒加载下载后写入） */
  posterLocalPath?: string;
  /** 背景图本地缓存路径（懒加载下载后写入） */
  backdropLocalPath?: string;
  /** 刮削时间戳（ms） */
  scrapedAt: number;
  /** 原始 API 响应（调试用） */
  rawJson?: string;
}

/**
 * 播放历史实体（对应 play_history 表）
 * v2 仅建表，CRUD 待后续播放进度功能实现时补充
 */
export interface PlayHistoryEntity {
  id?: number;
  /** 关联 videos.id */
  videoId: number;
  /** 上次播放位置（毫秒） */
  positionMs: number;
  /** 视频总时长快照（毫秒） */
  durationMs: number;
  /** 最后更新时间戳（ms） */
  updatedAt: number;
}

/**
 * 视频 + 刮削信息的聚合视图（UI 展示用）
 * 对应 videos LEFT JOIN scrape_info
 */
export interface MediaItem {
  // ── videos 字段 ──
  id: number;
  sourceId: number;
  directoryPath: string;
  filePath: string;
  fileName: string;
  fileSize?: number;
  durationMs?: number;
  width?: number;
  height?: number;
  videoCodec?: string;
  scannedAt: number;
  // ── scrape_info 字段（未刮削时为 undefined）──
  provider?: string;
  providerId?: string;
  mediaType?: string;
  title?: string;
  originalTitle?: string;
  overview?: string;
  releaseDate?: string;
  rating?: number;
  genresJson?: string;
  posterUrl?: string;
  backdropUrl?: string;
  posterLocalPath?: string;
  backdropLocalPath?: string;
}

/** 媒体统计信息 */
export interface MediaStats {
  total: number;
  movies: number;
  tv: number;
  other: number;
}

/**
 * 混合列表项：可以是单个视频，也可以是合集
 * kind='video'  → 单独视频（电影或无法归组的文件）
 * kind='series' → 多集合集
 */
export interface MediaListItem {
  kind: 'video' | 'series';
  /** kind='video' 时有值 */
  video?: MediaItem;
  /** kind='series' 时有值 */
  series?: SeriesGroup;
  /** 用于排序的时间戳（ms） */
  sortTs: number;
}

/**
 * 合集（电视剧/综艺多集归并）
 * 以 scrape_info 中相同 provider_id 的记录聚合，或以目录名推断
 */
export interface SeriesGroup {
  /** 合集标题（来自 scrape_info.title 或目录名） */
  title: string;
  /** 合集海报 URL */
  posterUrl?: string;
  posterLocalPath?: string;
  /** 评分 */
  rating?: number;
  /** 集数 */
  episodeCount: number;
  /** 所有剧集 */
  episodes: MediaItem[];
  /** 最新一集的 scanned_at */
  latestScannedAt: number;
}

/**
 * 年代分组（用于"上映年代"横向滚动）
 * label: 如 '今年' / '2020s' / '2010s'
 * years: 该年代内实际有视频的年份列表
 * count: 该年代视频总数
 */
export interface DecadeGroup {
  label: string;
  years: string[];
  count: number;
}

