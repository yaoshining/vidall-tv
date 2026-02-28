import relationalStore from '@ohos.data.relationalStore';
import { Context } from '@ohos.abilityAccessCtrl';
import { FileSource, FileSourceDirectory, FileSourceType } from '../models/FileSourceEntity';
import { VideoEntity, ScrapeInfoEntity, MediaItem, MediaStats, SeriesGroup, PlayHistoryEntity } from '../models/MediaEntity';
import { CryptoUtil } from '../../utils/CryptoUtil';
import { emitter } from "@kit.BasicServicesKit";

/**
 * 文件源数据库管理类
 * 使用单例模式管理关系型数据库
 */
export class FileSourceDatabase {
  // 数据库常量
  private static readonly DB_VERSION = 2;
  private static readonly DB_NAME = 'FILE_SOURCES_DB';
  private static readonly TABLE_FILE_SOURCES = 'file_sources';
  private static readonly TABLE_DIRECTORIES = 'file_source_directories';
  private static readonly TABLE_VIDEOS = 'videos';
  private static readonly TABLE_SCRAPE_INFO = 'scrape_info';
  private static readonly TABLE_PLAY_HISTORY = 'play_history';
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
      emitter.emit(FileSourceDatabase.DATABASE_READY)

      // 创建表
      await this.onCreate(this.rdbStore);

