import { FileSourceDatabase } from "../../db/files/FileSourceDatabase";
import { FileSource, FileSourceDirectory, DirStatus } from "../../db/models/FileSourceEntity";
import { MediaDataVersionStore } from "../../services/scrape/MediaDataVersionStore";
import { GlobalScrapeScope } from "../../services/scrape/ScopedScrapeTypes";
import { BusinessError } from '@kit.BasicServicesKit';
import { DirectoryDeletionModel } from './DirectoryDeletionAction';

/**
 * 文件夹项接口，包含文件夹信息和所属文件源信息
 */
export interface DirectoryItem {
  directoryPath: string;
  directoryName: string;
  customName: string;
  fileSourceName: string;
  fileSource: FileSource;
  /** 目录可达性状态 */
  dirStatus: DirStatus;
  /** 目录 DB 主键，用于状态更新与清理操作 */
  dirId?: number;
}

/**
 * 文件源缓存管理类
 * 使用单例模式管理文件源数据缓存
 */
@ObservedV2
export class FileSourceModel implements DirectoryDeletionModel {
  // 缓存有效期：5 分钟
  private static readonly CACHE_DURATION = 5 * 60 * 1000;

  // 刷新触发计数，每次自增触发 Tab 刷新
  @Trace refreshTick: number = 0;

  // 文件源列表
  @Trace fileSources: FileSource[] = [];

  @Trace directories: DirectoryItem[] = [];

  // 是否已加载
  @Trace isLoaded: boolean = false;

  // 最后更新时间
  private lastUpdateTime: number = 0;

  /**
   * 加载文件源列表
   * @param forceReload 是否强制重新加载
   */
  async loadFileSources(forceReload: boolean = false): Promise<void> {
    const now = Date.now();

    // 检查是否需要重新加载
    if (!forceReload && this.isLoaded && (now - this.lastUpdateTime) < FileSourceModel.CACHE_DURATION) {
      console.info('FileSourceStore: Using cached data');
      return;
    }

    try {
      console.info('FileSourceStore: Loading file sources from database');
      const database = FileSourceDatabase.getInstance();
      // 等待数据库就绪，避免冷启动时 getStore 抛「Database not initialized」导致列表为空
      await FileSourceDatabase.whenDatabaseReady();
      this.fileSources = await database.getAllFileSources();
      await this.loadFileSourceDirectories(this.fileSources)
      this.isLoaded = true;
      this.lastUpdateTime = now;
      console.info(`FileSourceStore: Loaded ${this.fileSources.length} file source(s)`);
    } catch (error) {
      console.error('FileSourceStore: Failed to load file sources', JSON.stringify(error));
      throw new Error('Failed to load file sources: ' + JSON.stringify(error));
    }
  }

  private async loadFileSourceDirectories(fileSources: FileSource[]) {
    const directories: DirectoryItem[] = []
    const database = FileSourceDatabase.getInstance()

    for (const fileSource of fileSources) {
      if (fileSource.id) {
        const dirs = await database.getDirectoriesBySourceId(fileSource.id)

        for (const dir of dirs) {
          // 从路径中提取文件夹名称
          const pathParts = dir.directoryPath.split('/').filter(p => p.length > 0)
          const dirName = pathParts.length > 0 ? pathParts[pathParts.length - 1] : '根目录'

          directories.push({
            directoryPath: dir.directoryPath,
            directoryName: dirName,
            customName: dir.customName || dirName,
            fileSourceName: fileSource.name,
            fileSource: fileSource,
            dirStatus: dir.dirStatus ?? 'active',
            dirId: dir.id
          })
        }
      }
    }

    this.directories = directories
  }

  /**
   * 添加文件源
   * @param fileSource 文件源对象
   * @returns 新插入的文件源 ID
   */
  async addFileSource(fileSource: FileSource): Promise<number> {
    try {
      console.info('FileSourceStore: Adding file source');
      const database = FileSourceDatabase.getInstance();
      const rowId = await database.insertFileSource(fileSource);

      // 更新缓存
      fileSource.id = rowId;
      this.fileSources.push(fileSource);
      this.lastUpdateTime = Date.now();

      console.info(`FileSourceStore: Added file source with id ${rowId}`);
      return rowId;
    } catch (error) {
      console.error('FileSourceStore: Failed to add file source', JSON.stringify(error));
      throw new Error('Failed to add file source: ' + JSON.stringify(error));
    }
  }

  /**
   * 更新文件源
   * @param fileSource 文件源对象
   */
  async updateFileSource(fileSource: FileSource): Promise<void> {
    if (!fileSource.id) {
      throw new Error('File source id is required for update');
    }

    try {
      console.info(`FileSourceStore: Updating file source with id ${fileSource.id}`);
      const database = FileSourceDatabase.getInstance();
      await database.updateFileSource(fileSource);

      // 更新缓存
      const index = this.fileSources.findIndex(item => item.id === fileSource.id);
      if (index !== -1) {
        this.fileSources[index] = fileSource;
      }
      this.lastUpdateTime = Date.now();

      console.info(`FileSourceStore: Updated file source with id ${fileSource.id}`);
    } catch (error) {
      console.error('FileSourceStore: Failed to update file source', JSON.stringify(error));
      throw new Error('Failed to update file source: ' + JSON.stringify(error));
    }
  }

  /**
   * 删除文件源
   * @param id 文件源 ID
   */
  async deleteFileSource(id: number): Promise<void> {
    try {
      console.info(`FileSourceStore: Deleting file source with id ${id}`);
      const database = FileSourceDatabase.getInstance();
      await database.deleteFileSource(id);

      // 更新缓存
      const index = this.fileSources.findIndex(item => item.id === id);
      if (index !== -1) {
        this.fileSources.splice(index, 1);
      }
      this.lastUpdateTime = Date.now();

      console.info(`FileSourceStore: Deleted file source with id ${id}`);
    } catch (error) {
      console.error('FileSourceStore: Failed to delete file source', JSON.stringify(error));
      throw new Error('Failed to delete file source: ' + JSON.stringify(error));
    }
  }

