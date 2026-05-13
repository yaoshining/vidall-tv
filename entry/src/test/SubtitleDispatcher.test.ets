import { describe, it, expect, beforeEach } from '@ohos/hypium';
import {
  AppPreferences,
  AppPreferencesLoader,
  AppPreferencesStore
} from '../../main/ets/utils/AppPreferences';
import { SubtitleDispatcher, SubtitleBinding } from '../../main/ets/subtitle/SubtitleDispatcher';
import { SubtitleTrackItem } from '../../main/ets/components/core/player/SubtitleBridgeAdapter';

// ──────────────────────────────────────────
// 内存 store mock
// ──────────────────────────────────────────

class InMemoryStore implements AppPreferencesStore {
  private readonly values: Map<string, string | number> = new Map<string, string | number>();

  seed(key: string, value: string | number): void {
    this.values.set(key, value);
  }

  async get(key: string, defaultValue: string | number): Promise<string | number> {
    const v = this.values.get(key);
    return v === undefined ? defaultValue : v;
  }

  async put(key: string, value: string | number): Promise<void> {
    this.values.set(key, value);
  }

  async flush(): Promise<void> {}
}

function makeLoader(store: InMemoryStore): AppPreferencesLoader {
  return async (): Promise<AppPreferencesStore> => store;
}

// ──────────────────────────────────────────
// 测试套件
// ──────────────────────────────────────────

export default function subtitleDispatcherTest() {
  describe('SubtitleDispatcher', () => {
    let store: InMemoryStore;
    let dispatcher: SubtitleDispatcher;
    const VIDEO_PATH = 'http://192.168.1.1/dav/test/movie.mkv';
    const SUBTITLE_URL = 'http://192.168.1.1/dav/test/movie.srt';

    beforeEach(async () => {
      store = new InMemoryStore();
      AppPreferences.setStoreLoaderForTesting(makeLoader(store));
      // 触发初始化（传空 Context，loader 不需要它）
      await AppPreferences.init({} as Parameters<typeof AppPreferences.init>[0]);
      dispatcher = new SubtitleDispatcher();
    });

    // ──────────────────────────────────────────
    // getUserBinding
    // ──────────────────────────────────────────

    it('getUserBinding_keyNotExist_returnsNull', async () => {
      const result = await dispatcher.getUserBinding(VIDEO_PATH);
      expect(result).toBeNull();
    });

    it('getUserBinding_validJson_returnsBinding', async () => {
      const binding: SubtitleBinding = {
        videoPath: VIDEO_PATH,
        subtitlePath: SUBTITLE_URL,
        subtitleType: 'local-file',
        savedAt: 1000000
      };
      await dispatcher.saveUserBinding(VIDEO_PATH, SUBTITLE_URL, 'local-file');
      const result = await dispatcher.getUserBinding(VIDEO_PATH);
      expect(result).not().toBeNull();
      if (result !== null) {
        expect(result.subtitlePath).assertEqual(SUBTITLE_URL);
        expect(result.subtitleType).assertEqual('local-file');
        expect(result.videoPath).assertEqual(VIDEO_PATH);
        expect(result.savedAt).assertLarger(0);
      }
      void binding;
    });

    it('getUserBinding_corruptedJson_returnsNull', async () => {
      // 直接在 store 写入损坏 JSON，key 通过已知前缀手动模拟
      // 由于 key 是 hash 计算的，先 save 一次再手动覆盖
      await dispatcher.saveUserBinding(VIDEO_PATH, SUBTITLE_URL, 'local-file');
      // 找到已写入的 key，覆盖为损坏值
      const allKeys: string[] = [];
      store['values'].forEach((_v: string | number, k: string) => {
        if (k.startsWith('subtitle_binding_')) {
          allKeys.push(k);
        }
      });
      if (allKeys.length > 0) {
        store.seed(allKeys[0], 'not-valid-json{{{');
      }
      const result = await dispatcher.getUserBinding(VIDEO_PATH);
      expect(result).toBeNull();
    });

    // ──────────────────────────────────────────
    // resolveSubtitle
    // ──────────────────────────────────────────

    it('resolveSubtitle_emptyTracks_returnsNone', async () => {
      const resolution = await dispatcher.resolveSubtitle(VIDEO_PATH, []);
      expect(resolution.type).assertEqual('none');
    });

    it('resolveSubtitle_bindingUrlMatches_returnsUserSpecified', async () => {
      await dispatcher.saveUserBinding(VIDEO_PATH, SUBTITLE_URL, 'local-file');

      const track: SubtitleTrackItem = {
        kind: 'external',
        displayName: 'movie.srt',
        url: SUBTITLE_URL
      };
      const tracks: SubtitleTrackItem[] = [track];
      const resolution = await dispatcher.resolveSubtitle(VIDEO_PATH, tracks);
      expect(resolution.type).assertEqual('user-specified');
      expect(resolution.trackIndex).assertEqual(0);
    });

    it('resolveSubtitle_bindingUrlNotInTracks_clearsBindingAndReturnsNone', async () => {
      await dispatcher.saveUserBinding(VIDEO_PATH, SUBTITLE_URL, 'local-file');

      // 传入轨道列表中不含 SUBTITLE_URL
      const track: SubtitleTrackItem = {
        kind: 'external',
        displayName: 'other.srt',
        url: 'http://192.168.1.1/dav/test/other.srt'
      };
      const tracks: SubtitleTrackItem[] = [track];
      const resolution = await dispatcher.resolveSubtitle(VIDEO_PATH, tracks);
      expect(resolution.type).assertEqual('none');

      // 绑定应已被清除
      const binding = await dispatcher.getUserBinding(VIDEO_PATH);
      expect(binding).toBeNull();
    });

    it('resolveSubtitle_noBindingNoTracks_returnsNone', async () => {
      const resolution = await dispatcher.resolveSubtitle(VIDEO_PATH, []);
      expect(resolution.type).assertEqual('none');
    });

    // ──────────────────────────────────────────
    // clearUserBinding
    // ──────────────────────────────────────────

    it('clearUserBinding_removesExistingBinding', async () => {
      await dispatcher.saveUserBinding(VIDEO_PATH, SUBTITLE_URL, 'local-file');
      await dispatcher.clearUserBinding(VIDEO_PATH);
      const result = await dispatcher.getUserBinding(VIDEO_PATH);
      expect(result).toBeNull();
    });
  });
}
