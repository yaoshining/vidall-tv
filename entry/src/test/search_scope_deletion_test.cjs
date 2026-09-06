// 主机回归：原生数据库 IO 由 search_scope_test.cjs 替换。
// 执行真实删除方法、来源状态、偏好持久化逻辑和范围解析。
const { describe, it, expect, beforeEach, afterEach } = require('@ohos/hypium');
const { VideoServerModel } = require('../main/ets/stores/servers/VideoServerModel.ets');
const { SourceSwitchModel } = require('../main/ets/stores/media/SourceSwitchModel.ets');
const { AppPreferences, PrefKey } = require('../main/ets/utils/AppPreferences.ets');
const { getSearchCapabilities, resolveSearchRoute } = require('../main/ets/models/search/SearchScope.ets');

module.exports = function deletionTests() {
  describe('搜索范围真实服务器删除', () => {
    let source, model, values;
    beforeEach(async () => {
      values = new Map();
      AppPreferences.resetForTesting();
      AppPreferences.setStoreLoaderForTesting(async () => ({
        get: async (key, fallback) => values.has(key) ? values.get(key) : fallback,
        put: async (key, value) => { values.set(key, value); },
        flush: async () => {}
      }));
      await AppPreferences.init({});
      source = SourceSwitchModel.getState();
      model = new VideoServerModel();
      model.videoServers = [1, 2].map(id => ({
        id, name: `Server ${id}`, type: 'jellyfin', configJson: '{}', createdAt: 1
      }));
      await source.setVideoServer(model.videoServers[0]);
    });
    afterEach(async () => {
      await source.setFileSource();
      AppPreferences.setStoreLoaderForTesting(null);
      AppPreferences.resetForTesting();
    });
    it('source notifications invalidate A B A synchronously before persistence', 0, async () => {
      const { SearchWorkspaceSession } = require('../main/ets/services/search/SearchWorkspaceSession.ets');
      const { VideoServerSearchService } = require('../main/ets/services/search/VideoServerSearchService.ets');
      const session = new SearchWorkspaceSession();
      const service = new VideoServerSearchService();
      let complete;
      service.search = () => new Promise(resolve => { complete = resolve; });
      const states = [];
      const current = () => {
        const scope = source.getSearchScope(model.videoServers);
        return { scope, server: model.getVideoServerById(scope.serverId) };
      };
      let notifications = 0;
      const unsubscribe = source.subscribeSearchSource(() => { notifications++; session.invalidate(); });
      const request = session.search('film', current, result => states.push(result.status), service);
      const b = source.setVideoServer(model.videoServers[1]);
      expect(notifications).assertEqual(1);
      const a = source.setVideoServer(model.videoServers[0]);
      expect(notifications).assertEqual(2);
      complete({ status: 'error', scopeKey: current().scope.key, keyword: 'film', items: [], errorCode: 'network' });
      await request; await a; await b;
      expect(states.join(',')).assertEqual('loading');
      unsubscribe();
      await source.setVideoServer(model.videoServers[0]);
      expect(notifications).assertEqual(2);
    });
    it('real same-id configuration update invalidates even after config returns to original', 0, async () => {
      const { SearchWorkspaceSession } = require('../main/ets/services/search/SearchWorkspaceSession.ets');
      const { VideoServerSearchService } = require('../main/ets/services/search/VideoServerSearchService.ets');
      const session = new SearchWorkspaceSession();
      const service = new VideoServerSearchService();
      let complete;
      service.search = () => new Promise(resolve => { complete = resolve; });
      const current = () => {
        const scope = source.getSearchScope(model.videoServers);
        return { scope, server: model.getVideoServerById(scope.serverId) };
      };
      let notifications = 0;
      const unsubscribe = model.subscribeSearchConfiguration(() => { notifications++; session.invalidate(); });
      const states = [];
      const request = session.search('film', current, result => states.push(result.status), service);
      const original = model.videoServers[0];
      await model.updateVideoServer({ ...original, configJson: '{"url":"changed"}' });
      await model.updateVideoServer(original);
      expect(notifications).assertEqual(2);
      complete({ status: 'success', scopeKey: current().scope.key, keyword: 'film', items: [], errorCode: 'none' });
      await request;
      expect(states.join(',')).assertEqual('loading');
      unsubscribe();
      await model.updateVideoServer(original);
      expect(notifications).assertEqual(2);
    });
    it('deletion notifies configuration consumers with unavailable active source', 0, async () => {
      let observed = '';
      const unsubscribe = model.subscribeSearchConfiguration(() => {
        observed = source.getSearchScope(model.videoServers).kind;
      });
      await model.deleteVideoServerWithFallback(1);
      expect(observed).assertEqual('unavailable');
      unsubscribe();
    });
    it('deleting active server preserves unavailable identity and persisted selection', 0, async () => {
      const persisted = values.get(PrefKey.ACTIVE_MEDIA_SOURCE);
      await model.deleteVideoServerWithFallback(1);
      expect(model.getVideoServerById(1)).assertEqual(null);
      expect(source.getActiveServerId()).assertEqual(1);
      expect(values.get(PrefKey.ACTIVE_MEDIA_SOURCE)).assertEqual(persisted);
      const scope = source.getSearchScope(model.videoServers);
      expect(scope.kind).assertEqual('unavailable');
      expect(getSearchCapabilities(scope).localSearch).assertEqual(false);
      expect(getSearchCapabilities(scope).localHistory).assertEqual(false);
      expect(resolveSearchRoute(null, scope, model.videoServers).scope.kind).assertEqual('unavailable');
      expect(resolveSearchRoute('movie', scope, model.videoServers).scope.kind).assertEqual('unavailable');
      const restored = new SourceSwitchModel();
      await restored.load(model.videoServers);
      expect(restored.getSearchScope(model.videoServers).kind).assertEqual('unavailable');
    });
    it('删除其他服务器不改变当前身份与持久化选择', 0, async () => {
      const persisted = values.get(PrefKey.ACTIVE_MEDIA_SOURCE);
      await model.deleteVideoServerWithFallback(2);
      expect(model.getVideoServerById(2)).assertEqual(null);
      expect(source.getActiveServerId()).assertEqual(1);
      expect(source.getSearchScope(model.videoServers).key).assertEqual('video-server:jellyfin:1');
      expect(values.get(PrefKey.ACTIVE_MEDIA_SOURCE)).assertEqual(persisted);
    });
    it('删除后仅主动选择本地才启用本地搜索', 0, async () => {
      await model.deleteVideoServerWithFallback(1);
      expect(getSearchCapabilities(source.getSearchScope(model.videoServers)).localSearch).assertEqual(false);
      await source.setFileSource();
      const scope = source.getSearchScope(model.videoServers);
      expect(scope.key).assertEqual('local-files');
      expect(getSearchCapabilities(scope).localSearch).assertTrue();
      expect(getSearchCapabilities(scope).localHistory).assertTrue();
      const restored = new SourceSwitchModel();
      await restored.load(model.videoServers);
      expect(restored.getSearchScope(model.videoServers).key).assertEqual('local-files');
    });
  });
};
