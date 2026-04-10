import relationalStore from '@ohos.data.relationalStore';
import { Context } from '@ohos.abilityAccessCtrl';
import { FileSource, FileSourceDirectory, FileSourceType, DirStatus } from '../models/FileSourceEntity';
import {
  VideoEntity, ScrapeInfoEntity, MovieEntity, TvSeriesEntity, TvSeasonEntity, TvEpisodeEntity,
  MediaItem, MediaStats, SeriesGroup, DecadeGroup, MediaListItem, PlayProgressEntity, MediaProgressEntry,
  SearchHistoryEntry
} from '../models/MediaEntity';
import { CryptoUtil } from '../../utils/CryptoUtil';
import { BusinessError, emitter } from "@kit.BasicServicesKit";

/** 媒体搜索选项（用于 searchMediaItems） */
export interface SearchMediaOptions {
  /** 媒体类型过滤：'movie' | 'tv' | 'all'，默认 'all' */
  mediaType?: 'movie' | 'tv' | 'all';
  /** 类别关键词，模糊匹配 genres_json */
  genre?: string;
  /** 最低评分（含），对应 COALESCE(m.rating, ts.rating) */
  minRating?: number;
  /** 年份起始（含），用于十年段筛选，例如 2020 表示 2020s 的起点 */
  yearFrom?: number;
  /** 年份截止（含），用于十年段筛选，例如 2029 表示 2020s 的终点 */
  yearTo?: number;
  /** 排序方式：rating（默认）| year | title */
  sortBy?: 'rating' | 'year' | 'title';
  /** 最大返回条数，默认 50 */
  limit?: number;
  /**
   * 观看进度过滤
   * 'unseen'  - 未看：media_progress 表无记录，或 position_ms = 0
   * 'partial' - 未看完：有进度且 position_ms < duration_ms * 0.9
   * 'done'    - 已看完：position_ms >= duration_ms * 0.9
   */
  watchProgress?: 'unseen' | 'partial' | 'done';
  /** 制作国过滤：ISO 3166-1 代码，如 "CN"、"JP"、"US"，LIKE 匹配 origin_country_json */
  originCountry?: string;
}

/**
 * 文件源数据库管理类 — DB v6
 * 表结构：file_sources, file_source_directories, videos, scrape_info,
 *         movies, tv_series, tv_seasons, tv_episodes, play_progress, media_progress
 */
export class FileSourceDatabase {
  private static readonly DB_VERSION = 9;
  private static readonly DB_NAME = 'FILE_SOURCES_DB';
  private static readonly TABLE_FILE_SOURCES = 'file_sources';
  private static readonly TABLE_DIRECTORIES = 'file_source_directories';
  private static readonly TABLE_VIDEOS = 'videos';
  private static readonly TABLE_SCRAPE_INFO = 'scrape_info';
  private static readonly TABLE_MOVIES = 'movies';
  private static readonly TABLE_TV_SERIES = 'tv_series';
  private static readonly TABLE_TV_SEASONS = 'tv_seasons';
  private static readonly TABLE_TV_EPISODES = 'tv_episodes';
  private static readonly TABLE_PLAY_PROGRESS = 'play_progress';
  private static readonly TABLE_MEDIA_PROGRESS = 'media_progress';
  private static readonly TABLE_SEARCH_HISTORY = 'search_history';
  private static readonly DATABASE_READY = 'FILE_SOURCES_DB_READY'

  // 单例实例
  private static instance: FileSourceDatabase | null = null;

  // 数据库存储
  private rdbStore: relationalStore.RdbStore | null = null;
  private context: Context | null = null;

  private constructor() {
  }

  /**
   * 获取数据库单例实例
   */
  static getInstance(context?: Context): FileSourceDatabase {
    if (FileSourceDatabase.instance === null) {
      FileSourceDatabase.instance = new FileSourceDatabase();
    }
    if (context) {
      FileSourceDatabase.instance.context = context;
    }
    return FileSourceDatabase.instance;
  }

  /**
   * 初始化数据库
   */
  async init(): Promise<void> {
    if (this.rdbStore !== null) {
      return; // 已经初始化
    }

    if (this.context === null) {
      throw new Error('Context is not set');
    }

    try {
      const config: relationalStore.StoreConfig = {
        name: FileSourceDatabase.DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };

      this.rdbStore = await relationalStore.getRdbStore(this.context, config);

      // ── 手动版本管理（PRAGMA user_version）──
      // 读取当前版本
      const verRs = await this.rdbStore.querySql('PRAGMA user_version');
      let currentVersion = 0;
      if (verRs.goToFirstRow()) {
        currentVersion = verRs.getLong(verRs.getColumnIndex('user_version'));
      }
      verRs.close();
      console.info(`FileSourceDatabase: 当前 user_version=${currentVersion}, 目标 version=${FileSourceDatabase.DB_VERSION}`);

      if (currentVersion === 0) {
        // 全新安装
        await this.onCreate(this.rdbStore);
      } else if (currentVersion < FileSourceDatabase.DB_VERSION) {
        // 需要升级
        await this.onUpgrade(this.rdbStore, currentVersion, FileSourceDatabase.DB_VERSION);
      } else {
        // 版本一致，但仍做防御性 schema 补全（应对手动降级/异常情况）
        await this.ensureScrapeInfoSchema(this.rdbStore);
      }

      // 版本不一致时（含旧版和全新安装）也做一次 schema 补全
      if (currentVersion !== FileSourceDatabase.DB_VERSION) {
        await this.ensureScrapeInfoSchema(this.rdbStore);
        await this.rdbStore.executeSql(`PRAGMA user_version = ${FileSourceDatabase.DB_VERSION}`);
        console.info(`FileSourceDatabase: user_version 已更新为 ${FileSourceDatabase.DB_VERSION}`);
      }

      // 防御性 schema 兼容：补齐 videos 扫描更新标记列
      await this.ensureVideosSchema(this.rdbStore);

      // 防御性 schema 兼容：补齐 movies/tv_series origin_country_json 列（v7 新增，幂等）
      await this.ensureOriginCountrySchema(this.rdbStore);

      // 防御性修复：确保 provider+provider_id 唯一索引已被移除（v8 起允许多文件源对应同一 TMDB 内容）
      await this.dropScrapeInfoProviderPidIndex(this.rdbStore);

      emitter.emit(FileSourceDatabase.DATABASE_READY);
      console.info('FileSourceDatabase: Database initialized successfully');
    } catch (error) {
      console.error('FileSourceDatabase: Failed to initialize database', JSON.stringify(error));
      throw new Error('Failed to initialize database: ' + JSON.stringify(error));
    }
  }

  /**
   * 创建全部表（新安装）
   */
  private async onCreate(rdbStore: relationalStore.RdbStore): Promise<void> {
    try {
      await rdbStore.executeSql(`
        CREATE TABLE IF NOT EXISTS ${FileSourceDatabase.TABLE_FILE_SOURCES} (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          type TEXT NOT NULL,
          config_json TEXT NOT NULL,
          created_at INTEGER NOT NULL
        )
      `);
      await rdbStore.executeSql(`
        CREATE TABLE IF NOT EXISTS ${FileSourceDatabase.TABLE_DIRECTORIES} (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source_id INTEGER NOT NULL,
          directory_path TEXT NOT NULL,
          custom_name TEXT,
          dir_status TEXT NOT NULL DEFAULT 'active',
          FOREIGN KEY(source_id) REFERENCES ${FileSourceDatabase.TABLE_FILE_SOURCES}(id) ON DELETE CASCADE
        )
      `);
      await this.createMediaTablesV3(rdbStore);
      // search_history：持久化搜索关键词，keyword 唯一
      await rdbStore.executeSql(`
        CREATE TABLE IF NOT EXISTS ${FileSourceDatabase.TABLE_SEARCH_HISTORY} (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          keyword TEXT NOT NULL,
          searched_at INTEGER NOT NULL,
          UNIQUE(keyword)
        )
      `);
      console.info('FileSourceDatabase: Tables created (v3)');
    } catch (error) {
      console.error('FileSourceDatabase: Failed to create tables', JSON.stringify(error));
      throw new Error('Failed to create tables: ' + JSON.stringify(error));
    }
  }

