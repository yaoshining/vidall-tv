import relationalStore from '@ohos.data.relationalStore';
import { Context } from '@ohos.abilityAccessCtrl';
import { toPinyinFull, toPinyinInitials } from '../../utils/PinyinUtil';
import { BusinessError, emitter } from "@kit.BasicServicesKit";
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  DB_VERSION, DEFAULT_DB_NAME, DATABASE_READY,
  TABLE_FILE_SOURCES, TABLE_VIDEO_SERVERS, TABLE_DIRECTORIES, TABLE_VIDEOS, TABLE_SCRAPE_INFO,
  TABLE_MOVIES, TABLE_TV_SERIES, TABLE_TV_SEASONS, TABLE_TV_EPISODES,
  TABLE_PLAY_PROGRESS, TABLE_MEDIA_PROGRESS, TABLE_SEARCH_HISTORY
} from './DbConstants';

// ─────────────────────────────────────────────
// 用于从 raw_json 回填 origin_country_json 的最小解析接口
// ─────────────────────────────────────────────
interface RawMovieJson {
  production_countries?: RawProductionCountry[];
}
interface RawProductionCountry {
  iso_3166_1: string;
}
interface RawTvJson {
  origin_country?: string[];
}

/**
 * 文件源数据库连接核心：持有 rdbStore，负责初始化、schema 创建与版本迁移、
 * 防御性补列、历史数据回填，以及供各 DAO 复用的低层 ResultSet 辅助方法。
 */
export class FileSourceDbCore {
  private static databaseNameOverride: string | null = null;

  private rdbStore: relationalStore.RdbStore | null = null;
  private context: Context | null = null;
  // 防止并发初始化：保存正在进行的 init Promise，供后续调用方直接等待
  private initPromise: Promise<void> | null = null;
  // 是否已完成全部初始化（含 schema 迁移与回填）。区别于 isReady() 的过早 true。
  private fullyReady: boolean = false;

  constructor(context?: Context) {
    if (context) {
      this.context = context;
    }
  }

  /** 测试隔离：设置数据库名覆盖值，随门面单例重置一起生效 */
  static setDatabaseNameOverride(databaseName: string | null): void {
    FileSourceDbCore.databaseNameOverride = databaseName;
  }

  static getDatabaseName(): string {
    return FileSourceDbCore.databaseNameOverride ?? DEFAULT_DB_NAME;
  }

  setContext(context: Context): void {
    this.context = context;
  }

  /** 获取底层 RdbStore，未初始化时抛错（与原 FileSourceDatabase 行为一致） */
  getStore(): relationalStore.RdbStore {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    return this.rdbStore;
  }

  /** 数据库是否已就绪（供门面 onReady 判断）。rdbStore 建立即视为就绪。 */
  isReady(): boolean {
    return this.rdbStore !== null;
  }

  /** 数据库是否已完成 schema 迁移与记录级回填（origin_country）。不含异步拼音回填。 */
  isFullyReady(): boolean {
    return this.fullyReady;
  }

  /**
   * 初始化数据库
   */
  async init(): Promise<void> {
    // 防止并发调用：若已有正在进行的 init，直接等待其完成（成功或失败都会 settle，
    // 供 whenDatabaseReady 复用，避免数据库迁移失败时调用方被永久阻塞）。
    if (this.initPromise !== null) {
      return this.initPromise;
    }

    // rdbStore 在 doInit 早期即被赋值，但迁移/回填仍在进行；此处仅在"已完成"时直接返回，
    // 避免调用方在迁移尚未完成时误认为已就绪。
    if (this.rdbStore !== null) {
      return; // 已经初始化完成
    }

    if (this.context === null) {
      throw new Error('Context is not set');
    }

    this.initPromise = this.doInit(this.context);
    try {
      await this.initPromise;
    } finally {
      this.initPromise = null;
    }
  }

