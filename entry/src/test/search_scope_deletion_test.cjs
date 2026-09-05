// Host-only regression: native database IO is stubbed by search_scope_test.cjs.
// Both deletion methods, source state, persistence and scope resolution are real.
const { describe, it, expect, beforeEach, afterEach } = require('@ohos/hypium');
const { VideoServerModel } = require('../main/ets/stores/servers/VideoServerModel.ets');
const { SourceSwitchModel } = require('../main/ets/stores/media/SourceSwitchModel.ets');
const { AppPreferences, PrefKey } = require('../main/ets/utils/AppPreferences.ets');
const { getSearchCapabilities, resolveSearchRoute } = require('../main/ets/models/search/SearchScope.ets');

module.exports = function deletionTests() {
  describe('Search scope actual server deletion', () => {
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
    it('deleting another server leaves active identity and persistence unchanged', 0, async () => {
      const persisted = values.get(PrefKey.ACTIVE_MEDIA_SOURCE);
      await model.deleteVideoServerWithFallback(2);
      expect(model.getVideoServerById(2)).assertEqual(null);
      expect(source.getActiveServerId()).assertEqual(1);
      expect(source.getSearchScope(model.videoServers).key).assertEqual('video-server:jellyfin:1');
      expect(values.get(PrefKey.ACTIVE_MEDIA_SOURCE)).assertEqual(persisted);
    });
    it('only explicit local selection enables local search after deletion', 0, async () => {
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
