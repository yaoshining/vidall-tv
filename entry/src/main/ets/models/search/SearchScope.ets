import { VideoServer, VideoServerType } from '../../db/models/VideoServerEntity';

/** Local WebDAV/SMB configurations share one scope. Cloud drives are not included. */
export interface SearchScope {
  kind: 'localFiles' | 'videoServer' | 'unavailable';
  key: string;
  label: string;
  serverId?: number;
  serverType?: VideoServerType;
}

/** Route/persisted input is untrusted; keys and labels are always rebuilt. */
export interface SearchScopeIdentity {
  kind: string;
  key?: string;
  serverId?: number;
  serverType?: VideoServerType;
}

export interface SearchRouteParam {
  scope?: SearchScopeIdentity;
  keyword?: string;
}

export interface ResolvedSearchRoute {
  scope: SearchScope;
  keyword: string;
}

export interface SearchCapabilities {
  localSearch: boolean;
  serverSearch: boolean;
  localHistory: boolean;
  localSuggestions: boolean;
  localDetail: boolean;
  inputModes: string[];
  hint: string;
}

export function createLocalSearchScope(): SearchScope {
  const scope: SearchScope = { kind: 'localFiles', key: 'local-files', label: '本地文件源' };
  return scope;
}

export function createUnavailableSearchScope(): SearchScope {
  const scope: SearchScope = { kind: 'unavailable', key: 'unavailable', label: '来源不可用' };
  return scope;
}

export function resolveSearchScope(identity: SearchScopeIdentity, servers: VideoServer[]): SearchScope {
  if (identity === null || identity === undefined) { return createUnavailableSearchScope(); }
  if (identity.kind === 'localFiles' || identity.kind === 'fileSource') {
    return createLocalSearchScope();
  }
  if (identity.kind !== 'videoServer' || identity.serverId === undefined || !Number.isInteger(identity.serverId) ||
    (identity.serverId ?? 0) <= 0) { return createUnavailableSearchScope(); }
  const server = servers.find((item: VideoServer) => item.id === identity.serverId);
  if (server === undefined ||
    (server.type !== VideoServerType.JELLYFIN && server.type !== VideoServerType.EMBY &&
      server.type !== VideoServerType.PLEX) ||
    (identity.serverType !== undefined && identity.serverType !== server.type)) {
    return createUnavailableSearchScope();
  }
  const scope: SearchScope = {
    kind: 'videoServer', key: `video-server:${server.type}:${server.id}`,
    label: server.name, serverId: server.id, serverType: server.type
  };
  return scope;
}

/** Copy identity explicitly: ArkTS does not allow structural assignment between these interfaces. */
export function toSearchScopeIdentity(scope: SearchScope): SearchScopeIdentity {
  const identity: SearchScopeIdentity = {
    kind: scope.kind, serverId: scope.serverId, serverType: scope.serverType
  };
  return identity;
}

/** Missing scope on legacy routes means current source, never global/local fallback. */
export function resolveSearchRoute(param: SearchRouteParam | string | null | undefined,
  currentScope: SearchScope, servers: VideoServer[]): ResolvedSearchRoute {
  let scope = currentScope;
  let keyword = '';
  if (typeof param === 'string') {
    keyword = param;
  } else if (param !== null && param !== undefined) {
    if (param.scope !== undefined) { scope = resolveSearchScope(param.scope, servers); }
    keyword = typeof param.keyword === 'string' ? param.keyword : '';
  }
  const route: ResolvedSearchRoute = { scope: resolveSearchScope(toSearchScopeIdentity(scope), servers), keyword };
  return route;
}

/** Only implemented capabilities are exposed. Server search is deliberately unavailable. */
export function getSearchCapabilities(scope: SearchScope): SearchCapabilities {
  const local = scope.kind === 'localFiles';
  const capabilities: SearchCapabilities = {
    localSearch: local, serverSearch: false, localHistory: local,
    localSuggestions: local, localDetail: local,
    inputModes: local ? ['initials', 'pinyin', 'chinese'] : [],
    hint: local ? '支持首字母、全拼、中文片名搜索' :
      scope.kind === 'videoServer' ? '当前影视服务器暂不支持搜索' : '来源不可用，请返回重新选择来源'
  };
  return capabilities;
}
