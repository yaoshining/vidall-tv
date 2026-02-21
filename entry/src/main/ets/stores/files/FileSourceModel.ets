import { FileSourceDatabase } from "../../db/files/FileSourceDatabase";
import { FileSource } from "../../db/models/FileSourceEntity";

/**
 * 文件夹项接口，包含文件夹信息和所属文件源信息
 */
export interface DirectoryItem {
  directoryPath: string;
  directoryName: string;
  customName: string;
  fileSourceName: string;
  fileSource: FileSource;
}

/**
 * 文件源缓存管理类
 * 使用单例模式管理文件源数据缓存
 */
@ObservedV2
export class FileSourceModel {
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
            fileSource: fileSource
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
}

