import { Context } from '@ohos.abilityAccessCtrl';
import { emitter } from "@kit.BasicServicesKit";
import { FileSource, FileSourceDirectory, DirStatus } from '../models/FileSourceEntity';
import { VideoServer } from '../models/VideoServerEntity';
import {
  VideoEntity, ScrapeInfoEntity, MovieEntity, TvSeriesEntity, TvSeasonEntity, TvEpisodeEntity,
  MediaItem, MediaStats, SeriesGroup, MediaListItem, PlayProgressEntity, MediaProgressEntry,
  SearchHistoryEntry, SearchMediaOptions
} from '../models/MediaEntity';
import { DATABASE_READY } from './DbConstants';
import { FileSourceDbCore } from './FileSourceDbCore';
import { FileSourceDao } from './FileSourceDao';
import { VideoServerDao } from './VideoServerDao';
import { VideoDao } from './VideoDao';
import { MediaContentDao } from './MediaContentDao';
import { ScrapeInfoDao } from './ScrapeInfoDao';
import { PlayProgressDao } from './PlayProgressDao';
import { MediaQueryDao } from './MediaQueryDao';
import { SearchHistoryDao } from './SearchHistoryDao';

/**
 * 文件源数据库门面（单例）。
 *
 * 数据库连接与 schema 迁移已拆至 FileSourceDbCore，各表 CRUD 拆至对应 DAO；
 * 本类保留原 FileSourceDatabase 的对外单例 API，所有方法委托给内部 DAO，
 * 对外方法签名与行为保持不变。
 */
export class FileSourceDatabase {
  // 单例实例
  private static instance: FileSourceDatabase | null = null;

  // 数据库连接核心 + 各表数据访问
  private core: FileSourceDbCore;
  private fileSourceDao: FileSourceDao;
  private videoServerDao: VideoServerDao;
  private videoDao: VideoDao;
  private mediaContentDao: MediaContentDao;
  private scrapeInfoDao: ScrapeInfoDao;
  private playProgressDao: PlayProgressDao;
  private mediaQueryDao: MediaQueryDao;
  private searchHistoryDao: SearchHistoryDao;

  private constructor() {
    this.core = new FileSourceDbCore();
    this.fileSourceDao = new FileSourceDao(this.core);
    this.videoServerDao = new VideoServerDao(this.core);
    this.videoDao = new VideoDao(this.core);
    this.mediaContentDao = new MediaContentDao(this.core);
    this.scrapeInfoDao = new ScrapeInfoDao(this.core);
    this.playProgressDao = new PlayProgressDao(this.core);
    this.mediaQueryDao = new MediaQueryDao(this.core);
    this.searchHistoryDao = new SearchHistoryDao(this.core);
  }

  /**
   * 获取数据库单例实例
   */
  static getInstance(context?: Context): FileSourceDatabase {
    if (FileSourceDatabase.instance === null) {
      FileSourceDatabase.instance = new FileSourceDatabase();
    }
    if (context) {
      FileSourceDatabase.instance.core.setContext(context);
    }
    return FileSourceDatabase.instance;
  }

  static setDatabaseNameForTesting(databaseName: string | null): void {
    FileSourceDbCore.setDatabaseNameOverride(databaseName);
    FileSourceDatabase.instance = null;
  }

  /** 初始化数据库（委托 core） */
  async init(): Promise<void> {
    await this.core.init();
  }

  static onReady(callback: Callback<emitter.EventData>) {
    if (FileSourceDatabase.instance && FileSourceDatabase.instance.core.isReady()) {
      callback({})
    } else {
      emitter.once(DATABASE_READY, callback)
    }
  }

  // ─────────────────────────────────────────────
  // file_sources / file_source_directories
  // ─────────────────────────────────────────────

  async insertFileSource(fileSource: FileSource): Promise<number> {
    return this.fileSourceDao.insertFileSource(fileSource);
  }

  async updateFileSource(fileSource: FileSource): Promise<void> {
    await this.fileSourceDao.updateFileSource(fileSource);
  }

  async deleteFileSource(id: number): Promise<void> {
    await this.fileSourceDao.deleteFileSource(id);
  }

  async getFileSourceById(id: number): Promise<FileSource | null> {
    return this.fileSourceDao.getFileSourceById(id);
  }

  async getAllFileSources(): Promise<FileSource[]> {
    return this.fileSourceDao.getAllFileSources();
  }

  async insertDirectories(sourceId: number, directories: FileSourceDirectory[]): Promise<void> {
    await this.fileSourceDao.insertDirectories(sourceId, directories);
  }

  async deleteDirectoriesBySourceId(sourceId: number): Promise<void> {
    await this.fileSourceDao.deleteDirectoriesBySourceId(sourceId);
  }

