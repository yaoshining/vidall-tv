import { describe, it, expect, beforeEach, afterEach, MockKit, when, ArgumentMatchers } from '@ohos/hypium';
import { VideoServer, VideoServerType } from '../main/ets/db/models/VideoServerEntity';
import { SearchScopeIdentity, resolveSearchScope, createLocalSearchScope } from '../main/ets/models/search/SearchScope';
import { JsonHttpClient, JsonHttpResponse, JsonHttpTransportError } from '../main/ets/lib/JsonHttpClient';
import { BusinessError } from '@kit.BasicServicesKit';
import { VideoServerSearchService } from '../main/ets/services/search/VideoServerSearchService';

function server(id: number, type: VideoServerType = VideoServerType.JELLYFIN): VideoServer {
  const value: VideoServer = {
    id, type, name: `Server ${id}`, createdAt: 1,
    configJson: JSON.stringify({ url: `server-${id}.test`, port: 8096, protocol: 'https',
      basePath: '/media', authMethod: 'apikey', apiKey: `fake-${id}`, token: `fake-${id}` })
  };
  return value;
}

class DeferredSearchResponse {
  private resolveResponse: (response: JsonHttpResponse) => void = () => {};
  promise: Promise<JsonHttpResponse> = new Promise<JsonHttpResponse>((resolve) => {
    this.resolveResponse = resolve;
  });

  complete(response: JsonHttpResponse): void {
    this.resolveResponse(response);
  }
}

