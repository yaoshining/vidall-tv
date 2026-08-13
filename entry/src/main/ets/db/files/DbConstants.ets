/**
 * 数据库共享常量：表名、版本号、事件名。
 * 拆分自 FileSourceDatabase.ets 的私有静态常量，供 DbCore 与各 DAO 共用。
 */
export const DB_VERSION: number = 11;
export const DEFAULT_DB_NAME: string = 'FILE_SOURCES_DB';
export const DATABASE_READY: string = 'FILE_SOURCES_DB_READY';

export const TABLE_FILE_SOURCES: string = 'file_sources';
export const TABLE_DIRECTORIES: string = 'file_source_directories';
export const TABLE_VIDEOS: string = 'videos';
export const TABLE_SCRAPE_INFO: string = 'scrape_info';
export const TABLE_MOVIES: string = 'movies';
export const TABLE_TV_SERIES: string = 'tv_series';
export const TABLE_TV_SEASONS: string = 'tv_seasons';
export const TABLE_TV_EPISODES: string = 'tv_episodes';
export const TABLE_PLAY_PROGRESS: string = 'play_progress';
export const TABLE_MEDIA_PROGRESS: string = 'media_progress';
export const TABLE_SEARCH_HISTORY: string = 'search_history';