  async saveDirectoriesForSource(sourceId: number, directories: FileSourceDirectory[]): Promise<void> {
    await this.fileSourceDao.saveDirectoriesForSource(sourceId, directories);
  }

  async getDirectoriesBySourceId(sourceId: number): Promise<FileSourceDirectory[]> {
    return this.fileSourceDao.getDirectoriesBySourceId(sourceId);
  }

  async updateDirStatus(dirId: number, status: DirStatus): Promise<void> {
    await this.fileSourceDao.updateDirStatus(dirId, status);
  }

  async clearMediaAndDirectoryForDir(dirId: number, sourceId: number, directoryPath: string): Promise<void> {
    await this.fileSourceDao.clearMediaAndDirectoryForDir(dirId, sourceId, directoryPath);
  }

  // ─────────────────────────────────────────────
  // video_servers
  // ─────────────────────────────────────────────

  async insertVideoServer(server: VideoServer): Promise<number> {
    return this.videoServerDao.insertVideoServer(server);
  }

  async updateVideoServer(server: VideoServer): Promise<void> {
    await this.videoServerDao.updateVideoServer(server);
  }

  async deleteVideoServer(id: number): Promise<void> {
    await this.videoServerDao.deleteVideoServer(id);
  }

  async getVideoServerById(id: number): Promise<VideoServer | null> {
    return this.videoServerDao.getVideoServerById(id);
  }

  async getAllVideoServers(): Promise<VideoServer[]> {
    return this.videoServerDao.getAllVideoServers();
  }

  // ─────────────────────────────────────────────
  // videos
  // ─────────────────────────────────────────────

  async upsertVideo(entity: VideoEntity): Promise<number> {
    return this.videoDao.upsertVideo(entity);
  }

  async getVideoByPath(filePath: string): Promise<VideoEntity | null> {
    return this.videoDao.getVideoByPath(filePath);
  }

  async getVideoById(videoId: number): Promise<VideoEntity | null> {
    return this.videoDao.getVideoById(videoId);
  }

  async getVideosBySourceId(sourceId: number): Promise<VideoEntity[]> {
    return this.videoDao.getVideosBySourceId(sourceId);
  }

  async getVideosByMovieId(movieId: number): Promise<VideoEntity[]> {
    return this.videoDao.getVideosByMovieId(movieId);
  }

  async getVideosByTvSeriesId(tvSeriesId: number): Promise<VideoEntity[]> {
    return this.videoDao.getVideosByTvSeriesId(tvSeriesId);
  }

  async getVideosBySeason(tvSeriesId: number, seasonNumber: number): Promise<VideoEntity[]> {
    return this.videoDao.getVideosBySeason(tvSeriesId, seasonNumber);
  }

  async getVideosByDirectoryTree(sourceId: number, directoryPath: string): Promise<VideoEntity[]> {
    return this.videoDao.getVideosByDirectoryTree(sourceId, directoryPath);
  }

  async getAllVideos(): Promise<VideoEntity[]> {
    return this.videoDao.getAllVideos();
  }

  async resetVideoUpdatedFlags(): Promise<void> {
    await this.videoDao.resetVideoUpdatedFlags();
  }

  async markVideoUpdatedByPath(filePath: string): Promise<void> {
    await this.videoDao.markVideoUpdatedByPath(filePath);
  }

  async deleteGhostVideosForSources(sourceIds: number[], foundPaths: string[]): Promise<number> {
    return this.videoDao.deleteGhostVideosForSources(sourceIds, foundPaths);
  }

  async deleteVideoWithScrapeInfo(videoId: number): Promise<void> {
    await this.videoDao.deleteVideoWithScrapeInfo(videoId);
  }

  async deleteVideosWithScrapeInfo(videoIds: number[]): Promise<void> {
    await this.videoDao.deleteVideosWithScrapeInfo(videoIds);
    await this.scrapeInfoDao.cleanupOrphanScrapeMedia();
  }

  async getLatestScanTime(): Promise<number> {
    return this.videoDao.getLatestScanTime();
  }

  // ─────────────────────────────────────────────
  // movies / tv_series / tv_seasons / tv_episodes
  // ─────────────────────────────────────────────

  async getMovieByProviderId(provider: string, providerId: string): Promise<MovieEntity | null> {
    return this.mediaContentDao.getMovieByProviderId(provider, providerId);
  }

  async getMovieById(id: number): Promise<MovieEntity | null> {
    return this.mediaContentDao.getMovieById(id);
  }

  async getAllMovies(): Promise<MovieEntity[]> {
    return this.mediaContentDao.getAllMovies();
  }

  async upsertMovie(e: MovieEntity): Promise<number> {
    return this.mediaContentDao.upsertMovie(e);
  }

