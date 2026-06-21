import { describe, it, expect } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@ohos.abilityAccessCtrl';
import {
  AppPreferences,
  AppPreferencesLoader,
  AppPreferencesStore,
  AppPreferenceValue
} from '../main/ets/utils/AppPreferences';
import { SubtitleDispatcher, SubtitleBinding, SubtitleResolution } from '../main/ets/subtitle/SubtitleDispatcher';
import { SubtitleTrackItem } from '../main/ets/components/core/player/SubtitleBridgeAdapter';

// ──────────────────────────────────────────
// 内存 store mock
// ──────────────────────────────────────────

class InMemoryStore implements AppPreferencesStore {
  private readonly values: Map<string, AppPreferenceValue> = new Map<string, AppPreferenceValue>();

  seed(key: string, value: AppPreferenceValue): void {
    this.values.set(key, value);
  }

  corruptFirstKey(prefix: string): void {
    this.values.forEach((_v: AppPreferenceValue, k: string) => {
      if (k.startsWith(prefix)) {
        this.values.set(k, 'not-valid-json{{{');
      }
    });
  }

  async get(key: string, defaultValue: AppPreferenceValue): Promise<AppPreferenceValue> {
    const v = this.values.get(key);
    return v === undefined ? defaultValue : v;
  }

  async put(key: string, value: AppPreferenceValue): Promise<void> {
    this.values.set(key, value);
  }

  async flush(): Promise<void> {}
}

interface DispatcherSetup {
  store: InMemoryStore;
  dispatcher: SubtitleDispatcher;
}

async function makeSetup(): Promise<DispatcherSetup> {
  const store = new InMemoryStore();
  const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
  const loader: AppPreferencesLoader = async () => store;
  AppPreferences.setStoreLoaderForTesting(loader);
  await AppPreferences.init(ctx);
  const dispatcher = new SubtitleDispatcher();
  const setup: DispatcherSetup = { store, dispatcher };
  return setup;
}

const VIDEO_PATH = 'http://192.168.1.1/dav/test/movie.mkv';
const SUBTITLE_URL = 'http://192.168.1.1/dav/test/movie.srt';

export default function subtitleDispatcherTest() {
  describe('SubtitleDispatcher', () => {

    it('getUserBinding_keyNotExist_returnsNull', 0, async () => {
      const setup = await makeSetup();
      const result: SubtitleBinding | null = await setup.dispatcher.getUserBinding(VIDEO_PATH);
      expect(result).assertNull();
    });

    it('getUserBinding_validJson_returnsBinding', 0, async () => {
      const setup = await makeSetup();
      await setup.dispatcher.saveUserBinding(VIDEO_PATH, SUBTITLE_URL, 'local-file');
      const result: SubtitleBinding | null = await setup.dispatcher.getUserBinding(VIDEO_PATH);
      expect(result).not().assertNull();
      if (result !== null) {
        expect(result.subtitlePath).assertEqual(SUBTITLE_URL);
        expect(result.subtitleType).assertEqual('local-file');
        expect(result.videoPath).assertEqual(VIDEO_PATH);
        expect(result.savedAt).assertLarger(0);
      }
    });

    it('getUserBinding_corruptedJson_returnsNull', 0, async () => {
      const setup = await makeSetup();
      await setup.dispatcher.saveUserBinding(VIDEO_PATH, SUBTITLE_URL, 'local-file');
      setup.store.corruptFirstKey('subtitle_binding_');
      const result: SubtitleBinding | null = await setup.dispatcher.getUserBinding(VIDEO_PATH);
      expect(result).assertNull();
    });

    it('resolveSubtitle_emptyTracks_returnsNone', 0, async () => {
      const setup = await makeSetup();
      const resolution: SubtitleResolution = await setup.dispatcher.resolveSubtitle(VIDEO_PATH, []);
      expect(resolution.type).assertEqual('none');
    });

    it('resolveSubtitle_bindingUrlMatches_returnsUserSpecified', 0, async () => {
      const setup = await makeSetup();
      await setup.dispatcher.saveUserBinding(VIDEO_PATH, SUBTITLE_URL, 'local-file');

      const track: SubtitleTrackItem = {
        kind: 'external',
        displayName: 'movie.srt',
        url: SUBTITLE_URL
      };
      const tracks: SubtitleTrackItem[] = [track];
      const resolution: SubtitleResolution = await setup.dispatcher.resolveSubtitle(VIDEO_PATH, tracks);
      expect(resolution.type).assertEqual('user-specified');
      expect(resolution.trackIndex).assertEqual(0);
    });

    it('resolveSubtitle_bindingUrlNotInTracks_clearsBindingAndReturnsNone', 0, async () => {
      const setup = await makeSetup();
      await setup.dispatcher.saveUserBinding(VIDEO_PATH, SUBTITLE_URL, 'local-file');

      const track: SubtitleTrackItem = {
        kind: 'external',
        displayName: 'other.srt',
        url: 'http://192.168.1.1/dav/test/other.srt'
      };
      const tracks: SubtitleTrackItem[] = [track];
      const resolution: SubtitleResolution = await setup.dispatcher.resolveSubtitle(VIDEO_PATH, tracks);
      expect(resolution.type).assertEqual('none');

      const binding: SubtitleBinding | null = await setup.dispatcher.getUserBinding(VIDEO_PATH);
      expect(binding?.subtitleType).assertEqual('disabled');
    });

    it('resolveSubtitle_noBindingNoTracks_returnsNone', 0, async () => {
      const setup = await makeSetup();
      const resolution: SubtitleResolution = await setup.dispatcher.resolveSubtitle(VIDEO_PATH, []);
      expect(resolution.type).assertEqual('none');
    });

    it('resolveSubtitle_internalBindingMatches_returnsUserSpecified', 0, async () => {
      const setup = await makeSetup();
      await setup.dispatcher.saveUserBinding(VIDEO_PATH, '简体中文', 'internal');

      const track: SubtitleTrackItem = {
        kind: 'internal',
        displayName: '简体中文'
      };
      const tracks: SubtitleTrackItem[] = [track];
      const resolution: SubtitleResolution = await setup.dispatcher.resolveSubtitle(VIDEO_PATH, tracks);
      expect(resolution.type).assertEqual('user-specified');
      expect(resolution.trackIndex).assertEqual(0);
    });

    it('resolveSubtitle_internalBindingNotInTracks_clearsBindingAndReturnsNone', 0, async () => {
      const setup = await makeSetup();
      await setup.dispatcher.saveUserBinding(VIDEO_PATH, '简体中文', 'internal');

      const track: SubtitleTrackItem = {
        kind: 'internal',
        displayName: 'English'
      };
      const tracks: SubtitleTrackItem[] = [track];
      const resolution: SubtitleResolution = await setup.dispatcher.resolveSubtitle(VIDEO_PATH, tracks);
      expect(resolution.type).assertEqual('none');

      const binding: SubtitleBinding | null = await setup.dispatcher.getUserBinding(VIDEO_PATH);
      expect(binding?.subtitleType).assertEqual('disabled');
    });

    it('clearUserBinding_removesExistingBinding', 0, async () => {
      const setup = await makeSetup();
      await setup.dispatcher.saveUserBinding(VIDEO_PATH, SUBTITLE_URL, 'local-file');
      await setup.dispatcher.clearUserBinding(VIDEO_PATH);
      const result: SubtitleBinding | null = await setup.dispatcher.getUserBinding(VIDEO_PATH);
      expect(result?.subtitleType).assertEqual('disabled');
    });
  });
}
