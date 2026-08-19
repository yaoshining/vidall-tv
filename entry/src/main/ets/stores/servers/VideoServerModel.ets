import { FileSourceDatabase } from "../../db/files/FileSourceDatabase";
import { VideoServer, VideoServerType } from "../../db/models/VideoServerEntity";

/**
 * 影视服务器缓存管理类。
 * 使用单例模式管理影视服务器数据缓存（镜像 FileSourceModel）。
 */
@ObservedV2
export class VideoServerModel {
  // 缓存有效期：5 分钟
  private static readonly CACHE_DURATION = 5 * 60 * 1000;

  // 影视服务器列表
  @Trace videoServers: VideoServer[] = [];

  // 是否已加载
  @Trace isLoaded: boolean = false;

  // 最后更新时间
  private lastUpdateTime: number = 0;

  /**
   * 加载影视服务器列表
   * @param forceReload 是否强制重新加载
   */
  async loadVideoServers(forceReload: boolean = false): Promise<void> {
    const now = Date.now();

    if (!forceReload && this.isLoaded && (now - this.lastUpdateTime) < VideoServerModel.CACHE_DURATION) {
      console.info('VideoServerModel: Using cached data');
      return;
    }

    try {
      console.info('VideoServerModel: Loading video servers from database');
      const database = FileSourceDatabase.getInstance();
      this.videoServers = await database.getAllVideoServers();
      this.isLoaded = true;
      this.lastUpdateTime = now;
      console.info(`VideoServerModel: Loaded ${this.videoServers.length} video server(s)`);
    } catch (error) {
      console.error('VideoServerModel: Failed to load video servers', JSON.stringify(error));
      throw new Error('Failed to load video servers: ' + JSON.stringify(error));
    }
  }

  /**
   * 添加影视服务器
   */
  async addVideoServer(server: VideoServer): Promise<number> {
    try {
      const database = FileSourceDatabase.getInstance();
      const rowId = await database.insertVideoServer(server);

      server.id = rowId;
      this.videoServers.push(server);
      this.lastUpdateTime = Date.now();

      console.info(`VideoServerModel: Added video server with id ${rowId}`);
      return rowId;
    } catch (error) {
      console.error('VideoServerModel: Failed to add video server', JSON.stringify(error));
      throw new Error('Failed to add video server: ' + JSON.stringify(error));
    }
  }

  /**
   * 更新影视服务器
   */
  async updateVideoServer(server: VideoServer): Promise<void> {
    if (!server.id) {
      throw new Error('Video server id is required for update');
    }

    try {
      const database = FileSourceDatabase.getInstance();
      await database.updateVideoServer(server);

      // 重新赋值数组，确保 @Trace 响应式更新（列表与当前源名都会刷新）
      this.videoServers = this.videoServers.map(item => item.id === server.id ? server : item);
      this.lastUpdateTime = Date.now();
    } catch (error) {
      console.error('VideoServerModel: Failed to update video server', JSON.stringify(error));
      throw new Error('Failed to update video server: ' + JSON.stringify(error));
    }
  }

  /**
   * 删除影视服务器
   */
  async deleteVideoServer(id: number): Promise<void> {
    try {
      const database = FileSourceDatabase.getInstance();
      await database.deleteVideoServer(id);

      const index = this.videoServers.findIndex(item => item.id === id);
      if (index !== -1) {
        this.videoServers.splice(index, 1);
      }
      this.lastUpdateTime = Date.now();
    } catch (error) {
      console.error('VideoServerModel: Failed to delete video server', JSON.stringify(error));
      throw new Error('Failed to delete video server: ' + JSON.stringify(error));
    }
  }

  /**
   * 根据 ID 获取影视服务器
   */
  getVideoServerById(id: number): VideoServer | null {
    const server = this.videoServers.find(item => item.id === id);
    return server || null;
  }

  /**
   * 使缓存失效
   */
  invalidateCache(): void {
    this.isLoaded = false;
    this.lastUpdateTime = 0;
  }
}

/**
 * 影视服务器类型中文标签
 */
export function videoServerTypeLabel(type: VideoServerType): string {
  switch (type) {
    case VideoServerType.JELLYFIN:
      return 'Jellyfin';
    case VideoServerType.EMBY:
      return 'Emby';
    case VideoServerType.PLEX:
      return 'Plex';
    default:
      return '未知';
  }
}
