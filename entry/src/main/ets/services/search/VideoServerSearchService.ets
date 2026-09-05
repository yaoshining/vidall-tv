import { BusinessError } from '@kit.BasicServicesKit';
import { VideoServer, VideoServerType } from '../../db/models/VideoServerEntity';
import { JellyfinClient, VideoServerMediaItem } from '../../lib/JellyfinClient';
import { PlexClient } from '../../lib/PlexClient';
import { SearchScope, resolveSearchScope, toSearchScopeIdentity } from '../../models/search/SearchScope';

export type VideoServerSearchErrorCode =
  'none' | 'unavailable' | 'invalidQuery' | 'auth' | 'timeout' | 'network' | 'invalidResponse';

export interface VideoServerSearchItem {
  key: string;
  scopeKey: string;
  serverId: number;
  serverType: VideoServerType;
  media: VideoServerMediaItem;
}

/** Terminal results contain no raw errors/configuration. Image URLs inherit client authentication: do not log them. */
export interface VideoServerSearchResult {
  status: 'loading' | 'success' | 'empty' | 'error';
  scopeKey: string;
  keyword: string;
  items: VideoServerSearchItem[];
  errorCode: VideoServerSearchErrorCode;
}

/** Stateless, bounded first-page search (100 items); not a total count or pagination contract.
 * Each invocation captures its identity before IO and never publishes shared state.
 * Consumers must guard completion with their request generation, invalidating on source/config changes or disposal.
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
    // Snapshot identity before awaiting; callers may mutate their selected server while IO is pending.
    const serverId = server.id as number;
    const serverType = server.type;
    try {
      let mediaItems: VideoServerMediaItem[];
      if (serverType === VideoServerType.PLEX) {
        mediaItems = await PlexClient.fromConfigJson(server.configJson).searchItems(result.keyword);
      } else {
        mediaItems = await JellyfinClient.fromConfigJson(server.configJson).searchItems(result.keyword);
      }
      const seen = new Set<string>();
      for (const media of mediaItems) {
        if (media.id.length === 0 ||
          (media.type !== 'movie' && media.type !== 'series' && media.type !== 'episode')) { continue; }
        const key = `${result.scopeKey}:${encodeURIComponent(media.id)}`;
        if (seen.has(key)) { continue; }
        seen.add(key);
        const item: VideoServerSearchItem = { key, scopeKey: result.scopeKey, serverId, serverType, media };
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
}