  private async doInit(ctx: Context): Promise<void> {
    try {
      const config: relationalStore.StoreConfig = {
        name: FileSourceDbCore.getDatabaseName(),
        securityLevel: relationalStore.SecurityLevel.S1
      };

      this.rdbStore = await relationalStore.getRdbStore(ctx, config);

      // ── 手动版本管理（PRAGMA user_version）──
      // 读取当前版本
      const verRs = await this.rdbStore.querySql('PRAGMA user_version');
      let currentVersion = 0;
      if (verRs.goToFirstRow()) {
        currentVersion = verRs.getLong(verRs.getColumnIndex('user_version'));
      }
      verRs.close();
      console.info(`FileSourceDatabase: 当前 user_version=${currentVersion}, 目标 version=${DB_VERSION}`);

      if (currentVersion === 0) {
        // 全新安装
        await this.onCreate(this.rdbStore);
      } else if (currentVersion < DB_VERSION) {
        // 需要升级
        await this.onUpgrade(this.rdbStore, currentVersion, DB_VERSION);
      } else {
        // 版本一致，但仍做防御性 schema 补全（应对手动降级/异常情况）
        await this.ensureScrapeInfoSchema(this.rdbStore);
      }

      // 版本不一致时（含旧版和全新安装）也做一次 schema 补全
      if (currentVersion !== DB_VERSION) {
        await this.ensureScrapeInfoSchema(this.rdbStore);
        await this.rdbStore.executeSql(`PRAGMA user_version = ${DB_VERSION}`);
        console.info(`FileSourceDatabase: user_version 已更新为 ${DB_VERSION}`);
      }

      // 防御性 schema 兼容：补齐 videos 扫描更新标记列
      await this.ensureVideosSchema(this.rdbStore);
      // 防御性 schema 兼容：补建媒体核心表，覆盖 user_version 已对齐但历史库缺表的场景
      await this.createMediaTablesV3(this.rdbStore);
      // 防御性 schema 兼容：补建 video_servers 表，覆盖 user_version 已对齐但历史库缺表的场景
      await this.createVideoServersTable(this.rdbStore);

      // 防御性 schema 兼容：补齐 movies/tv_series origin_country_json 列（v7 新增，幂等）
      await this.ensureOriginCountrySchema(this.rdbStore);
      // 防御性 schema 兼容：补齐 tv_series 历史缺失列，避免旧库在读取详情时因列漂移失败
      await this.ensureTvSeriesSchema(this.rdbStore);

      // 防御性修复：确保 provider+provider_id 唯一索引已被移除（v8 起允许多文件源对应同一 TMDB 内容）
      await this.dropScrapeInfoProviderPidIndex(this.rdbStore);

      // 回填历史数据 origin_country_json（await 确保 DATABASE_READY 前数据可用）
      await this.backfillOriginCountryFromRawJson();
      // 回填拼音字段（数据库就绪后异步执行，不阻塞 DATABASE_READY 事件）。
      // 注意：fullyReady 仅表示 schema 迁移/回填(origin_country)完成，不包含此异步拼音回填。
      this.backfillPinyinFields(this.rdbStore!).catch(() => {});
      this.fullyReady = true;
      emitter.emit(DATABASE_READY);
      console.info('FileSourceDatabase: Database initialized successfully');
    } catch (error) {
      console.error('FileSourceDatabase: Failed to initialize database', JSON.stringify(error));
      // 初始化失败：清空状态允许后续重试，且 whenDatabaseReady/await init() 会收到 reject，
      // 避免调用方在 DATABASE_READY 上被永久阻塞。
      this.rdbStore = null;
      this.fullyReady = false;
      throw new Error('Failed to initialize database: ' + JSON.stringify(error));
    }
  }

  private async getLastInsertedRowId(): Promise<number> {
    return this.queryFirstLong('SELECT last_insert_rowid()', []);
  }

  private async querySingleId(sql: string, args: relationalStore.ValueType[]): Promise<number> {
    return this.queryFirstLong(sql, args);
  }

