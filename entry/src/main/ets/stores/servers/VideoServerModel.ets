import { FileSourceDatabase } from "../../db/files/FileSourceDatabase";
import { VideoServer, VideoServerType } from "../../db/models/VideoServerEntity";
import { BusinessError } from "@kit.BasicServicesKit";
import SettingType from "../../pages/settings/SettingType";

/**
 * 影视服务器缓存管理类。
 * 使用单例模式管理影视服务器数据缓存（镜像 FileSourceModel）。
 */
@ObservedV2
export class VideoServerModel {
  // 缓存有效期：5 分钟
  private static readonly CACHE_DURATION = 5 * 60 * 1000;

  // 影视服务器列表
  @Trace private servers: VideoServer[] = [];
  private searchListeners: Set<() => void> = new Set<() => void>();

  // Separate intent notifications preserve the existing publication-only listener contract.
  private revisionListeners: Set<() => void> = new Set<() => void>();
  private configurationRevision: number = 0;
  private pendingConfigurationWrites: number = 0;

  get searchConfigurationRevision(): number { return this.configurationRevision; }

  subscribeSearchConfigurationRevision(listener: () => void): () => void {
    this.revisionListeners.add(listener);
    return () => { this.revisionListeners.delete(listener); };
  }

  private notifyConfigurationRevision(): void {
    this.revisionListeners.forEach((listener: () => void) => listener());
  }

  private beginConfigurationWrite(): void {
    this.pendingConfigurationWrites++;
    this.configurationRevision++;
    this.invalidateCache();
    this.notifyConfigurationRevision();
  }

  private finishConfigurationWrite(): void {
    this.pendingConfigurationWrites--;
    this.configurationRevision++;
    this.invalidateCache();
    this.notifyConfigurationRevision();
  }

  get videoServers(): VideoServer[] { return this.servers; }
  set videoServers(value: VideoServer[]) {
    this.configurationRevision++;
    this.servers = value;
    this.notifyConfigurationRevision();
    this.notifySearchConfiguration();
  }

  subscribeSearchConfiguration(listener: () => void): () => void {
    this.searchListeners.add(listener);
    return () => { this.searchListeners.delete(listener); };
  }

  private notifySearchConfiguration(): void {
    this.searchListeners.forEach((listener: () => void) => listener());
  }

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
    if (this.pendingConfigurationWrites > 0) {
      throw new Error('Server configuration write in progress');
    }
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
    const revision = this.configurationRevision;
    try {
      console.info('VideoServerModel: Loading video servers from database');
      const database = FileSourceDatabase.getInstance();
      // 等待数据库就绪，避免冷启动时 getStore 抛「Database not initialized」导致列表为空
      await FileSourceDatabase.whenDatabaseReady();
      const servers = await database.getAllVideoServers();
      // Never publish a read that overlaps a write, including a failed write.
      if (revision !== this.configurationRevision || this.pendingConfigurationWrites > 0) {
        throw new Error('Server configuration changed during load');
      }
      this.servers = servers;
      this.notifySearchConfiguration();
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
    this.beginConfigurationWrite();
    try {
      const database = FileSourceDatabase.getInstance();
      const rowId = await database.insertVideoServer(server);

      server.id = rowId;
      this.videoServers = this.videoServers.concat([server]);
      this.lastUpdateTime = Date.now();

      console.info(`VideoServerModel: Added video server with id ${rowId}`);
      return rowId;
    } catch (error) {
      const msg = (error as BusinessError).message ?? String(error);
      console.error('VideoServerModel: Failed to add video server', msg);
      throw new Error('Failed to add video server: ' + msg);
    } finally {
      this.finishConfigurationWrite();
    }
  }

  /**
   * 更新影视服务器
   */
  async updateVideoServer(server: VideoServer): Promise<void> {
    if (server.id === undefined) {
      throw new Error('Video server id is required for update');
    }

    this.beginConfigurationWrite();
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
    } finally {
      this.finishConfigurationWrite();
    }
  }

  /**
   * 删除影视服务器
   */
  async deleteVideoServer(id: number): Promise<void> {
    this.beginConfigurationWrite();
    try {
      const database = FileSourceDatabase.getInstance();
      await database.deleteVideoServer(id);

      const index = this.videoServers.findIndex(item => item.id === id);
      if (index !== -1) {
        this.videoServers = this.videoServers.filter((server: VideoServer) => server.id !== id);
      }
      this.lastUpdateTime = Date.now();
    } catch (error) {
      const msg = (error as BusinessError).message ?? String(error);
      console.error('VideoServerModel: Failed to delete video server', msg);
      throw new Error('Failed to delete video server: ' + msg);
    } finally {
      this.finishConfigurationWrite();
    }
  }

  /**
   * 统一删除入口，保留原方法名以兼容调用方。
   * 保留当前源及持久化身份：已删除服务器由范围解析判为不可用，
   * 只有用户主动选择文件源才允许本地搜索；删除非当前源不改变选择。
   */
  async deleteVideoServerWithFallback(id: number): Promise<void> {
    await this.deleteVideoServer(id);
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