export default function videoServerSearchTest() {
  describe('VideoServerSearch', () => {
    const service = new VideoServerSearchService();
    let mocker = new MockKit();
    let urls: string[] = [];
    let tokens: string[] = [];
    let status = 200;
    let body = '';
    let failure = '';
    beforeEach(() => {
      mocker = new MockKit();
      urls = [];
      tokens = [];
      status = 200;
      failure = '';
      body = '{"Items":[{"Id":"same","Name":"Film","Type":"Movie"}]}';
      // 仅替换 HTTP 边界，协议解析、鉴权与搜索归一化仍执行真实客户端。
      const mockGet: Function = mocker.mockFunc(JsonHttpClient, JsonHttpClient.get);
      when(mockGet)(ArgumentMatchers.anyString, ArgumentMatchers.anyObj).afterAction(async (url: string, headers: Record<string, string>): Promise<JsonHttpResponse> => {
        urls.push(url);
        tokens.push(headers['X-Emby-Token'] ?? headers['X-Plex-Token'] ?? '');
        if (failure === 'native') {
          const error = new Error('localized transport failure') as BusinessError;
          error.code = 2300028;
          throw new JsonHttpTransportError(error);
        }
        if (failure.length > 0) { throw new Error(failure); }
        const response: JsonHttpResponse = {
          statusCode: status, body: url.endsWith('/Users') ? '[{"Id":"user"}]' : body
        };
        return response;
      });
      const mockPost: Function = mocker.mockFunc(JsonHttpClient, JsonHttpClient.post);
      when(mockPost)(ArgumentMatchers.anyString, ArgumentMatchers.anyObj, ArgumentMatchers.anyString).afterAction((): Promise<JsonHttpResponse> => {
        return Promise.reject(new Error('非预期的 HTTP POST 请求'));
      });
    });
    afterEach(() => {
      mocker.clear(JsonHttpClient);
    });
    for (const type of [VideoServerType.JELLYFIN, VideoServerType.EMBY, VideoServerType.PLEX]) {
      it(`routes ${type} only to selected instance and normalizes media`, 0, async () => {
        const target = server(2, type);
        if (type === VideoServerType.PLEX) {
          body = '{"MediaContainer":{"Hub":[{"type":"show","Metadata":[{"ratingKey":"same","title":"TV","type":"show"}]}]}}';
        }
        const identity: SearchScopeIdentity = { kind: 'videoServer', serverId: 2, serverType: type };
        const scope = resolveSearchScope(identity, [server(1, type), target]);
        const result = await service.search(scope, target, ' 中文 &/? ');
        expect(result.status).assertEqual('success');
        expect(result.items[0].serverId).assertEqual(2);
        expect(result.items[0].serverType).assertEqual(type);
        expect(result.items[0].media.type).assertEqual(type === VideoServerType.PLEX ? 'series' : 'movie');
        expect(result.items[0].selection.serverId).assertEqual(2);
        expect(result.items[0].selection.serverType).assertEqual(type);
        expect(result.items[0].selection.mediaId).assertEqual('same');
        expect(result.items[0].selection.mediaType).assertEqual(type === VideoServerType.PLEX ? 'series' : 'movie');
        expect(result.items[0].selection.detailItemId).assertEqual('same');
        expect(result.items[0].sourceSnapshot.matches(scope, target)).assertTrue();
        expect(urls.every((url: string) => url.startsWith('https://server-2.test:8096/'))).assertTrue();
        expect(urls[urls.length - 1].includes(encodeURIComponent('中文 &/?'))).assertTrue();
        expect(tokens.every((token: string) => token === 'fake-2')).assertTrue();
        expect(urls[urls.length - 1].includes(type === VideoServerType.PLEX ? '/hubs/search?' : '/media/Users/user/Items?')).assertTrue();
      });
    }
    it('separates identical media IDs across same-protocol A/B and ignores forged key', 0, async () => {
      const a = server(1);
      const b = server(2);
      const identityA: SearchScopeIdentity = { kind: 'videoServer', serverId: 1 };
      const identityB: SearchScopeIdentity = { kind: 'videoServer', serverId: 2 };
      const scopeA = resolveSearchScope(identityA, [a, b]);
      scopeA.key = 'local-files';
      const first = await service.search(scopeA, a, 'film');
      const second = await service.search(resolveSearchScope(identityB, [a, b]), b, 'film');
      expect(first.items[0].key).assertEqual('video-server:jellyfin:1:same');
      expect(second.items[0].key).assertEqual('video-server:jellyfin:2:same');
    });
    it('rejects local, missing and mismatched identity without IO or fallback', 0, async () => {
      const a = server(1);
      const identity: SearchScopeIdentity = { kind: 'videoServer', serverId: 1 };
      const scope = resolveSearchScope(identity, [a]);
      expect((await service.search(createLocalSearchScope(), a, 'film')).errorCode).assertEqual('unavailable');
      expect((await service.search(scope, server(2), 'film')).errorCode).assertEqual('unavailable');
      expect((await service.search(scope, server(1, VideoServerType.PLEX), 'film')).errorCode).assertEqual('unavailable');
      expect((await service.search(resolveSearchScope(identity, []), a, 'film')).errorCode).assertEqual('unavailable');
      expect((await service.search(scope, a, '  ')).errorCode).assertEqual('invalidQuery');
      expect(urls.length).assertEqual(0);
    });
    it('exposes independent loading, empty and malformed-response states', 0, async () => {
      const a = server(1);
      const identity: SearchScopeIdentity = { kind: 'videoServer', serverId: 1 };
      const scope = resolveSearchScope(identity, [a]);
      const loading = service.createLoadingState(scope, a, ' film ');
      body = '{"Items":[]}';
      expect((await service.search(scope, a, 'film')).status).assertEqual('empty');
      expect(loading.status).assertEqual('loading');
      expect(loading.keyword).assertEqual('film');
      for (const invalid of ['{}', 'not json', 'null']) {
        body = invalid;
        expect((await service.search(scope, a, 'film')).errorCode).assertEqual('invalidResponse');
      }
    });
    for (const type of [VideoServerType.JELLYFIN, VideoServerType.EMBY, VideoServerType.PLEX]) {
      for (const code of [401, 403]) {
        it(`normalizes ${type} ${code} without exposing response`, 0, async () => {
          const a = server(1, type);
          const identity: SearchScopeIdentity = { kind: 'videoServer', serverId: 1 };
          status = code;
          body = 'sensitive response';
          const result = await service.search(resolveSearchScope(identity, [a]), a, 'film');
          expect(result.errorCode).assertEqual('auth');
          expect(result.items.length).assertEqual(0);
          expect(JSON.stringify(result).includes('sensitive')).assertEqual(false);
        });
      }
    }
    it('normalizes native and textual timeouts and generic network failures', 0, async () => {
      const a = server(1);
      const identity: SearchScopeIdentity = { kind: 'videoServer', serverId: 1 };
      const scope = resolveSearchScope(identity, [a]);
      for (const message of ['native', 'timeout', 'timed out']) {
        failure = message;
        expect((await service.search(scope, a, 'film')).errorCode).assertEqual('timeout');
      }
      failure = 'private host refused';
      const result = await service.search(scope, a, 'film');
      expect(result.errorCode).assertEqual('network');
      expect(JSON.stringify(result).includes('private host')).assertEqual(false);
    });
    it('loading factory validates real identity and blank input without IO', 0, () => {
      const a = server(1);
      const identity: SearchScopeIdentity = { kind: 'videoServer', serverId: 1 };
      const scope = resolveSearchScope(identity, [a]);
      scope.key = 'forged';
      expect(service.createLoadingState(scope, a, 'film').scopeKey).assertEqual('video-server:jellyfin:1');
      expect(service.createLoadingState(scope, server(2), 'film').errorCode).assertEqual('unavailable');
      expect(service.createLoadingState(scope, server(1, VideoServerType.PLEX), 'film').status).assertEqual('error');
      expect(service.createLoadingState(createLocalSearchScope(), a, 'film').scopeKey).assertEqual('unavailable');
      expect(service.createLoadingState(scope, a, '  ').errorCode).assertEqual('invalidQuery');
      expect(urls.length).assertEqual(0);
    });
    it('encodes media identity segments without delimiter or percent collisions', 0, async () => {
      const a = server(1);
      const identity: SearchScopeIdentity = { kind: 'videoServer', serverId: 1 };
      body = '{"Items":[{"Id":"a:b/c","Type":"Movie"},{"Id":"a%3Ab%2Fc","Type":"Movie"}]}';
      const result = await service.search(resolveSearchScope(identity, [a]), a, 'film');
      expect(result.items.length).assertEqual(2);
      expect(result.items[0].key).assertEqual('video-server:jellyfin:1:a%3Ab%2Fc');
      expect(result.items[1].key).assertEqual('video-server:jellyfin:1:a%253Ab%252Fc');
      expect(result.items[0].selection.mediaId).assertEqual('a:b/c');
      expect(result.items[1].selection.mediaId).assertEqual('a%3Ab%2Fc');
    });
    it('Plex handles empty hubs, filters non-video and deduplicates local metadata', 0, async () => {
      const a = server(1, VideoServerType.PLEX);
      const identity: SearchScopeIdentity = { kind: 'videoServer', serverId: 1 };
      const scope = resolveSearchScope(identity, [a]);
      for (const empty of ['{"MediaContainer":{"size":0}}', '{"MediaContainer":{"Hub":[]}}']) {
        body = empty;
        expect((await service.search(scope, a, 'film')).status).assertEqual('empty');
      }
      body = '{"MediaContainer":{"Hub":[{"type":"actor"},{"type":"movie","Metadata":[' +
        '{"ratingKey":"same","type":"movie"},{"ratingKey":"same","type":"movie"},' +
        '{"type":"movie"}]}]}}';
      expect((await service.search(scope, a, 'film')).items.length).assertEqual(1);
      for (const invalid of ['{}', '{"MediaContainer":{"Hub":{}}}', '{"MediaContainer":null}']) {
        body = invalid;
        expect((await service.search(scope, a, 'film')).errorCode).assertEqual('invalidResponse');
      }
    });
    it('source snapshot serialization never exposes raw config', 0, async () => {
      const a = server(1);
      const identity: SearchScopeIdentity = { kind: 'videoServer', serverId: 1 };
      const result = await service.search(resolveSearchScope(identity, [a]), a, 'film');
      expect(result.items.length).assertEqual(1);
      const serialized = JSON.stringify(result.items[0].sourceSnapshot);
      expect(serialized).assertEqual('{"scopeKey":"video-server:jellyfin:1","serverId":1,"serverType":"jellyfin"}');
      expect(serialized.includes('fake-1')).assertEqual(false);
      expect(serialized.includes('server-1.test')).assertEqual(false);
      expect(serialized.includes('config')).assertEqual(false);
    });
    it('late request completion keeps captured identity and cannot mutate newer result', 0, async () => {
      const a = server(1, VideoServerType.PLEX);
      const b = server(2, VideoServerType.PLEX);
      const identityA: SearchScopeIdentity = { kind: 'videoServer', serverId: 1 };
      const identityB: SearchScopeIdentity = { kind: 'videoServer', serverId: 2 };
      const scopeA = resolveSearchScope(identityA, [a]);
      const pending = new DeferredSearchResponse();
      const deferredMocker = new MockKit();
      const mockGet: Function = deferredMocker.mockFunc(JsonHttpClient, JsonHttpClient.get);
      when(mockGet)(ArgumentMatchers.anyString, ArgumentMatchers.anyObj).afterAction((url: string): Promise<JsonHttpResponse> => {
        if (url.includes('server-1.test')) { return pending.promise; }
        const response: JsonHttpResponse = { statusCode: 200, body: '{"MediaContainer":{"size":0}}' };
        return Promise.resolve(response);
      });
      const oldRequest = service.search(scopeA, a, 'old');
      a.id = 99;
      scopeA.serverId = 99;
      const current = await service.search(resolveSearchScope(identityB, [b]), b, 'new');
      const response: JsonHttpResponse = { statusCode: 200,
        body: '{"MediaContainer":{"Hub":[{"type":"movie","Metadata":[{"ratingKey":"same","type":"movie"}]}]}}' };
      pending.complete(response);
      const old = await oldRequest;
      expect(old.items[0].serverId).assertEqual(1);
      expect(old.scopeKey).assertEqual('video-server:plex:1');
      expect(old.keyword).assertEqual('old');
      expect(current.scopeKey).assertEqual('video-server:plex:2');
      expect(current.keyword).assertEqual('new');
      expect(current.status).assertEqual('empty');
      expect(current.items.length).assertEqual(0);
    });
    for (const type of [VideoServerType.JELLYFIN, VideoServerType.EMBY, VideoServerType.PLEX]) {
      it(`episodes retain original media identity and route ${type} detail to series entry`, 0, async () => {
        const a = server(1, type);
        const identity: SearchScopeIdentity = { kind: 'videoServer', serverId: 1, serverType: type };
        if (type === VideoServerType.PLEX) {
          body = '{"MediaContainer":{"Hub":[{"type":"episode","Metadata":[{"ratingKey":"episode-1",' +
            '"grandparentRatingKey":"series-1","title":"Episode","type":"episode"}]}]}}';
        } else {
          body = '{"Items":[{"Id":"episode-1","SeriesId":"series-1","Name":"Episode","Type":"Episode"}]}';
        }
        const result = await service.search(resolveSearchScope(identity, [a]), a, 'film');
        expect(result.items.length).assertEqual(1);
        expect(result.items[0].selection.mediaId).assertEqual('episode-1');
        expect(result.items[0].selection.mediaType).assertEqual('episode');
        expect(result.items[0].selection.detailItemId).assertEqual('series-1');
      });
    }
    it('reuses password authentication and its returned user', 0, async () => {
      const a = server(1);
      a.configJson = '{"url":"server-1.test","authMethod":"password","username":"test","password":"fake"}';
      const authenticationMocker = new MockKit();
      const mockPost: Function = authenticationMocker.mockFunc(JsonHttpClient, JsonHttpClient.post);
      when(mockPost)(ArgumentMatchers.anyString, ArgumentMatchers.anyObj, ArgumentMatchers.anyString).afterAction(async (): Promise<JsonHttpResponse> => {
        const response: JsonHttpResponse = { statusCode: 200, body: '{"AccessToken":"fake-1","User":{"Id":"signed-in"}}' };
        return response;
      });
      const identity: SearchScopeIdentity = { kind: 'videoServer', serverId: 1 };
      expect((await service.search(resolveSearchScope(identity, [a]), a, 'film')).status).assertEqual('success');
      expect(urls.length).assertEqual(1);
      expect(urls[0].includes('/Users/signed-in/Items?')).assertTrue();
      expect(tokens[0]).assertEqual('fake-1');
    });
  });
}