  /**
   * 删除整个文件源及其全部关联数据（目录、视频、刮削信息、播放进度），
   * 并同步更新缓存。用于文件源在服务器上已不存在时的一键删除。
   */
  async deleteFileSourceWithData(id: number): Promise<void> {
    try {
      console.info(`FileSourceStore: Deleting file source with data, id ${id}`);
      const database = FileSourceDatabase.getInstance();
      await database.deleteFileSourceWithData(id);

      // 更新缓存：移除文件源与其目录
      const sourceIndex = this.fileSources.findIndex(item => item.id === id);
      if (sourceIndex !== -1) {
        this.fileSources.splice(sourceIndex, 1);
      }
      const remainingDirs = this.directories.filter(item => item.fileSource.id !== id);
      this.directories = remainingDirs;
      this.lastUpdateTime = Date.now();

      // 广播媒体数据版本变化，触发首页「继续观看」与媒体库列表刷新，
      // 避免删除文件源后媒体库残留已清理条目（需重启才消失）。
      this.publishGlobalMediaChange();

      console.info(`FileSourceStore: Deleted file source with data, id ${id}`);
    } catch (e) {
      const error = e as BusinessError;
      console.error('FileSourceStore: Failed to delete file source with data', error.message);
      throw new Error('Failed to delete file source with data: ' + error.message);
    }
  }

  /**
   * 根据 ID 获取文件源
   * @param id 文件源 ID
   */
  getFileSourceById(id: number): FileSource | null {
    const fileSource = this.fileSources.find(item => item.id === id);
    return fileSource || null;
  }

  /**
   * 使缓存失效
   */
  invalidateCache(): void {
    console.info('FileSourceStore: Invalidating cache');
    this.isLoaded = false;
    this.lastUpdateTime = 0;
  }

  /**
   * 一键清理缺失目录：删除目录配置 + 关联媒体记录，并刷新缓存
   * @param dirId         file_source_directories 主键
   * @param sourceId      所属文件源 ID
   * @param directoryPath 目录路径
   */
  async clearMissingDirectory(dirId: number, sourceId: number, directoryPath: string): Promise<void> {
    try {
      const database = FileSourceDatabase.getInstance();
      await database.clearMediaAndDirectoryForDir(dirId, sourceId, directoryPath);
      // 从缓存中移除
      const idx = this.directories.findIndex(
        d => d.dirId === dirId
      );
      if (idx !== -1) {
        this.directories.splice(idx, 1);
      }
      this.lastUpdateTime = Date.now();
      this.publishGlobalMediaChange();
      console.info(`FileSourceModel: 目录 ${directoryPath} 已清理`);
    } catch (e) {
      const error = e as BusinessError;
      console.error('FileSourceModel: clearMissingDirectory 失败', error.message);
      throw new Error('Failed to clearMissingDirectory: ' + error.message);
    }
  }

  /**
   * 保存文件源目录并清理被移除目录的媒体数据。
   * 目录选择器取消勾选文件夹后，被移除目录下的 videos/scrape_info/play_progress
   * 一并清理，并清理由此产生的孤儿刮削元数据（空季/空剧/空电影），
   * 最后刷新缓存并广播媒体数据版本变化。
   * @param sourceId    所属文件源 ID
   * @param directories 保存后的完整目录列表（替换旧的目录配置）
   */
  async saveDirectoriesWithCleanup(sourceId: number, directories: FileSourceDirectory[]): Promise<void> {
    try {
      const database = FileSourceDatabase.getInstance();
      // 1. 读取旧目录，diff 出被移除（取消勾选）的目录
      const oldDirs = await database.getDirectoriesBySourceId(sourceId);
      const newPathSet = new Set<string>();
      directories.forEach((d: FileSourceDirectory) => newPathSet.add(d.directoryPath));
      const removedDirs = oldDirs.filter((d: FileSourceDirectory) => !newPathSet.has(d.directoryPath));
      // 2. 在单个事务内完成「媒体清理 + 目录配置替换」，保证同生共死
      const removedPaths: string[] = removedDirs.map((d: FileSourceDirectory) => d.directoryPath);
      await database.saveDirectoriesWithMediaCleanup(sourceId, removedPaths, directories);
      // 3. 清理孤儿刮削元数据（空季/空剧/空电影）。
      //    依赖原生 SQL，Transaction 不提供 executeSql，故放在事务提交后幂等调用。
      await database.cleanupOrphanScrapeMedia();
      // 4. 刷新缓存并广播媒体数据变化
      await this.loadFileSources(true);
      this.publishGlobalMediaChange();
      console.info(`FileSourceModel: 目录已保存，清理了 ${removedDirs.length} 个被移除目录`);
    } catch (e) {
      const error = e as BusinessError;
      console.error('FileSourceModel: saveDirectoriesWithCleanup 失败', error.message);
      throw new Error('Failed to saveDirectoriesWithCleanup: ' + error.message);
    }
  }

  /**
   * 广播全局媒体数据版本变化，触发首页「继续观看」与媒体库列表刷新。
   * 删除文件源/目录后必须广播，否则首页 MediaLibraryTab 持有的
   * recentlyAdded 内存数据陈旧，会残留已清理条目。
   */
  private publishGlobalMediaChange(): void {
    const scope: GlobalScrapeScope = { kind: 'global', displayName: '' };
    MediaDataVersionStore.getState().publish(scope);
  }
}

