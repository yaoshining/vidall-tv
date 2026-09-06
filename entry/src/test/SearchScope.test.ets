import { describe, it, expect } from '@ohos/hypium';
import { SearchScopeIdentity, SearchRouteParam, createLocalSearchScope, resolveSearchScope, resolveSearchRoute, getSearchCapabilities } from '../main/ets/models/search/SearchScope';
import { VideoServer, VideoServerType } from '../main/ets/db/models/VideoServerEntity';

export default function searchScopeTest() {
  const servers: VideoServer[] = [
    { id: 1, type: VideoServerType.JELLYFIN, name: 'A', configJson: '{}', createdAt: 1 },
    { id: 2, type: VideoServerType.PLEX, name: 'B', configJson: '{}', createdAt: 1 }
  ];
  describe('搜索来源范围', () => {
    it('聚合本地文件源配置', 0, () => {
      expect(createLocalSearchScope().key).assertEqual('local-files');
      expect(createLocalSearchScope().label).assertEqual('本地文件源');
      expect(getSearchCapabilities(createLocalSearchScope()).localSearch).assertTrue();
    });
    it('从配置恢复旧服务器身份', 0, () => {
      const scope = resolveSearchScope({ kind: 'videoServer', serverId: 1 } as SearchScopeIdentity, servers);
      expect(scope.key).assertEqual('video-server:jellyfin:1');
      expect(scope.label).assertEqual('A');
      expect(getSearchCapabilities(scope).localHistory).assertEqual(false);
      expect(getSearchCapabilities(scope).serverSearch).assertEqual(true);
      expect(getSearchCapabilities(scope).inputModes.join(',')).assertEqual('text');
    });
    it('隔离服务器实例与类型', 0, () => {
      expect(resolveSearchScope({ kind: 'videoServer', serverId: 2 } as SearchScopeIdentity, servers).key)
        .assertEqual('video-server:plex:2');
    });
    it('重新生成不可信来源键', 0, () => {
      const scope = resolveSearchScope({ kind: 'videoServer', serverId: 1,
        serverType: VideoServerType.JELLYFIN, key: 'local-files' } as SearchScopeIdentity, servers);
      expect(scope.key).assertEqual('video-server:jellyfin:1');
    });
    it('删除或类型不匹配时禁止回退本地', 0, () => {
      const deleted = resolveSearchScope({ kind: 'videoServer', serverId: 99 } as SearchScopeIdentity, servers);
      const mismatch = resolveSearchScope({ kind: 'videoServer', serverId: 1,
        serverType: VideoServerType.PLEX } as SearchScopeIdentity, servers);
      expect(deleted.kind).assertEqual('unavailable');
      expect(mismatch.kind).assertEqual('unavailable');
      expect(getSearchCapabilities(deleted).localSearch).assertEqual(false);
      expect(getSearchCapabilities(deleted).localHistory).assertEqual(false);
    });
    it('旧空值与关键词路由跟随当前服务器', 0, () => {
      const current = resolveSearchScope({ kind: 'videoServer', serverId: 1 } as SearchScopeIdentity, servers);
      expect(resolveSearchRoute(null, current, servers).scope.key).assertEqual(current.key);
      const route = resolveSearchRoute('hello', current, servers);
      expect(route.scope.key).assertEqual(current.key);
      expect(route.keyword).assertEqual('hello');
    });
    it('显式范围在切源与序列化后保持身份', 0, () => {
      const route = resolveSearchRoute({ scope: { kind: 'videoServer', serverId: 2 } } as SearchRouteParam,
        createLocalSearchScope(), servers);
      expect(resolveSearchRoute(JSON.parse(JSON.stringify(route)) as SearchRouteParam, createLocalSearchScope(), servers)
        .scope.key).assertEqual('video-server:plex:2');
    });
    it('无效显式范围禁止回退本地', 0, () => {
      expect(resolveSearchRoute({ scope: { kind: 'bad' } } as SearchRouteParam, createLocalSearchScope(), servers)
        .scope.kind).assertEqual('unavailable');
    });
  });
}
