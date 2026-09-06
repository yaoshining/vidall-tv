import { BusinessError } from '@kit.BasicServicesKit';
import { VideoServer, VideoServerType } from '../../db/models/VideoServerEntity';
import { JellyfinClient, VideoServerMediaItem } from '../../lib/JellyfinClient';
import { PlexClient } from '../../lib/PlexClient';
import { SearchScope, resolveSearchScope, toSearchScopeIdentity } from '../../models/search/SearchScope';

export type VideoServerSearchErrorCode =
  'none' | 'unavailable' | 'invalidQuery' | 'auth' | 'timeout' | 'network' | 'invalidResponse';

export type NormalizedVideoServerMediaType = 'movie' | 'series' | 'episode';

export interface VideoServerSearchSelection {
  serverId: number;
  serverType: VideoServerType;
  mediaId: string;
  mediaType: NormalizedVideoServerMediaType;
  detailItemId: string;
}

const videoServerSearchSourceConfigurations = new WeakMap<VideoServerSearchSourceSnapshot, string>();

/** 配置快照只保留在内存对象中用于失效校验，不进 key / 日志 / 持久化。 */
export class VideoServerSearchSourceSnapshot {
  readonly scopeKey: string;
  readonly serverId: number;
  readonly serverType: VideoServerType;

  constructor(scopeKey: string, server: VideoServer) {
    this.scopeKey = scopeKey;
    this.serverId = server.id as number;
    this.serverType = server.type;
    videoServerSearchSourceConfigurations.set(this, server.configJson);
  }

  matches(scope: SearchScope, server: VideoServer | undefined): boolean {
    const configuration = videoServerSearchSourceConfigurations.get(this) ?? '';
    return scope.kind === 'videoServer' && scope.key === this.scopeKey &&
      scope.serverId === this.serverId && scope.serverType === this.serverType &&
      server !== undefined && server.id === this.serverId && server.type === this.serverType &&
      server.configJson === configuration;
  }
}

export interface VideoServerSearchItem {
  key: string;
  scopeKey: string;
  serverId: number;
  serverType: VideoServerType;
  media: VideoServerMediaItem;
  selection: VideoServerSearchSelection;
  sourceSnapshot: VideoServerSearchSourceSnapshot;
}

/** 终态结果不包含原始错误或配置；图片 URL 沿用客户端鉴权，禁止写入日志。 */
export interface VideoServerSearchResult {
  status: 'loading' | 'success' | 'empty' | 'error';
  scopeKey: string;
  keyword: string;
  items: VideoServerSearchItem[];
  errorCode: VideoServerSearchErrorCode;
}

/** 无状态搜索仅返回首屏最多 100 条，不代表总数或分页契约。
 * 每次调用在 IO 前捕获身份，不发布共享状态。
 * 调用方须用请求代次校验完成回调，并在来源、配置变化或销毁时使请求失效。
 */
export class VideoServerSearchService {
  createLoadingState(scope: SearchScope, server: VideoServer, keyword: string): VideoServerSearchResult {
    const resolved = resolveSearchScope(toSearchScopeIdentity(scope), [server]);
    const result: VideoServerSearchResult = {
      status: 'loading', scopeKey: resolved.key, keyword: keyword.trim(), items: [], errorCode: 'none'
    };
    if (scope.kind !== 'videoServer' || resolved.kind !== 'videoServer' ||
      scope.serverType !== server.type || resolved.serverId === undefined) {
      result.scopeKey = 'unavailable';
      return this.fail(result, 'unavailable');
    }
    if (result.keyword.length === 0) { return this.fail(result, 'invalidQuery'); }
    return result;
  }

  async search(scope: SearchScope, server: VideoServer, keyword: string): Promise<VideoServerSearchResult> {
    const result = this.createLoadingState(scope, server, keyword);
    if (result.status === 'error') { return result; }
    // 在等待前捕获身份快照，避免 IO 期间调用方修改所选服务器。
    const serverId = server.id as number;
    const serverType = server.type;
    const sourceSnapshot = new VideoServerSearchSourceSnapshot(result.scopeKey, server);
    try {
      let mediaItems: VideoServerMediaItem[];
      if (serverType === VideoServerType.PLEX) {
        mediaItems = await PlexClient.fromConfigJson(server.configJson).searchItems(result.keyword);
      } else {
        mediaItems = await JellyfinClient.fromConfigJson(server.configJson).searchItems(result.keyword);
      }
      const seen = new Set<string>();
      for (const media of mediaItems) {
        const mediaType = this.normalizeMediaType(media.type);
        if (media.id.length === 0 || mediaType === null) { continue; }
        const key = `${result.scopeKey}:${encodeURIComponent(media.id)}`;
        if (seen.has(key)) { continue; }
        seen.add(key);
        const selection = this.createSelection(serverId, serverType, media, mediaType);
        const item: VideoServerSearchItem = {
          key, scopeKey: result.scopeKey, serverId, serverType, media, selection, sourceSnapshot
        };
        result.items.push(item);
        if (result.items.length === 100) { break; }
      }
      result.status = result.items.length > 0 ? 'success' : 'empty';
      return result;
    } catch (e) {
      const error = e as BusinessError;
      const message = (error.message ?? '').toLowerCase();
      if (message.includes('鉴权失败') || message.includes('缺少') || message.includes('accesstoken')) {
        return this.fail(result, 'auth');
      }
      if (error.code === 2300028 || message.includes('timeout') || message.includes('timed out') ||
        message.includes('超时')) { return this.fail(result, 'timeout'); }
      if (e instanceof SyntaxError || e instanceof TypeError || message === 'invalid search response') {
        return this.fail(result, 'invalidResponse');
      }
      return this.fail(result, 'network');
    }
  }

  private fail(result: VideoServerSearchResult, code: VideoServerSearchErrorCode): VideoServerSearchResult {
    result.status = 'error';
    result.items = [];
    result.errorCode = code;
    return result;
  }

  private normalizeMediaType(type: string): NormalizedVideoServerMediaType | null {
    if (type === 'movie' || type === 'series' || type === 'episode') {
      return type;
    }
    return null;
  }

  private createSelection(serverId: number, serverType: VideoServerType, media: VideoServerMediaItem,
    mediaType: NormalizedVideoServerMediaType): VideoServerSearchSelection {
    const detailItemId = mediaType === 'episode' && media.seriesId.length > 0 ? media.seriesId : media.id;
    const selection: VideoServerSearchSelection = {
      serverId, serverType, mediaId: media.id, mediaType, detailItemId
    };
    return selection;
  }
}
