import relationalStore from '@ohos.data.relationalStore';
import { FileSource, FileSourceDirectory, FileSourceType, DirStatus } from '../models/FileSourceEntity';
import { CryptoUtil } from '../../utils/CryptoUtil';
import { BusinessError } from "@kit.BasicServicesKit";
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  TABLE_FILE_SOURCES, TABLE_DIRECTORIES, TABLE_VIDEOS, TABLE_SCRAPE_INFO, TABLE_PLAY_PROGRESS
} from './DbConstants';
import { FileSourceDbCore } from './FileSourceDbCore';

/**
 * file_sources 与 file_source_directories 表的数据访问。
 * 拆分自 FileSourceDatabase，保持原方法签名与行为不变。
 */
export class FileSourceDao {
  private core: FileSourceDbCore;

  constructor(core: FileSourceDbCore) {
    this.core = core;
  }

  /**
   * 插入文件源
   */
  async insertFileSource(fileSource: FileSource): Promise<number> {
    const store = this.core.getStore();

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

      const rowId = await store.insert(TABLE_FILE_SOURCES, valueBucket);
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
    const store = this.core.getStore();

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

      const predicates = new relationalStore.RdbPredicates(TABLE_FILE_SOURCES);
      predicates.equalTo('id', fileSource.id);

      const rows = await store.update(valueBucket, predicates);
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
    const store = this.core.getStore();

    try {
      const predicates = new relationalStore.RdbPredicates(TABLE_FILE_SOURCES);
      predicates.equalTo('id', id);

      const rows = await store.delete(predicates);
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
    const store = this.core.getStore();

    let resultSet: relationalStore.ResultSet | null = null;
    try {
      const predicates = new relationalStore.RdbPredicates(TABLE_FILE_SOURCES);
      predicates.equalTo('id', id);

      resultSet = await store.query(predicates);

      if (resultSet.goToFirstRow()) {
        return await this.parseFileSource(resultSet);
      }

      return null;
    } catch (error) {
      console.error('FileSourceDatabase: Failed to get file source by id', JSON.stringify(error));
      throw new Error('Failed to get file source by id: ' + JSON.stringify(error));
    } finally {
      try { resultSet?.close(); } catch { }
    }
  }

  async getAllFileSources(): Promise<FileSource[]> {
    const store = this.core.getStore();

    let resultSet: relationalStore.ResultSet | null = null;
    try {
      const predicates = new relationalStore.RdbPredicates(TABLE_FILE_SOURCES);
      resultSet = await store.query(predicates);

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
      try { resultSet?.close(); } catch { }
    }
  }

  /**
   * 从 ResultSet 解析文件源对象
   */
  private async parseFileSource(resultSet: relationalStore.ResultSet): Promise<FileSource> {
    try {
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
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `parseFileSource 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }

  /**
   * 批量插入文件源目录关联
   */
  async insertDirectories(sourceId: number, directories: FileSourceDirectory[]): Promise<void> {
    const store = this.core.getStore();

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
        await store.insert(TABLE_DIRECTORIES, valueBucket);
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
    const store = this.core.getStore();

    try {
      const predicates = new relationalStore.RdbPredicates(TABLE_DIRECTORIES);
      predicates.equalTo('source_id', sourceId);

      const rows = await store.delete(predicates);
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
    const store = this.core.getStore();
    let tx: relationalStore.Transaction | null = null;
    try {
      tx = await store.createTransaction();
      const predicates = new relationalStore.RdbPredicates(TABLE_DIRECTORIES);
      predicates.equalTo('source_id', sourceId);
      await tx.delete(predicates);
      for (const dir of directories) {
        const valueBucket: relationalStore.ValuesBucket = {
          source_id: sourceId,
          directory_path: dir.directoryPath,
          custom_name: dir.customName ?? null,
          dir_status: dir.dirStatus ?? 'active'
        };
        await tx.insert(TABLE_DIRECTORIES, valueBucket);
      }
      await tx.commit();
      console.info(`FileSourceDatabase: Saved ${directories.length} directory(ies) for source ${sourceId}`);
    } catch (error) {
      if (tx !== null) { try { await tx.rollback(); } catch { } }
      console.error('FileSourceDatabase: saveDirectoriesForSource failed, rollback', JSON.stringify(error));
      throw new Error('Failed to save directories: ' + JSON.stringify(error));
    }
  }

  /**
   * 查询指定文件源的所有目录关联
   */
  async getDirectoriesBySourceId(sourceId: number): Promise<FileSourceDirectory[]> {
    const store = this.core.getStore();

    let resultSet: relationalStore.ResultSet | null = null;
    try {
      const predicates = new relationalStore.RdbPredicates(TABLE_DIRECTORIES);
      predicates.equalTo('source_id', sourceId);

      resultSet = await store.query(predicates);

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
      try { resultSet?.close(); } catch { }
    }
  }

  /**
   * 更新单条目录的可达性状态
   * @param dirId  file_source_directories 主键
   * @param status 新状态：'active' | 'missing' | 'unreachable'
   */
  async updateDirStatus(dirId: number, status: DirStatus): Promise<void> {
    const store = this.core.getStore();
    try {
      const valueBucket: relationalStore.ValuesBucket = { dir_status: status };
      const predicates = new relationalStore.RdbPredicates(TABLE_DIRECTORIES);
      predicates.equalTo('id', dirId);
      await store.update(valueBucket, predicates);
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
    const store = this.core.getStore();
    const BATCH_SIZE = 100;

    // 1. 查询该目录下的 video id 列表（事务外只读，不影响原子性）
    const videoQueryPredicates = new relationalStore.RdbPredicates(TABLE_VIDEOS);
    videoQueryPredicates.equalTo('source_id', sourceId);
    videoQueryPredicates.and();
    videoQueryPredicates.equalTo('directory_path', directoryPath);
    let videoRs: relationalStore.ResultSet | null = null;
    const videoIds: number[] = [];
    try {
      videoRs = await store.query(videoQueryPredicates, ['id']);
      while (videoRs.goToNextRow()) {
        videoIds.push(videoRs.getLong(videoRs.getColumnIndex('id')));
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `clearMediaAndDirectoryForDir query 失败: ${err.message}`);
      throw new Error(err.message);
    } finally {
      try { videoRs?.close(); } catch { }
    }

    // 2. 在事务中执行所有删除操作，保证原子性
    let tx: relationalStore.Transaction | null = null;
    try {
      tx = await store.createTransaction();
      // 2a. 分批删除 scrape_info（防止超过 SQLite 999 参数上限）
      for (let i = 0; i < videoIds.length; i += BATCH_SIZE) {
        const batch = videoIds.slice(i, i + BATCH_SIZE);
        const scrapePredicates = new relationalStore.RdbPredicates(TABLE_SCRAPE_INFO);
        scrapePredicates.in('video_id', batch.map(v => v as relationalStore.ValueType));
        await tx.delete(scrapePredicates);
      }

      // 2b. 分批删除 play_progress（外键未启用，无级联删除）
      for (let i = 0; i < videoIds.length; i += BATCH_SIZE) {
        const batch = videoIds.slice(i, i + BATCH_SIZE);
        const progressPredicates = new relationalStore.RdbPredicates(TABLE_PLAY_PROGRESS);
        progressPredicates.in('video_id', batch.map(v => v as relationalStore.ValueType));
        await tx.delete(progressPredicates);
      }

      // 2c. 删除视频记录
      const videoDelPredicates = new relationalStore.RdbPredicates(TABLE_VIDEOS);
      videoDelPredicates.equalTo('source_id', sourceId);
      videoDelPredicates.and();
      videoDelPredicates.equalTo('directory_path', directoryPath);
      await tx.delete(videoDelPredicates);

      // 2d. 删除目录配置本身
      const dirPredicates = new relationalStore.RdbPredicates(TABLE_DIRECTORIES);
      dirPredicates.equalTo('id', dirId);
      await tx.delete(dirPredicates);

      await tx.commit();
      console.info(`[DB][clearMediaAndDirectoryForDir] dirId=${dirId} sourceId=${sourceId} path=${directoryPath} 已清理`);
    } catch (error) {
      if (tx !== null) { try { await tx.rollback(); } catch { } }
      console.error('[DB][clearMediaAndDirectoryForDir] 失败，已回滚', JSON.stringify(error));
      throw new Error('Failed to clearMediaAndDirectoryForDir: ' + JSON.stringify(error));
    }
  }
}