  private async queryFirstLong(sql: string, args: relationalStore.ValueType[]): Promise<number> {
    if (this.rdbStore === null) { return -1; }
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await this.rdbStore.querySql(sql, args);
      if (rs.goToFirstRow()) {
        return rs.getLong(0);
      }
      return -1;
    } catch (e) {
      console.error(`[DB][queryFirstLong] sql=${sql} args=${JSON.stringify(args)} error=${JSON.stringify(e)}`);
      return -1;
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  private getNullableString(rs: relationalStore.ResultSet, index: number): string | undefined {
    try {
      return rs.isColumnNull(index) ? undefined : rs.getString(index);
    } catch (_e) {
      return undefined;
    }
  }

  private getNullableLong(rs: relationalStore.ResultSet, index: number): number | undefined {
    try {
      return rs.isColumnNull(index) ? undefined : rs.getLong(index);
    } catch (_e) {
      return undefined;
    }
  }

  private getNullableDouble(rs: relationalStore.ResultSet, index: number): number | undefined {
    try {
      return rs.isColumnNull(index) ? undefined : rs.getDouble(index);
    } catch (_e) {
      return undefined;
    }
  }

  /** 查询第一列 long 值的便捷方法（供 DAO 复用） */
  async queryFirstLongValue(sql: string, args: relationalStore.ValueType[]): Promise<number> {
    return this.queryFirstLong(sql, args);
  }

  /** 查询单条 id 的便捷方法（供 DAO 复用） */
  async querySingleIdValue(sql: string, args: relationalStore.ValueType[]): Promise<number> {
    return this.querySingleId(sql, args);
  }

  /** 获取最近插入的行 id（供 DAO 复用） */
  async lastInsertedRowId(): Promise<number> {
    return this.getLastInsertedRowId();
  }

  /** 从 ResultSet 安全读取可空字符串（供 DAO 复用） */
  nullableString(rs: relationalStore.ResultSet, index: number): string | undefined {
    return this.getNullableString(rs, index);
  }

  /** 从 ResultSet 安全读取可空长整数（供 DAO 复用） */
  nullableLong(rs: relationalStore.ResultSet, index: number): number | undefined {
    return this.getNullableLong(rs, index);
  }

  /** 从 ResultSet 安全读取可空浮点数（供 DAO 复用） */
  nullableDouble(rs: relationalStore.ResultSet, index: number): number | undefined {
    return this.getNullableDouble(rs, index);
  }

  /**
   * 创建全部表（新安装）
   */
  private async onCreate(rdbStore: relationalStore.RdbStore): Promise<void> {
    try {
      await rdbStore.executeSql(`
        CREATE TABLE IF NOT EXISTS ${TABLE_FILE_SOURCES} (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          type TEXT NOT NULL,
          config_json TEXT NOT NULL,
          created_at INTEGER NOT NULL
        )
      `);
      await rdbStore.executeSql(`
        CREATE TABLE IF NOT EXISTS ${TABLE_DIRECTORIES} (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source_id INTEGER NOT NULL,
          directory_path TEXT NOT NULL,
          custom_name TEXT,
          dir_status TEXT NOT NULL DEFAULT 'active',
          FOREIGN KEY(source_id) REFERENCES ${TABLE_FILE_SOURCES}(id) ON DELETE CASCADE
        )
      `);
      await this.createMediaTablesV3(rdbStore);
      // search_history：持久化搜索关键词，keyword 唯一
      await rdbStore.executeSql(`
        CREATE TABLE IF NOT EXISTS ${TABLE_SEARCH_HISTORY} (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          keyword TEXT NOT NULL,
          searched_at INTEGER NOT NULL,
          UNIQUE(keyword)
        )
      `);
      // video_servers：影视服务器配置（Jellyfin / Emby / Plex）
      await this.createVideoServersTable(rdbStore);
      console.info('FileSourceDatabase: Tables created (v3)');
    } catch (error) {
      console.error('FileSourceDatabase: Failed to create tables', JSON.stringify(error));
      throw new Error('Failed to create tables: ' + JSON.stringify(error));
    }
  }

  /** 创建 v3 全部媒体表 */
  private async createMediaTablesV3(rdbStore: relationalStore.RdbStore): Promise<void> {
    try {
    // videos
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${TABLE_VIDEOS} (
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
        FOREIGN KEY(source_id) REFERENCES ${TABLE_FILE_SOURCES}(id)
      )
    `);
    // movies
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${TABLE_MOVIES} (
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
        title_pinyin TEXT,
        title_initials TEXT,
        UNIQUE(provider, provider_id)
      )
    `);
    // tv_series
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${TABLE_TV_SERIES} (
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
        title_pinyin TEXT,
        title_initials TEXT,
        UNIQUE(provider, provider_id)
      )
    `);
    // tv_seasons
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${TABLE_TV_SEASONS} (
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
        FOREIGN KEY(series_id) REFERENCES ${TABLE_TV_SERIES}(id) ON DELETE CASCADE,
        UNIQUE(series_id, season_number)
      )
    `);
    // tv_episodes
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${TABLE_TV_EPISODES} (
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
        FOREIGN KEY(series_id) REFERENCES ${TABLE_TV_SERIES}(id) ON DELETE CASCADE,
        FOREIGN KEY(season_id) REFERENCES ${TABLE_TV_SEASONS}(id),
        UNIQUE(series_id, season_number, episode_number)
      )
    `);
    // scrape_info（桥表）
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${TABLE_SCRAPE_INFO} (
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
        FOREIGN KEY(video_id) REFERENCES ${TABLE_VIDEOS}(id) ON DELETE CASCADE,
        FOREIGN KEY(movie_id) REFERENCES ${TABLE_MOVIES}(id),
        FOREIGN KEY(tv_series_id) REFERENCES ${TABLE_TV_SERIES}(id),
        FOREIGN KEY(episode_id) REFERENCES ${TABLE_TV_EPISODES}(id)
      )
    `);
    // play_progress（含媒体库上下文关联的播放进度表）
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${TABLE_PLAY_PROGRESS} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        video_id INTEGER NOT NULL,
        series_provider_id TEXT NOT NULL DEFAULT '',
        season_number INTEGER NOT NULL DEFAULT 0,
        episode_number INTEGER NOT NULL DEFAULT 0,
        position_ms INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY(video_id) REFERENCES ${TABLE_VIDEOS}(id) ON DELETE CASCADE,
        UNIQUE(video_id)
      )
    `);
    console.info('FileSourceDatabase: v3 media tables created');

    // media_progress（媒体级播放进度，以 media_key 为主键）
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${TABLE_MEDIA_PROGRESS} (
        media_key TEXT PRIMARY KEY,
        position_ms INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        last_played_at INTEGER NOT NULL,
        episode_number INTEGER NOT NULL DEFAULT 0,
        season_number INTEGER NOT NULL DEFAULT 0,
        is_watched INTEGER NOT NULL DEFAULT 0
      )
    `);
    // 防御性补列：表已存在时补齐 is_watched（幂等，列已存在时忽略）
    try {
      await rdbStore.executeSql(
        `ALTER TABLE ${TABLE_MEDIA_PROGRESS} ADD COLUMN is_watched INTEGER NOT NULL DEFAULT 0`
      );
    } catch (e) {
      // 列已存在时正常忽略
    }
    console.info('FileSourceDatabase: media_progress table created');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `createMediaTablesV3 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }

  /**
   * 创建 video_servers 表（IF NOT EXISTS，供 onCreate / 迁移 / 防御性补表复用）。
   */
  private async createVideoServersTable(rdbStore: relationalStore.RdbStore): Promise<void> {
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${TABLE_VIDEO_SERVERS} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        config_json TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    `);
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
          `DELETE FROM ${TABLE_SCRAPE_INFO} WHERE video_id NOT IN (SELECT id FROM ${TABLE_VIDEOS})`
        );
        currentVersion = 8;
        console.info('[DB] 已迁移到 v8：移除 scrape_info 唯一索引，清理孤立刮削数据');
      }
      if (currentVersion < 9) {
        // v9：file_source_directories 新增 dir_status 列，追踪目录可达性
        try {
          await rdbStore.executeSql(
            `ALTER TABLE ${TABLE_DIRECTORIES} ADD COLUMN dir_status TEXT NOT NULL DEFAULT 'active'`
          );
        } catch (e) {
          // 列已存在时忽略（幂等）
          console.warn('[DB] v9 ALTER TABLE dir_status: 列可能已存在，已忽略', JSON.stringify(e));
        }
        currentVersion = 9;
        console.info('[DB] 已迁移到 v9：file_source_directories 新增 dir_status 列');
      }
      if (currentVersion < 10) {
        // v10：media_progress 新增 is_watched 列，用于完播标记，避免删除进度记录
        try {
          await rdbStore.executeSql(
            `ALTER TABLE ${TABLE_MEDIA_PROGRESS} ADD COLUMN is_watched INTEGER NOT NULL DEFAULT 0`
          );
        } catch (e) {
          // 列已存在时忽略（幂等）
          console.warn('[DB] v10 ALTER TABLE is_watched: 列可能已存在，已忽略', JSON.stringify(e));
        }
        // 回填历史完播数据：position_ms >= duration_ms * 0.95 或剩余 < 60 秒视为已看完
        await rdbStore.executeSql(
          `UPDATE ${TABLE_MEDIA_PROGRESS}` +
          ` SET is_watched = 1` +
          ` WHERE is_watched = 0 AND duration_ms > 0 AND (` +
          `   (duration_ms - position_ms) < 60000 OR` +
          `   CAST(position_ms AS REAL) >= CAST(duration_ms AS REAL) * 0.95` +
          ` )`
        );
        currentVersion = 10;
        console.info('[DB] 已迁移到 v10：media_progress 新增 is_watched 完播标记列，并回填历史完播数据');
      }
      if (currentVersion < 11) {
        // v11：movies / tv_series 新增 title_pinyin / title_initials 拼音字段
        const tables: string[] = ['movies', 'tv_series'];
        for (const tbl of tables) {
          try {
            await rdbStore.executeSql(`ALTER TABLE ${tbl} ADD COLUMN title_pinyin TEXT`);
          } catch (e) {
            console.warn(`[DB] v11 ALTER ${tbl} title_pinyin: 列已存在，已忽略`);
          }
          try {
            await rdbStore.executeSql(`ALTER TABLE ${tbl} ADD COLUMN title_initials TEXT`);
          } catch (e) {
            console.warn(`[DB] v11 ALTER ${tbl} title_initials: 列已存在，已忽略`);
          }
        }
        currentVersion = 11;
        console.info('[DB] 已迁移到 v11：新增拼音字段（回填将在后台异步执行）');
      }
      if (currentVersion < 12) {
        // v12：新增 video_servers 表，存储影视服务器配置
        await this.createVideoServersTable(rdbStore);
        currentVersion = 12;
        console.info('[DB] 已迁移到 v12：新增 video_servers 表');
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
    try {
    const dropOrder: string[] = [
      'scrape_info', 'play_history', 'tv_episodes', 'tv_seasons',
      'videos', 'movies', 'tv_series'
    ];
    for (const t of dropOrder) {
      await rdbStore.executeSql(`DROP TABLE IF EXISTS ${t}`);
      console.info(`FileSourceDatabase: DROP TABLE ${t}`);
    }
    await this.createMediaTablesV3(rdbStore);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `migrateToV4 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }

  /**
   * 迁移至 v5：用带上下文字段的 play_progress 取代 play_history。
   * 复用 createMediaTablesV3 建表，避免与主建表逻辑重复定义。
   */
  private async migrateV4ToV5(rdbStore: relationalStore.RdbStore): Promise<void> {
    try {
    await rdbStore.executeSql(`DROP TABLE IF EXISTS play_history`);
    console.info(`FileSourceDatabase: DROP TABLE play_history`);
    await this.createMediaTablesV3(rdbStore);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `migrateV4ToV5 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }

  /**
   * 迁移至 v6：新增媒体级播放进度表 media_progress，
   * 以及旧版本升级时未自动建立的 search_history 表。
   * 复用 createMediaTablesV3 建表，避免与主建表逻辑重复定义。
   */
  private async migrateV5ToV6(rdbStore: relationalStore.RdbStore): Promise<void> {
    try {
    await this.createMediaTablesV3(rdbStore);
    // 旧版本升级时 onCreate 不再执行，需在此补建 search_history 表
    await rdbStore.executeSql(
      `CREATE TABLE IF NOT EXISTS ${TABLE_SEARCH_HISTORY} (` +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'keyword TEXT NOT NULL, ' +
      'searched_at INTEGER NOT NULL DEFAULT 0, ' +
      'UNIQUE(keyword))'
    );
    console.info(`FileSourceDatabase: CREATE TABLE search_history`);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `migrateV5ToV6 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }

  /** 确保 videos 表存在扫描更新标记列 */
  private async ensureOriginCountrySchema(rdbStore: relationalStore.RdbStore): Promise<void> {
    try {
      await rdbStore.executeSql(
        `ALTER TABLE ${TABLE_MOVIES} ADD COLUMN origin_country_json TEXT`
      );
    } catch {
      // 列已存在时忽略
    }
    try {
      await rdbStore.executeSql(
        `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN origin_country_json TEXT`
      );
    } catch {
      // 列已存在时忽略
    }
  }

  private async ensureTvSeriesSchema(rdbStore: relationalStore.RdbStore): Promise<void> {
    const alterCols: string[] = [
      `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN original_title TEXT`,
      `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN overview TEXT`,
      `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN first_air_date TEXT`,
      `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN rating REAL`,
      `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN vote_count INTEGER`,
      `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN poster_path TEXT`,
      `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN backdrop_path TEXT`,
      `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN poster_url TEXT`,
      `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN backdrop_url TEXT`,
      `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN poster_local_path TEXT`,
      `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN backdrop_local_path TEXT`,
      `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN genres_json TEXT`,
      `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN cast_json TEXT`,
      `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN number_of_seasons INTEGER`,
      `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN original_language TEXT`,
      `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN origin_country_json TEXT`,
      `ALTER TABLE ${TABLE_TV_SERIES} ADD COLUMN raw_json TEXT`
    ];
    for (const sql of alterCols) {
      try {
        await rdbStore.executeSql(sql);
      } catch {
        // 列已存在时忽略
      }
    }
  }

  private async ensureVideosSchema(rdbStore: relationalStore.RdbStore): Promise<void> {
    try {
      await rdbStore.executeSql(
        `ALTER TABLE ${TABLE_VIDEOS} ADD COLUMN updated_in_last_scan INTEGER NOT NULL DEFAULT 0`
      );
    } catch {
      // 列已存在时忽略
    }
  }

  /**
   * 确保 scrape_info 表有 v3 所需的列（旧设备升级兼容）
   * SQLite ALTER TABLE ADD COLUMN 若列已存在会报错，try/catch 忽略即可
   */
  private async ensureScrapeInfoSchema(rdbStore: relationalStore.RdbStore): Promise<void> {
    const alterCols: string[] = [
      `ALTER TABLE ${TABLE_SCRAPE_INFO} ADD COLUMN movie_id INTEGER`,
      `ALTER TABLE ${TABLE_SCRAPE_INFO} ADD COLUMN tv_series_id INTEGER`,
      `ALTER TABLE ${TABLE_SCRAPE_INFO} ADD COLUMN episode_id INTEGER`,
      `ALTER TABLE ${TABLE_SCRAPE_INFO} ADD COLUMN season_number INTEGER`,
      `ALTER TABLE ${TABLE_SCRAPE_INFO} ADD COLUMN episode_number INTEGER`,
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
    // 确保 (tv_series_id, episode_id) 索引存在，供多版本去重查询使用
    try {
      await rdbStore.executeSql(
        `CREATE INDEX IF NOT EXISTS idx_scrape_info_tvs_ep` +
        ` ON ${TABLE_SCRAPE_INFO}(tv_series_id, episode_id)`
      );
    } catch {
      // 索引已存在时忽略
    }
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
   * 从 raw_json 为历史数据回填 origin_country_json。
   *
   * v7 迁移仅添加了列，未对已有数据赋值，导致老数据 origin_country_json=NULL，
   * 地区筛选 LIKE 条件对 NULL 值永远不匹配，选具体地区后结果为空。
   * 本方法在 DB init 后作为后台任务异步执行，补全全部 NULL 行。
   */
  private async backfillOriginCountryFromRawJson(): Promise<void> {
    if (this.rdbStore === null) {
      return;
    }
    let movieUpdated = 0;
    let tvUpdated = 0;
    try {
      // ── 回填 movies：从 raw_json.production_countries[*].iso_3166_1 ──
      let movieRs: relationalStore.ResultSet | null = null;
      try {
        movieRs = await this.rdbStore.querySql(
          `SELECT id, raw_json FROM ${TABLE_MOVIES} WHERE raw_json IS NOT NULL AND (origin_country_json IS NULL OR TRIM(origin_country_json) = '' OR origin_country_json NOT LIKE '%"%')`
        );
        interface MovieRow { id: number; rawJson: string }
        const rows: MovieRow[] = [];
        while (movieRs.goToNextRow()) {
          const id = movieRs.getLong(movieRs.getColumnIndex('id'));
          const rawJson = movieRs.getString(movieRs.getColumnIndex('raw_json'));
          const row: MovieRow = { id, rawJson };
          rows.push(row);
        }
        for (const row of rows) {
          try {
            const parsed = JSON.parse(row.rawJson) as RawMovieJson;
            const countries = parsed.production_countries;
            if (countries && countries.length > 0) {
              const codes: string[] = countries.map((c: RawProductionCountry): string => c.iso_3166_1);
              const countryJson: string = JSON.stringify(codes);
              await this.rdbStore!.executeSql(
                `UPDATE ${TABLE_MOVIES} SET origin_country_json = ? WHERE id = ?`,
                [countryJson, row.id]
              );
              movieUpdated++;
            }
          } catch (e) {
            // 单条 raw_json 格式异常时跳过，不中止整体回填
          }
        }
      } finally {
        try { movieRs?.close(); } catch { }
      }

      // ── 回填 tv_series：从 raw_json.origin_country ──
      let tvRs: relationalStore.ResultSet | null = null;
      try {
        tvRs = await this.rdbStore.querySql(
          `SELECT id, raw_json FROM ${TABLE_TV_SERIES} WHERE raw_json IS NOT NULL AND (origin_country_json IS NULL OR TRIM(origin_country_json) = '' OR origin_country_json NOT LIKE '%"%')`
        );
        interface TvRow { id: number; rawJson: string }
        const tvRows: TvRow[] = [];
        while (tvRs.goToNextRow()) {
          const id = tvRs.getLong(tvRs.getColumnIndex('id'));
          const rawJson = tvRs.getString(tvRs.getColumnIndex('raw_json'));
          const row: TvRow = { id, rawJson };
          tvRows.push(row);
        }
        for (const row of tvRows) {
          try {
            const parsed = JSON.parse(row.rawJson) as RawTvJson;
            const countries = parsed.origin_country;
            if (countries && countries.length > 0) {
              const countryJson: string = JSON.stringify(countries);
              await this.rdbStore!.executeSql(
                `UPDATE ${TABLE_TV_SERIES} SET origin_country_json = ? WHERE id = ?`,
                [countryJson, row.id]
              );
              tvUpdated++;
            }
          } catch (e) {
            // 单条 raw_json 格式异常时跳过
          }
        }
      } finally {
        try { tvRs?.close(); } catch { }
      }

      console.info(`[DB][backfillOriginCountry] 完成：movies=${movieUpdated} tv_series=${tvUpdated}`);
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[DB][backfillOriginCountry] 异常 code=${err.code} msg=${err.message}`);
    }
  }

  private async backfillPinyinFields(rdbStore: relationalStore.RdbStore): Promise<void> {
    const tables: string[] = ['movies', 'tv_series'];
    for (const tbl of tables) {
      // ── 第一步：先将全量行读入内存，关闭 ResultSet ──
      // 避免在游标未关闭时对同一表执行 UPDATE，防止游标失效/锁冲突
      interface PinyinRow { id: number; title: string }
      const rows: PinyinRow[] = [];
      let rs: relationalStore.ResultSet | null = null;
      try {
        rs = await rdbStore.querySql(`SELECT id, title FROM ${tbl} WHERE title IS NOT NULL`);
        while (rs.goToNextRow()) {
          const row: PinyinRow = {
            id: rs.getLong(rs.getColumnIndex('id')),
            title: rs.getString(rs.getColumnIndex('title'))
          };
          rows.push(row);
        }
      } catch (e) {
        const msg: string = (e instanceof Error) ? e.message : String(e);
        console.warn(`[DB] v11 读取 ${tbl} 拼音回填数据失败: ${msg}`);
      } finally {
        try { rs?.close(); } catch { }
      }

      // ── 第二步：ResultSet 已关闭，再批量 UPDATE ──
      try {
        for (const row of rows) {
          const full = toPinyinFull(row.title);
          const initials = toPinyinInitials(row.title);
          await rdbStore.executeSql(
            `UPDATE ${tbl} SET title_pinyin = ?, title_initials = ? WHERE id = ?`,
            [full, initials, row.id]
          );
        }
        console.info(`[DB] v11 回填 ${tbl} 拼音字段完成，共 ${rows.length} 条`);
      } catch (e) {
        const msg: string = (e instanceof Error) ? e.message : String(e);
        console.warn(`[DB] v11 回填 ${tbl} 失败: ${msg}`);
      }
    }
  }
}
