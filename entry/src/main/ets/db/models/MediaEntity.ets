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