      console.info('FileSourceDatabase: Database initialized successfully');
    } catch (error) {
      console.error('FileSourceDatabase: Failed to initialize database', JSON.stringify(error));
      throw new Error('Failed to initialize database: ' + JSON.stringify(error));
    }
  }

  /**
   * 创建表结构（新安装直接建全部 5 张表）
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
          FOREIGN KEY(source_id) REFERENCES ${FileSourceDatabase.TABLE_FILE_SOURCES}(id) ON DELETE CASCADE
        )
      `);
      await this.createMediaTables(rdbStore);
      console.info('FileSourceDatabase: Tables created successfully');
    } catch (error) {
      console.error('FileSourceDatabase: Failed to create tables', JSON.stringify(error));
      throw new Error('Failed to create tables: ' + JSON.stringify(error));
    }
  }

  /** 创建 v2 媒体三张表（onCreate 和 onUpgrade 共用） */
  private async createMediaTables(rdbStore: relationalStore.RdbStore): Promise<void> {
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
        scanned_at INTEGER NOT NULL,
        FOREIGN KEY(source_id) REFERENCES ${FileSourceDatabase.TABLE_FILE_SOURCES}(id)
      )
    `);
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${FileSourceDatabase.TABLE_SCRAPE_INFO} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        video_id INTEGER NOT NULL UNIQUE,
        provider TEXT NOT NULL,
        provider_id TEXT NOT NULL,
        media_type TEXT NOT NULL,
        title TEXT NOT NULL,
        original_title TEXT,
        overview TEXT,
        release_date TEXT,
        rating REAL,
        genres_json TEXT,
        cast_json TEXT,
        directors_json TEXT,
        poster_url TEXT,
        backdrop_url TEXT,
        poster_local_path TEXT,
        backdrop_local_path TEXT,
        scraped_at INTEGER NOT NULL,
        raw_json TEXT,
        FOREIGN KEY(video_id) REFERENCES ${FileSourceDatabase.TABLE_VIDEOS}(id) ON DELETE CASCADE
      )
    `);
    await rdbStore.executeSql(`
      CREATE TABLE IF NOT EXISTS ${FileSourceDatabase.TABLE_PLAY_HISTORY} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        video_id INTEGER NOT NULL,
        position_ms INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY(video_id) REFERENCES ${FileSourceDatabase.TABLE_VIDEOS}(id) ON DELETE CASCADE
      )
    `);
    console.info('FileSourceDatabase: Media tables created successfully');
  }

  /**
   * 数据库版本升级处理
   */
  private async onUpgrade(rdbStore: relationalStore.RdbStore, oldVersion: number, newVersion: number): Promise<void> {
    console.info(`FileSourceDatabase: Upgrading database from version ${oldVersion} to ${newVersion}`);
    try {
      switch (oldVersion) {
        case 1:
          await this.createMediaTables(rdbStore);
          break;
        default:
          console.warn(`FileSourceDatabase: No upgrade path defined for version ${oldVersion}`);
          break;
      }
      console.info('FileSourceDatabase: Database upgraded successfully');
    } catch (error) {
      console.error('FileSourceDatabase: Failed to upgrade database', JSON.stringify(error));
      throw new Error('Failed to upgrade database: ' + JSON.stringify(error));
    }
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

    try {
      const predicates = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_FILE_SOURCES);
      predicates.equalTo('id', id);

      const resultSet = await this.rdbStore.query(predicates);

      if (resultSet.goToFirstRow()) {
        const fileSource = await this.parseFileSource(resultSet);
        resultSet.close();
        return fileSource;
      }

      resultSet.close();
      return null;
    } catch (error) {
      console.error('FileSourceDatabase: Failed to get file source by id', JSON.stringify(error));
      throw new Error('Failed to get file source by id: ' + JSON.stringify(error));
    }
  }

  /**
   * 获取所有文件源
   */
  async getAllFileSources(): Promise<FileSource[]> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }

    try {
      const predicates = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_FILE_SOURCES);
      const resultSet = await this.rdbStore.query(predicates);

      const fileSources: FileSource[] = [];
      while (resultSet.goToNextRow()) {
        const fileSource = await this.parseFileSource(resultSet);
        fileSources.push(fileSource);
      }

      resultSet.close();
      console.info(`FileSourceDatabase: Retrieved ${fileSources.length} file source(s)`);
      return fileSources;
    } catch (error) {
      console.error('FileSourceDatabase: Failed to get all file sources', JSON.stringify(error));
      throw new Error('Failed to get all file sources: ' + JSON.stringify(error));
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
          custom_name: dir.customName ?? null
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
   * 查询指定文件源的所有目录关联
   */
  async getDirectoriesBySourceId(sourceId: number): Promise<FileSourceDirectory[]> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }

    try {
      const predicates = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_DIRECTORIES);
      predicates.equalTo('source_id', sourceId);

      const resultSet = await this.rdbStore.query(predicates);

      const directories: FileSourceDirectory[] = [];
      while (resultSet.goToNextRow()) {
        const id = resultSet.getLong(resultSet.getColumnIndex('id'));
        const sourceIdVal = resultSet.getLong(resultSet.getColumnIndex('source_id'));
        const directoryPath = resultSet.getString(resultSet.getColumnIndex('directory_path'));
        const customNameIdx = resultSet.getColumnIndex('custom_name');
        const customName = resultSet.isColumnNull(customNameIdx) ? undefined : resultSet.getString(customNameIdx);

        directories.push({
          id: id,
          sourceId: sourceIdVal,
          directoryPath: directoryPath,
          customName: customName
        });
      }

      resultSet.close();
      console.info(`FileSourceDatabase: Retrieved ${directories.length} directory(ies) for source ${sourceId}`);
      return directories;
    } catch (error) {
      console.error('FileSourceDatabase: Failed to get directories', JSON.stringify(error));
      throw new Error('Failed to get directories: ' + JSON.stringify(error));
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
      // 先查是否存在
      const existing = await this.getVideoByPath(entity.filePath);
      const bucket: relationalStore.ValuesBucket = {
        source_id: entity.sourceId,
        directory_path: entity.directoryPath,
        file_path: entity.filePath,
        file_name: entity.fileName,
        file_size: entity.fileSize ?? null,
        last_modified: entity.lastModified ?? null,
        content_type: entity.contentType ?? null,
        duration_ms: entity.durationMs ?? null,
        width: entity.width ?? null,
        height: entity.height ?? null,
        frame_rate: entity.frameRate ?? null,
        video_codec: entity.videoCodec ?? null,
        audio_tracks_json: entity.audioTracksJson ?? null,
        subtitle_tracks_json: entity.subtitleTracksJson ?? null,
        scanned_at: entity.scannedAt
      };

      if (existing && existing.id !== undefined) {
        const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_VIDEOS);
        pred.equalTo('id', existing.id);
        await this.rdbStore.update(bucket, pred);
        console.info(`[FileSourceDatabase] upsertVideo UPDATE id=${existing.id} path=${entity.filePath}`);
        return existing.id;
      } else {
        const rowId = await this.rdbStore.insert(FileSourceDatabase.TABLE_VIDEOS, bucket);
        console.info(`[FileSourceDatabase] upsertVideo INSERT id=${rowId} path=${entity.filePath}`);
        return rowId;
      }
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
      const rs = await this.rdbStore.query(pred);
      if (rs.goToFirstRow()) {
        const entity = this.parseVideoEntity(rs);
        rs.close();
        return entity;
      }
      rs.close();
      return null;
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
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_VIDEOS);
      pred.equalTo('source_id', sourceId);
      const rs = await this.rdbStore.query(pred);
      const list: VideoEntity[] = [];
      while (rs.goToNextRow()) {
        list.push(this.parseVideoEntity(rs));
      }
      rs.close();
      return list;
    } catch (error) {
      console.error(`[FileSourceDatabase] getVideosBySourceId 失败: ${JSON.stringify(error)}`);
      return [];
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
      scannedAt: get('scanned_at')
    };
  }

  // ─────────────────────────────────────────────
  // scrape_info 表操作
  // ─────────────────────────────────────────────

  /** 插入或更新刮削信息（以 video_id 为唯一键） */
  async upsertScrapeInfo(entity: ScrapeInfoEntity): Promise<void> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    try {
      const existing = await this.getScrapeInfoByVideoId(entity.videoId);
      const bucket: relationalStore.ValuesBucket = {
        video_id: entity.videoId,
        provider: entity.provider,
        provider_id: entity.providerId,
        media_type: entity.mediaType,
        title: entity.title,
        original_title: entity.originalTitle ?? null,
        overview: entity.overview ?? null,
        release_date: entity.releaseDate ?? null,
        rating: entity.rating ?? null,
        genres_json: entity.genresJson ?? null,
        cast_json: entity.castJson ?? null,
        directors_json: entity.directorsJson ?? null,
        poster_url: entity.posterUrl ?? null,
        backdrop_url: entity.backdropUrl ?? null,
        poster_local_path: entity.posterLocalPath ?? null,
        backdrop_local_path: entity.backdropLocalPath ?? null,
        scraped_at: entity.scrapedAt,
        raw_json: entity.rawJson ?? null
      };

      if (existing && existing.id !== undefined) {
        const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_SCRAPE_INFO);
        pred.equalTo('id', existing.id);
        await this.rdbStore.update(bucket, pred);
        console.info(`[FileSourceDatabase] upsertScrapeInfo UPDATE videoId=${entity.videoId} title="${entity.title}"`);
      } else {
        await this.rdbStore.insert(FileSourceDatabase.TABLE_SCRAPE_INFO, bucket);
        console.info(`[FileSourceDatabase] upsertScrapeInfo INSERT videoId=${entity.videoId} title="${entity.title}"`);
      }
    } catch (error) {
      console.error(`[FileSourceDatabase] upsertScrapeInfo 失败: ${JSON.stringify(error)}`);
      throw new Error('upsertScrapeInfo failed: ' + JSON.stringify(error));
    }
  }

  /** 按 videoId 查询刮削信息 */
  async getScrapeInfoByVideoId(videoId: number): Promise<ScrapeInfoEntity | null> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_SCRAPE_INFO);
      pred.equalTo('video_id', videoId);
      const rs = await this.rdbStore.query(pred);
      if (rs.goToFirstRow()) {
        const entity = this.parseScrapeInfoEntity(rs);
        rs.close();
        return entity;
      }
      rs.close();
      return null;
    } catch (error) {
      console.error(`[FileSourceDatabase] getScrapeInfoByVideoId 失败: ${JSON.stringify(error)}`);
      return null;
    }
  }

  private parseScrapeInfoEntity(rs: relationalStore.ResultSet): ScrapeInfoEntity {
    const get = (col: string): number => rs.getLong(rs.getColumnIndex(col));
    const str = (col: string): string | undefined => {
      const idx = rs.getColumnIndex(col);
      return rs.isColumnNull(idx) ? undefined : rs.getString(idx);
    };
    const dbl = (col: string): number | undefined => {
      const idx = rs.getColumnIndex(col);
      return rs.isColumnNull(idx) ? undefined : rs.getDouble(idx);
    };
    return {
      id: get('id'),
      videoId: get('video_id'),
      provider: rs.getString(rs.getColumnIndex('provider')),
      providerId: rs.getString(rs.getColumnIndex('provider_id')),
      mediaType: rs.getString(rs.getColumnIndex('media_type')),
      title: rs.getString(rs.getColumnIndex('title')),
      originalTitle: str('original_title'),
      overview: str('overview'),
      releaseDate: str('release_date'),
      rating: dbl('rating'),
      genresJson: str('genres_json'),
      castJson: str('cast_json'),
      directorsJson: str('directors_json'),
      posterUrl: str('poster_url'),
      backdropUrl: str('backdrop_url'),
      posterLocalPath: str('poster_local_path'),
      backdropLocalPath: str('backdrop_local_path'),
      scrapedAt: get('scraped_at'),
      rawJson: str('raw_json')
    };
  }

  // ─────────────────────────────────────────────
  // 媒体库查询（videos JOIN scrape_info）
  // ─────────────────────────────────────────────

  /**
   * 查询所有视频（含刮削信息，LEFT JOIN），按 scanned_at 倒序
   */
  async getAllMediaItems(): Promise<MediaItem[]> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    try {
      const sql = `
        SELECT v.*, s.provider, s.provider_id, s.media_type, s.title AS scrape_title,
               s.original_title, s.overview, s.release_date, s.rating,
               s.genres_json, s.poster_url, s.backdrop_url,
               s.poster_local_path, s.backdrop_local_path, s.scraped_at
        FROM ${FileSourceDatabase.TABLE_VIDEOS} v
        LEFT JOIN ${FileSourceDatabase.TABLE_SCRAPE_INFO} s ON v.id = s.video_id
        ORDER BY v.scanned_at DESC
      `;
      const rs = await this.rdbStore.querySql(sql);
      const items: MediaItem[] = [];
      while (rs.goToNextRow()) {
        items.push(this.parseMediaItem(rs));
      }
      rs.close();
      console.info(`[FileSourceDatabase] getAllMediaItems: ${items.length} 条`);
      return items;
    } catch (error) {
      console.error(`[FileSourceDatabase] getAllMediaItems 失败: ${JSON.stringify(error)}`);
      return [];
    }
  }

  /**
   * 按媒体类型查询（movie / tv）
   */
  async getMediaItemsByType(mediaType: string): Promise<MediaItem[]> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    try {
      const sql = `
        SELECT v.*, s.provider, s.provider_id, s.media_type, s.title AS scrape_title,
               s.original_title, s.overview, s.release_date, s.rating,
               s.genres_json, s.poster_url, s.backdrop_url,
               s.poster_local_path, s.backdrop_local_path, s.scraped_at
        FROM ${FileSourceDatabase.TABLE_VIDEOS} v
        INNER JOIN ${FileSourceDatabase.TABLE_SCRAPE_INFO} s ON v.id = s.video_id
        WHERE s.media_type = ?
        ORDER BY v.scanned_at DESC
      `;
      const rs = await this.rdbStore.querySql(sql, [mediaType]);
      const items: MediaItem[] = [];
      while (rs.goToNextRow()) {
        items.push(this.parseMediaItem(rs));
      }
      rs.close();
      return items;
    } catch (error) {
      console.error(`[FileSourceDatabase] getMediaItemsByType 失败: ${JSON.stringify(error)}`);
      return [];
    }
  }

  /**
   * 查询所有有刮削数据的视频，按评分倒序
   */
  async getMediaItemsByRating(): Promise<MediaItem[]> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    try {
      const sql = `
        SELECT v.*, s.provider, s.provider_id, s.media_type, s.title AS scrape_title,
               s.original_title, s.overview, s.release_date, s.rating,
               s.genres_json, s.poster_url, s.backdrop_url,
               s.poster_local_path, s.backdrop_local_path, s.scraped_at
        FROM ${FileSourceDatabase.TABLE_VIDEOS} v
        INNER JOIN ${FileSourceDatabase.TABLE_SCRAPE_INFO} s ON v.id = s.video_id
        WHERE s.rating IS NOT NULL
        ORDER BY s.rating DESC
      `;
      const rs = await this.rdbStore.querySql(sql);
      const items: MediaItem[] = [];
      while (rs.goToNextRow()) {
        items.push(this.parseMediaItem(rs));
      }
      rs.close();
      return items;
    } catch (error) {
      console.error(`[FileSourceDatabase] getMediaItemsByRating 失败: ${JSON.stringify(error)}`);
      return [];
    }
  }

  /**
   * 查询所有不重复的上映年份列表（倒序）
   */
  async getDistinctReleaseYears(): Promise<string[]> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    try {
      const sql = `
        SELECT DISTINCT substr(s.release_date, 1, 4) AS year
        FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} s
        WHERE s.release_date IS NOT NULL AND length(s.release_date) >= 4
        ORDER BY year DESC
      `;
      const rs = await this.rdbStore.querySql(sql);
      const years: string[] = [];
      while (rs.goToNextRow()) {
        const y = rs.getString(rs.getColumnIndex('year'));
        if (y) {
          years.push(y);
        }
      }
      rs.close();
      return years;
    } catch (error) {
      console.error(`[FileSourceDatabase] getDistinctReleaseYears 失败: ${JSON.stringify(error)}`);
      return [];
    }
  }

  /**
   * 按上映年份查询视频
   */
  async getMediaItemsByYear(year: string): Promise<MediaItem[]> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    try {
      const sql = `
        SELECT v.*, s.provider, s.provider_id, s.media_type, s.title AS scrape_title,
               s.original_title, s.overview, s.release_date, s.rating,
               s.genres_json, s.poster_url, s.backdrop_url,
               s.poster_local_path, s.backdrop_local_path, s.scraped_at
        FROM ${FileSourceDatabase.TABLE_VIDEOS} v
        INNER JOIN ${FileSourceDatabase.TABLE_SCRAPE_INFO} s ON v.id = s.video_id
        WHERE substr(s.release_date, 1, 4) = ?
        ORDER BY s.release_date DESC
      `;
      const rs = await this.rdbStore.querySql(sql, [year]);
      const items: MediaItem[] = [];
      while (rs.goToNextRow()) {
        items.push(this.parseMediaItem(rs));
      }
      rs.close();
      return items;
    } catch (error) {
      console.error(`[FileSourceDatabase] getMediaItemsByYear 失败: ${JSON.stringify(error)}`);
      return [];
    }
  }

  /**
   * 统计各类型数量
   */
  async getMediaStats(): Promise<MediaStats> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    try {
      const totalRs = await this.rdbStore.querySql(
        `SELECT COUNT(*) AS cnt FROM ${FileSourceDatabase.TABLE_VIDEOS}`
      );
      totalRs.goToFirstRow();
      const total = totalRs.getLong(totalRs.getColumnIndex('cnt'));
      totalRs.close();

      const movieRs = await this.rdbStore.querySql(
        `SELECT COUNT(*) AS cnt FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} WHERE media_type = 'movie'`
      );
      movieRs.goToFirstRow();
      const movies = movieRs.getLong(movieRs.getColumnIndex('cnt'));
      movieRs.close();

      const tvRs = await this.rdbStore.querySql(
        `SELECT COUNT(*) AS cnt FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} WHERE media_type = 'tv'`
      );
      tvRs.goToFirstRow();
      const tv = tvRs.getLong(tvRs.getColumnIndex('cnt'));
      tvRs.close();

      const scrapedRs = await this.rdbStore.querySql(
        `SELECT COUNT(*) AS cnt FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO}`
      );
      scrapedRs.goToFirstRow();
      const scraped = scrapedRs.getLong(scrapedRs.getColumnIndex('cnt'));
      scrapedRs.close();

      return {
        total,
        movies,
        tv,
        other: total - scraped
      };
    } catch (error) {
      console.error(`[FileSourceDatabase] getMediaStats 失败: ${JSON.stringify(error)}`);
      const stats: MediaStats = { total: 0, movies: 0, tv: 0, other: 0 };
      return stats;
    }
  }

  private parseMediaItem(rs: relationalStore.ResultSet): MediaItem {
    const getL = (col: string): number => {
      const idx = rs.getColumnIndex(col);
      return idx >= 0 && !rs.isColumnNull(idx) ? rs.getLong(idx) : 0;
    };
    const str = (col: string): string | undefined => {
      const idx = rs.getColumnIndex(col);
      return idx >= 0 && !rs.isColumnNull(idx) ? rs.getString(idx) : undefined;
    };
    const dbl = (col: string): number | undefined => {
      const idx = rs.getColumnIndex(col);
      return idx >= 0 && !rs.isColumnNull(idx) ? rs.getDouble(idx) : undefined;
    };
    return {
      // videos 字段
      id: getL('id'),
      sourceId: getL('source_id'),
      directoryPath: rs.getString(rs.getColumnIndex('directory_path')),
      filePath: rs.getString(rs.getColumnIndex('file_path')),
      fileName: rs.getString(rs.getColumnIndex('file_name')),
      fileSize: str('file_size') !== undefined ? getL('file_size') : undefined,
      durationMs: str('duration_ms') !== undefined ? getL('duration_ms') : undefined,
      width: str('width') !== undefined ? getL('width') : undefined,
      height: str('height') !== undefined ? getL('height') : undefined,
      videoCodec: str('video_codec'),
      scannedAt: getL('scanned_at'),
      // scrape_info 字段
      provider: str('provider'),
      providerId: str('provider_id'),
      mediaType: str('media_type'),
      title: str('scrape_title'),
      originalTitle: str('original_title'),
      overview: str('overview'),
      releaseDate: str('release_date'),
      rating: dbl('rating'),
      genresJson: str('genres_json'),
      posterUrl: str('poster_url'),
      backdropUrl: str('backdrop_url'),
      posterLocalPath: str('poster_local_path'),
      backdropLocalPath: str('backdrop_local_path'),
    };
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
      const scrapedTv = await this.getMediaItemsByType('tv');
      const unscrapedAll = await this.getUnscrapedMediaItems();

      const providerMap = new Map<string, MediaItem[]>();

      // ── 有刮削 tv：以 provider::providerId 聚合 ──
      for (const item of scrapedTv) {
        const key = `scraped::${item.provider ?? ''}::${item.providerId ?? ''}`;
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

      // 只有同目录 >= 2 个文件才算合集
      const unscrapedEntries: string[] = [];
      unscrapedMap.forEach((_v: MediaItem[], k: string) => {
        unscrapedEntries.push(k);
      });
      for (const parentDir of unscrapedEntries) {
        const items = unscrapedMap.get(parentDir);
        if (items !== undefined && items.length >= 2) {
          providerMap.set(`unscraped::${parentDir}`, items);
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

        // 合集标题 + 季标签
        let groupTitle: string;
        let seasonLabel: string | undefined = undefined;
        if (first.title) {
          // 有刮削，直接用 scrape title，暂无季信息
          groupTitle = first.title;
        } else {
          const parentDir = this.getParentDir(first.filePath);
          const segments = parentDir.split('/').filter((s: string) => s.length > 0);
          const lastSeg = segments.length > 0 ? segments[segments.length - 1] : '';
          const dirName = lastSeg ?? '';
          if (this.isGenericSeasonName(dirName) && segments.length >= 2) {
            // 父目录是季名：剧名取上级，季标签保留目录名并格式化
            const parentSeg = segments[segments.length - 2];
            groupTitle = parentSeg ?? dirName;
            seasonLabel = this.formatSeasonLabel(dirName);
          } else {
            groupTitle = dirName.length > 0 ? dirName : first.fileName;
          }
        }
        void key;

        const group: SeriesGroup = {
          title: groupTitle,
          seasonLabel,
          posterUrl: first.posterUrl,
          posterLocalPath: first.posterLocalPath,
          rating: first.rating,
          episodeCount: items.length,
          episodes: items,
          latestScannedAt
        };
        groups.push(group);
      }

      groups.sort((a, b) => b.latestScannedAt - a.latestScannedAt);
      console.info(
        `[FileSourceDatabase] getSeriesGroups: ${groups.length} 组` +
        `（有刮削 tv=${scrapedTv.length} 集，无刮削候选=${unscrapedAll.length} 个）`
      );
      return groups;
    } catch (error) {
      console.error(`[FileSourceDatabase] getSeriesGroups 失败: ${JSON.stringify(error)}`);
      return [];
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
   * 把目录名格式化为短季标签显示在卡片上
   * Season1 / Season 1 → S1
   * S01 / S1 → S1
   * 第八季 → 第8季（保留中文）
   * extras / specials → 特典
   */
  private formatSeasonLabel(dirName: string): string {
    const lower = dirName.toLowerCase().trim();
    // Season N / Season N
    const seasonMatch = lower.match(/^season\s*(\d+)$/);
    if (seasonMatch) {
      return `S${seasonMatch[1]}`;
    }
    // S01 / S1 等
    const sMatch = lower.match(/^s(\d+)$/);
    if (sMatch) {
      const n = parseInt(sMatch[1]);
      return `S${n}`;
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
    try {
      const sql = `
        SELECT v.*, NULL AS provider, NULL AS provider_id, NULL AS media_type,
               NULL AS scrape_title, NULL AS original_title, NULL AS overview,
               NULL AS release_date, NULL AS rating, NULL AS genres_json,
               NULL AS poster_url, NULL AS backdrop_url,
               NULL AS poster_local_path, NULL AS backdrop_local_path,
               NULL AS scraped_at
        FROM ${FileSourceDatabase.TABLE_VIDEOS} v
        WHERE NOT EXISTS (
          SELECT 1 FROM ${FileSourceDatabase.TABLE_SCRAPE_INFO} s WHERE s.video_id = v.id
        )
        ORDER BY v.scanned_at DESC
      `;
      const rs = await this.rdbStore.querySql(sql);
      const items: MediaItem[] = [];
      while (rs.goToNextRow()) {
        items.push(this.parseMediaItem(rs));
      }
      rs.close();
      return items;
    } catch (error) {
      console.error(`[FileSourceDatabase] getUnscrapedMediaItems 失败: ${JSON.stringify(error)}`);
      return [];
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
    try {
      const rs = await this.rdbStore.querySql(
        `SELECT MAX(scanned_at) AS latest FROM ${FileSourceDatabase.TABLE_VIDEOS}`
      );
      if (rs.goToFirstRow()) {
        const idx = rs.getColumnIndex('latest');
        const val = rs.isColumnNull(idx) ? 0 : rs.getLong(idx);
        rs.close();
        return val;
      }
      rs.close();
      return 0;
    } catch {
      return 0;
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
  // play_history 表操作
  // ─────────────────────────────────────────────

  /**
   * 插入或更新播放历史（以 video_id 为唯一键）
   */
  async upsertPlayHistory(entity: PlayHistoryEntity): Promise<void> {
    if (this.rdbStore === null) {
      console.error('[FileSourceDatabase] upsertPlayHistory 失败: Database not initialized');
      return;
    }
    try {
      const existing = await this.getPlayHistoryByVideoId(entity.videoId);
      const bucket: relationalStore.ValuesBucket = {
        video_id: entity.videoId,
        position_ms: entity.positionMs,
        duration_ms: entity.durationMs,
        updated_at: entity.updatedAt
      };

      if (existing && existing.id !== undefined) {
        const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_PLAY_HISTORY);
        pred.equalTo('id', existing.id);
        await this.rdbStore.update(bucket, pred);
        console.info(`[FileSourceDatabase] upsertPlayHistory UPDATE videoId=${entity.videoId} position=${entity.positionMs}ms`);
      } else {
        await this.rdbStore.insert(FileSourceDatabase.TABLE_PLAY_HISTORY, bucket);
        console.info(`[FileSourceDatabase] upsertPlayHistory INSERT videoId=${entity.videoId} position=${entity.positionMs}ms`);
      }
    } catch (error) {
      console.error(`[FileSourceDatabase] upsertPlayHistory 失败: ${JSON.stringify(error)}`);
      // 不再抛出异常，只记录错误，让调用者能够继续执行
    }
  }

  /**
   * 根据 videoId 查询播放历史
   */
  async getPlayHistoryByVideoId(videoId: number): Promise<PlayHistoryEntity | null> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_PLAY_HISTORY);
      pred.equalTo('video_id', videoId);
      const rs = await this.rdbStore.query(pred);
      if (rs.goToFirstRow()) {
        const entity = this.parsePlayHistoryEntity(rs);
        rs.close();
        return entity;
      }
      rs.close();
      return null;
    } catch (error) {
      console.error(`[FileSourceDatabase] getPlayHistoryByVideoId 失败: ${JSON.stringify(error)}`);
      return null;
    }
  }

  /**
   * 删除指定视频的播放历史
   */
  async deletePlayHistory(videoId: number): Promise<void> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_PLAY_HISTORY);
      pred.equalTo('video_id', videoId);
      const rows = await this.rdbStore.delete(pred);
      console.info(`[FileSourceDatabase] deletePlayHistory: 删除 ${rows} 条记录 for videoId=${videoId}`);
    } catch (error) {
      console.error(`[FileSourceDatabase] deletePlayHistory 失败: ${JSON.stringify(error)}`);
      throw new Error('deletePlayHistory failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 获取所有播放历史（按更新时间倒序）
   */
  async getAllPlayHistory(): Promise<PlayHistoryEntity[]> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }
    try {
      const pred = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_PLAY_HISTORY);
      pred.orderByDesc('updated_at');
      const rs = await this.rdbStore.query(pred);
      const list: PlayHistoryEntity[] = [];
      while (rs.goToNextRow()) {
        list.push(this.parsePlayHistoryEntity(rs));
      }
      rs.close();
      console.info(`[FileSourceDatabase] getAllPlayHistory: 获取 ${list.length} 条记录`);
      return list;
    } catch (error) {
      console.error(`[FileSourceDatabase] getAllPlayHistory 失败: ${JSON.stringify(error)}`);
      return [];
    }
  }

  private parsePlayHistoryEntity(rs: relationalStore.ResultSet): PlayHistoryEntity {
    const get = (col: string): number => rs.getLong(rs.getColumnIndex(col));
    return {
      id: get('id'),
      videoId: get('video_id'),
      positionMs: get('position_ms'),
      durationMs: get('duration_ms'),
      updatedAt: get('updated_at')
    };
  }
}



