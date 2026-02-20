import relationalStore from '@ohos.data.relationalStore';
import { Context } from '@ohos.abilityAccessCtrl';
import { FileSource, FileSourceType } from '../models/FileSourceModel';
import { CryptoUtil } from '../../utils/CryptoUtil';

/**
 * 文件源数据库管理类
 * 使用单例模式管理关系型数据库
 */
export class FileSourceDatabase {
  // 数据库常量
  private static readonly DB_VERSION = 1;
  private static readonly DB_NAME = 'FILE_SOURCES_DB';
  private static readonly TABLE_FILE_SOURCES = 'file_sources';
  private static readonly TABLE_DIRECTORIES = 'file_source_directories';

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

      // 创建表
      await this.onCreate(this.rdbStore);

      console.info('FileSourceDatabase: Database initialized successfully');
    } catch (error) {
      console.error('FileSourceDatabase: Failed to initialize database', JSON.stringify(error));
      throw new Error('Failed to initialize database: ' + JSON.stringify(error));
    }
  }

  /**
   * 创建表结构
   */
  private async onCreate(rdbStore: relationalStore.RdbStore): Promise<void> {
    try {
      // 创建文件源表
      const createFileSourcesTable = `
        CREATE TABLE IF NOT EXISTS ${FileSourceDatabase.TABLE_FILE_SOURCES} (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          type TEXT NOT NULL,
          config_json TEXT NOT NULL,
          created_at INTEGER NOT NULL
        )
      `;
      await rdbStore.executeSql(createFileSourcesTable);

      // 创建文件源目录表
      const createDirectoriesTable = `
        CREATE TABLE IF NOT EXISTS ${FileSourceDatabase.TABLE_DIRECTORIES} (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source_id INTEGER NOT NULL,
          directory_path TEXT NOT NULL,
          FOREIGN KEY(source_id) REFERENCES ${FileSourceDatabase.TABLE_FILE_SOURCES}(id) ON DELETE CASCADE
        )
      `;
      await rdbStore.executeSql(createDirectoriesTable);

      console.info('FileSourceDatabase: Tables created successfully');
    } catch (error) {
      console.error('FileSourceDatabase: Failed to create tables', JSON.stringify(error));
      throw new Error('Failed to create tables: ' + JSON.stringify(error));
    }
  }

  /**
   * 数据库版本升级处理
   * 当前版本为 1，预留扩展
   */
  private async onUpgrade(rdbStore: relationalStore.RdbStore, oldVersion: number, newVersion: number): Promise<void> {
    console.info(`FileSourceDatabase: Upgrading database from version ${oldVersion} to ${newVersion}`);

    try {
      // 使用 switch-case 处理不同版本的升级逻辑
      switch (oldVersion) {
        case 1:
          // 如果未来需要从版本 1 升级到版本 2，在这里添加升级逻辑
          // 例如：await rdbStore.executeSql('ALTER TABLE ...');
          break;
        // 可以继续添加更多版本的升级逻辑
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
  async insertDirectories(sourceId: number, paths: string[]): Promise<void> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }

    if (paths.length === 0) {
      console.info('FileSourceDatabase: No directories to insert');
      return;
    }

    try {
      // 批量插入目录记录
      for (const path of paths) {
        const valueBucket: relationalStore.ValuesBucket = {
          source_id: sourceId,
          directory_path: path
        };
        await this.rdbStore.insert(FileSourceDatabase.TABLE_DIRECTORIES, valueBucket);
      }
      console.info(`FileSourceDatabase: Inserted ${paths.length} directory(ies) for source ${sourceId}`);
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
  async getDirectoriesBySourceId(sourceId: number): Promise<import('../models/FileSourceModel').FileSourceDirectory[]> {
    if (this.rdbStore === null) {
      throw new Error('Database not initialized');
    }

    try {
      const predicates = new relationalStore.RdbPredicates(FileSourceDatabase.TABLE_DIRECTORIES);
      predicates.equalTo('source_id', sourceId);

      const resultSet = await this.rdbStore.query(predicates);

      const directories: import('../models/FileSourceModel').FileSourceDirectory[] = [];
      while (resultSet.goToNextRow()) {
        const id = resultSet.getLong(resultSet.getColumnIndex('id'));
        const sourceIdVal = resultSet.getLong(resultSet.getColumnIndex('source_id'));
        const directoryPath = resultSet.getString(resultSet.getColumnIndex('directory_path'));

        directories.push({
          id: id,
          sourceId: sourceIdVal,
          directoryPath: directoryPath
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
}



