import { describe, it, expect, beforeEach, afterEach } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@ohos.abilityAccessCtrl';
import {
  AppPreferences,
  PrefKey,
  AppPreferencesLoader,
  AppPreferencesStore
} from '../main/ets/utils/AppPreferences';
import { SourceSwitchModel } from '../main/ets/stores/media/SourceSwitchModel';
import { VideoServer, VideoServerType } from '../main/ets/db/models/VideoServerEntity';

class InMemoryAppPreferencesStore implements AppPreferencesStore {
  private readonly values: Map<string, string | number> = new Map<string, string | number>();

  async get(key: string, defaultValue: string | number): Promise<string | number> {
    const value = this.values.get(key);
    return value === undefined ? defaultValue : value;
  }

  async put(key: string, value: string | number): Promise<void> {
    this.values.set(key, value);
  }

  async flush(): Promise<void> {
  }
}

function makeServer(id: number, name: string): VideoServer {
  return {
    id,
    name,
    type: VideoServerType.JELLYFIN,
    configJson: '{}',
    createdAt: 1
  };
}

export default function sourceSwitchModelTest() {
  describe('SourceSwitchModel 源切换', () => {
    let store: InMemoryAppPreferencesStore;

    beforeEach(async () => {
      AppPreferences.resetForTesting();
      store = new InMemoryAppPreferencesStore();
      const loader: AppPreferencesLoader = async () => store;
      AppPreferences.setStoreLoaderForTesting(loader);
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      await AppPreferences.init(ctx);
    });

    afterEach(() => {
      AppPreferences.setStoreLoaderForTesting(null);
      AppPreferences.resetForTesting();
    });

    it('默认显示名为文件源', 0, () => {
      const model = new SourceSwitchModel();
      expect(model.getDisplayName()).assertEqual('文件源');
      expect(model.isFileSource()).assertTrue();
      expect(model.getActiveServerId()).assertEqual(undefined);
    });

    it('setVideoServer 后显示名为服务器名', 0, () => {
      const model = new SourceSwitchModel();
      model.setVideoServer(makeServer(3, 'Home'));
      expect(model.getDisplayName()).assertEqual('Home');
      expect(model.isFileSource()).assertEqual(false);
      expect(model.getActiveServerId()).assertEqual(3);
    });

    it('setFileSource 切回文件源', 0, () => {
      const model = new SourceSwitchModel();
      model.setVideoServer(makeServer(3, 'Home'));
      model.setFileSource();
      expect(model.getDisplayName()).assertEqual('文件源');
      expect(model.isFileSource()).assertTrue();
    });

    it('load 恢复已持久化的服务器源', 0, async () => {
      const model = new SourceSwitchModel();
      await model.setVideoServer(makeServer(5, 'NAS'));
      const restored = new SourceSwitchModel();
      await restored.load([makeServer(5, 'NAS')]);
      expect(restored.getDisplayName()).assertEqual('NAS');
      expect(restored.getActiveServerId()).assertEqual(5);
    });

    it('load 时服务器已删除则禁止本地搜索', 0, async () => {
      const model = new SourceSwitchModel();
      await model.setVideoServer(makeServer(9, '已删除'));
      const restored = new SourceSwitchModel();
      await restored.load([makeServer(1, 'A'), makeServer(2, 'B')]);
      expect(restored.isFileSource()).assertEqual(false);
      expect(restored.getSearchScope([]).kind).assertEqual('unavailable');
    });

    it('旧偏好仅 serverId 从配置恢复类型与名称', 0, async () => {
      await store.put(PrefKey.ACTIVE_MEDIA_SOURCE, '{"kind":"videoServer","serverId":5}');
      const model = new SourceSwitchModel();
      const servers: VideoServer[] = [makeServer(5, 'Current')];
      await model.load(servers);
      expect(model.activeSource.serverType).assertEqual(VideoServerType.JELLYFIN);
      expect(model.getDisplayName()).assertEqual('Current');
      expect(model.getSearchScope(servers).key).assertEqual('video-server:jellyfin:5');
    });

    it('未加载与损坏偏好不恢复本地搜索', 0, async () => {
      const model = new SourceSwitchModel();
      expect(model.getSearchScope([]).kind).assertEqual('unavailable');
      await store.put(PrefKey.ACTIVE_MEDIA_SOURCE, 'bad-json');
      await model.load([]);
      expect(model.getSearchScope([]).kind).assertEqual('unavailable');
    });

    it('持久化类型与现配置不匹配时不可用', 0, async () => {
      await store.put(PrefKey.ACTIVE_MEDIA_SOURCE,
        '{"kind":"videoServer","serverId":5,"serverType":"plex"}');
      const model = new SourceSwitchModel();
      const servers: VideoServer[] = [makeServer(5, 'Changed')];
      await model.load(servers);
      expect(model.getSearchScope(servers).kind).assertEqual('unavailable');
    });

    it('load 无持久化值时默认文件源', 0, async () => {
      const model = new SourceSwitchModel();
      await model.load([makeServer(1, 'A'), makeServer(2, 'B')]);
      expect(model.isFileSource()).assertTrue();
    });
  });
}