  /** 创建 v3 全部媒体表 */
  private async createMediaTablesV3(rdbStore: relationalStore.RdbStore): Promise<void> {
    // videos
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${FileSourceDatabase.TABLE_VIDEOS} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_id INTEGER NOT NULL,
        directory_path TEXT NOT NULL,
        file_path TEXT NOT NULL UNIQUE,
        file_name TEXT NOT NULL,
        file_size INTEGER,
        last_modified TEXT,
        content_type TEXT,
        duration_ms INTEGER,
        width INTEGER,
        height INTEGER,
        frame_rate REAL,
        video_codec TEXT,
        audio_tracks_json TEXT,
        subtitle_tracks_json TEXT,
        updated_in_last_scan INTEGER NOT NULL DEFAULT 0,
        scanned_at INTEGER NOT NULL,
        FOREIGN KEY(source_id) REFERENCES ${FileSourceDatabase.TABLE_FILE_SOURCES}(id)
      )
    `);
    // movies
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${FileSourceDatabase.TABLE_MOVIES} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        provider TEXT NOT NULL,
        provider_id TEXT NOT NULL,
        title TEXT NOT NULL,
        original_title TEXT,
        overview TEXT,
        release_date TEXT,
        rating REAL,
        vote_count INTEGER,
        poster_path TEXT,
        backdrop_path TEXT,
        poster_url TEXT,
        backdrop_url TEXT,
        poster_local_path TEXT,
        backdrop_local_path TEXT,
        genres_json TEXT,
        cast_json TEXT,
        directors_json TEXT,
        runtime INTEGER,
        original_language TEXT,
        origin_country_json TEXT,
        raw_json TEXT,
        scraped_at INTEGER NOT NULL,
        UNIQUE(provider, provider_id)
      )
    `);
    // tv_series
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${FileSourceDatabase.TABLE_TV_SERIES} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        provider TEXT NOT NULL,
        provider_id TEXT NOT NULL,
        title TEXT NOT NULL,
        original_title TEXT,
        overview TEXT,
        first_air_date TEXT,
        rating REAL,
        vote_count INTEGER,
        poster_path TEXT,
        backdrop_path TEXT,
        poster_url TEXT,
        backdrop_url TEXT,
        poster_local_path TEXT,
        backdrop_local_path TEXT,
        genres_json TEXT,
        cast_json TEXT,
        number_of_seasons INTEGER,
        original_language TEXT,
        origin_country_json TEXT,
        raw_json TEXT,
        scraped_at INTEGER NOT NULL,
        UNIQUE(provider, provider_id)
      )
    `);
    // tv_seasons
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${FileSourceDatabase.TABLE_TV_SEASONS} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        series_id INTEGER NOT NULL,
        provider TEXT NOT NULL,
        provider_id TEXT NOT NULL,
        season_number INTEGER NOT NULL,
        title TEXT,
        overview TEXT,
        air_date TEXT,
        episode_count INTEGER,
        poster_path TEXT,
        poster_url TEXT,
        poster_local_path TEXT,
        raw_json TEXT,
        scraped_at INTEGER NOT NULL,
        FOREIGN KEY(series_id) REFERENCES ${FileSourceDatabase.TABLE_TV_SERIES}(id) ON DELETE CASCADE,
        UNIQUE(series_id, season_number)
      )
    `);
    // tv_episodes
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${FileSourceDatabase.TABLE_TV_EPISODES} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        series_id INTEGER NOT NULL,
        season_id INTEGER,
        provider TEXT NOT NULL,
        provider_id TEXT NOT NULL,
        season_number INTEGER NOT NULL,
        episode_number INTEGER NOT NULL,
        title TEXT,
        overview TEXT,
        air_date TEXT,
        runtime INTEGER,
        rating REAL,
        still_path TEXT,
        still_url TEXT,
        raw_json TEXT,
        scraped_at INTEGER NOT NULL,
        FOREIGN KEY(series_id) REFERENCES ${FileSourceDatabase.TABLE_TV_SERIES}(id) ON DELETE CASCADE,
        FOREIGN KEY(season_id) REFERENCES ${FileSourceDatabase.TABLE_TV_SEASONS}(id),
        UNIQUE(series_id, season_number, episode_number)
      )
    `);
    // scrape_info（桥表）
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${FileSourceDatabase.TABLE_SCRAPE_INFO} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        video_id INTEGER NOT NULL UNIQUE,
        provider TEXT NOT NULL,
        provider_id TEXT NOT NULL,
        media_type TEXT NOT NULL,
        title TEXT NOT NULL,
        original_title TEXT,
        movie_id INTEGER,
        tv_series_id INTEGER,
        episode_id INTEGER,
        season_number INTEGER,
        episode_number INTEGER,
        scraped_at INTEGER NOT NULL,
        FOREIGN KEY(video_id) REFERENCES ${FileSourceDatabase.TABLE_VIDEOS}(id) ON DELETE CASCADE,
        FOREIGN KEY(movie_id) REFERENCES ${FileSourceDatabase.TABLE_MOVIES}(id),
        FOREIGN KEY(tv_series_id) REFERENCES ${FileSourceDatabase.TABLE_TV_SERIES}(id),
        FOREIGN KEY(episode_id) REFERENCES ${FileSourceDatabase.TABLE_TV_EPISODES}(id)
      )
    `);
    // play_progress（含媒体库上下文关联的播放进度表）
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${FileSourceDatabase.TABLE_PLAY_PROGRESS} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        video_id INTEGER NOT NULL,
        series_provider_id TEXT NOT NULL DEFAULT '',
        season_number INTEGER NOT NULL DEFAULT 0,
        episode_number INTEGER NOT NULL DEFAULT 0,
        position_ms INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY(video_id) REFERENCES ${FileSourceDatabase.TABLE_VIDEOS}(id) ON DELETE CASCADE,
        UNIQUE(video_id)
      )
    `);
    console.info('FileSourceDatabase: v3 media tables created');

    // media_progress（媒体级播放进度，以 media_key 为主键）
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${FileSourceDatabase.TABLE_MEDIA_PROGRESS} (
        media_key TEXT PRIMARY KEY,
        position_ms INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        last_played_at INTEGER NOT NULL,
        episode_number INTEGER NOT NULL DEFAULT 0,
        season_number INTEGER NOT NULL DEFAULT 0
      )
    `);
    console.info('FileSourceDatabase: media_progress table created');
  }

  /**
   * 版本升级入口：按 currentVersion 逐步执行各版本迁移步骤，
   * 确保从任意旧版本升级都能经过所有中间版本的 DDL 变更。
   */
  private async onUpgrade(rdbStore: relationalStore.RdbStore, oldVersion: number, newVersion: number): Promise<void> {
    console.info(`FileSourceDatabase: Upgrading ${oldVersion} → ${newVersion}`);
    // 用 currentVersion 追踪迁移进度，避免 oldVersion 固定导致跳步
    let currentVersion = oldVersion;
    try {
      if (currentVersion < 4 && currentVersion < newVersion) {
        const fromVersion = currentVersion;
        await this.migrateToV4(rdbStore);
        currentVersion = 4;
        console.info(`[DB] 迁移: v${fromVersion} → v${currentVersion} 完成`);
      }
      if (currentVersion < 5 && currentVersion < newVersion) {
        const fromVersion = currentVersion;
        await this.migrateV4ToV5(rdbStore);
        currentVersion = 5;
        console.info(`[DB] 迁移: v${fromVersion} → v${currentVersion} 完成`);
      }
      if (currentVersion < 6 && currentVersion < newVersion) {
        const fromVersion = currentVersion;
        await this.migrateV5ToV6(rdbStore);
        currentVersion = 6;
        console.info(`[DB] 迁移: v${fromVersion} → v${currentVersion} 完成`);
      }
      if (currentVersion < 7 && currentVersion < newVersion) {
        await this.ensureOriginCountrySchema(rdbStore);
        currentVersion = 7;
        console.info('[DB] 已迁移到 v7：movies/tv_series 新增 origin_country_json');
      }
      if (currentVersion < 8) {
        // 移除 scrape_info.(provider,provider_id) 唯一索引：多个文件源可以对应同一 TMDB 条目
        await rdbStore.executeSql(`DROP INDEX IF EXISTS idx_scrape_info_provider_pid_uq`);
        // 清理孤立 scrape_info（video_id 不在 videos 表中，由历史 INSERT OR REPLACE 产生）
        await rdbStore.executeSql(
          `DELETE FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} WHERE video_id NOT IN (SELECT id FROM ${FileSourceDatabase.TABLE_VIDEOS})`
        );
        currentVersion = 8;
        console.info('[DB] 已迁移到 v8：移除 scrape_info 唯一索引，清理孤立刮削数据');
      }
      if (currentVersion < 9) {
        // v9：file_source_directories 新增 dir_status 列，追踪目录可达性
        try {
          await rdbStore.executeSql(
            `ALTER TABLE ${FileSourceDatabase.TABLE_DIRECTORIES} ADD COLUMN dir_status TEXT NOT NULL DEFAULT 'active'`
          );
        } catch (e) {
          // 列已存在时忽略（幂等）
          console.warn('[DB] v9 ALTER TABLE dir_status: 列可能已存在，已忽略', JSON.stringify(e));
        }
        currentVersion = 9;
        console.info('[DB] 已迁移到 v9：file_source_directories 新增 dir_status 列');
      }
      console.info('FileSourceDatabase: Upgrade complete');
    } catch (error) {
      console.error('FileSourceDatabase: Upgrade failed', JSON.stringify(error));
      throw new Error('Upgrade failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 迁移至 v4：清除旧版媒体表，重建含完整最新结构的媒体表
   * （包含 play_progress、media_progress 等后续版本表，均以 IF NOT EXISTS 保护）。
   * 适用于从 v1/v2/v3 任意版本升级的场景。
   * 注意：DROP 顺序需遵守外键依赖（先子表再父表）。
   */
  private async migrateToV4(rdbStore: relationalStore.RdbStore): Promise<void> {
    const dropOrder: string[] = [
      'scrape_info', 'play_history', 'tv_episodes', 'tv_seasons',
      'videos', 'movies', 'tv_series'
    ];
    for (const t of dropOrder) {
      await rdbStore.executeSql(`DROP TABLE IF EXISTS ${t}`);
      console.info(`FileSourceDatabase: DROP TABLE ${t}`);
    }
    await this.createMediaTablesV3(rdbStore);
  }

  /**
   * 迁移至 v5：用带上下文字段的 play_progress 取代 play_history。
   * 复用 createMediaTablesV3 建表，避免与主建表逻辑重复定义。
   */
  private async migrateV4ToV5(rdbStore: relationalStore.RdbStore): Promise<void> {
    await rdbStore.executeSql(`DROP TABLE IF EXISTS play_history`);
    console.info(`FileSourceDatabase: DROP TABLE play_history`);
    await this.createMediaTablesV3(rdbStore);
  }

  /**
   * 迁移至 v6：新增媒体级播放进度表 media_progress，
   * 以及旧版本升级时未自动建立的 search_history 表。
   * 复用 createMediaTablesV3 建表，避免与主建表逻辑重复定义。
   */
  private async migrateV5ToV6(rdbStore: relationalStore.RdbStore): Promise<void> {
    await this.createMediaTablesV3(rdbStore);
    // 旧版本升级时 onCreate 不再执行，需在此补建 search_history 表
    await rdbStore.executeSql(
      `CREATE TABLE IF NOT EXISTS ${FileSourceDatabase.TABLE_SEARCH_HISTORY} (` +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'keyword TEXT NOT NULL, ' +
      'searched_at INTEGER NOT NULL DEFAULT 0, ' +
      'UNIQUE(keyword))'
    );
    console.info(`FileSourceDatabase: CREATE TABLE search_history`);
  }

  /**
   * 插入文件源
   */
  async insertFileSource(fileSource: FileSource): Promise<number> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }

    try {
      // 解析配置并加密密码
      const config = JSON.parse(fileSource.configJson) as Record<string, Object>;
      if (config.password) {
        config.password = await CryptoUtil.encrypt(config.password as string);
      }

      const valueBucket: relationalStore.ValuesBucket = {
        name: fileSource.name,
        type: fileSource.type,
        config_json: JSON.stringify(config),
        created_at: fileSource.createdAt
      };

      const rowId = await this.rdbStore.insert(FileSourceDatabase.TABLE_FILE_SOURCES, valueBucket);
      console.info(`FileSourceDatabase: Inserted file source with id ${rowId}`);
      return rowId;
    } catch (error) {
      console.error('FileSourceDatabase: Failed to insert file source', JSON.stringify(error));
      throw new Error('Failed to insert file source: ' + JSON.stringify(error));
    }
  }

  /**
   * 更新文件源
   */
  async updateFileSource(fileSource: FileSource): Promise<void> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }

    if (!fileSource.id) {
      throw new Error('File source id is required for update');
    }

    try {
      // 解析配置并加密密码
      const config = JSON.parse(fileSource.configJson) as Record<string, Object>;
      if (config.password) {
        config.password = await CryptoUtil.encrypt(config.password as string);
      }

      const valueBucket: relationalStore.ValuesBucket = {
        name: fileSource.name,
        type: fileSource.type,
        config_json: JSON.stringify(config),
        created_at: fileSource.createdAt
      };

      const predicates = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_FILE_SOURCES);
      predicates.equalTo('id', fileSource.id);

      const rows = await this.rdbStore.update(valueBucket, predicates);
      console.info(`FileSourceDatabase: Updated ${rows} file source(s)`);
    } catch (error) {
      console.error('FileSourceDatabase: Failed to update file source', JSON.stringify(error));
      throw new Error('Failed to update file source: ' + JSON.stringify(error));
    }
  }

  /**
   * 删除文件源
   */
  async deleteFileSource(id: number): Promise<void> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }

    try {
      const predicates = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_FILE_SOURCES);
      predicates.equalTo('id', id);

      const rows = await this.rdbStore.delete(predicates);
      console.info(`FileSourceDatabase: Deleted ${rows} file source(s)`);
    } catch (error) {
      console.error('FileSourceDatabase: Failed to delete file source', JSON.stringify(error));
      throw new Error('Failed to delete file source: ' + JSON.stringify(error));
    }
  }

  /**
   * 根据 ID 获取文件源
   */
  async getFileSourceById(id: number): Promise<FileSource | null> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }

    let resultSet: relationalStore.ResultSet | null = null;
    try {
      const predicates = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_FILE_SOURCES);
      predicates.equalTo('id', id);

      resultSet = await this.rdbStore.query(predicates);

      if (resultSet.goToFirstRow()) {
        return await this.parseFileSource(resultSet);
      }

      return null;
    } catch (error) {
      console.error('FileSourceDatabase: Failed to get file source by id', JSON.stringify(error));
      throw new Error('Failed to get file source by id: ' + JSON.stringify(error));
    } finally {
      resultSet?.close();
    }
  }

  /**
   * 获取所有文件源
   */
  async getAllFileSources(): Promise<FileSource[]> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }

    let resultSet: relationalStore.ResultSet | null = null;
    try {
      const predicates = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_FILE_SOURCES);
      resultSet = await this.rdbStore.query(predicates);

      const fileSources: FileSource[] = [];
      while (resultSet.goToNextRow()) {
        const fileSource = await this.parseFileSource(resultSet);
        fileSources.push(fileSource);
      }

      console.info(`FileSourceDatabase: Retrieved ${fileSources.length} file source(s)`);
      return fileSources;
    } catch (error) {
      console.error('FileSourceDatabase: Failed to get all file sources', JSON.stringify(error));
      throw new Error('Failed to get all file sources: ' + JSON.stringify(error));
    } finally {
      resultSet?.close();
    }
  }

  /**
   * 从 ResultSet 解析文件源对象
   */
  private async parseFileSource(resultSet: relationalStore.ResultSet): Promise<FileSource> {
    const id = resultSet.getLong(resultSet.getColumnIndex('id'));
    const name = resultSet.getString(resultSet.getColumnIndex('name'));
    const typeString = resultSet.getString(resultSet.getColumnIndex('type'));
    const configJson = resultSet.getString(resultSet.getColumnIndex('config_json'));
    const createdAt = resultSet.getLong(resultSet.getColumnIndex('created_at'));

    // 解析配置并解密密码
    const config = JSON.parse(configJson) as Record<string, Object>;
    if (config.password) {
      try {
        config.password = await CryptoUtil.decrypt(config.password as string);
      } catch (error) {
        console.error('FileSourceDatabase: Failed to decrypt password', JSON.stringify(error));
        // 解密失败时保持加密状态
      }
    }

    return {
      id: id,
      name: name,
      type: typeString as FileSourceType,
      configJson: JSON.stringify(config),
      createdAt: createdAt
    };
  }

  /**
   * 批量插入文件源目录关联
   */
  async insertDirectories(sourceId: number, directories: FileSourceDirectory[]): Promise<void> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }

    if (directories.length === 0) {
      console.info('FileSourceDatabase: No directories to insert');
      return;
    }

    try {
      for (const dir of directories) {
        const valueBucket: relationalStore.ValuesBucket = {
          source_id: sourceId,
          directory_path: dir.directoryPath,
          custom_name: dir.customName ?? null,
          dir_status: dir.dirStatus ?? 'active'
        };
        await this.rdbStore.insert(FileSourceDatabase.TABLE_DIRECTORIES, valueBucket);
      }
      console.info(`FileSourceDatabase: Inserted ${directories.length} directory(ies) for source ${sourceId}`);
    } catch (error) {
      console.error('FileSourceDatabase: Failed to insert directories', JSON.stringify(error));
      throw new Error('Failed to insert directories: ' + JSON.stringify(error));
    }
  }

  /**
   * 删除指定文件源的所有目录关联
   */
  async deleteDirectoriesBySourceId(sourceId: number): Promise<void> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }

    try {
      const predicates = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_DIRECTORIES);
      predicates.equalTo('source_id', sourceId);

      const rows = await this.rdbStore.delete(predicates);
      console.info(`FileSourceDatabase: Deleted ${rows} directory(ies) for source ${sourceId}`);
    } catch (error) {
      console.error('FileSourceDatabase: Failed to delete directories', JSON.stringify(error));
      throw new Error('Failed to delete directories: ' + JSON.stringify(error));
    }
  }

  /**
   * 原子性替换指定文件源的目录关联（先删后插，在同一事务内完成，避免部分失败导致数据丢失）
   */
  async saveDirectoriesForSource(sourceId: number, directories: FileSourceDirectory[]): Promise<void> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    const store = this.rdbStore;
    const tx = await store.createTransaction();
    try {
      const predicates = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_DIRECTORIES);
      predicates.equalTo('source_id', sourceId);
      await tx.delete(predicates);
      for (const dir of directories) {
        const valueBucket: relationalStore.ValuesBucket = {
          source_id: sourceId,
          directory_path: dir.directoryPath,
          custom_name: dir.customName ?? null,
          dir_status: dir.dirStatus ?? 'active'
        };
        await tx.insert(FileSourceDatabase.TABLE_DIRECTORIES, valueBucket);
      }
      await tx.commit();
      console.info(`FileSourceDatabase: Saved ${directories.length} directory(ies) for source ${sourceId}`);
    } catch (error) {
      await tx.rollback();
      console.error('FileSourceDatabase: saveDirectoriesForSource failed, rollback', JSON.stringify(error));
      throw new Error('Failed to save directories: ' + JSON.stringify(error));
    }
  }

  /**
   * 查询指定文件源的所有目录关联
   */
  async getDirectoriesBySourceId(sourceId: number): Promise<FileSourceDirectory[]> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }

    let resultSet: relationalStore.ResultSet | null = null;
    try {
      const predicates = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_DIRECTORIES);
      predicates.equalTo('source_id', sourceId);

      resultSet = await this.rdbStore.query(predicates);

      const directories: FileSourceDirectory[] = [];
      while (resultSet.goToNextRow()) {
        const id = resultSet.getLong(resultSet.getColumnIndex('id'));
        const sourceIdVal = resultSet.getLong(resultSet.getColumnIndex('source_id'));
        const directoryPath = resultSet.getString(resultSet.getColumnIndex('directory_path'));
        const customNameIdx = resultSet.getColumnIndex('custom_name');
        const customName = resultSet.isColumnNull(customNameIdx) ? undefined : resultSet.getString(customNameIdx);
        // 兼容旧版本（dir_status 列可能不存在）
        let dirStatus: DirStatus = 'active';
        try {
          const statusIdx = resultSet.getColumnIndex('dir_status');
          if (statusIdx >= 0 && !resultSet.isColumnNull(statusIdx)) {
            dirStatus = resultSet.getString(statusIdx) as DirStatus;
          }
        } catch {
          // 旧 schema 无此列，保持 active 默认值
        }

        directories.push({
          id: id,
          sourceId: sourceIdVal,
          directoryPath: directoryPath,
          customName: customName,
          dirStatus: dirStatus
        });
      }

      console.info(`FileSourceDatabase: Retrieved ${directories.length} directory(ies) for source ${sourceId}`);
      return directories;
    } catch (error) {
      console.error('FileSourceDatabase: Failed to get directories', JSON.stringify(error));
      throw new Error('Failed to get directories: ' + JSON.stringify(error));
    } finally {
      resultSet?.close();
    }
  }

  /**
   * 更新单条目录的可达性状态
   * @param dirId  file_source_directories 主键
   * @param status 新状态：'active' | 'missing' | 'unreachable'
   */
  async updateDirStatus(dirId: number, status: DirStatus): Promise<void> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    try {
      const valueBucket: relationalStore.ValuesBucket = { dir_status: status };
      const predicates = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_DIRECTORIES);
      predicates.equalTo('id', dirId);
      await this.rdbStore.update(valueBucket, predicates);
      console.info(`[DB][updateDirStatus] dirId=${dirId} → ${status}`);
    } catch (error) {
      console.error('[DB][updateDirStatus] 失败', JSON.stringify(error));
      throw new Error('Failed to updateDirStatus: ' + JSON.stringify(error));
    }
  }

  /**
   * 清理指定目录及其下属视频文件、关联的 scrape_info、play_progress。
   * 注意：movies/tv_series 等元数据表可能跨目录/文件源共享，不在本次清理范围内。
   * 孤立的元数据记录由 cleanOrphanedScrapeData() 统一处理。
   * 所有删除操作在同一事务内完成，保证原子性。
   * @param dirId         file_source_directories 主键
   * @param sourceId      所属文件源 ID
   * @param directoryPath 目录路径（用于过滤 videos 表）
   */
  async clearMediaAndDirectoryForDir(dirId: number, sourceId: number, directoryPath: string): Promise<void> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    const store = this.rdbStore;
    const BATCH_SIZE = 100;

    // 1. 查询该目录下的 video id 列表（事务外只读，不影响原子性）
    const videoQueryPredicates = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_VIDEOS);
    videoQueryPredicates.equalTo('source_id', sourceId);
    videoQueryPredicates.and();
    videoQueryPredicates.equalTo('directory_path', directoryPath);
    const videoRs = await store.query(videoQueryPredicates, ['id']);
    const videoIds: number[] = [];
    while (videoRs.goToNextRow()) {
      videoIds.push(videoRs.getLong(videoRs.getColumnIndex('id')));
    }
    videoRs.close();

    // 2. 在事务中执行所有删除操作，保证原子性
    const tx = await store.createTransaction();
    try {
      // 2a. 分批删除 scrape_info（防止超过 SQLite 999 参数上限）
      for (let i = 0; i < videoIds.length; i += BATCH_SIZE) {
        const batch = videoIds.slice(i, i + BATCH_SIZE);
        const scrapePredicates = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_SCRAPE_INFO);
        scrapePredicates.in('video_id', batch.map(v => v as relationalStore.ValueType));
        await tx.delete(scrapePredicates);
      }

      // 2b. 分批删除 play_progress（外键未启用，无级联删除）
      for (let i = 0; i < videoIds.length; i += BATCH_SIZE) {
        const batch = videoIds.slice(i, i + BATCH_SIZE);
        const progressPredicates = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_PLAY_PROGRESS);
        progressPredicates.in('video_id', batch.map(v => v as relationalStore.ValueType));
        await tx.delete(progressPredicates);
      }

      // 2c. 删除视频记录
      const videoDelPredicates = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_VIDEOS);
      videoDelPredicates.equalTo('source_id', sourceId);
      videoDelPredicates.and();
      videoDelPredicates.equalTo('directory_path', directoryPath);
      await tx.delete(videoDelPredicates);

      // 2d. 删除目录配置本身
      const dirPredicates = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_DIRECTORIES);
      dirPredicates.equalTo('id', dirId);
      await tx.delete(dirPredicates);

      await tx.commit();
      console.info(`[DB][clearMediaAndDirectoryForDir] dirId=${dirId} sourceId=${sourceId} path=${directoryPath} 已清理`);
    } catch (error) {
      await tx.rollback();
      console.error('[DB][clearMediaAndDirectoryForDir] 失败，已回滚', JSON.stringify(error));
      throw new Error('Failed to clearMediaAndDirectoryForDir: ' + JSON.stringify(error));
    }
  }

  // ─────────────────────────────────────────────
  // videos 表操作
  // ─────────────────────────────────────────────

  /**
   * 插入或更新视频记录（以 file_path 为唯一键）
   * @returns 视频的 id
   */
  async upsertVideo(entity: VideoEntity): Promise<number> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    try {
      // 先查是否已存在，有则 UPDATE（保留原始 id，避免外键级联删除 scrape_info）
      const existing = await this.getVideoByPath(entity.filePath);
      if (existing && existing.id !== undefined) {
        const bucket: relationalStore.ValuesBucket = {
          source_id: entity.sourceId,
          directory_path: entity.directoryPath,
          file_name: entity.fileName,
          file_size: entity.fileSize !== undefined ? entity.fileSize : null,
          last_modified: entity.lastModified ?? null,
          content_type: entity.contentType ?? null,
          duration_ms: entity.durationMs !== undefined ? entity.durationMs : null,
          width: entity.width !== undefined ? entity.width : null,
          height: entity.height !== undefined ? entity.height : null,
          frame_rate: entity.frameRate !== undefined ? entity.frameRate : null,
          video_codec: entity.videoCodec ?? null,
          audio_tracks_json: entity.audioTracksJson ?? null,
          subtitle_tracks_json: entity.subtitleTracksJson ?? null,
          updated_in_last_scan: 1,
          scanned_at: entity.scannedAt
        };
        const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_VIDEOS);
        pred.equalTo('id', existing.id);
        await this.rdbStore.update(bucket, pred);
        console.info(`[FileSourceDatabase] upsertVideo UPDATE id=${existing.id} path=${entity.filePath}`);
        return existing.id;
      }
      // 新文件 INSERT
      const sql = `
        INSERT OR IGNORE INTO ${FileSourceDatabase.TABLE_VIDEOS}
          (source_id, directory_path, file_path, file_name, file_size, last_modified,
           content_type, duration_ms, width, height, frame_rate, video_codec,
           audio_tracks_json, subtitle_tracks_json, updated_in_last_scan, scanned_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      `;
      const args: relationalStore.ValueType[] = [
        entity.sourceId, entity.directoryPath, entity.filePath, entity.fileName,
        entity.fileSize !== undefined ? entity.fileSize : null,
        entity.lastModified ?? null, entity.contentType ?? null,
        entity.durationMs !== undefined ? entity.durationMs : null,
        entity.width !== undefined ? entity.width : null,
        entity.height !== undefined ? entity.height : null,
        entity.frameRate !== undefined ? entity.frameRate : null,
        entity.videoCodec ?? null,
        entity.audioTracksJson ?? null,
        entity.subtitleTracksJson ?? null,
        1,
        entity.scannedAt
      ];
      await this.rdbStore.executeSql(sql, args);
      const inserted = await this.getVideoByPath(entity.filePath);
      const rowId = inserted?.id ?? -1;
      console.info(`[FileSourceDatabase] upsertVideo INSERT id=${rowId} path=${entity.filePath}`);
      return rowId;
    } catch (error) {
      console.error(`[FileSourceDatabase] upsertVideo 失败: ${JSON.stringify(error)}`);
      throw new Error('upsertVideo failed: ' + JSON.stringify(error));
    }
  }

  /** 按 filePath 查询视频记录 */
  async getVideoByPath(filePath: string): Promise<VideoEntity | null> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_VIDEOS);
      pred.equalTo('file_path', filePath);
      let rs: relationalStore.ResultSet | null = null;
      try {
        rs = await this.rdbStore.query(pred);
        if (rs.goToFirstRow()) {
          return this.parseVideoEntity(rs);
        }
        return null;
      } finally {
        rs?.close();
      }
    } catch (error) {
      console.error(`[FileSourceDatabase] getVideoByPath 失败: ${JSON.stringify(error)}`);
      return null;
    }
  }

  /** 按 sourceId 查询该文件源下所有视频 */
  async getVideosBySourceId(sourceId: number): Promise<VideoEntity[]> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_VIDEOS);
      pred.equalTo('source_id', sourceId);
      rs = await this.rdbStore.query(pred);
      const list: VideoEntity[] = [];
      while (rs.goToNextRow()) {
        list.push(this.parseVideoEntity(rs));
      }
      return list;
    } catch (error) {
      console.error(`[FileSourceDatabase] getVideosBySourceId 失败: ${JSON.stringify(error)}`);
      return [];
    } finally {
      rs?.close();
    }
  }

  /** 获取所有视频 */
  async getAllVideos(): Promise<VideoEntity[]> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_VIDEOS);
      rs = await this.rdbStore.query(pred);
      const list: VideoEntity[] = [];
      while (rs.goToNextRow()) {
        list.push(this.parseVideoEntity(rs));
      }
      return list;
    } catch (error) {
      console.error(`[FileSourceDatabase] getAllVideos 失败: ${JSON.stringify(error)}`);
      return [];
    } finally {
      rs?.close();
    }
  }

  /** 扫描前重置更新标记，扫描中命中的视频会在 upsert 时置为 1 */
  async resetVideoUpdatedFlags(): Promise<void> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    try {
      await this.rdbStore.executeSql(
        `UPDATE ${FileSourceDatabase.TABLE_VIDEOS} SET updated_in_last_scan = 0`
      );
      console.info('[FileSourceDatabase] resetVideoUpdatedFlags 完成');
    } catch (error) {
      console.warn(`[FileSourceDatabase] resetVideoUpdatedFlags 失败: ${JSON.stringify(error)}`);
    }
  }

  /** 将已存在的视频标记为本轮扫描命中，用于增量扫描跳过未变化文件时置位 */
  async markVideoUpdatedByPath(filePath: string): Promise<void> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    try {
      await this.rdbStore.executeSql(
        `UPDATE ${FileSourceDatabase.TABLE_VIDEOS} SET updated_in_last_scan = 1 WHERE file_path = ?`,
        [filePath]
      );
    } catch (error) {
      console.warn(`[FileSourceDatabase] markVideoUpdatedByPath 失败 path=${filePath}: ${JSON.stringify(error)}`);
    }
  }

  private parseVideoEntity(rs: relationalStore.ResultSet): VideoEntity {
    const get = (col: string): number => rs.getLong(rs.getColumnIndex(col));
    const str = (col: string): string | undefined => {
      const idx = rs.getColumnIndex(col);
      return rs.isColumnNull(idx) ? undefined : rs.getString(idx);
    };
    const num = (col: string): number | undefined => {
      const idx = rs.getColumnIndex(col);
      return rs.isColumnNull(idx) ? undefined : rs.getLong(idx);
    };
    const dbl = (col: string): number | undefined => {
      const idx = rs.getColumnIndex(col);
      return rs.isColumnNull(idx) ? undefined : rs.getDouble(idx);
    };
    return {
      id: get('id'),
      sourceId: get('source_id'),
      directoryPath: rs.getString(rs.getColumnIndex('directory_path')),
      filePath: rs.getString(rs.getColumnIndex('file_path')),
      fileName: rs.getString(rs.getColumnIndex('file_name')),
      fileSize: num('file_size'),
      lastModified: str('last_modified'),
      contentType: str('content_type'),
      durationMs: num('duration_ms'),
      width: num('width'),
      height: num('height'),
      frameRate: dbl('frame_rate'),
      videoCodec: str('video_codec'),
      audioTracksJson: str('audio_tracks_json'),
      subtitleTracksJson: str('subtitle_tracks_json'),
      updatedInLastScan: num('updated_in_last_scan'),
      scannedAt: get('scanned_at')
    };
  }

  // ─────────────────────────────────────────────
  // movies 表
  // ─────────────────────────────────────────────

  /** 按 provider+providerId 查询电影，存在则返回，不存在返回 null */
  async getMovieByProviderId(provider: string, providerId: string): Promise<MovieEntity | null> {
    if (this.rdbStore === null) { return null; }
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_MOVIES);
      pred.equalTo('provider', provider).and().equalTo('provider_id', providerId);
      const rs = await this.rdbStore.query(pred);
      if (rs.goToFirstRow()) {
        const e = this.parseMovieEntity(rs); rs.close(); return e;
      }
      rs.close(); return null;
    } catch { return null; }
  }

  async getMovieById(id: number): Promise<MovieEntity | null> {
    if (this.rdbStore === null) { return null; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_MOVIES);
      pred.equalTo('id', id);
      rs = await this.rdbStore.query(pred);
      if (rs.goToFirstRow()) { return this.parseMovieEntity(rs); }
      return null;
    } catch {
      return null;
    } finally {
      rs?.close();
    }
  }

  /** 批量获取所有电影，供播放历史等场景一次性加载 */
  async getAllMovies(): Promise<MovieEntity[]> {
    if (this.rdbStore === null) { return []; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_MOVIES);
      rs = await this.rdbStore.query(pred);
      const items: MovieEntity[] = [];
      while (rs.goToNextRow()) { items.push(this.parseMovieEntity(rs)); }
      return items;
    } catch (e) {
      console.error('[FileSourceDatabase] getAllMovies', JSON.stringify(e));
      return [];
    } finally {
      rs?.close();
    }
  }

  /** 插入或更新电影（以 provider+provider_id 唯一），返回 id */
  async upsertMovie(e: MovieEntity): Promise<number> {
    if (this.rdbStore === null) { throw new Error('Database not initialized'); }
    // 先查，有则 UPDATE，无则 INSERT OR IGNORE 保证并发安全
    const existing = await this.getMovieByProviderId(e.provider, e.providerId);
    if (existing && existing.id !== undefined) {
      const bucket: relationalStore.ValuesBucket = {
        provider: e.provider, provider_id: e.providerId, title: e.title,
        original_title: e.originalTitle ?? null, overview: e.overview ?? null,
        release_date: e.releaseDate ?? null, rating: e.rating ?? null,
        vote_count: e.voteCount ?? null, poster_path: e.posterPath ?? null,
        backdrop_path: e.backdropPath ?? null, poster_url: e.posterUrl ?? null,
        backdrop_url: e.backdropUrl ?? null, poster_local_path: e.posterLocalPath ?? null,
        backdrop_local_path: e.backdropLocalPath ?? null, genres_json: e.genresJson ?? null,
        cast_json: e.castJson ?? null, directors_json: e.directorsJson ?? null,
        runtime: e.runtime ?? null, original_language: e.originalLanguage ?? null,
        origin_country_json: e.originCountryJson ?? null,
        raw_json: e.rawJson ?? null, scraped_at: e.scrapedAt
      };
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_MOVIES);
      pred.equalTo('id', existing.id);
      await this.rdbStore.update(bucket, pred);
      console.info(`[DB][upsertMovie] UPDATE id=${existing.id} title="${e.title}" posterUrl=${e.posterUrl ? e.posterUrl.substring(0, 40) : 'null'}`);
      return existing.id;
    }
    const sql = `
      INSERT OR IGNORE INTO ${FileSourceDatabase.TABLE_MOVIES}
        (provider, provider_id, title, original_title, overview, release_date, rating,
         vote_count, poster_path, backdrop_path, poster_url, backdrop_url,
         poster_local_path, backdrop_local_path, genres_json, cast_json, directors_json,
         runtime, original_language, origin_country_json, raw_json, scraped_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    `;
    const args: relationalStore.ValueType[] = [
      e.provider, e.providerId, e.title, e.originalTitle ?? null, e.overview ?? null,
      e.releaseDate ?? null, e.rating ?? null, e.voteCount ?? null,
      e.posterPath ?? null, e.backdropPath ?? null, e.posterUrl ?? null,
      e.backdropUrl ?? null, e.posterLocalPath ?? null, e.backdropLocalPath ?? null,
      e.genresJson ?? null, e.castJson ?? null, e.directorsJson ?? null,
      e.runtime ?? null, e.originalLanguage ?? null, e.originCountryJson ?? null, e.rawJson ?? null, e.scrapedAt
    ];
    await this.rdbStore.executeSql(sql, args);
    // 查回刚插入的 id
    const inserted = await this.getMovieByProviderId(e.provider, e.providerId);
    const newId = inserted?.id ?? -1;
    console.info(`[DB][upsertMovie] INSERT id=${newId} title="${e.title}" posterUrl=${e.posterUrl ? e.posterUrl.substring(0, 40) : 'null'}`);
    return newId;
  }

  private parseMovieEntity(rs: relationalStore.ResultSet): MovieEntity {
    const str = (col: string): string | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getString(i); };
    const num = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getLong(i); };
    const dbl = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getDouble(i); };
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      provider: rs.getString(rs.getColumnIndex('provider')),
      providerId: rs.getString(rs.getColumnIndex('provider_id')),
      title: rs.getString(rs.getColumnIndex('title')),
      originalTitle: str('original_title'), overview: str('overview'),
      releaseDate: str('release_date'), rating: dbl('rating'), voteCount: num('vote_count'),
      posterPath: str('poster_path'), backdropPath: str('backdrop_path'),
      posterUrl: str('poster_url'), backdropUrl: str('backdrop_url'),
      posterLocalPath: str('poster_local_path'), backdropLocalPath: str('backdrop_local_path'),
      genresJson: str('genres_json'), castJson: str('cast_json'), directorsJson: str('directors_json'),
      runtime: num('runtime'), originalLanguage: str('original_language'),
      originCountryJson: str('origin_country_json'),
      rawJson: str('raw_json'), scrapedAt: rs.getLong(rs.getColumnIndex('scraped_at'))
    };
  }

  // ─────────────────────────────────────────────
  // tv_series 表
  // ─────────────────────────────────────────────

  async getTvSeriesByProviderId(provider: string, providerId: string): Promise<TvSeriesEntity | null> {
    if (this.rdbStore === null) { return null; }
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_TV_SERIES);
      pred.equalTo('provider', provider).and().equalTo('provider_id', providerId);
      const rs = await this.rdbStore.query(pred);
      if (rs.goToFirstRow()) { const e = this.parseTvSeriesEntity(rs); rs.close(); return e; }
      rs.close(); return null;
    } catch { return null; }
  }

  /** 批量获取所有剧集，供播放历史等场景一次性加载 */
  async getAllTvSeries(): Promise<TvSeriesEntity[]> {
    if (this.rdbStore === null) { return []; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_TV_SERIES);
      rs = await this.rdbStore.query(pred);
      const items: TvSeriesEntity[] = [];
      while (rs.goToNextRow()) { items.push(this.parseTvSeriesEntity(rs)); }
      return items;
    } catch (e) {
      console.error('[FileSourceDatabase] getAllTvSeries', JSON.stringify(e));
      return [];
    } finally {
      rs?.close();
    }
  }

  async upsertTvSeries(e: TvSeriesEntity): Promise<number> {
    if (this.rdbStore === null) { throw new Error('Database not initialized'); }
    const existing = await this.getTvSeriesByProviderId(e.provider, e.providerId);
    if (existing && existing.id !== undefined) {
      const bucket: relationalStore.ValuesBucket = {
        provider: e.provider, provider_id: e.providerId, title: e.title,
        original_title: e.originalTitle ?? null, overview: e.overview ?? null,
        first_air_date: e.firstAirDate ?? null, rating: e.rating ?? null,
        vote_count: e.voteCount ?? null, poster_path: e.posterPath ?? null,
        backdrop_path: e.backdropPath ?? null, poster_url: e.posterUrl ?? null,
        backdrop_url: e.backdropUrl ?? null, poster_local_path: e.posterLocalPath ?? null,
        backdrop_local_path: e.backdropLocalPath ?? null, genres_json: e.genresJson ?? null,
        cast_json: e.castJson ?? null, number_of_seasons: e.numberOfSeasons ?? null,
        original_language: e.originalLanguage ?? null, origin_country_json: e.originCountryJson ?? null,
        raw_json: e.rawJson ?? null,
        scraped_at: e.scrapedAt
      };
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_TV_SERIES);
      pred.equalTo('id', existing.id);
      await this.rdbStore.update(bucket, pred);
      return existing.id;
    }
    const sql = `
      INSERT OR IGNORE INTO ${FileSourceDatabase.TABLE_TV_SERIES}
        (provider, provider_id, title, original_title, overview, first_air_date, rating,
         vote_count, poster_path, backdrop_path, poster_url, backdrop_url,
         poster_local_path, backdrop_local_path, genres_json, cast_json,
         number_of_seasons, original_language, origin_country_json, raw_json, scraped_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    `;
    const args: relationalStore.ValueType[] = [
      e.provider, e.providerId, e.title, e.originalTitle ?? null, e.overview ?? null,
      e.firstAirDate ?? null, e.rating ?? null, e.voteCount ?? null,
      e.posterPath ?? null, e.backdropPath ?? null, e.posterUrl ?? null,
      e.backdropUrl ?? null, e.posterLocalPath ?? null, e.backdropLocalPath ?? null,
      e.genresJson ?? null, e.castJson ?? null,
      e.numberOfSeasons !== undefined ? e.numberOfSeasons : null,
      e.originalLanguage ?? null, e.originCountryJson ?? null, e.rawJson ?? null, e.scrapedAt
    ];
    await this.rdbStore.executeSql(sql, args);
    const inserted = await this.getTvSeriesByProviderId(e.provider, e.providerId);
    return inserted?.id ?? -1;
  }

  private parseTvSeriesEntity(rs: relationalStore.ResultSet): TvSeriesEntity {
    const str = (col: string): string | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getString(i); };
    const num = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getLong(i); };
    const dbl = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getDouble(i); };
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      provider: rs.getString(rs.getColumnIndex('provider')),
      providerId: rs.getString(rs.getColumnIndex('provider_id')),
      title: rs.getString(rs.getColumnIndex('title')),
      originalTitle: str('original_title'), overview: str('overview'),
      firstAirDate: str('first_air_date'), rating: dbl('rating'), voteCount: num('vote_count'),
      posterPath: str('poster_path'), backdropPath: str('backdrop_path'),
      posterUrl: str('poster_url'), backdropUrl: str('backdrop_url'),
      posterLocalPath: str('poster_local_path'), backdropLocalPath: str('backdrop_local_path'),
      genresJson: str('genres_json'), castJson: str('cast_json'),
      numberOfSeasons: num('number_of_seasons'), originalLanguage: str('original_language'),
      originCountryJson: str('origin_country_json'),
      rawJson: str('raw_json'), scrapedAt: rs.getLong(rs.getColumnIndex('scraped_at'))
    };
  }

  // ─────────────────────────────────────────────
  // tv_seasons 表
  // ─────────────────────────────────────────────

  async getTvSeason(seriesId: number, seasonNumber: number): Promise<TvSeasonEntity | null> {
    if (this.rdbStore === null) { return null; }
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_TV_SEASONS);
      pred.equalTo('series_id', seriesId).and().equalTo('season_number', seasonNumber);
      const rs = await this.rdbStore.query(pred);
      if (rs.goToFirstRow()) { const e = this.parseTvSeasonEntity(rs); rs.close(); return e; }
      rs.close(); return null;
    } catch { return null; }
  }

  async upsertTvSeason(e: TvSeasonEntity): Promise<number> {
    if (this.rdbStore === null) { throw new Error('Database not initialized'); }
    const existing = await this.getTvSeason(e.seriesId, e.seasonNumber);
    if (existing && existing.id !== undefined) {
      const bucket: relationalStore.ValuesBucket = {
        series_id: e.seriesId, provider: e.provider, provider_id: e.providerId,
        season_number: e.seasonNumber, title: e.title ?? null, overview: e.overview ?? null,
        air_date: e.airDate ?? null, episode_count: e.episodeCount ?? null,
        poster_path: e.posterPath ?? null, poster_url: e.posterUrl ?? null,
        poster_local_path: e.posterLocalPath ?? null, raw_json: e.rawJson ?? null,
        scraped_at: e.scrapedAt
      };
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_TV_SEASONS);
      pred.equalTo('id', existing.id);
      await this.rdbStore.update(bucket, pred);
      return existing.id;
    }
    const sql = `
      INSERT OR IGNORE INTO ${FileSourceDatabase.TABLE_TV_SEASONS}
        (series_id, provider, provider_id, season_number, title, overview,
         air_date, episode_count, poster_path, poster_url, poster_local_path, raw_json, scraped_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
    `;
    const args: relationalStore.ValueType[] = [
      e.seriesId, e.provider, e.providerId, e.seasonNumber,
      e.title ?? null, e.overview ?? null, e.airDate ?? null,
      e.episodeCount !== undefined ? e.episodeCount : null,
      e.posterPath ?? null, e.posterUrl ?? null, e.posterLocalPath ?? null,
      e.rawJson ?? null, e.scrapedAt
    ];
    await this.rdbStore.executeSql(sql, args);
    const inserted = await this.getTvSeason(e.seriesId, e.seasonNumber);
    return inserted?.id ?? -1;
  }

  private parseTvSeasonEntity(rs: relationalStore.ResultSet): TvSeasonEntity {
    const str = (col: string): string | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getString(i); };
    const num = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getLong(i); };
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      seriesId: rs.getLong(rs.getColumnIndex('series_id')),
      provider: rs.getString(rs.getColumnIndex('provider')),
      providerId: rs.getString(rs.getColumnIndex('provider_id')),
      seasonNumber: rs.getLong(rs.getColumnIndex('season_number')),
      title: str('title'), overview: str('overview'), airDate: str('air_date'),
      episodeCount: num('episode_count'), posterPath: str('poster_path'),
      posterUrl: str('poster_url'), posterLocalPath: str('poster_local_path'),
      rawJson: str('raw_json'), scrapedAt: rs.getLong(rs.getColumnIndex('scraped_at'))
    };
  }

  // ─────────────────────────────────────────────
  // tv_episodes 表
  // ─────────────────────────────────────────────

  async getTvEpisode(seriesId: number, seasonNumber: number, episodeNumber: number): Promise<TvEpisodeEntity | null> {
    if (this.rdbStore === null) { return null; }
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_TV_EPISODES);
      pred.equalTo('series_id', seriesId).and().equalTo('season_number', seasonNumber).and().equalTo('episode_number', episodeNumber);
      const rs = await this.rdbStore.query(pred);
      if (rs.goToFirstRow()) { const e = this.parseTvEpisodeEntity(rs); rs.close(); return e; }
      rs.close(); return null;
    } catch { return null; }
  }

  /** 获取某部剧某季的全部集（按 episode_number 升序），用于季详情页集列表展示 */
  async getEpisodesBySeriesAndSeason(seriesId: number, seasonNumber: number): Promise<TvEpisodeEntity[]> {
    if (this.rdbStore === null) { return []; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql = `SELECT * FROM ${FileSourceDatabase.TABLE_TV_EPISODES}
        WHERE series_id = ? AND season_number = ?
        ORDER BY episode_number ASC`;
      rs = await this.rdbStore.querySql(sql, [seriesId, seasonNumber]);
      const items: TvEpisodeEntity[] = [];
      while (rs.goToNextRow()) { items.push(this.parseTvEpisodeEntity(rs)); }
      return items;
    } catch (e) {
      console.error('[DB][getEpisodesBySeriesAndSeason]', JSON.stringify(e));
      return [];
    } finally {
      rs?.close();
    }
  }

  /** 获取剧集中 season_number > 0 的最小季、最小集号的第一集（用于续播卡片默认展示） */
  async getFirstTvEpisode(seriesId: number): Promise<TvEpisodeEntity | null> {
    if (this.rdbStore === null) { return null; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql = `SELECT * FROM ${FileSourceDatabase.TABLE_TV_EPISODES}
        WHERE series_id = ? AND season_number > 0
        ORDER BY season_number ASC, episode_number ASC
        LIMIT 1`;
      rs = await this.rdbStore.querySql(sql, [seriesId]);
      if (rs.goToFirstRow()) { return this.parseTvEpisodeEntity(rs); }
      return null;
    } catch { return null; } finally { rs?.close(); }
  }

  async upsertTvEpisode(e: TvEpisodeEntity): Promise<number> {
    if (this.rdbStore === null) { throw new Error('Database not initialized'); }
    const existing = await this.getTvEpisode(e.seriesId, e.seasonNumber, e.episodeNumber);
    if (existing && existing.id !== undefined) {
      const bucket: relationalStore.ValuesBucket = {
        series_id: e.seriesId, season_id: e.seasonId !== undefined ? e.seasonId : null,
        provider: e.provider, provider_id: e.providerId,
        season_number: e.seasonNumber, episode_number: e.episodeNumber,
        title: e.title ?? null, overview: e.overview ?? null, air_date: e.airDate ?? null,
        runtime: e.runtime !== undefined ? e.runtime : null,
        rating: e.rating !== undefined ? e.rating : null,
        still_path: e.stillPath ?? null, still_url: e.stillUrl ?? null,
        raw_json: e.rawJson ?? null, scraped_at: e.scrapedAt
      };
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_TV_EPISODES);
      pred.equalTo('id', existing.id);
      await this.rdbStore.update(bucket, pred);
      return existing.id;
    }
    const sql = `
      INSERT OR IGNORE INTO ${FileSourceDatabase.TABLE_TV_EPISODES}
        (series_id, season_id, provider, provider_id, season_number, episode_number,
         title, overview, air_date, runtime, rating, still_path, still_url, raw_json, scraped_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    `;
    const args: relationalStore.ValueType[] = [
      e.seriesId, e.seasonId !== undefined ? e.seasonId : null,
      e.provider, e.providerId, e.seasonNumber, e.episodeNumber,
      e.title ?? null, e.overview ?? null, e.airDate ?? null,
      e.runtime !== undefined ? e.runtime : null,
      e.rating !== undefined ? e.rating : null,
      e.stillPath ?? null, e.stillUrl ?? null,
      e.rawJson ?? null, e.scrapedAt
    ];
    await this.rdbStore.executeSql(sql, args);
    const inserted = await this.getTvEpisode(e.seriesId, e.seasonNumber, e.episodeNumber);
    return inserted?.id ?? -1;
  }

  private parseTvEpisodeEntity(rs: relationalStore.ResultSet): TvEpisodeEntity {
    const str = (col: string): string | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getString(i); };
    const num = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getLong(i); };
    const dbl = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getDouble(i); };
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      seriesId: rs.getLong(rs.getColumnIndex('series_id')),
      seasonId: num('season_id'),
      provider: rs.getString(rs.getColumnIndex('provider')),
      providerId: rs.getString(rs.getColumnIndex('provider_id')),
      seasonNumber: rs.getLong(rs.getColumnIndex('season_number')),
      episodeNumber: rs.getLong(rs.getColumnIndex('episode_number')),
      title: str('title'), overview: str('overview'), airDate: str('air_date'),
      runtime: num('runtime'), rating: dbl('rating'),
      stillPath: str('still_path'), stillUrl: str('still_url'),
      rawJson: str('raw_json'), scrapedAt: rs.getLong(rs.getColumnIndex('scraped_at'))
    };
  }

  // ─────────────────────────────────────────────
  // schema 防御性补齐
  // ─────────────────────────────────────────────

  /** 确保 videos 表存在扫描更新标记列 */
  private async ensureOriginCountrySchema(rdbStore: relationalStore.RdbStore): Promise<void> {
    try {
      await rdbStore.executeSql(
        `ALTER TABLE ${FileSourceDatabase.TABLE_MOVIES} ADD COLUMN origin_country_json TEXT`
      );
    } catch {
      // 列已存在时忽略
    }
    try {
      await rdbStore.executeSql(
        `ALTER TABLE ${FileSourceDatabase.TABLE_TV_SERIES} ADD COLUMN origin_country_json TEXT`
      );
    } catch {
      // 列已存在时忽略
    }
  }

  private async ensureVideosSchema(rdbStore: relationalStore.RdbStore): Promise<void> {
    try {
      await rdbStore.executeSql(
        `ALTER TABLE ${FileSourceDatabase.TABLE_VIDEOS} ADD COLUMN updated_in_last_scan INTEGER NOT NULL DEFAULT 0`
      );
    } catch {
      // 列已存在时忽略
    }
  }

  // ─────────────────────────────────────────────
  // scrape_info 桥表
  // ─────────────────────────────────────────────

  /**
   * 确保 scrape_info 表有 v3 所需的列（旧设备升级兼容）
   * SQLite ALTER TABLE ADD COLUMN 若列已存在会报错，try/catch 忽略即可
   */
  private async ensureScrapeInfoSchema(rdbStore: relationalStore.RdbStore): Promise<void> {
    const alterCols: string[] = [
      `ALTER TABLE ${FileSourceDatabase.TABLE_SCRAPE_INFO} ADD COLUMN movie_id INTEGER`,
      `ALTER TABLE ${FileSourceDatabase.TABLE_SCRAPE_INFO} ADD COLUMN tv_series_id INTEGER`,
      `ALTER TABLE ${FileSourceDatabase.TABLE_SCRAPE_INFO} ADD COLUMN episode_id INTEGER`,
      `ALTER TABLE ${FileSourceDatabase.TABLE_SCRAPE_INFO} ADD COLUMN season_number INTEGER`,
      `ALTER TABLE ${FileSourceDatabase.TABLE_SCRAPE_INFO} ADD COLUMN episode_number INTEGER`,
    ];
    for (const sql of alterCols) {
      try {
        await rdbStore.executeSql(sql);
      } catch {
        // 列已存在时 SQLite 报错，忽略
      }
    }
    // 同时确保新表（movies/tv_series/tv_seasons/tv_episodes）存在
    await this.createMediaTablesV3(rdbStore);
  }

  /**
   * 确保 scrape_info 的 provider+provider_id 联合唯一索引已被移除。
   * v8 起允许多个文件源（WebDAV/SMB）指向同一 TMDB 内容，不能再用该索引限制写入。
   */
  private async dropScrapeInfoProviderPidIndex(rdbStore: relationalStore.RdbStore): Promise<void> {
    try {
      await rdbStore.executeSql(`DROP INDEX IF EXISTS idx_scrape_info_provider_pid_uq`);
      console.info('[DB] scrape_info provider+provider_id 唯一索引已移除（多文件源兼容）');
    } catch (e) {
      console.warn('[DB] 移除 scrape_info 唯一索引失败: ' + JSON.stringify(e));
    }
  }

  /**
   * 全量覆盖扫描完成后，删除指定文件源中不再存在的鬼记录（旧扫描遗留、现已不在 NAS 上的视频）。
   * foundPaths：本轮扫描写入 DB 的 file_path 集合。
   * 注意：SQLite 外键未启用，需显式删除 scrape_info（overwrite 模式下已由 clearScrapeInfoForSources 预清空）。
   */
  async deleteGhostVideosForSources(sourceIds: number[], foundPaths: string[]): Promise<number> {
    if (!this.rdbStore || sourceIds.length === 0) { return 0; }
    try {
      const foundPathsSet = new Set<string>(foundPaths);
      const sidHolders = sourceIds.map(() => '?').join(', ');
      const sidArgs: relationalStore.ValueType[] = sourceIds.map(id => id as relationalStore.ValueType);

      // 1. 查询这些文件源的所有视频记录
      const rs = await this.rdbStore.querySql(
        `SELECT id, file_path FROM ${FileSourceDatabase.TABLE_VIDEOS} WHERE source_id IN (${sidHolders})`,
        sidArgs
      );
      const ghostIds: number[] = [];
      while (rs.goToNextRow()) {
        const filePath = rs.getString(rs.getColumnIndex('file_path'));
        const id = rs.getLong(rs.getColumnIndex('id'));
        if (!foundPathsSet.has(filePath)) {
          ghostIds.push(id);
        }
      }
      rs.close();

      if (ghostIds.length === 0) {
        console.info(`[DB][deleteGhostVideos] 无鬼记录，无需清理`);
        return 0;
      }

      // 2. 分批删除（SQLite IN 参数上限 999）
      const BATCH = 100;
      for (let i = 0; i < ghostIds.length; i += BATCH) {
        const batch = ghostIds.slice(i, i + BATCH);
        const idHolders = batch.map(() => '?').join(', ');
        const idArgs: relationalStore.ValueType[] = batch.map(gid => gid as relationalStore.ValueType);
        // 先删 scrape_info（无外键 CASCADE）
        await this.rdbStore!.executeSql(
          `DELETE FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} WHERE video_id IN (${idHolders})`,
          idArgs
        );
        // 再删 videos
        await this.rdbStore!.executeSql(
          `DELETE FROM ${FileSourceDatabase.TABLE_VIDEOS} WHERE id IN (${idHolders})`,
          idArgs
        );
      }

      console.info(`[DB][deleteGhostVideos] 已清理 ${ghostIds.length} 条鬼记录，source_id IN (${sourceIds})`);
      return ghostIds.length;
    } catch (e) {
      console.warn('[DB][deleteGhostVideos] 清理鬼记录失败: ' + JSON.stringify(e));
      return 0;
    }
  }

  async getScrapeInfoByVideoId(videoId: number): Promise<ScrapeInfoEntity | null> {
    if (this.rdbStore === null) { return null; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_SCRAPE_INFO);
      pred.equalTo('video_id', videoId);
      rs = await this.rdbStore.query(pred);
      if (rs.goToFirstRow()) { return this.parseScrapeInfoEntity(rs); }
      return null;
    } catch { return null; } finally { rs?.close(); }
  }

  /** 清理孤立 scrape_info（video_id 不在 videos 表中），由历史 INSERT OR REPLACE 产生 */
  async cleanupOrphanedScrapeInfo(): Promise<void> {
    if (this.rdbStore === null) { return; }
    try {
      await this.rdbStore.executeSql(
        `DELETE FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} WHERE video_id NOT IN (SELECT id FROM ${FileSourceDatabase.TABLE_VIDEOS})`
      );
      console.info('[DB] cleanupOrphanedScrapeInfo 完成');
    } catch (e) {
      console.warn(`[DB] cleanupOrphanedScrapeInfo 失败: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 全量覆盖模式专用：清空指定文件源下所有视频的 scrape_info，
   * 确保重刮前无历史垃圾数据干扰。
   */
  async clearScrapeInfoForSources(sourceIds: number[]): Promise<void> {
    if (this.rdbStore === null || sourceIds.length === 0) { return; }
    try {
      const placeholders = sourceIds.map(() => '?').join(',');
      const args: relationalStore.ValueType[] = [];
      for (const id of sourceIds) {
        args.push(id);
      }
      await this.rdbStore.executeSql(
        `DELETE FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO}
         WHERE video_id IN (
           SELECT id FROM ${FileSourceDatabase.TABLE_VIDEOS} WHERE source_id IN (${placeholders})
         )`,
        args
      );
      console.info(`[DB] clearScrapeInfoForSources 完成 sourceIds=[${sourceIds.join(',')}]`);
    } catch (e) {
      console.warn(`[DB] clearScrapeInfoForSources 失败: ${JSON.stringify(e)}`);
    }
  }

  /** 查询 scrape_info 中某剧已刮削的所有季号（用于季列表过滤） */
  async getScrapedSeasonNumbers(tvSeriesId: number): Promise<number[]> {
    if (this.rdbStore === null) { return []; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_SCRAPE_INFO);
      pred.equalTo('tv_series_id', tvSeriesId).and().isNotNull('season_number');
      rs = await this.rdbStore.query(pred, ['season_number']);
      const nums: number[] = [];
      while (rs.goToNextRow()) {
        const n = rs.getLong(rs.getColumnIndex('season_number'));
        if (nums.indexOf(n) < 0) { nums.push(n); }
      }
      return nums;
    } catch { return []; } finally { rs?.close(); }
  }

  async upsertScrapeInfo(e: ScrapeInfoEntity): Promise<void> {
    if (this.rdbStore === null) { throw new Error('Database not initialized'); }
    console.info(`[DB][upsertScrapeInfo] videoId=${e.videoId} type=${e.mediaType} movieId=${e.movieId ?? 'null'} tvSeriesId=${e.tvSeriesId ?? 'null'} episodeId=${e.episodeId ?? 'null'} title="${e.title}"`);
    // 先查 video_id 是否已有 scrape_info，有则 UPDATE（不依赖 provider+provider_id 唯一索引）
    const existing = await this.getScrapeInfoByVideoId(e.videoId);
    if (existing && existing.id !== undefined) {
      const bucket: relationalStore.ValuesBucket = {
        provider: e.provider,
        provider_id: e.providerId,
        media_type: e.mediaType,
        title: e.title,
        original_title: e.originalTitle ?? null,
        movie_id: e.movieId !== undefined ? e.movieId : null,
        tv_series_id: e.tvSeriesId !== undefined ? e.tvSeriesId : null,
        episode_id: e.episodeId !== undefined ? e.episodeId : null,
        season_number: e.seasonNumber !== undefined ? e.seasonNumber : null,
        episode_number: e.episodeNumber !== undefined ? e.episodeNumber : null,
        scraped_at: e.scrapedAt
      };
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_SCRAPE_INFO);
      pred.equalTo('id', existing.id);
      await this.rdbStore.update(bucket, pred);
      console.info(`[DB][upsertScrapeInfo] ✅ 写入成功 videoId=${e.videoId}`);
      return;
    }
    const sql = `
      INSERT OR IGNORE INTO ${FileSourceDatabase.TABLE_SCRAPE_INFO}
        (video_id, provider, provider_id, media_type, title, original_title,
         movie_id, tv_series_id, episode_id, season_number, episode_number, scraped_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `;
    const args: relationalStore.ValueType[] = [
      e.videoId,
      e.provider,
      e.providerId,
      e.mediaType,
      e.title,
      e.originalTitle ?? null,
      e.movieId !== undefined ? e.movieId : null,
      e.tvSeriesId !== undefined ? e.tvSeriesId : null,
      e.episodeId !== undefined ? e.episodeId : null,
      e.seasonNumber !== undefined ? e.seasonNumber : null,
      e.episodeNumber !== undefined ? e.episodeNumber : null,
      e.scrapedAt
    ];
    await this.rdbStore.executeSql(sql, args);
    console.info(`[DB][upsertScrapeInfo] ✅ 写入成功 videoId=${e.videoId}`);
  }

  private parseScrapeInfoEntity(rs: relationalStore.ResultSet): ScrapeInfoEntity {
    const num = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getLong(i); };
    const str = (col: string): string | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getString(i); };
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      videoId: rs.getLong(rs.getColumnIndex('video_id')),
      provider: rs.getString(rs.getColumnIndex('provider')),
      providerId: rs.getString(rs.getColumnIndex('provider_id')),
      mediaType: rs.getString(rs.getColumnIndex('media_type')),
      title: rs.getString(rs.getColumnIndex('title')),
      originalTitle: str('original_title'),
      movieId: num('movie_id'), tvSeriesId: num('tv_series_id'),
      episodeId: num('episode_id'), seasonNumber: num('season_number'),
      episodeNumber: num('episode_number'),
      scrapedAt: rs.getLong(rs.getColumnIndex('scraped_at'))
    };
  }

  // ─────────────────────────────────────────────
  // 媒体库聚合查询
  // ─────────────────────────────────────────────

  /** 公共 SELECT 片段：videos LEFT JOIN scrape_info LEFT JOIN movies/tv_series */
  private get mediaItemSql(): string {
    return `
      SELECT v.id, v.source_id, v.directory_path, v.file_path, v.file_name,
             v.file_size, v.duration_ms, v.width, v.height, v.video_codec,
             v.audio_tracks_json, v.scanned_at,
             s.provider, s.provider_id, s.media_type,
             s.movie_id, s.tv_series_id, s.episode_id,
             s.season_number, s.episode_number,
             COALESCE(m.title, ts.title, s.title)                 AS scrape_title,
             COALESCE(m.original_title, ts.original_title)        AS original_title,
             COALESCE(te.overview, m.overview, ts.overview)       AS overview,
             COALESCE(m.release_date, ts.first_air_date)          AS release_date,
             COALESCE(m.rating, ts.rating)                        AS rating,
             COALESCE(m.genres_json, ts.genres_json)              AS genres_json,
             COALESCE(ts.poster_url, m.poster_url)                AS poster_url,
             COALESCE(ts.backdrop_url, m.backdrop_url)            AS backdrop_url,
             COALESCE(ts.poster_local_path, m.poster_local_path)  AS poster_local_path,
             COALESCE(ts.backdrop_local_path, m.backdrop_local_path) AS backdrop_local_path
      FROM ${FileSourceDatabase.TABLE_VIDEOS} v
      LEFT JOIN ${FileSourceDatabase.TABLE_SCRAPE_INFO} s ON v.id = s.video_id
      LEFT JOIN ${FileSourceDatabase.TABLE_MOVIES} m ON s.movie_id = m.id
      LEFT JOIN ${FileSourceDatabase.TABLE_TV_SERIES} ts ON s.tv_series_id = ts.id
      LEFT JOIN ${FileSourceDatabase.TABLE_TV_EPISODES} te ON s.episode_id = te.id
    `;
  }

  async getAllMediaItems(): Promise<MediaItem[]> {
    if (this.rdbStore === null) { return []; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await this.rdbStore.querySql(this.mediaItemSql + ' ORDER BY v.scanned_at DESC');
      const items: MediaItem[] = [];
      while (rs.goToNextRow()) { items.push(this.parseMediaItem(rs)); }
      // ── 诊断日志 ──
      const withTitle = items.filter(i => i.title !== undefined).length;
      const withPoster = items.filter(i => i.posterUrl !== undefined || i.posterLocalPath !== undefined).length;
      const withRating = items.filter(i => i.rating !== undefined).length;
      const sample = items.slice(0, 3).map(i =>
        `{id=${i.id} type=${i.mediaType ?? 'null'} title=${i.title ?? 'null'} tvSid=${i.tvSeriesId ?? 'null'} movieId=${i.movieId ?? 'null'} rating=${i.rating ?? 'null'} poster=${i.posterUrl ? 'Y' : 'N'}}`
      ).join(', ');
      console.info(`[DB][getAllMediaItems] 总数=${items.length} 有标题=${withTitle} 有海报=${withPoster} 有评分=${withRating}`);
      console.info(`[DB][getAllMediaItems] 采样(前3): ${sample}`);
      return items;
    } catch (e) {
      console.error('[FileSourceDatabase] getAllMediaItems', JSON.stringify(e));
      return [];
    } finally {
      rs?.close();
    }
  }

  async getMediaItemsByType(mediaType: string): Promise<MediaItem[]> {
    if (this.rdbStore === null) { return []; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql = this.mediaItemSql + ' WHERE s.media_type = ? ORDER BY v.scanned_at DESC';
      rs = await this.rdbStore.querySql(sql, [mediaType]);
      const items: MediaItem[] = [];
      while (rs.goToNextRow()) { items.push(this.parseMediaItem(rs)); }
      // ── 诊断日志 ──
      const withPoster = items.filter(i => i.posterUrl !== undefined || i.posterLocalPath !== undefined).length;
      const sample = items.slice(0, 2).map(i =>
        `{id=${i.id} tvSid=${i.tvSeriesId ?? 'null'} title=${i.title ?? 'null'} poster=${i.posterUrl ? 'Y' : 'N'}}`
      ).join(', ');
      console.info(`[DB][getMediaItemsByType('${mediaType}')] 数量=${items.length} 有海报=${withPoster} 采样: ${sample}`);
      return items;
    } catch (e) { console.error('[FileSourceDatabase] getMediaItemsByType', JSON.stringify(e)); return []; } finally { rs?.close(); }
  }

  async getMediaItemsByRating(): Promise<MediaItem[]> {
    if (this.rdbStore === null) { return []; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql = this.mediaItemSql + ' WHERE COALESCE(m.rating, ts.rating) IS NOT NULL ORDER BY COALESCE(m.rating, ts.rating) DESC';
      rs = await this.rdbStore.querySql(sql);
      const items: MediaItem[] = [];
      while (rs.goToNextRow()) { items.push(this.parseMediaItem(rs)); }
      console.info(`[DB][getMediaItemsByRating] 数量=${items.length} (有评分的视频数)`);
      return items;
    } catch (e) { console.error('[FileSourceDatabase] getMediaItemsByRating', JSON.stringify(e)); return []; } finally { rs?.close(); }
  }

  async getDistinctReleaseYears(): Promise<string[]> {
    if (this.rdbStore === null) { return []; }
    try {
      // ── 先诊断 scrape_info / movies / tv_series 的基本数量 ──
      const diagRs = await this.rdbStore.querySql(`SELECT
        (SELECT COUNT(*) FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO}) AS si_cnt,
        (SELECT COUNT(*) FROM ${FileSourceDatabase.TABLE_MOVIES}) AS m_cnt,
        (SELECT COUNT(*) FROM ${FileSourceDatabase.TABLE_TV_SERIES}) AS ts_cnt,
        (SELECT COUNT(*) FROM ${FileSourceDatabase.TABLE_TV_SERIES} WHERE first_air_date IS NOT NULL) AS ts_date_cnt,
        (SELECT COUNT(*) FROM ${FileSourceDatabase.TABLE_MOVIES} WHERE release_date IS NOT NULL) AS m_date_cnt`);
      if (diagRs.goToFirstRow()) {
        const siCnt = diagRs.getLong(diagRs.getColumnIndex('si_cnt'));
        const mCnt = diagRs.getLong(diagRs.getColumnIndex('m_cnt'));
        const tsCnt = diagRs.getLong(diagRs.getColumnIndex('ts_cnt'));
        const tsDateCnt = diagRs.getLong(diagRs.getColumnIndex('ts_date_cnt'));
        const mDateCnt = diagRs.getLong(diagRs.getColumnIndex('m_date_cnt'));
        console.info(`[DB][诊断] scrape_info=${siCnt} movies=${mCnt}(有日期=${mDateCnt}) tv_series=${tsCnt}(有日期=${tsDateCnt})`);
      }
      diagRs.close();

      // ── 诊断 scrape_info 中 movie_id / tv_series_id 的分布 ──
      const joinRs = await this.rdbStore.querySql(`SELECT
        COUNT(*) AS total,
        SUM(CASE WHEN movie_id IS NOT NULL THEN 1 ELSE 0 END) AS has_movie_id,
        SUM(CASE WHEN tv_series_id IS NOT NULL THEN 1 ELSE 0 END) AS has_tv_series_id,
        SUM(CASE WHEN movie_id IS NULL AND tv_series_id IS NULL THEN 1 ELSE 0 END) AS no_fk
        FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO}`);
      if (joinRs.goToFirstRow()) {
        const total = joinRs.getLong(joinRs.getColumnIndex('total'));
        const hasMov = joinRs.getLong(joinRs.getColumnIndex('has_movie_id'));
        const hasTv = joinRs.getLong(joinRs.getColumnIndex('has_tv_series_id'));
        const noFk = joinRs.getLong(joinRs.getColumnIndex('no_fk'));
        console.info(`[DB][诊断] scrape_info: 总=${total} 有movie_id=${hasMov} 有tv_series_id=${hasTv} 无FK=${noFk}`);
      }
      joinRs.close();

      const sql = `
        SELECT DISTINCT substr(COALESCE(m.release_date, ts.first_air_date), 1, 4) AS year
        FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} s
        LEFT JOIN ${FileSourceDatabase.TABLE_MOVIES} m ON s.movie_id = m.id
        LEFT JOIN ${FileSourceDatabase.TABLE_TV_SERIES} ts ON s.tv_series_id = ts.id
        WHERE COALESCE(m.release_date, ts.first_air_date) IS NOT NULL
        ORDER BY year DESC
      `;
      let rs: relationalStore.ResultSet | null = null;
      try {
        rs = await this.rdbStore.querySql(sql);
        const years: string[] = [];
        while (rs.goToNextRow()) { const y = rs.getString(rs.getColumnIndex('year')); if (y) { years.push(y); } }
        console.info(`[DB][getDistinctReleaseYears] 年份列表: ${JSON.stringify(years)}`);
        return years;
      } finally {
        rs?.close();
      }
    } catch (e) { console.error('[DB][getDistinctReleaseYears] 异常', JSON.stringify(e)); return []; }
  }

  async getMediaItemsByYear(year: string): Promise<MediaItem[]> {
    if (this.rdbStore === null) { return []; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql = this.mediaItemSql + ` WHERE substr(COALESCE(m.release_date, ts.first_air_date), 1, 4) = ? ORDER BY COALESCE(m.release_date, ts.first_air_date) DESC`;
      rs = await this.rdbStore.querySql(sql, [year]);
      const items: MediaItem[] = [];
      while (rs.goToNextRow()) { items.push(this.parseMediaItem(rs)); }
      return items;
    } catch { return []; } finally { rs?.close(); }
  }

  async getMediaStats(): Promise<MediaStats> {
    if (this.rdbStore === null) { return { total: 0, movies: 0, tv: 0, other: 0 }; }
    try {
      const q = async (sql: string): Promise<number> => {
        let rs: relationalStore.ResultSet | null = null;
        try {
          rs = await this.rdbStore!.querySql(sql);
          rs.goToFirstRow();
          return rs.getLong(rs.getColumnIndex('cnt'));
        } finally {
          rs?.close();
        }
      };
      const total = await q(`SELECT COUNT(*) AS cnt FROM ${FileSourceDatabase.TABLE_VIDEOS}`);
      const movies = await q(`SELECT COUNT(DISTINCT movie_id) AS cnt FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} WHERE movie_id IS NOT NULL`);
      const tv = await q(`SELECT COUNT(DISTINCT tv_series_id) AS cnt FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} WHERE tv_series_id IS NOT NULL`);
      const scraped = await q(`SELECT COUNT(DISTINCT video_id) AS cnt FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO}`);
      const other = total - scraped;

      // 诊断：打印无刮削记录的文件列表（source_id + file_name）
      if (other > 0 && this.rdbStore) {
        let diagRs: relationalStore.ResultSet | undefined;
        try {
          diagRs = await this.rdbStore.querySql(
            `SELECT v.source_id, v.file_name, v.file_path FROM ${FileSourceDatabase.TABLE_VIDEOS} v
             WHERE NOT EXISTS (SELECT 1 FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} s WHERE s.video_id = v.id)
             ORDER BY v.source_id, v.file_name`
          );
          const unscrapedFiles: string[] = [];
          while (diagRs.goToNextRow()) {
            const sid = diagRs.getLong(diagRs.getColumnIndex('source_id'));
            const name = diagRs.getString(diagRs.getColumnIndex('file_name'));
            unscrapedFiles.push(`[src=${sid}] ${name}`);
          }
          console.info(`[DB][getMediaStats] 未刮削文件(${other}个):\n${unscrapedFiles.join('\n')}`);
        } catch {
          // 诊断失败不影响主流程
        } finally {
          diagRs?.close();
        }
      }

      return { total, movies, tv, other };
    } catch { return { total: 0, movies: 0, tv: 0, other: 0 }; }
  }

  private parseMediaItem(rs: relationalStore.ResultSet): MediaItem {
    const L = (col: string): number => { const i = rs.getColumnIndex(col); return i >= 0 && !rs.isColumnNull(i) ? rs.getLong(i) : 0; };
    const str = (col: string): string | undefined => { const i = rs.getColumnIndex(col); return i >= 0 && !rs.isColumnNull(i) ? rs.getString(i) : undefined; };
    const dbl = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return i >= 0 && !rs.isColumnNull(i) ? rs.getDouble(i) : undefined; };
    const numOpt = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return i >= 0 && !rs.isColumnNull(i) ? rs.getLong(i) : undefined; };
    return {
      id: L('id'), sourceId: L('source_id'),
      directoryPath: rs.getString(rs.getColumnIndex('directory_path')),
      filePath: rs.getString(rs.getColumnIndex('file_path')),
      fileName: rs.getString(rs.getColumnIndex('file_name')),
      fileSize: numOpt('file_size'), durationMs: numOpt('duration_ms'),
      width: numOpt('width'), height: numOpt('height'),
      videoCodec: str('video_codec'), audioTracksJson: str('audio_tracks_json'),
      scannedAt: L('scanned_at'),
      provider: str('provider'), providerId: str('provider_id'), mediaType: str('media_type'),
      movieId: numOpt('movie_id'), tvSeriesId: numOpt('tv_series_id'),
      episodeId: numOpt('episode_id'), seasonNumber: numOpt('season_number'),
      episodeNumber: numOpt('episode_number'),
      title: str('scrape_title'), originalTitle: str('original_title'),
      overview: str('overview'), releaseDate: str('release_date'),
      rating: dbl('rating'), genresJson: str('genres_json'),
      posterUrl: str('poster_url'), backdropUrl: str('backdrop_url'),
      posterLocalPath: str('poster_local_path'), backdropLocalPath: str('backdrop_local_path'),
    };
  }

  /**
   * 按 tv_series_id 查询该剧所有分集（含元数据），按季号+集号排序
   * 用于剧集详情页加载集列表
   */
  async getMediaItemsByTvSeriesId(seriesId: number): Promise<MediaItem[]> {
    if (this.rdbStore === null) { return []; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql = this.mediaItemSql +
        ' WHERE s.tv_series_id = ?' +
        ' ORDER BY COALESCE(s.season_number, 0) ASC, COALESCE(s.episode_number, 0) ASC';
      rs = await this.rdbStore.querySql(sql, [seriesId]);
      const items: MediaItem[] = [];
      while (rs.goToNextRow()) { items.push(this.parseMediaItem(rs)); }
      return items;
    } catch (e) {
      console.error('[DB][getMediaItemsByTvSeriesId]', JSON.stringify(e));
      return [];
    } finally {
      rs?.close();
    }
  }

  /**
   * 按主键查询 tv_series 行（用于剧集详情页显示简介/类别/演员等）
   */
  async getTvSeriesById(id: number): Promise<TvSeriesEntity | null> {
    if (this.rdbStore === null) { return null; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_TV_SERIES);
      pred.equalTo('id', id);
      rs = await this.rdbStore.query(pred);
      if (rs.goToFirstRow()) { return this.parseTvSeriesEntity(rs); }
      return null;
    } catch {
      return null;
    } finally {
      rs?.close();
    }
  }

  /**
   * 聚合电视剧/综艺合集
   *
   * 聚合策略：
   * 1. 有刮削数据（media_type='tv'）-> 以 provider::providerId 聚合
   * 2. 无刮削数据 -> 以视频文件的"直接父目录"路径聚合，
   *    同目录 >= 2 个视频才算合集（单文件不算）
   *    若父目录名是通用季名（如 Season1、S01、第1季）则再取上一级目录名作合集标题
   */
  async getSeriesGroups(): Promise<SeriesGroup[]> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    try {
      // TMDB 对剧集整体返回 media_type='tv'，对单集返回 media_type='episode'，两者都要纳入聚合
      const scrapedTv = await this.getMediaItemsByType('tv');
      const scrapedEpisode = await this.getMediaItemsByType('episode');

      // ── 诊断：直接查 scrape_info 表，验证 media_type 分布 ──
      let rawRs: relationalStore.ResultSet | null = null;
      const mediaTypeDist: string[] = [];
      try {
        rawRs = await this.rdbStore.querySql(`
          SELECT media_type, COUNT(*) AS cnt, MIN(tv_series_id) AS min_tsid, MAX(tv_series_id) AS max_tsid
          FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO}
          GROUP BY media_type
        `);
        while (rawRs.goToNextRow()) {
          const mt = rawRs.getString(rawRs.getColumnIndex('media_type'));
          const cnt = rawRs.getLong(rawRs.getColumnIndex('cnt'));
          const minTsid = rawRs.isColumnNull(rawRs.getColumnIndex('min_tsid')) ? 'null' : String(rawRs.getLong(rawRs.getColumnIndex('min_tsid')));
          const maxTsid = rawRs.isColumnNull(rawRs.getColumnIndex('max_tsid')) ? 'null' : String(rawRs.getLong(rawRs.getColumnIndex('max_tsid')));
          mediaTypeDist.push(`${mt}:${cnt}(tsid=${minTsid}~${maxTsid})`);
        }
      } finally {
        rawRs?.close();
      }
      console.info(`[DB][getSeriesGroups] scrape_info media_type分布: ${mediaTypeDist.join(', ')}`);

      // ── 诊断：JOIN 是否正常 ──
      let joinDiagRs: relationalStore.ResultSet | null = null;
      const joinSamples: string[] = [];
      try {
        joinDiagRs = await this.rdbStore.querySql(`
          SELECT s.video_id, s.media_type, s.tv_series_id, ts.title AS ts_title, ts.poster_url AS ts_poster
          FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} s
          LEFT JOIN ${FileSourceDatabase.TABLE_TV_SERIES} ts ON s.tv_series_id = ts.id
          WHERE s.media_type IN ('tv','episode')
          LIMIT 5
        `);
        while (joinDiagRs.goToNextRow()) {
          const vid = joinDiagRs.getLong(joinDiagRs.getColumnIndex('video_id'));
          const mt = joinDiagRs.getString(joinDiagRs.getColumnIndex('media_type'));
          const tsid = joinDiagRs.isColumnNull(joinDiagRs.getColumnIndex('tv_series_id')) ? 'null' : String(joinDiagRs.getLong(joinDiagRs.getColumnIndex('tv_series_id')));
          const tsTitle = joinDiagRs.isColumnNull(joinDiagRs.getColumnIndex('ts_title')) ? 'null' : joinDiagRs.getString(joinDiagRs.getColumnIndex('ts_title'));
          const tsPoster = joinDiagRs.isColumnNull(joinDiagRs.getColumnIndex('ts_poster')) ? 'null' : 'Y';
          joinSamples.push(`vid=${vid} type=${mt} tsid=${tsid} title=${tsTitle} poster=${tsPoster}`);
        }
      } finally {
        joinDiagRs?.close();
      }
      console.info(`[DB][getSeriesGroups] JOIN诊断(前5): ${joinSamples.join(' | ')}`);

      const allScrapedTv: MediaItem[] = [];
      for (const it of scrapedTv) { allScrapedTv.push(it); }
      for (const it of scrapedEpisode) { allScrapedTv.push(it); }

      const unscrapedAll = await this.getUnscrapedMediaItems();
      console.info(`[DB][getSeriesGroups] 输入: tv=${scrapedTv.length} episode=${scrapedEpisode.length} unscraped=${unscrapedAll.length}`);

      const providerMap = new Map<string, MediaItem[]>();

      // ── 有刮削 tv/episode：以 tvSeriesId 聚合（精确，避免标题歧义）──
      for (const item of allScrapedTv) {
        // tvSeriesId 是最精确的 key；无则降级用规范化标题
        const key = item.tvSeriesId !== undefined
          ? `scraped::sid::${item.tvSeriesId}`
          : `scraped::title::${this.extractBaseSeriesTitle(item.title ?? item.fileName)}`;
        const existing = providerMap.get(key);
        if (existing) {
          existing.push(item);
        } else {
          providerMap.set(key, [item]);
        }
      }

      // ── 无刮削：以直接父目录聚合，先统计数量 ──
      const unscrapedMap = new Map<string, MediaItem[]>();
      for (const item of unscrapedAll) {
        const parentDir = this.getParentDir(item.filePath);
        const existing = unscrapedMap.get(parentDir);
        if (existing) {
          existing.push(item);
        } else {
          unscrapedMap.set(parentDir, [item]);
        }
      }

      // 若父目录是「Season N / 第X季 / S01」等季目录，先归并到上一层系列目录，再按 >=2 过滤
      const mergedUnscrapedMap = new Map<string, MediaItem[]>();
      const unscrapedEntries: string[] = [];
      unscrapedMap.forEach((_v: MediaItem[], k: string) => {
        unscrapedEntries.push(k);
      });
      for (const parentDir of unscrapedEntries) {
        const items = unscrapedMap.get(parentDir);
        if (items === undefined || items.length === 0) { continue; }
        const segs = parentDir.split('/').filter((s: string) => s.length > 0);
        const lastSeg = segs.length > 0 ? segs[segs.length - 1] : '';
        // 季目录 → 归并到上一层（系列根目录）
        let mergeKey: string;
        if (lastSeg.length > 0 && this.isGenericSeasonName(lastSeg) && segs.length >= 2) {
          mergeKey = segs.slice(0, segs.length - 1).join('/');
        } else {
          mergeKey = parentDir;
        }
        const existing = mergedUnscrapedMap.get(mergeKey);
        if (existing) {
          for (const item of items) { existing.push(item); }
        } else {
          const arr: MediaItem[] = [];
          for (const item of items) { arr.push(item); }
          mergedUnscrapedMap.set(mergeKey, arr);
        }
      }
      // 只有 >=2 个文件才算合集
      const mergedKeys: string[] = [];
      mergedUnscrapedMap.forEach((_v: MediaItem[], k: string) => {
        mergedKeys.push(k);
      });
      for (const mergeKey of mergedKeys) {
        const items = mergedUnscrapedMap.get(mergeKey);
        if (items !== undefined && items.length >= 2) {
          providerMap.set(`unscraped::${mergeKey}`, items);
        }
      }

      const groups: SeriesGroup[] = [];
      const providerKeys: string[] = [];
      providerMap.forEach((_v: MediaItem[], k: string) => {
        providerKeys.push(k);
      });

      for (const key of providerKeys) {
        const items = providerMap.get(key);
        if (items === undefined || items.length === 0) {
          continue;
        }
        const first = items[0];
        if (first === undefined) {
          continue;
        }
        let latestScannedAt = 0;
        for (const it of items) {
          if (it.scannedAt > latestScannedAt) {
            latestScannedAt = it.scannedAt;
          }
        }

        // 合集标题：有刮削的统一用基础剧名（去掉"第X季"后缀），首页不显示季标签
        let groupTitle: string;
        let seasonLabel: string | undefined = undefined;
        if (first.tvSeriesId !== undefined || first.title) {
          // 有刮削：取基础剧名（COALESCE 已取到 ts.title，去掉季名后缀即为基础剧名）
          groupTitle = this.extractBaseSeriesTitle(first.title ?? first.fileName);
        } else {
          const parentDir = this.getParentDir(first.filePath);
          const segments = parentDir.split('/').filter((s: string) => s.length > 0);
          const lastSeg = segments.length > 0 ? segments[segments.length - 1] : '';
          const dirName = lastSeg ?? '';
          if (this.isGenericSeasonName(dirName) && segments.length >= 2) {
            const parentSeg = segments[segments.length - 2];
            groupTitle = parentSeg ?? dirName;
            seasonLabel = this.formatSeasonLabel(dirName);
          } else {
            groupTitle = dirName.length > 0 ? dirName : first.fileName;
          }
        }
        void key;

        // 从所有 items 中挑最佳代表封面：有海报且评分最高的
        let representative: MediaItem = first;
        for (const it of items) {
          const itHasPoster = it.posterUrl !== undefined || it.posterLocalPath !== undefined;
          const curHasPoster = representative.posterUrl !== undefined || representative.posterLocalPath !== undefined;
          if (itHasPoster && !curHasPoster) {
            representative = it;
          } else if (itHasPoster === curHasPoster && (it.rating ?? 0) > (representative.rating ?? 0)) {
            representative = it;
          }
        }

        // 查该季的海报（tv_seasons 表）
        let seasonPosterUrl: string | undefined;
        const repSeasonNum = first.seasonNumber;
        const repSeriesId = first.tvSeriesId;
        if (repSeriesId !== undefined && repSeasonNum !== undefined) {
          try {
            let seasonRs: relationalStore.ResultSet | null = null;
            try {
              seasonRs = await this.rdbStore.querySql(
                `SELECT poster_url FROM ${FileSourceDatabase.TABLE_TV_SEASONS} WHERE series_id=? AND season_number=? LIMIT 1`,
                [repSeriesId, repSeasonNum]
              );
              if (seasonRs.goToFirstRow()) {
                const idx = seasonRs.getColumnIndex('poster_url');
                if (!seasonRs.isColumnNull(idx)) {
                  seasonPosterUrl = seasonRs.getString(idx);
                }
              }
            } finally {
              seasonRs?.close();
            }
          } catch {
            // 查不到就不设，不影响主流程
          }
        }

        const group: SeriesGroup = {
          title: groupTitle,
          seasonLabel,
          posterUrl: representative.posterUrl,
          posterLocalPath: representative.posterLocalPath,
          backdropUrl: representative.backdropUrl,
          seasonNumber: repSeasonNum,
          seasonPosterUrl,
          rating: representative.rating,
          episodeCount: items.length,
          episodes: items,
          latestScannedAt
        };
        groups.push(group);
      }

      groups.sort((a, b) => b.latestScannedAt - a.latestScannedAt);
      console.info(
        `[FileSourceDatabase] getSeriesGroups: ${groups.length} 组` +
        `（有刮削 tv=${scrapedTv.length} episode=${scrapedEpisode.length} 集，无刮削候选=${unscrapedAll.length} 个）`
      );
      return groups;
    } catch (error) {
      console.error(`[FileSourceDatabase] getSeriesGroups 失败: ${JSON.stringify(error)}`);
      return [];
    }
  }

  // ─────────────────────────────────────────────
  // 首页展示：精确 SQL 查询（替代旧的复杂内存归并）
  // ─────────────────────────────────────────────

  /**
   * 电视剧栏：从 scrape_info 按 tv_series_id GROUP BY，
   * 取去重后的每部剧（联 tv_series 拿海报、评分），按最新刮削时间倒序。
   */
  async getDistinctTvSeriesGroups(limit: number = 30): Promise<SeriesGroup[]> {
    if (this.rdbStore === null) { return []; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql = `
        SELECT ts.id AS series_id, ts.title, ts.rating,
               ts.poster_url, ts.backdrop_url,
               ts.poster_local_path, ts.backdrop_local_path,
               COUNT(*) AS episode_count,
               MAX(si.scraped_at) AS latest_scraped_at
        FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} si
        JOIN ${FileSourceDatabase.TABLE_TV_SERIES} ts ON si.tv_series_id = ts.id
        WHERE si.tv_series_id IS NOT NULL
        GROUP BY si.tv_series_id
        ORDER BY latest_scraped_at DESC
        LIMIT ?
      `;
      rs = await this.rdbStore.querySql(sql, [limit]);
      const groups: SeriesGroup[] = [];
      while (rs.goToNextRow()) {
        const str = (col: string): string | undefined => {
          const i = rs!.getColumnIndex(col);
          return rs!.isColumnNull(i) ? undefined : rs!.getString(i);
        };
        const dbl = (col: string): number | undefined => {
          const i = rs!.getColumnIndex(col);
          return rs!.isColumnNull(i) ? undefined : rs!.getDouble(i);
        };
        const seriesId = rs.getLong(rs.getColumnIndex('series_id'));
        const group: SeriesGroup = {
          title: rs.getString(rs.getColumnIndex('title')),
          tvSeriesId: seriesId,
          posterUrl: str('poster_url'),
          backdropUrl: str('backdrop_url'),
          posterLocalPath: str('poster_local_path'),
          rating: dbl('rating'),
          episodeCount: rs.getLong(rs.getColumnIndex('episode_count')),
          episodes: [],
          latestScannedAt: rs.getLong(rs.getColumnIndex('latest_scraped_at'))
        };
        groups.push(group);
      }
      console.info(`[DB][getDistinctTvSeriesGroups] ${groups.length} 部电视剧`);
      return groups;
    } catch (e) {
      console.error('[DB][getDistinctTvSeriesGroups] 查询失败', JSON.stringify(e));
      return [];
    } finally {
      rs?.close();
    }
  }

  /**
   * 最近添加列表：
   * - 电视剧按 (tv_series_id, season_number) GROUP BY，取季海报，按最新刮削时间倒序
   * - 电影按 scraped_at 倒序
   * - 两者合并后按 sortTs 倒序，取前 limit 条
   */
  async getRecentlyAddedList(limit: number = 20): Promise<MediaListItem[]> {
    if (this.rdbStore === null) { return []; }
    let tvRs: relationalStore.ResultSet | null = null;
    let movieRs: relationalStore.ResultSet | null = null;
    let unscrapedRs: relationalStore.ResultSet | null = null;
    try {
      // ── 电视剧（按剧+季分组）──────────────────────────────────
      const tvSql = `
        SELECT si.tv_series_id, COALESCE(si.season_number, 0) AS season_num,
               ts.title, ts.rating, ts.poster_url, ts.poster_local_path, ts.backdrop_url,
               tss.poster_url AS season_poster_url,
               COUNT(*) AS episode_count,
               MAX(si.scraped_at) AS latest_scraped_at
        FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} si
        JOIN ${FileSourceDatabase.TABLE_TV_SERIES} ts ON si.tv_series_id = ts.id
        LEFT JOIN ${FileSourceDatabase.TABLE_TV_SEASONS} tss
               ON tss.series_id = si.tv_series_id
              AND tss.season_number = si.season_number
        WHERE si.tv_series_id IS NOT NULL
        GROUP BY si.tv_series_id, COALESCE(si.season_number, 0)
        ORDER BY latest_scraped_at DESC
        LIMIT ?
      `;
      tvRs = await this.rdbStore.querySql(tvSql, [limit]);
      const tvItems: MediaListItem[] = [];
      while (tvRs.goToNextRow()) {
        const str = (col: string): string | undefined => {
          const i = tvRs!.getColumnIndex(col);
          return tvRs!.isColumnNull(i) ? undefined : tvRs!.getString(i);
        };
        const dbl = (col: string): number | undefined => {
          const i = tvRs!.getColumnIndex(col);
          return tvRs!.isColumnNull(i) ? undefined : tvRs!.getDouble(i);
        };
        const seasonNum = tvRs.getLong(tvRs.getColumnIndex('season_num'));
        const sortTs = tvRs.getLong(tvRs.getColumnIndex('latest_scraped_at'));
        const group: SeriesGroup = {
          title: tvRs.getString(tvRs.getColumnIndex('title')),
          tvSeriesId: tvRs.getLong(tvRs.getColumnIndex('tv_series_id')),
          seasonNumber: seasonNum > 0 ? seasonNum : undefined,
          seasonLabel: seasonNum > 0 ? `第${seasonNum}季` : undefined,
          posterUrl: str('poster_url'),
          backdropUrl: str('backdrop_url'),
          posterLocalPath: str('poster_local_path'),
          seasonPosterUrl: str('season_poster_url'),
          rating: dbl('rating'),
          episodeCount: tvRs.getLong(tvRs.getColumnIndex('episode_count')),
          episodes: [],
          latestScannedAt: sortTs
        };
        const item: MediaListItem = { kind: 'series', series: group, sortTs };
        tvItems.push(item);
      }
      tvRs.close(); tvRs = null;

      // ── 电影 ─────────────────────────────────────────────────
      const movieSql = `
        SELECT m.title, m.rating, m.poster_url, m.poster_local_path, m.backdrop_url,
               v.id AS vid, v.source_id, v.directory_path, v.file_path, v.file_name,
               v.file_size, v.duration_ms, v.width, v.height, v.video_codec,
               v.audio_tracks_json, v.scanned_at,
               si.scraped_at, si.provider, si.provider_id, si.movie_id
        FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} si
        JOIN ${FileSourceDatabase.TABLE_MOVIES} m ON si.movie_id = m.id
        JOIN ${FileSourceDatabase.TABLE_VIDEOS} v ON si.video_id = v.id
        WHERE si.movie_id IS NOT NULL
        ORDER BY si.scraped_at DESC
        LIMIT ?
      `;
      movieRs = await this.rdbStore.querySql(movieSql, [limit]);
      const movieItems: MediaListItem[] = [];
      while (movieRs.goToNextRow()) {
        const str = (col: string): string | undefined => {
          const i = movieRs!.getColumnIndex(col);
          return movieRs!.isColumnNull(i) ? undefined : movieRs!.getString(i);
        };
        const num = (col: string): number | undefined => {
          const i = movieRs!.getColumnIndex(col);
          return movieRs!.isColumnNull(i) ? undefined : movieRs!.getLong(i);
        };
        const dbl = (col: string): number | undefined => {
          const i = movieRs!.getColumnIndex(col);
          return movieRs!.isColumnNull(i) ? undefined : movieRs!.getDouble(i);
        };
        const scrapedAt = movieRs.getLong(movieRs.getColumnIndex('scraped_at'));
        const mediaItem: MediaItem = {
          id: movieRs.getLong(movieRs.getColumnIndex('vid')),
          sourceId: movieRs.getLong(movieRs.getColumnIndex('source_id')),
          directoryPath: str('directory_path') ?? '',
          filePath: str('file_path') ?? '',
          fileName: str('file_name') ?? '',
          fileSize: num('file_size'),
          durationMs: num('duration_ms'),
          width: num('width'),
          height: num('height'),
          videoCodec: str('video_codec'),
          audioTracksJson: str('audio_tracks_json'),
          scannedAt: movieRs.getLong(movieRs.getColumnIndex('scanned_at')),
          mediaType: 'movie',
          title: str('title'),
          posterUrl: str('poster_url'),
          posterLocalPath: str('poster_local_path'),
          backdropUrl: str('backdrop_url'),
          rating: dbl('rating'),
          provider: str('provider'),
          providerId: str('provider_id'),
          movieId: num('movie_id')
        };
        const item: MediaListItem = { kind: 'video', video: mediaItem, sortTs: scrapedAt };
        movieItems.push(item);
      }
      movieRs.close(); movieRs = null;

      // ── 未刮削视频（兜底：新增目录扫描后未配置 TMDB Key 或刮削失败的文件） ──
      // 这类文件存在于 videos 表但无 scrape_info 记录，通过 scanned_at 排序保证新扫描文件出现在最前
      const unscrapedSql = `
        SELECT v.id AS vid, v.source_id, v.directory_path, v.file_path, v.file_name,
               v.file_size, v.duration_ms, v.width, v.height, v.video_codec,
               v.audio_tracks_json, v.scanned_at
        FROM ${FileSourceDatabase.TABLE_VIDEOS} v
        WHERE NOT EXISTS (
          SELECT 1 FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} si WHERE si.video_id = v.id
        )
        ORDER BY v.scanned_at DESC
        LIMIT ?
      `;
      unscrapedRs = await this.rdbStore.querySql(unscrapedSql, [limit]);
      const unscrapedItems: MediaListItem[] = [];
      while (unscrapedRs.goToNextRow()) {
        const strU = (col: string): string | undefined => {
          const i = unscrapedRs!.getColumnIndex(col);
          return unscrapedRs!.isColumnNull(i) ? undefined : unscrapedRs!.getString(i);
        };
        const numU = (col: string): number | undefined => {
          const i = unscrapedRs!.getColumnIndex(col);
          return unscrapedRs!.isColumnNull(i) ? undefined : unscrapedRs!.getLong(i);
        };
        const uScannedAt = unscrapedRs.getLong(unscrapedRs.getColumnIndex('scanned_at'));
        const uMediaItem: MediaItem = {
          id: unscrapedRs.getLong(unscrapedRs.getColumnIndex('vid')),
          sourceId: unscrapedRs.getLong(unscrapedRs.getColumnIndex('source_id')),
          directoryPath: strU('directory_path') ?? '',
          filePath: strU('file_path') ?? '',
          fileName: strU('file_name') ?? '',
          fileSize: numU('file_size'),
          durationMs: numU('duration_ms'),
          width: numU('width'),
          height: numU('height'),
          videoCodec: strU('video_codec'),
          audioTracksJson: strU('audio_tracks_json'),
          scannedAt: uScannedAt,
        };
        const uListItem: MediaListItem = { kind: 'video', video: uMediaItem, sortTs: uScannedAt };
        unscrapedItems.push(uListItem);
      }
      unscrapedRs.close(); unscrapedRs = null;

      // ── 合并，按 sortTs 倒序，取前 limit 条 ──────────────────
      const combined: MediaListItem[] = [];
      for (const it of tvItems) { combined.push(it); }
      for (const it of movieItems) { combined.push(it); }
      for (const it of unscrapedItems) { combined.push(it); }
      combined.sort((a: MediaListItem, b: MediaListItem) => b.sortTs - a.sortTs);
      const result = combined.slice(0, limit);
      console.info(`[DB][getRecentlyAddedList] TV季=${tvItems.length} 电影=${movieItems.length} 未刮削=${unscrapedItems.length} 合并后=${result.length}`);
      return result;
    } catch (e) {
      console.error('[DB][getRecentlyAddedList] 查询失败', JSON.stringify(e));
      return [];
    } finally {
      tvRs?.close();
      movieRs?.close();
      unscrapedRs?.close();
    }
  }

  /**
   * 判断目录名是否是通用季名，如 Season1/Season 1/S01/第1季/第一季 等
   */
  private isGenericSeasonName(name: string): boolean {
    const lower = name.toLowerCase();
    return lower.startsWith('season') ||
      lower.startsWith('s0') ||
      lower.startsWith('s1') ||
      lower.startsWith('s2') ||
      lower.startsWith('s3') ||
      name.startsWith('第') ||
      lower === 'extras' ||
      lower === 'specials' ||
      lower === 'featurettes';
  }

  /**
   * 把目录名格式化为短季标签显示在卡片上，统一用「第X季」中文格式
   * Season1 / Season 1 → 第1季
   * S01 / S1 → 第1季
   * 第八季 → 第八季（保留中文数字）
   * extras / specials → 特典
   */
  private formatSeasonLabel(dirName: string): string {
    const lower = dirName.toLowerCase().trim();
    // Season N / Season N
    const seasonMatch = lower.match(/^season\s*(\d+)$/);
    if (seasonMatch) {
      return `第${parseInt(seasonMatch[1])}季`;
    }
    // S01 / S1 等
    const sMatch = lower.match(/^s(\d+)$/);
    if (sMatch) {
      return `第${parseInt(sMatch[1])}季`;
    }
    // 第N季（中文数字保留原样）
    if (dirName.startsWith('第') && dirName.endsWith('季')) {
      return dirName;
    }
    // 特典类
    if (lower === 'extras' || lower === 'specials' || lower === 'featurettes') {
      return '特典';
    }
    // 其他直接返回原名（截短）
    return dirName.length > 6 ? dirName.substring(0, 6) : dirName;
  }

  /**
   * 从刮削标题中提取基础剧名，去掉季数后缀，用于首页合并同系列不同季。
   *
   * 处理示例：
   *   "权力的游戏 第七季"  → "权力的游戏"
   *   "Game of Thrones Season 7" → "Game of Thrones"
   *   "The Crown (Season 4)"     → "The Crown"
   *   "Breaking Bad"             → "Breaking Bad"（无变化）
   */
  private extractBaseSeriesTitle(title: string): string {
    if (!title || title.length === 0) { return title; }
    let t = title.trim();

    // 中文：去掉末尾"第X季"（X 为数字或汉字数字）
    // 例："权力的游戏 第七季" / "权力的游戏第3季"
    t = t.replace(/\s*第[零一二三四五六七八九十百\d]+季\s*$/, '').trim();

    // 英文：去掉末尾 Season N / S1 / (Season N) 等
    // 例："Game of Thrones Season 7" / "The Crown (Season 4)"
    t = t.replace(/\s*[\(（]?\s*[Ss]eason\s*\d+\s*[\)）]?\s*$/, '').trim();
    t = t.replace(/\s*[\(（]?\s*[Ss]\d+\s*[\)）]?\s*$/, '').trim();

    // 冒号 + 季名后缀："权力的游戏：第七季" / "Game of Thrones: Season 7"
    t = t.replace(/\s*[：:]\s*第[零一二三四五六七八九十百\d]+季\s*$/, '').trim();
    t = t.replace(/\s*[：:]\s*[Ss]eason\s*\d+\s*$/, '').trim();

    return t.length > 0 ? t : title;
  }

  /** 辅助：取文件路径的直接父目录（去掉最后一段文件名） */
  private getParentDir(filePath: string): string {
    const lastSlash = filePath.lastIndexOf('/');
    if (lastSlash <= 0) {
      return '/';
    }
    return filePath.substring(0, lastSlash);
  }

  /** 查询所有没有刮削数据的视频（scrape_info 为 NULL） */
  private async getUnscrapedMediaItems(): Promise<MediaItem[]> {
    if (this.rdbStore === null) {
      return [];
    }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql = `
        SELECT v.id, v.source_id, v.directory_path, v.file_path, v.file_name,
               v.file_size, v.duration_ms, v.width, v.height, v.video_codec,
               v.audio_tracks_json, v.scanned_at,
               NULL AS provider, NULL AS provider_id, NULL AS media_type,
               NULL AS movie_id, NULL AS tv_series_id, NULL AS episode_id,
               NULL AS season_number, NULL AS episode_number,
               NULL AS scrape_title, NULL AS original_title, NULL AS overview,
               NULL AS release_date, NULL AS rating, NULL AS genres_json,
               NULL AS poster_url, NULL AS backdrop_url,
               NULL AS poster_local_path, NULL AS backdrop_local_path
        FROM ${FileSourceDatabase.TABLE_VIDEOS} v
        WHERE NOT EXISTS (
          SELECT 1 FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} s WHERE s.video_id = v.id
        )
        ORDER BY v.scanned_at DESC
      `;
      rs = await this.rdbStore.querySql(sql);
      const items: MediaItem[] = [];
      while (rs.goToNextRow()) {
        items.push(this.parseMediaItem(rs));
      }
      return items;
    } catch (error) {
      console.error(`[FileSourceDatabase] getUnscrapedMediaItems 失败: ${JSON.stringify(error)}`);
      return [];
    } finally {
      rs?.close();
    }
  }

  /**
   * 获取最近一次扫描时间（videos 表中最大 scanned_at）
   * 返回 0 表示未扫描
   */
  async getLatestScanTime(): Promise<number> {
    if (this.rdbStore === null) {
      return 0;
    }
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await this.rdbStore.querySql(
        `SELECT MAX(scanned_at) AS latest FROM ${FileSourceDatabase.TABLE_VIDEOS}`
      );
      if (rs.goToFirstRow()) {
        const idx = rs.getColumnIndex('latest');
        return rs.isColumnNull(idx) ? 0 : rs.getLong(idx);
      }
      return 0;
    } catch {
      return 0;
    } finally {
      rs?.close();
    }
  }

  static onReady(callback: Callback<emitter.EventData>) {
    if (FileSourceDatabase.instance && FileSourceDatabase.instance.rdbStore) {
      callback({})
    } else {
      emitter.once(FileSourceDatabase.DATABASE_READY, callback)
    }
  }

  // ─────────────────────────────────────────────
  // play_progress 表操作
  // ─────────────────────────────────────────────

  /**
   * 写入或更新播放进度（以 video_id 为唯一键，INSERT OR REPLACE）。
   * 写入失败仅打 warn 日志，不抛出异常，不阻塞播放。
   */
  async upsertPlayProgress(progress: PlayProgressEntity): Promise<void> {
    if (this.rdbStore === null) {
      console.warn('[DB][upsertPlayProgress] DB 未初始化，跳过写入');
      return;
    }
    try {
      const sql = `
        INSERT OR REPLACE INTO ${FileSourceDatabase.TABLE_PLAY_PROGRESS}
          (video_id, series_provider_id, season_number, episode_number,
           position_ms, duration_ms, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      `;
      const args: relationalStore.ValueType[] = [
        progress.videoId,
        progress.seriesProviderId,
        progress.seasonNumber,
        progress.episodeNumber,
        progress.positionMs,
        progress.durationMs,
        progress.updatedAt
      ];
      await this.rdbStore.executeSql(sql, args);
      console.info(
        `[DB][upsertPlayProgress] videoId=${progress.videoId} pos=${progress.positionMs}ms ` +
        `series=${progress.seriesProviderId} s${progress.seasonNumber}e${progress.episodeNumber}`
      );
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][upsertPlayProgress] 写入失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 查询指定视频的播放进度，不存在返回 null。
   */
  async getPlayProgress(videoId: number): Promise<PlayProgressEntity | null> {
    if (this.rdbStore === null) { return null; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_PLAY_PROGRESS);
      pred.equalTo('video_id', videoId);
      rs = await this.rdbStore.query(pred);
      if (rs.goToFirstRow()) {
        return this.parsePlayProgressEntity(rs);
      }
      return null;
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][getPlayProgress] 查询失败 videoId=${videoId} code=${err.code} msg=${err.message}`);
      return null;
    } finally {
      rs?.close();
    }
  }

  /**
   * 批量查询某剧某季的播放进度列表（避免逐集查询）。
   */
  async getPlayProgressBySeriesContext(
    seriesProviderId: string,
    seasonNumber: number
  ): Promise<PlayProgressEntity[]> {
    if (this.rdbStore === null) { return []; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_PLAY_PROGRESS);
      pred.equalTo('series_provider_id', seriesProviderId)
        .and()
        .equalTo('season_number', seasonNumber);
      rs = await this.rdbStore.query(pred);
      const list: PlayProgressEntity[] = [];
      while (rs.goToNextRow()) {
        list.push(this.parsePlayProgressEntity(rs));
      }
      return list;
    } catch (error) {
      const err = error as BusinessError;
      console.warn(
        `[DB][getPlayProgressBySeriesContext] 查询失败 series=${seriesProviderId} s=${seasonNumber} ` +
        `code=${err.code} msg=${err.message}`
      );
      return [];
    } finally {
      rs?.close();
    }
  }

  /**
   * 查询某剧所有进度记录（用于 ContinueWatchingCard 展示最近播放集）。
   */
  async getPlayProgressBySeries(seriesProviderId: string): Promise<PlayProgressEntity[]> {
    if (this.rdbStore === null) { return []; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_PLAY_PROGRESS);
      pred.equalTo('series_provider_id', seriesProviderId).orderByDesc('updated_at');
      rs = await this.rdbStore.query(pred);
      const list: PlayProgressEntity[] = [];
      while (rs.goToNextRow()) {
        list.push(this.parsePlayProgressEntity(rs));
      }
      return list;
    } catch (error) {
      const err = error as BusinessError;
      console.warn(
        `[DB][getPlayProgressBySeries] 查询失败 series=${seriesProviderId} ` +
        `code=${err.code} msg=${err.message}`
      );
      return [];
    } finally {
      rs?.close();
    }
  }

  private parsePlayProgressEntity(rs: relationalStore.ResultSet): PlayProgressEntity {
    const num = (col: string): number => {
      const i = rs.getColumnIndex(col);
      return rs.isColumnNull(i) ? 0 : rs.getLong(i);
    };
    const str = (col: string): string => {
      const i = rs.getColumnIndex(col);
      return rs.isColumnNull(i) ? '' : rs.getString(i);
    };
    return {
      id: num('id'),
      videoId: num('video_id'),
      seriesProviderId: str('series_provider_id'),
      seasonNumber: num('season_number'),
      episodeNumber: num('episode_number'),
      positionMs: num('position_ms'),
      durationMs: num('duration_ms'),
      updatedAt: num('updated_at')
    };
  }

  // ─────────────────────────────────────────────
  // 媒体级播放进度（media_progress 表）
  // ─────────────────────────────────────────────

  /**
   * 写入或更新媒体级播放进度（以 media_key 为主键，INSERT OR REPLACE）。
   * 写入失败仅打 warn，不抛出异常，不阻塞调用方。
   */
  async upsertMediaProgress(entry: MediaProgressEntry): Promise<void> {
    if (this.rdbStore === null) {
      console.warn('[DB][upsertMediaProgress] DB 未初始化，跳过写入');
      return;
    }
    try {
      const sql = `
        INSERT OR REPLACE INTO ${FileSourceDatabase.TABLE_MEDIA_PROGRESS}
          (media_key, position_ms, duration_ms, last_played_at, episode_number, season_number)
        VALUES (?, ?, ?, ?, ?, ?)
      `;
      const args: relationalStore.ValueType[] = [
        entry.mediaKey,
        entry.positionMs,
        entry.durationMs,
        entry.lastPlayedAt,
        entry.episodeNumber,
        entry.seasonNumber
      ];
      await this.rdbStore.executeSql(sql, args);
      console.info(
        `[DB][upsertMediaProgress] key=${entry.mediaKey} pos=${entry.positionMs}ms ` +
        `s${entry.seasonNumber}e${entry.episodeNumber}`
      );
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][upsertMediaProgress] 写入失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 查询媒体级播放进度，不存在返回 null。
   */
  async getMediaProgress(mediaKey: string): Promise<MediaProgressEntry | null> {
    if (this.rdbStore === null) {
      return null;
    }
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_MEDIA_PROGRESS);
      pred.equalTo('media_key', mediaKey);
      const rs = await this.rdbStore.query(pred, [
        'media_key', 'position_ms', 'duration_ms', 'last_played_at',
        'episode_number', 'season_number'
      ]);
      if (!rs.goToFirstRow()) {
        rs.close();
        return null;
      }
      const entry: MediaProgressEntry = {
        mediaKey: rs.getString(rs.getColumnIndex('media_key')),
        positionMs: rs.getLong(rs.getColumnIndex('position_ms')),
        durationMs: rs.getLong(rs.getColumnIndex('duration_ms')),
        lastPlayedAt: rs.getLong(rs.getColumnIndex('last_played_at')),
        episodeNumber: rs.getLong(rs.getColumnIndex('episode_number')),
        seasonNumber: rs.getLong(rs.getColumnIndex('season_number'))
      };
      rs.close();
      return entry;
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][getMediaProgress] 查询失败 code=${err.code} msg=${err.message}`);
      return null;
    }
  }

  /**
   * 删除媒体级播放进度（完播重置）。
   */
  async clearMediaProgress(mediaKey: string): Promise<void> {
    if (this.rdbStore === null) {
      return;
    }
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_MEDIA_PROGRESS);
      pred.equalTo('media_key', mediaKey);
      await this.rdbStore.delete(pred);
      console.info(`[DB][clearMediaProgress] key=${mediaKey} 已清除`);
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][clearMediaProgress] 删除失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 删除指定剧集所有集的进度记录。
   * 匹配所有 media_key 以 media_progress_episode_tmdb_{seriesTmdbId}_ 开头的记录。
   * @param seriesTmdbId 剧集 TMDB ID（如 "1399"），不含下划线等特殊字符
   */
  async clearAllMediaProgressBySeries(seriesTmdbId: string): Promise<void> {
    if (this.rdbStore === null) {
      return;
    }
    if (!/^\d+$/.test(seriesTmdbId)) {
      console.warn(`[DB][clearAllMediaProgressBySeries] 非法 seriesTmdbId: ${seriesTmdbId}`);
      return;
    }
    try {
      // 同时清除新格式（集级 key）和旧格式（整剧级 key），确保历史迁移数据也能被删除
      const episodePrefix = `media_progress_episode_tmdb_${seriesTmdbId}_`;
      const oldKey = `media_progress_series_tmdb_${seriesTmdbId}`;
      const sql =
        `DELETE FROM ${FileSourceDatabase.TABLE_MEDIA_PROGRESS}` +
        ` WHERE media_key LIKE ? OR media_key = ?`;
      await this.rdbStore.executeSql(sql, [`${episodePrefix}%`, oldKey]);
      console.info(`[DB][clearAllMediaProgressBySeries] seriesTmdbId=${seriesTmdbId} 已全部清除（含旧格式）`);
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][clearAllMediaProgressBySeries] 删除失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 查询指定剧集最近播放的一集进度。
   * @param seriesTmdbId 剧集 TMDB ID，如 "1399"
   */
  async getLatestMediaProgressBySeries(seriesTmdbId: string): Promise<MediaProgressEntry | null> {
    if (this.rdbStore === null) {
      return null;
    }
    if (!/^\d+$/.test(seriesTmdbId)) {
      console.warn(`[DB][getLatestMediaProgressBySeries] 非法 seriesTmdbId: ${seriesTmdbId}`);
      return null;
    }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const episodePrefix = `media_progress_episode_tmdb_${seriesTmdbId}_`;
      const oldKey = `media_progress_series_tmdb_${seriesTmdbId}`;
      // 同时查新旧格式，取最近播放的一条
      const sql =
        `SELECT media_key, position_ms, duration_ms, last_played_at, episode_number, season_number` +
        ` FROM ${FileSourceDatabase.TABLE_MEDIA_PROGRESS}` +
        ` WHERE media_key LIKE ? OR media_key = ?` +
        ` ORDER BY last_played_at DESC LIMIT 1`;
      rs = await this.rdbStore.querySql(sql, [`${episodePrefix}%`, oldKey]);
      if (rs.goToNextRow()) {
        const entry: MediaProgressEntry = {
          mediaKey: rs.getString(rs.getColumnIndex('media_key')),
          positionMs: rs.getLong(rs.getColumnIndex('position_ms')),
          durationMs: rs.getLong(rs.getColumnIndex('duration_ms')),
          lastPlayedAt: rs.getLong(rs.getColumnIndex('last_played_at')),
          episodeNumber: rs.getLong(rs.getColumnIndex('episode_number')),
          seasonNumber: rs.getLong(rs.getColumnIndex('season_number')),
        };
        return entry;
      }
      return null;
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[DB][getLatestMediaProgressBySeries] 查询失败 code=${err.code} msg=${err.message}`);
      return null;
    } finally {
      rs?.close();
    }
  }

  /**
   * 查询全部媒体级播放进度，按最近播放时间倒序返回。
   * 用于「继续播放」栏数据源。
   */
  async getAllMediaProgress(limit: number = 40): Promise<MediaProgressEntry[]> {
    if (this.rdbStore === null) {
      return [];
    }
    let rs: relationalStore.ResultSet | null = null;
    try {
      // limit 为数字类型，不存在注入风险；默认 40 用于「继续播放」栏，历史页可传 200
      const sql =
        `SELECT media_key, position_ms, duration_ms, last_played_at, episode_number, season_number` +
        ` FROM ${FileSourceDatabase.TABLE_MEDIA_PROGRESS}` +
        ` ORDER BY last_played_at DESC LIMIT ${limit}`;
      rs = await this.rdbStore.querySql(sql);
      const result: MediaProgressEntry[] = [];
      while (rs.goToNextRow()) {
        const entry: MediaProgressEntry = {
          mediaKey: rs.getString(rs.getColumnIndex('media_key')),
          positionMs: rs.getLong(rs.getColumnIndex('position_ms')),
          durationMs: rs.getLong(rs.getColumnIndex('duration_ms')),
          lastPlayedAt: rs.getLong(rs.getColumnIndex('last_played_at')),
          episodeNumber: rs.getLong(rs.getColumnIndex('episode_number')),
          seasonNumber: rs.getLong(rs.getColumnIndex('season_number')),
        };
        result.push(entry);
      }
      console.info(`[DB][getAllMediaProgress] 共 ${result.length} 条记录`);
      return result;
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[DB][getAllMediaProgress] 查询失败 code=${err.code} msg=${err.message}`);
      return [];
    } finally {
      rs?.close();
    }
  }

  /**
   * 删除指定剧集在 play_progress 表中的进度记录。
   * @param seriesProviderId 剧集 provider ID（如 TMDB ID 字符串）
   */
  async clearPlayProgressBySeries(seriesProviderId: string): Promise<void> {
    if (this.rdbStore === null) {
      return;
    }
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_PLAY_PROGRESS);
      pred.equalTo('series_provider_id', seriesProviderId);
      await this.rdbStore.delete(pred);
      console.info(`[DB][clearPlayProgressBySeries] series=${seriesProviderId} 已清除`);
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][clearPlayProgressBySeries] 失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 清空 play_progress 表全部记录（用于"清除全部历史"场景）。
   */
  async clearAllPlayProgress(): Promise<void> {
    if (this.rdbStore === null) {
      return;
    }
    try {
      await this.rdbStore.executeSql(
        `DELETE FROM ${FileSourceDatabase.TABLE_PLAY_PROGRESS}`
      );
      console.info('[DB][clearAllPlayProgress] 全部已清除');
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][clearAllPlayProgress] 失败 code=${err.code} msg=${err.message}`);
    }
  }

  // ─────────────────────────────────────────────
  // 媒体搜索查询 — Issue #101
  // ─────────────────────────────────────────────

  /**
   * 多条件媒体搜索，支持关键词/类型/类别/评分/年份/排序/分页。
   *
   * - keyword 为空字符串时返回全部（受其余筛选条件约束）
   * - 所有用户输入均通过 ? 参数化，不拼接进 SQL 字符串
   *
   * @param keyword  搜索关键词（标题 / 原始标题模糊匹配）
   * @param options  可选筛选与排序参数，缺省值见各字段注释
   */
  async searchMediaItems(keyword: string, options?: SearchMediaOptions): Promise<MediaItem[]> {
    if (this.rdbStore === null) {
      return [];
    }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const conditions: string[] = [];
      const params: relationalStore.ValueType[] = [];

      // ── 统一 trim keyword，避免含前后空格时无法正确匹配 ──
      const kw: string = keyword.trim();

      // ── keyword 非空时：title / original_title 四字段模糊匹配 ──
      if (kw.length > 0) {
        const kwLike: string = `%${kw}%`;
        conditions.push('(m.title LIKE ? OR m.original_title LIKE ? OR ts.title LIKE ? OR ts.original_title LIKE ?)');
        params.push(kwLike);
        params.push(kwLike);
        params.push(kwLike);
        params.push(kwLike);
      }

      // ── mediaType 过滤（'all' 时不加条件） ──
      // TV 系列整体存为 media_type='tv'，单集存为 media_type='episode'，两者均属电视剧
      // 同时要求 tv_series_id IS NOT NULL，剔除刮削不完整的脏数据（无系列关联的单集）
      const mediaType: string = options?.mediaType ?? 'all';
      if (mediaType === 'tv') {
        conditions.push("(s.media_type IN ('tv', 'episode') AND s.tv_series_id IS NOT NULL)");
      } else if (mediaType !== 'all') {
        conditions.push('s.media_type = ?');
        params.push(mediaType);
      }

      // ── genre 过滤：genres_json 模糊匹配（加表别名避免多表 JOIN 时列名歧义） ──
      if (options?.genre !== undefined && options.genre.length > 0) {
        conditions.push('COALESCE(m.genres_json, ts.genres_json) LIKE ?');
        params.push(`%${options.genre}%`);
      }

      // ── minRating 过滤 ──
      if (options?.minRating !== undefined) {
        conditions.push('COALESCE(m.rating, ts.rating) >= ?');
        params.push(options.minRating);
      }

      // ── yearFrom / yearTo 过滤：十年段区间匹配 ──
      if (options?.yearFrom !== undefined) {
        conditions.push("CAST(substr(COALESCE(m.release_date, ts.first_air_date), 1, 4) AS INTEGER) >= ?");
        params.push(options.yearFrom);
      }
      if (options?.yearTo !== undefined) {
        conditions.push("CAST(substr(COALESCE(m.release_date, ts.first_air_date), 1, 4) AS INTEGER) <= ?");
        params.push(options.yearTo);
      }

      // ── watchProgress 过滤：通过 EXISTS 子查询匹配 media_progress 表 ──
      // 电影 key 格式: media_progress_movie_{s.provider_id}
      // 集级剧集 key 格式: media_progress_episode_tmdb_{ts.provider_id}_s{n}_e{n}
      // 使用 '_s%' 后缀而非 '_%'，避免 provider_id 为前缀子串时误匹配（如 1399 匹配到 13990）
      if (options?.watchProgress === 'unseen') {
        conditions.push(
          `((s.media_type = 'movie' AND NOT EXISTS (` +
            `SELECT 1 FROM ${FileSourceDatabase.TABLE_MEDIA_PROGRESS} mp2 ` +
            `WHERE mp2.media_key = 'media_progress_movie_' || s.provider_id ` +
            `AND mp2.position_ms > 0` +
          `)) OR (s.media_type IN ('tv', 'episode') AND ts.provider_id IS NOT NULL AND NOT EXISTS (` +
            `SELECT 1 FROM ${FileSourceDatabase.TABLE_MEDIA_PROGRESS} mp2 ` +
            `WHERE mp2.media_key LIKE 'media_progress_episode_tmdb_' || ts.provider_id || '_s%' ` +
            `AND mp2.position_ms > 0` +
          `)))`
        );
      } else if (options?.watchProgress === 'partial') {
        conditions.push(
          `((s.media_type = 'movie' AND EXISTS (` +
            `SELECT 1 FROM ${FileSourceDatabase.TABLE_MEDIA_PROGRESS} mp2 ` +
            `WHERE mp2.media_key = 'media_progress_movie_' || s.provider_id ` +
            `AND mp2.position_ms > 0 AND mp2.duration_ms > 0 ` +
            `AND CAST(mp2.position_ms AS REAL) < CAST(mp2.duration_ms AS REAL) * 0.9` +
          `)) OR (s.media_type IN ('tv', 'episode') AND ts.provider_id IS NOT NULL AND EXISTS (` +
            `SELECT 1 FROM ${FileSourceDatabase.TABLE_MEDIA_PROGRESS} mp2 ` +
            `WHERE mp2.media_key LIKE 'media_progress_episode_tmdb_' || ts.provider_id || '_s%' ` +
            `AND mp2.position_ms > 0 AND mp2.duration_ms > 0 ` +
            `AND CAST(mp2.position_ms AS REAL) < CAST(mp2.duration_ms AS REAL) * 0.9` +
          `)))`
        );
      } else if (options?.watchProgress === 'done') {
        conditions.push(
          `((s.media_type = 'movie' AND EXISTS (` +
            `SELECT 1 FROM ${FileSourceDatabase.TABLE_MEDIA_PROGRESS} mp2 ` +
            `WHERE mp2.media_key = 'media_progress_movie_' || s.provider_id ` +
            `AND mp2.duration_ms > 0 ` +
            `AND CAST(mp2.position_ms AS REAL) >= CAST(mp2.duration_ms AS REAL) * 0.9` +
          `)) OR (s.media_type IN ('tv', 'episode') AND ts.provider_id IS NOT NULL AND EXISTS (` +
            `SELECT 1 FROM ${FileSourceDatabase.TABLE_MEDIA_PROGRESS} mp2 ` +
            `WHERE mp2.media_key LIKE 'media_progress_episode_tmdb_' || ts.provider_id || '_s%' ` +
            `AND mp2.duration_ms > 0 ` +
            `AND CAST(mp2.position_ms AS REAL) >= CAST(mp2.duration_ms AS REAL) * 0.9` +
          `)))`
        );
      }

      // ── originCountry 过滤：分别匹配 movies / tv_series 的 origin_country_json ──
      // 用 OR 而非 COALESCE，避免 COALESCE 优先取电影字段导致同行存在 tv_series 国家数据时被屏蔽，
      // 同时保持参数化查询防止 SQL 注入。
      if (options?.originCountry !== undefined && options.originCountry.length > 0) {
        conditions.push('(m.origin_country_json LIKE ? OR ts.origin_country_json LIKE ?)');
        params.push(`%"${options.originCountry}"%`);
        params.push(`%"${options.originCountry}"%`);
      }

      const whereClause: string = conditions.length > 0 ? ` WHERE ${conditions.join(' AND ')}` : '';

      // ── ORDER BY ──
      const sortBy: string = options?.sortBy ?? 'rating';
      let orderClause: string;
      if (sortBy === 'year') {
        orderClause = ' ORDER BY release_date DESC';
      } else if (sortBy === 'title') {
        orderClause = ' ORDER BY COALESCE(m.title, ts.title) ASC';
      } else {
        // 默认：评分降序
        orderClause = ' ORDER BY COALESCE(m.rating, ts.rating) DESC';
      }

      // ── LIMIT 范围校验，防止 NaN/负数/超大值 ──
      const rawLimit: number = options?.limit ?? 50;
      const safeLimit: number = (Number.isInteger(rawLimit) && rawLimit > 0) ? Math.min(rawLimit, 500) : 50;

      // TV 模式：SQL 层直接按 tv_series_id 分组去重，LIMIT 对准唯一 series 数量
      // 非 TV 模式：多拉一批后在内存去重再裁剪（电影 movieId 唯一，冗余极少）
      let groupClause: string;
      let fetchLimit: number;
      if (mediaType === 'tv') {
        groupClause = ' GROUP BY s.tv_series_id';
        fetchLimit = safeLimit;
      } else {
        groupClause = '';
        fetchLimit = Math.min(safeLimit * 10, 2000);
      }
      const limitClause: string = ` LIMIT ${fetchLimit}`;

      const sql: string = this.mediaItemSql + whereClause + groupClause + orderClause + limitClause;
      rs = await this.rdbStore.querySql(sql, params);
      const rawItems: MediaItem[] = [];
      while (rs.goToNextRow()) {
        rawItems.push(this.parseMediaItem(rs));
      }

      // 按 tvSeriesId / movieId 去重，避免同一部剧多集重复展示
      const seen = new Set<string>();
      const items: MediaItem[] = [];
      for (const item of rawItems) {
        let key: string;
        if (item.tvSeriesId !== undefined) {
          key = `tv-${item.tvSeriesId}`;
        } else if (item.movieId !== undefined) {
          key = `mv-${item.movieId}`;
        } else {
          key = `vid-${item.id}`;
        }
        if (!seen.has(key)) {
          seen.add(key);
          items.push(item);
          if (items.length >= safeLimit) { break; }
        }
      }

      // 剔除 tv/episode 类型但缺少系列关联的脏数据（tv_series_id=NULL 导致无标题无海报）
      const displayItems = items.filter((item: MediaItem): boolean => {
        if (item.mediaType === 'episode' || item.mediaType === 'tv') {
          return item.tvSeriesId !== undefined && item.title !== undefined;
        }
        // 剔除完全未刮削的视频（无标题、无海报），此类内容在媒体库中无可识别信息
        if (item.title === undefined && item.posterUrl === undefined && item.posterLocalPath === undefined) {
          return false;
        }
        return true;
      });

      console.info(`[DB][searchMediaItems] keyword=[${kw.length}chars] type=${mediaType} raw=${rawItems.length} deduped=${items.length} display=${displayItems.length}`);
      return displayItems;
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[DB][searchMediaItems] 异常 code=${err.code} msg=${err.message}`);
      return [];
    } finally {
      rs?.close();
    }
  }

  /**
   * 获取所有有效的 genres_json 原始值列表（DISTINCT，升序排列）。
   *
   * genres_json 格式示例：`["剧情","动作"]`
   * 调用方需自行解析 JSON 数组、拆分并去重各类别标签。
   * 此方法仅负责从 DB 获取原始值，不做 JSON 解析。
   */
  async getDistinctGenres(): Promise<string[]> {
    if (this.rdbStore === null) {
      return [];
    }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql: string = `
        SELECT DISTINCT COALESCE(m.genres_json, ts.genres_json) AS genres_json
        FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} s
        LEFT JOIN ${FileSourceDatabase.TABLE_MOVIES} m ON s.movie_id = m.id
        LEFT JOIN ${FileSourceDatabase.TABLE_TV_SERIES} ts ON s.tv_series_id = ts.id
        WHERE COALESCE(m.genres_json, ts.genres_json) IS NOT NULL
        ORDER BY genres_json ASC
      `;
      rs = await this.rdbStore.querySql(sql);
      const result: string[] = [];
      while (rs.goToNextRow()) {
        const g: string = rs.getString(rs.getColumnIndex('genres_json'));
        if (g) {
          result.push(g);
        }
      }
      console.info(`[DB][getDistinctGenres] 共 ${result.length} 条 genres_json 记录`);
      return result;
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[DB][getDistinctGenres] 异常 code=${err.code} msg=${err.message}`);
      return [];
    } finally {
      rs?.close();
    }
  }

  /**
   * 从当前库中提取所有独立 genre 名称（已解析，去重，排序）。
   * @param mediaType 'movie' | 'tv' | undefined（undefined = 全部）
   */
  async getDistinctGenreNames(mediaType?: 'movie' | 'tv'): Promise<string[]> {
    if (this.rdbStore === null) { return []; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      let typeCondition: string = '';
      const typeParams: relationalStore.ValueType[] = [];
      if (mediaType === 'movie') {
        typeCondition = "WHERE s.media_type = 'movie' AND m.genres_json IS NOT NULL";
      } else if (mediaType === 'tv') {
        typeCondition = "WHERE (s.media_type IN ('tv', 'episode')) AND s.tv_series_id IS NOT NULL AND ts.genres_json IS NOT NULL";
      } else {
        typeCondition = 'WHERE COALESCE(m.genres_json, ts.genres_json) IS NOT NULL';
      }
      const sql: string = `
        SELECT COALESCE(m.genres_json, ts.genres_json) AS genres_json
        FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} s
        LEFT JOIN ${FileSourceDatabase.TABLE_MOVIES} m ON s.movie_id = m.id
        LEFT JOIN ${FileSourceDatabase.TABLE_TV_SERIES} ts ON s.tv_series_id = ts.id
        ${typeCondition}
      `;
      rs = await this.rdbStore.querySql(sql, typeParams);
      const nameSet = new Set<string>();
      while (rs.goToNextRow()) {
        const raw: string = rs.getString(rs.getColumnIndex('genres_json'));
        if (raw) {
          try {
            const arr = JSON.parse(raw) as string[];
            for (const name of arr) {
              if (name && name.length > 0) { nameSet.add(name); }
            }
          } catch {
            // 解析失败跳过
          }
        }
      }
      const result: string[] = Array.from(nameSet).sort();
      console.info(`[DB][getDistinctGenreNames] mediaType=${mediaType ?? 'all'} 共 ${result.length} 个 genre`);
      return result;
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[DB][getDistinctGenreNames] 异常 code=${err.code} msg=${err.message}`);
      return [];
    } finally {
      rs?.close();
    }
  }

  // ─────────────────────────────────────────────
  // 搜索历史 CRUD
  // ─────────────────────────────────────────────

  /**
   * 新增或更新搜索历史（upsert by keyword）。
   * 相同关键词重复搜索时，更新 searched_at 为当前时间。
   */
  async upsertSearchHistory(keyword: string): Promise<void> {
    if (this.rdbStore === null) {
      return;
    }
    const now = Date.now();
    try {
      // 标准 SQLite upsert：ON CONFLICT(keyword) DO UPDATE
      await this.rdbStore.executeSql(
        `INSERT INTO ${FileSourceDatabase.TABLE_SEARCH_HISTORY} (keyword, searched_at) VALUES (?, ?)` +
        ` ON CONFLICT(keyword) DO UPDATE SET searched_at = excluded.searched_at`,
        [keyword, now]
      );
      // 裁剪：只保留最近 15 条，防止表无限增长
      await this.rdbStore.executeSql(
        'DELETE FROM search_history WHERE id NOT IN ' +
        '(SELECT id FROM search_history ORDER BY searched_at DESC LIMIT 15)'
      );
      console.info(`[DB][upsertSearchHistory] keyword=[${keyword.length}chars]`);
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[DB][upsertSearchHistory] 失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 获取搜索历史列表，按 searched_at 倒序排列。
   * @param limit 最大返回条数，默认 20
   */
  async getSearchHistory(limit: number = 20): Promise<SearchHistoryEntry[]> {
    if (this.rdbStore === null) {
      return [];
    }
    // 入口校验：防止 NaN / 负数 / 超出合理范围的值
    const safeLimit: number = (Number.isInteger(limit) && limit > 0 && limit <= 50) ? limit : 20;
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await this.rdbStore.querySql(
        `SELECT keyword, searched_at FROM ${FileSourceDatabase.TABLE_SEARCH_HISTORY}` +
        ` ORDER BY searched_at DESC LIMIT ${safeLimit}`
      );
      const result: SearchHistoryEntry[] = [];
      while (rs.goToNextRow()) {
        const entry = new SearchHistoryEntry();
        entry.keyword = rs.getString(rs.getColumnIndex('keyword'));
        entry.searchedAt = rs.getLong(rs.getColumnIndex('searched_at'));
        result.push(entry);
      }
      console.info(`[DB][getSearchHistory] 共 ${result.length} 条记录`);
      return result;
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[DB][getSearchHistory] 查询失败 code=${err.code} msg=${err.message}`);
      return [];
    } finally {
      rs?.close();
    }
  }

  /**
   * 删除单条搜索历史。
   * @param keyword 要删除的关键词
   */
  async deleteSearchHistory(keyword: string): Promise<void> {
    if (this.rdbStore === null) {
      return;
    }
    try {
      await this.rdbStore.executeSql(
        `DELETE FROM ${FileSourceDatabase.TABLE_SEARCH_HISTORY} WHERE keyword = ?`,
        [keyword]
      );
      console.info(`[DB][deleteSearchHistory] keyword=[${keyword.length}chars] 已删除`);
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[DB][deleteSearchHistory] 失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 检查指定 movie 是否已有 origin_country_json。
   */
  async hasMovieOriginCountry(movieId: number): Promise<boolean> {
    if (!this.rdbStore) {
      return false;
    }
    let rs: relationalStore.ResultSet | undefined;
    try {
      rs = await this.rdbStore.querySql('SELECT origin_country_json FROM movies WHERE id = ?', [movieId]);
      if (rs.goToNextRow()) {
        const idx = rs.getColumnIndex('origin_country_json');
        const isNull = rs.isColumnNull(idx);
        return !isNull;
      }
      return false;
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[DB][hasMovieOriginCountry] 失败 code=${err.code} msg=${err.message}`);
      return false;
    } finally {
      rs?.close();
    }
  }

  /**
   * 检查指定 tv_series 是否已有 origin_country_json。
   */
  async hasTvSeriesOriginCountry(seriesId: number): Promise<boolean> {
    if (!this.rdbStore) {
      return false;
    }
    let rs: relationalStore.ResultSet | undefined;
    try {
      rs = await this.rdbStore.querySql('SELECT origin_country_json FROM tv_series WHERE id = ?', [seriesId]);
      if (rs.goToNextRow()) {
        const idx = rs.getColumnIndex('origin_country_json');
        const isNull = rs.isColumnNull(idx);
        return !isNull;
      }
      return false;
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[DB][hasTvSeriesOriginCountry] 失败 code=${err.code} msg=${err.message}`);
      return false;
    } finally {
      rs?.close();
    }
  }

  /**
   * 清空全部搜索历史。
   */
  async clearSearchHistory(): Promise<void> {
    if (this.rdbStore === null) {
      return;
    }
    try {
      await this.rdbStore.executeSql(
        `DELETE FROM ${FileSourceDatabase.TABLE_SEARCH_HISTORY}`
      );
      console.info('[DB][clearSearchHistory] 全部搜索历史已清空');
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[DB][clearSearchHistory] 失败 code=${err.code} msg=${err.message}`);
    }
  }
}




