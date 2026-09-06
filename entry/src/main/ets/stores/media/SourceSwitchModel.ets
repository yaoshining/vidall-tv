import { SearchScopeIdentity, SearchScope, resolveSearchScope, createUnavailableSearchScope } from '../../models/search/SearchScope';
import { AppPreferences, PrefKey } from '../../utils/AppPreferences';
import { VideoServer, VideoServerType } from '../../db/models/VideoServerEntity';

/**
 * 媒体库当前数据源描述。
 * - kind = 'fileSource'：本地 / 文件源扫描的媒体库
 * - kind = 'videoServer'：某台影视服务器（Jellyfin / Emby / Plex）
 */
export interface ActiveMediaSource {
  kind: 'fileSource' | 'videoServer';
  serverId?: number;
  serverType?: VideoServerType;
  name?: string;
}

/**
 * 媒体库数据源切换状态（单例可观察）。
 * 顶部栏「Home」按钮与媒体库均消费本模型。
 */
@ObservedV2
export class SourceSwitchModel {
  private static instance: SourceSwitchModel | null = null;

  static getState(): SourceSwitchModel {
    if (!SourceSwitchModel.instance) {
      SourceSwitchModel.instance = new SourceSwitchModel();
    }
    return SourceSwitchModel.instance;
  }

  @Trace private sourceLoaded: boolean = false;

  @Trace private selectedSource: ActiveMediaSource = { kind: 'fileSource' };
  private searchListeners: Set<() => void> = new Set<() => void>();

  get activeSource(): ActiveMediaSource { return this.selectedSource; }
  set activeSource(value: ActiveMediaSource) {
    this.selectedSource = value;
    this.searchListeners.forEach((listener: () => void) => listener());
  }

  subscribeSearchSource(listener: () => void): () => void {
    this.searchListeners.add(listener);
    return () => { this.searchListeners.delete(listener); };
  }

  /** 数据源切换弹窗是否可见（供返回键拦截） */
  @Trace sourceSwitchDialogVisible: boolean = false;

  /** 当前源展示名：文件源 / 服务器名 */
  getDisplayName(): string {
    if (this.activeSource.kind === 'videoServer') {
      return this.activeSource.name ?? '';
    }
    return '文件源';
  }

  isFileSource(): boolean {
    return this.activeSource.kind === 'fileSource';
  }

  getActiveServerId(): number | undefined {
    return this.activeSource.kind === 'videoServer' ? this.activeSource.serverId : undefined;
  }

  async setFileSource(): Promise<void> {
    this.sourceLoaded = true;
    this.activeSource = { kind: 'fileSource' };
    await this.persist();
  }

  async setVideoServer(server: VideoServer): Promise<void> {
    if (server.id === undefined) {
      return;
    }
    this.sourceLoaded = true;
    this.activeSource = { kind: 'videoServer', serverId: server.id, serverType: server.type, name: server.name };
    await this.persist();
  }

  /**
   * 服务器改名 / 配置更新后同步当前源的名称（供 Home 按钮与切换弹窗实时刷新）。
   */
  async syncServerName(server: VideoServer): Promise<void> {
    if (this.activeSource.kind === 'videoServer' && this.activeSource.serverId === server.id) {
      this.activeSource = { kind: 'videoServer', serverId: server.id, serverType: server.type, name: server.name };
      await this.persist();
    }
  }

  /**
   * 从偏好加载当前源。从已加载配置恢复类型；删除的服务器保留为不可用身份。
   * @param servers 当前已加载的服务器配置
   */
  async load(servers: VideoServer[]): Promise<void> {
    try {
      const raw = await AppPreferences.get(PrefKey.ACTIVE_MEDIA_SOURCE, '');
      if (raw.length === 0) {
        this.activeSource = { kind: 'fileSource' };
        return;
      }
      const parsed = JSON.parse(raw) as ActiveMediaSource;
      if (parsed.kind === 'videoServer') {
        const serverId = parsed.serverId;
        const server = servers.find((item: VideoServer) => item.id === serverId);
        if (server !== undefined && (parsed.serverType === undefined || parsed.serverType === server.type)) {
          this.activeSource = { kind: 'videoServer', serverId: server.id,
            serverType: server.type, name: server.name };
          return;
        }
        // 保留无效身份，禁止搜索静默回退本地数据。
        this.activeSource = { kind: 'videoServer', serverId, serverType: parsed.serverType, name: '来源不可用' };
        return;
      }
      this.activeSource = parsed.kind === 'fileSource' ? { kind: 'fileSource' } :
        { kind: 'videoServer', name: '来源不可用' };
    } catch (e) {
      this.activeSource = { kind: 'videoServer', name: '来源不可用' };
    } finally {
      this.sourceLoaded = true;
      this.searchListeners.forEach((listener: () => void) => listener());
    }
  }

  getSearchScope(servers: VideoServer[]): SearchScope {
    if (!this.sourceLoaded) { return createUnavailableSearchScope(); }
    const identity: SearchScopeIdentity = {
      kind: this.activeSource.kind,
      serverId: this.activeSource.serverId,
      serverType: this.activeSource.serverType
    };
    return resolveSearchScope(identity, servers);
  }

  private async persist(): Promise<void> {
    try {
      await AppPreferences.set(PrefKey.ACTIVE_MEDIA_SOURCE, JSON.stringify(this.activeSource));
    } catch (e) {
      console.warn('[SourceSwitchModel] 持久化失败', (e as Error).message ?? String(e));
    }
  }
}
