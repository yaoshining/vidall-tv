/**
 * 媒体实体定义 — DB v3
 *
 * 表关系：
 *   tv_series  1──* tv_seasons  1──* tv_episodes
 *   movies     独立一张表
 *   videos     本地/文件源视频文件
 *   scrape_info  videos 与 tv_series/movie/tv_episode 的关联桥表
 */

// ─────────────────────────────────────────────
// 本地视频文件
// ─────────────────────────────────────────────

/** 视频文件实体（对应 videos 表） */
export interface VideoEntity {
  id?: number;
  sourceId: number;
  directoryPath: string;
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
  audioTracksJson?: string;
  subtitleTracksJson?: string;
  /** 本轮扫描是否被更新（1=已更新,0=未更新） */
  updatedInLastScan?: number;
  scannedAt: number;
}

// ─────────────────────────────────────────────
// 刮削关联桥表
// ─────────────────────────────────────────────

/**
 * scrape_info — videos 与刮削数据的关联桥表
 * mediaType 决定关联哪张表：
 *   'movie'   → movieId 有值
 *   'tv'      → tvSeriesId 有值
 *   'episode' → tvSeriesId + episodeId 有值
 */
export interface ScrapeInfoEntity {
  id?: number;
  videoId: number;
  provider: string;
  providerId: string;
  mediaType: string;
  title: string;
  originalTitle?: string;
  movieId?: number;
  tvSeriesId?: number;
  episodeId?: number;
  seasonNumber?: number;
  episodeNumber?: number;
  scrapedAt: number;
}

// ─────────────────────────────────────────────
// 电影
// ─────────────────────────────────────────────

export interface MovieEntity {
  id?: number;
  provider: string;
  providerId: string;
  title: string;
  originalTitle?: string;
  overview?: string;
  releaseDate?: string;
  rating?: number;
  voteCount?: number;
  posterPath?: string;
  backdropPath?: string;
  posterUrl?: string;
  backdropUrl?: string;
  posterLocalPath?: string;
  backdropLocalPath?: string;
  genresJson?: string;
  castJson?: string;
  directorsJson?: string;
  runtime?: number;
  originalLanguage?: string;
  rawJson?: string;
  scrapedAt: number;
}

// ─────────────────────────────────────────────
// 电视剧
// ─────────────────────────────────────────────

export interface TvSeriesEntity {
  id?: number;
  provider: string;
  providerId: string;
  title: string;
  originalTitle?: string;
  overview?: string;
  firstAirDate?: string;
  rating?: number;
  voteCount?: number;
  posterPath?: string;
  backdropPath?: string;
  posterUrl?: string;
  backdropUrl?: string;
  posterLocalPath?: string;
  backdropLocalPath?: string;
  genresJson?: string;
  castJson?: string;
  numberOfSeasons?: number;
  originalLanguage?: string;
  rawJson?: string;
  scrapedAt: number;
}

export interface TvSeasonEntity {
  id?: number;
  seriesId: number;
  provider: string;
  /** 格式：{seriesProviderId}_s{seasonNumber}，如 "1399_s7" */
  providerId: string;
  seasonNumber: number;
  title?: string;
  overview?: string;
  airDate?: string;
  episodeCount?: number;
  posterPath?: string;
  posterUrl?: string;
  posterLocalPath?: string;
  rawJson?: string;
  scrapedAt: number;
}

export interface TvEpisodeEntity {
  id?: number;
  seriesId: number;
  seasonId?: number;
  provider: string;
  /** TMDB episode id */
  providerId: string;
  seasonNumber: number;
  episodeNumber: number;
  title?: string;
  overview?: string;
  airDate?: string;
  runtime?: number;
  rating?: number;
  stillPath?: string;
  stillUrl?: string;
  rawJson?: string;
  scrapedAt: number;
}

// ─────────────────────────────────────────────
// 播放进度（含媒体库上下文关联）
// ─────────────────────────────────────────────

/** 播放进度实体（对应 play_progress 表） */
export interface PlayProgressEntity {
  id?: number;
  /** 关联 videos.id */
  videoId: number;
  /** TMDB 剧集 ID，电影为空字符串 */
  seriesProviderId: string;
  /** 季号，电影为 0 */
  seasonNumber: number;
  /** 集号，电影为 0 */
  episodeNumber: number;
  /** 上次播放位置（毫秒） */
  positionMs: number;
  /** 视频总时长（毫秒） */
  durationMs: number;
  /** 最后更新时间戳 */
  updatedAt: number;
}

// ─────────────────────────────────────────────
// 媒体级播放进度（跨季聚合，key 由 MediaProgressStore 构造）
// ─────────────────────────────────────────────

/** 媒体级播放进度实体（对应 media_progress 表） */
export interface MediaProgressEntry {
  /** 存储 key，格式 media_progress_series_<id> 或 media_progress_movie_<id> */
  mediaKey: string;
  /** 上次播放位置（毫秒） */
  positionMs: number;
  /** 视频总时长（毫秒） */
  durationMs: number;
  /** 最近播放时间戳 */
  lastPlayedAt: number;
  /** 剧集：集号（0 表示无） */
  episodeNumber: number;
  /** 剧集：季号（0 表示无） */
  seasonNumber: number;
}

// ─────────────────────────────────────────────
// UI 聚合视图
// ─────────────────────────────────────────────

export interface MediaItem {
  // videos
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
  audioTracksJson?: string;
  scannedAt: number;
  // scrape_info
  provider?: string;
  providerId?: string;
  mediaType?: string;
  tvSeriesId?: number;
  movieId?: number;
  episodeId?: number;
  seasonNumber?: number;
  episodeNumber?: number;
  // movie / tv_series 详情
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

export interface MediaStats {
  total: number;
  movies: number;
  tv: number;
  other: number;
}

export interface MediaListItem {
  kind: 'video' | 'series';
  video?: MediaItem;
  series?: SeriesGroup;
  sortTs: number;
}

export interface SeriesGroup {
  title: string;
  /** tv_series 表主键，用于详情页加载剧集数据 */
  tvSeriesId?: number;
  seasonLabel?: string;
  posterUrl?: string;
  posterLocalPath?: string;
  backdropUrl?: string;
  /** 当前聚合所对应的季编号（有刮削时从 scrape_info.season_number 取） */
  seasonNumber?: number;
  /** tv_season 表中该季的海报 URL（优先用于最近添加卡片） */
  seasonPosterUrl?: string;
  rating?: number;
  episodeCount: number;
  episodes: MediaItem[];
  latestScannedAt: number;
}

export interface DecadeGroup {
  label: string;
  years: string[];
  count: number;
}