  async getTvSeriesByProviderId(provider: string, providerId: string): Promise<TvSeriesEntity | null> {
    return this.mediaContentDao.getTvSeriesByProviderId(provider, providerId);
  }

  async getAllTvSeries(): Promise<TvSeriesEntity[]> {
    return this.mediaContentDao.getAllTvSeries();
  }

  async upsertTvSeries(e: TvSeriesEntity): Promise<number> {
    return this.mediaContentDao.upsertTvSeries(e);
  }

  async getTvSeriesById(id: number): Promise<TvSeriesEntity | null> {
    return this.mediaContentDao.getTvSeriesById(id);
  }

  async getTvSeason(seriesId: number, seasonNumber: number): Promise<TvSeasonEntity | null> {
    return this.mediaContentDao.getTvSeason(seriesId, seasonNumber);
  }

  async upsertTvSeason(e: TvSeasonEntity): Promise<number> {
    return this.mediaContentDao.upsertTvSeason(e);
  }

  async getTvEpisode(seriesId: number, seasonNumber: number, episodeNumber: number): Promise<TvEpisodeEntity | null> {
    return this.mediaContentDao.getTvEpisode(seriesId, seasonNumber, episodeNumber);
  }

  async getEpisodesBySeriesAndSeason(seriesId: number, seasonNumber: number): Promise<TvEpisodeEntity[]> {
    return this.mediaContentDao.getEpisodesBySeriesAndSeason(seriesId, seasonNumber);
  }

  async getFirstTvEpisode(seriesId: number): Promise<TvEpisodeEntity | null> {
    return this.mediaContentDao.getFirstTvEpisode(seriesId);
  }

  async upsertTvEpisode(e: TvEpisodeEntity): Promise<number> {
    return this.mediaContentDao.upsertTvEpisode(e);
  }

  async hasMovieOriginCountry(movieId: number): Promise<boolean> {
    return this.mediaContentDao.hasMovieOriginCountry(movieId);
  }

  async hasTvSeriesOriginCountry(seriesId: number): Promise<boolean> {
    return this.mediaContentDao.hasTvSeriesOriginCountry(seriesId);
  }

  // ─────────────────────────────────────────────
  // scrape_info
  // ─────────────────────────────────────────────

  async getScrapeInfoByVideoId(videoId: number): Promise<ScrapeInfoEntity | null> {
    return this.scrapeInfoDao.getScrapeInfoByVideoId(videoId);
  }

  async cleanupOrphanedScrapeInfo(): Promise<void> {
    await this.scrapeInfoDao.cleanupOrphanedScrapeInfo();
  }

  async clearScrapeInfoForSources(sourceIds: number[]): Promise<void> {
    await this.scrapeInfoDao.clearScrapeInfoForSources(sourceIds);
  }

  async getScrapedSeasonNumbers(tvSeriesId: number): Promise<number[]> {
    return this.scrapeInfoDao.getScrapedSeasonNumbers(tvSeriesId);
  }

  async upsertScrapeInfo(e: ScrapeInfoEntity): Promise<void> {
    await this.scrapeInfoDao.upsertScrapeInfo(e);
  }

  async clearScrapeInfoForVideo(videoId: number): Promise<void> {
    await this.scrapeInfoDao.clearScrapeInfoForVideo(videoId);
  }

  async clearScrapeInfoByTvSeriesId(tvSeriesId: number): Promise<void> {
    await this.scrapeInfoDao.clearScrapeInfoByTvSeriesId(tvSeriesId);
  }

  /** 删除指定电视剧的所有数据（刮削信息、进度、历史记录），用于重新刮削 */
  async deleteSeriesAllData(tvSeriesId: number, seriesProviderId: string): Promise<void> {
    await this.scrapeInfoDao.clearScrapeInfoByTvSeriesId(tvSeriesId);
    await this.playProgressDao.clearPlayProgressBySeries(seriesProviderId);
    await this.playProgressDao.clearAllMediaProgressBySeries(seriesProviderId);
  }

  // ─────────────────────────────────────────────
  // play_progress / media_progress
  // ─────────────────────────────────────────────

  async upsertPlayProgress(progress: PlayProgressEntity): Promise<void> {
    await this.playProgressDao.upsertPlayProgress(progress);
  }

  async getPlayProgress(videoId: number): Promise<PlayProgressEntity | null> {
    return this.playProgressDao.getPlayProgress(videoId);
  }

  async getPlayProgressBySeriesContext(
    seriesProviderId: string,
    seasonNumber: number
  ): Promise<PlayProgressEntity[]> {
    return this.playProgressDao.getPlayProgressBySeriesContext(seriesProviderId, seasonNumber);
  }

