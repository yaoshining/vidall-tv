import { AppPreferences, PrefKey } from '../../utils/AppPreferences';
import { VideoServer } from '../../db/models/VideoServerEntity';

/**
 * 媒体库当前数据源描述。
 * - kind = 'fileSource'：本地 / 文件源扫描的媒体库
 * - kind = 'videoServer'：某台影视服务器（Jellyfin / Emby / Plex）
 */
export interface ActiveMediaSource {
  kind: 'fileSource' | 'videoServer';
  serverId?: number;
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

  @Trace activeSource: ActiveMediaSource = { kind: 'fileSource' };

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

  setFileSource(): void {
    this.activeSource = { kind: 'fileSource' };
    this.persist();
  }

  setVideoServer(server: VideoServer): void {
    if (!server.id) {
      return;
    }
    this.activeSource = { kind: 'videoServer', serverId: server.id, name: server.name };
    this.persist();
  }

  /**
   * 服务器改名 / 配置更新后同步当前源的名称（供 Home 按钮与切换弹窗实时刷新）。
   */
  syncServerName(server: VideoServer): void {
    if (this.activeSource.kind === 'videoServer' && this.activeSource.serverId === server.id) {
      this.activeSource = { kind: 'videoServer', serverId: server.id, name: server.name };
      this.persist();
    }
  }

  /**
   * 从偏好加载当前源。若指向的服务器已不存在则回退到文件源。
   * @param existingServerIds 当前已加载的服务器 ID 集合
   */
  async load(existingServerIds: number[]): Promise<void> {
    try {
      const raw = await AppPreferences.get(PrefKey.ACTIVE_MEDIA_SOURCE, '');
      if (raw.length === 0) {
        this.activeSource = { kind: 'fileSource' };
        return;
      }
      const parsed = JSON.parse(raw) as ActiveMediaSource;
      if (parsed.kind === 'videoServer') {
        const serverId = parsed.serverId ?? -1;
        if (existingServerIds.includes(serverId)) {
          this.activeSource = parsed;
          return;
        }
        // 服务器已删除，回退文件源
        this.activeSource = { kind: 'fileSource' };
        await this.persist();
        return;
      }
      this.activeSource = { kind: 'fileSource' };
    } catch {
      this.activeSource = { kind: 'fileSource' };
    }
  }

  private async persist(): Promise<void> {
    try {
      await AppPreferences.set(PrefKey.ACTIVE_MEDIA_SOURCE, JSON.stringify(this.activeSource));
    } catch (e) {
      console.warn('[SourceSwitchModel] 持久化失败', JSON.stringify(e));
    }
  }
}
