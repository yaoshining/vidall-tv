import relationalStore from '@ohos.data.relationalStore';
import { Context } from '@ohos.abilityAccessCtrl';
import { FileSource, FileSourceDirectory, FileSourceType } from '../models/FileSourceEntity';
import { VideoEntity, ScrapeInfoEntity } from '../models/MediaEntity';
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

  static onReady(callback: Callback<emitter.EventData>) {
    if (FileSourceDatabase.instance && FileSourceDatabase.instance.rdbStore) {
      callback({})
    } else {
      emitter.once(FileSourceDatabase.DATABASE_READY, callback)
    }
  }
}