  async getPlayProgressBySeries(seriesProviderId: string): Promise<PlayProgressEntity[]> {
    return this.playProgressDao.getPlayProgressBySeries(seriesProviderId);
  }

  async upsertMediaProgress(entry: MediaProgressEntry): Promise<void> {
    await this.playProgressDao.upsertMediaProgress(entry);
  }

  async getMediaProgress(mediaKey: string): Promise<MediaProgressEntry | null> {
    return this.playProgressDao.getMediaProgress(mediaKey);
  }

  async clearMediaProgress(mediaKey: string): Promise<void> {
    await this.playProgressDao.clearMediaProgress(mediaKey);
  }

  async clearAllMediaProgressBySeries(seriesTmdbId: string): Promise<void> {
    await this.playProgressDao.clearAllMediaProgressBySeries(seriesTmdbId);
  }

  async markAsWatched(mediaKey: string): Promise<void> {
    await this.playProgressDao.markAsWatched(mediaKey);
  }

  async markAllSeriesWatched(seriesTmdbId: string): Promise<void> {
    await this.playProgressDao.markAllSeriesWatched(seriesTmdbId);
  }

  async getLatestMediaProgressBySeries(seriesTmdbId: string): Promise<MediaProgressEntry | null> {
    return this.playProgressDao.getLatestMediaProgressBySeries(seriesTmdbId);
  }

  async getAllMediaProgress(limit: number = 40): Promise<MediaProgressEntry[]> {
    return this.playProgressDao.getAllMediaProgress(limit);
  }

  async clearPlayProgressBySeries(seriesProviderId: string): Promise<void> {
    await this.playProgressDao.clearPlayProgressBySeries(seriesProviderId);
  }

  async clearAllPlayProgress(): Promise<void> {
    await this.playProgressDao.clearAllPlayProgress();
  }

  // ─────────────────────────────────────────────
  // 媒体库聚合查询 / 搜索 / 流派
  // ─────────────────────────────────────────────

  async getMediaItemByVideoId(videoId: number): Promise<MediaItem | null> {
    return this.mediaQueryDao.getMediaItemByVideoId(videoId);
  }

  async getAllMediaItems(): Promise<MediaItem[]> {
    return this.mediaQueryDao.getAllMediaItems();
  }

  async getMediaItemsByType(mediaType: string): Promise<MediaItem[]> {
    return this.mediaQueryDao.getMediaItemsByType(mediaType);
  }

  async getMediaItemsByRating(): Promise<MediaItem[]> {
    return this.mediaQueryDao.getMediaItemsByRating();
  }

  async getDistinctReleaseYears(): Promise<string[]> {
    return this.mediaQueryDao.getDistinctReleaseYears();
  }

  async getMediaItemsByYear(year: string): Promise<MediaItem[]> {
    return this.mediaQueryDao.getMediaItemsByYear(year);
  }

  async getMediaStats(): Promise<MediaStats> {
    return this.mediaQueryDao.getMediaStats();
  }

  async getMediaItemsByTvSeriesId(seriesId: number): Promise<MediaItem[]> {
    return this.mediaQueryDao.getMediaItemsByTvSeriesId(seriesId);
  }

  async getSeriesGroups(): Promise<SeriesGroup[]> {
    return this.mediaQueryDao.getSeriesGroups();
  }

  async getDistinctTvSeriesGroups(limit: number = 30): Promise<SeriesGroup[]> {
    return this.mediaQueryDao.getDistinctTvSeriesGroups(limit);
  }

  async getRecentlyAddedList(limit: number = 20): Promise<MediaListItem[]> {
    return this.mediaQueryDao.getRecentlyAddedList(limit);
  }

  async searchMediaItems(keyword: string, options?: SearchMediaOptions): Promise<MediaItem[]> {
    return this.mediaQueryDao.searchMediaItems(keyword, options);
  }

  async getDistinctGenres(): Promise<string[]> {
    return this.mediaQueryDao.getDistinctGenres();
  }

  async getDistinctGenreNames(mediaType?: 'movie' | 'tv'): Promise<string[]> {
    return this.mediaQueryDao.getDistinctGenreNames(mediaType);
  }

  // ─────────────────────────────────────────────
  // search_history
  // ─────────────────────────────────────────────

  async upsertSearchHistory(keyword: string): Promise<void> {
    await this.searchHistoryDao.upsertSearchHistory(keyword);
  }

  async getSearchHistory(limit: number = 20): Promise<SearchHistoryEntry[]> {
    return this.searchHistoryDao.getSearchHistory(limit);
  }

  async deleteSearchHistory(keyword: string): Promise<void> {
    await this.searchHistoryDao.deleteSearchHistory(keyword);
  }

  async clearSearchHistory(): Promise<void> {
    await this.searchHistoryDao.clearSearchHistory();
  }
}
