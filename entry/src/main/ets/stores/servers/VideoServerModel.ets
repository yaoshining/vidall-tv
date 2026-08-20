import { FileSourceDatabase } from "../../db/files/FileSourceDatabase";
import { VideoServer, VideoServerType } from "../../db/models/VideoServerEntity";
import { BusinessError } from "@kit.BasicServicesKit";
import SettingType from "../../pages/settings/SettingType";
import { SourceSwitchModel } from "../media/SourceSwitchModel";

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

  // 进行中的加载请求，用于并发去重（多个调用方共享同一次数据库读取与解密）
  private loadingPromise: Promise<void> | null = null;

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

    if (this.loadingPromise !== null) {
      return this.loadingPromise;
    }
    this.loadingPromise = this.doLoad(now);
    try {
      await this.loadingPromise;
    } finally {
      this.loadingPromise = null;
    }
  }

  private async doLoad(now: number): Promise<void> {
    try {
      console.info('VideoServerModel: Loading video servers from database');
      const database = FileSourceDatabase.getInstance();
      this.videoServers = await database.getAllVideoServers();
      this.isLoaded = true;
      this.lastUpdateTime = now;
      console.info(`VideoServerModel: Loaded ${this.videoServers.length} video server(s)`);
    } catch (error) {
      const msg = (error as BusinessError).message ?? String(error);
      console.error('VideoServerModel: Failed to load video servers', msg);
      throw new Error('Failed to load video servers: ' + msg);
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
      const msg = (error as BusinessError).message ?? String(error);
      console.error('VideoServerModel: Failed to add video server', msg);
      throw new Error('Failed to add video server: ' + msg);
    }
  }

  /**
   * 更新影视服务器
   */
  async updateVideoServer(server: VideoServer): Promise<void> {
    if (server.id === undefined) {
      throw new Error('Video server id is required for update');
    }

    try {
      const database = FileSourceDatabase.getInstance();
      await database.updateVideoServer(server);

      // 重新赋值数组，确保 @Trace 响应式更新（列表与当前源名都会刷新）
      this.videoServers = this.videoServers.map(item => item.id === server.id ? server : item);
      this.lastUpdateTime = Date.now();
    } catch (error) {
      const msg = (error as BusinessError).message ?? String(error);
      console.error('VideoServerModel: Failed to update video server', msg);
      throw new Error('Failed to update video server: ' + msg);
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
      const msg = (error as BusinessError).message ?? String(error);
      console.error('VideoServerModel: Failed to delete video server', msg);
      throw new Error('Failed to delete video server: ' + msg);
    }
  }

  /**
   * 删除影视服务器并处理当前源回退（统一删除流程）。
   * 若被删除的服务器恰好是当前激活源，自动回退到文件源。
   * 源回退的持久化失败不中断删除流程（服务器已删除不可恢复，
   * 残余的无效源引用会在下次 load() 时自动回退）。
   */
  async deleteVideoServerWithFallback(id: number): Promise<void> {
    await this.deleteVideoServer(id);
    const sourceSwitch = SourceSwitchModel.getState();
    if (sourceSwitch.getActiveServerId() === id) {
      try {
        await sourceSwitch.setFileSource();
      } catch (e) {
        console.warn('VideoServerModel: 源回退持久化失败，将在下次加载时自动恢复', (e as BusinessError).message ?? String(e));
      }
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
 * 影视服务器类型 → 设置页类型映射（供 VideoServerTab / VideoServerSettingBuilder 共享）
 */
export function settingTypeFor(serverType: VideoServerType): SettingType {
  switch (serverType) {
    case VideoServerType.JELLYFIN:
      return SettingType.JELLYFIN_CONFIG
    case VideoServerType.EMBY:
      return SettingType.EMBY_CONFIG
    case VideoServerType.PLEX:
      return SettingType.PLEX_CONFIG
    default:
      return SettingType.JELLYFIN_CONFIG
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
