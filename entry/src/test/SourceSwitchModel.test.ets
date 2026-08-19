import { describe, it, expect, beforeEach, afterEach } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@ohos.abilityAccessCtrl';
import {
  AppPreferences,
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
      expect(model.isFileSource()).assertFalse();
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
      model.setVideoServer(makeServer(5, 'NAS'));
      const restored = new SourceSwitchModel();
      await restored.load([5]);
      expect(restored.getDisplayName()).assertEqual('NAS');
      expect(restored.getActiveServerId()).assertEqual(5);
    });

    it('load 时服务器已删除则回退文件源', 0, async () => {
      const model = new SourceSwitchModel();
      model.setVideoServer(makeServer(9, '已删除'));
      const restored = new SourceSwitchModel();
      await restored.load([1, 2]);
      expect(restored.isFileSource()).assertTrue();
      expect(restored.getDisplayName()).assertEqual('文件源');
    });

    it('load 无持久化值时默认文件源', 0, async () => {
      const model = new SourceSwitchModel();
      await model.load([1, 2]);
      expect(model.isFileSource()).assertTrue();
    });
  });
}
