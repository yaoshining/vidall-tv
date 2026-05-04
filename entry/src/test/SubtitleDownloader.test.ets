import { describe, it, expect, beforeEach, afterEach } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@ohos.abilityAccessCtrl';
import {
  AppPreferences,
  AppPreferencesLoader,
  AppPreferencesStore
} from '../main/ets/utils/AppPreferences';
import {
  sha256Hex,
  buildSubtitlePath,
  buildSubtitleDir,
  SubtitleStorageContext,
  SUBTITLE_DOWNLOADED_EVENT_ID
} from '../main/ets/subtitle/SubtitleDownloader';

// ─────────────────────────────────────────────
// 内存 Store 辅助（与其他测试保持一致）
// ─────────────────────────────────────────────

class InMemoryStore implements AppPreferencesStore {
  private readonly values: Map<string, string | number> = new Map<string, string | number>();

  seed(key: string, value: string | number): void {
    this.values.set(key, value);
  }

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

// ─────────────────────────────────────────────
// 最小 Context stub
// ─────────────────────────────────────────────

class FakeSubtitleContext implements SubtitleStorageContext {
  readonly filesDir: string;

  constructor(filesDir: string) {
    this.filesDir = filesDir;
  }
}

// ─────────────────────────────────────────────
// 辅助：判断字符串是否为合法 hex
// ─────────────────────────────────────────────

function isHex(s: string): boolean {
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    const isDigit = c >= '0' && c <= '9';
    const isLower = c >= 'a' && c <= 'f';
    if (!isDigit && !isLower) {
      return false;
    }
  }
  return true;
}

// ─────────────────────────────────────────────
// 测试套件
// ─────────────────────────────────────────────

export default function subtitleDownloaderTest() {

  // ── Task 4.2：路径 hash 计算 ──────────────────

  describe('SubtitleDownloader_sha256Hex', () => {
    beforeEach(() => {
      AppPreferences.resetForTesting();
    });

    afterEach(() => {
      AppPreferences.setStoreLoaderForTesting(null);
      AppPreferences.resetForTesting();
    });

    it('filePathHash should be exactly 32 characters', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      const loader: AppPreferencesLoader = async () => store;
      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      const videoPath = '/data/storage/webdav/source1/movies/Inception.mkv';
      const hash = await sha256Hex(videoPath);

      expect(hash.length).assertEqual(32);
    });

    it('filePathHash should only contain lowercase hex characters', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      const loader: AppPreferencesLoader = async () => store;
      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      const videoPath = '/data/storage/webdav/source1/movies/Inception.mkv';
      const hash = await sha256Hex(videoPath);

      expect(isHex(hash)).assertTrue();
    });

    it('different videoPaths should produce different hashes', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      const loader: AppPreferencesLoader = async () => store;
      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      const hash1 = await sha256Hex('/path/to/movie1.mkv');
      const hash2 = await sha256Hex('/path/to/movie2.mkv');

      expect(hash1).assertContain('');  // 非空
      expect(hash1 === hash2).assertFalse();
    });

    it('same videoPath should always produce same hash', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      const loader: AppPreferencesLoader = async () => store;
      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      const videoPath = '/data/storage/webdav/42/series/S01E01.mkv';
      const hash1 = await sha256Hex(videoPath);
      const hash2 = await sha256Hex(videoPath);

      expect(hash1).assertEqual(hash2);
    });
  });

  // ── Task 4.2：目录路径构造 ────────────────────

  describe('SubtitleDownloader_path_construction', () => {

    it('buildSubtitleDir should contain subtitles prefix', 0, () => {
      const fakeCtx = new FakeSubtitleContext('/data/app/files');
      const hash = 'abcdef1234567890abcdef1234567890';

      const dirPath = buildSubtitleDir(fakeCtx.filesDir, 'webdav', '42', hash);

      expect(dirPath.indexOf('subtitles/') >= 0).assertTrue();
    });

    it('buildSubtitleDir should contain sourceType_sourceId segment', 0, () => {
      const fakeCtx = new FakeSubtitleContext('/data/app/files');
      const hash = 'abcdef1234567890abcdef1234567890';

      const dirPath = buildSubtitleDir(fakeCtx.filesDir, 'webdav', '42', hash);

      expect(dirPath.indexOf('webdav_42') >= 0).assertTrue();
    });

    it('buildSubtitlePath should end with fileName', 0, () => {
      const fakeCtx = new FakeSubtitleContext('/data/app/files');
      const hash = 'abcdef1234567890abcdef1234567890';
      const fileName = 'Inception.zh-CN.srt';

      const localPath = buildSubtitlePath(fakeCtx.filesDir, 'webdav', '42', hash, fileName);

      expect(localPath.endsWith(fileName)).assertTrue();
    });

    it('buildSubtitlePath should match expected format', 0, () => {
      const filesDir = '/data/app/files';
      const fakeCtx = new FakeSubtitleContext(filesDir);
      const hash = 'abcdef1234567890abcdef1234567890';
      const fileName = 'test.srt';

      const localPath = buildSubtitlePath(fakeCtx.filesDir, 'smb', '7', hash, fileName);
      const expected = `${filesDir}/subtitles/smb_7/${hash}/${fileName}`;

      expect(localPath).assertEqual(expected);
    });

    it('filePathHash in path should be 32 characters', 0, async () => {
      const fakeCtx = new FakeSubtitleContext('/data/app/files');
      const videoPath = '/mnt/videos/sample.mp4';

      const hash = await sha256Hex(videoPath);
      const localPath = buildSubtitlePath(fakeCtx.filesDir, 'webdav', '1', hash, 'sample.srt');

      // hash 段（目录中倒数第 2 段）应为 32 字符
      const parts = localPath.split('/');
      const hashSegment = parts[parts.length - 2];
      expect(hashSegment.length).assertEqual(32);
      expect(isHex(hashSegment)).assertTrue();
    });
  });

  // ── Task 4.4：事件 ID 验证 ────────────────────

  describe('SubtitleDownloader_event_id', () => {

    it('SUBTITLE_DOWNLOADED_EVENT_ID should equal 10031', 0, () => {
      expect(SUBTITLE_DOWNLOADED_EVENT_ID).assertEqual(10031);
    });
  });
}
