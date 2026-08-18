import { describe, it, expect, beforeEach, afterEach } from '@ohos/hypium';
import fs from '@ohos.file.fs';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import UIAbility from '@ohos.app.ability.UIAbility';
import { Context } from '@ohos.abilityAccessCtrl';
import {
  SubtitleCacheManager,
  CachedSubtitleEntry
} from '../../../main/ets/subtitle/SubtitleCacheManager';
import { sha256Hex, buildSubtitleDir } from '../../../main/ets/subtitle/SubtitleDownloader';

// ─────────────────────────────────────────────
// 常量
// ─────────────────────────────────────────────

const SOURCE_TYPE = 'webdav';
/** 每个测试用独立 sourceId，彻底隔离跨运行和运行内的数据污染；追加随机后缀避免同毫秒多进程碰撞 */
const _RUN_EPOCH = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
let _testCounter = 0;
let SOURCE_ID = 'test-42'; // 会在每个 beforeEach 里更新
const VIDEO_PATH = 'http://192.168.1.1/dav/films/movie.mkv';
const VIDEO_PATH_2 = 'http://192.168.1.1/dav/films/other.mkv';

function makeEntry(fileName: string, lang: string = 'zh', daysAgo: number = 0): CachedSubtitleEntry {
  const date = new Date(Date.now() - daysAgo * 86400000);
  const entry: CachedSubtitleEntry = {
    fileName,
    language: lang,
    downloadedAt: date.toISOString(),
    source: 'opensubtitles',
    subDownloadCount: 100
  };
  return entry;
}

/** 清理指定字幕目录（静默） */
function cleanDir(dir: string): void {
  try {
    const files = fs.listFileSync(dir);
    for (let i = 0; i < files.length; i++) {
      try {
        fs.unlinkSync(`${dir}/${files[i]}`);
      } catch {
        // 忽略
      }
    }
    fs.rmdirSync(dir);
  } catch {
    // 目录不存在时静默
  }
}

/**
 * 同步清理 sourceType_sourceId 下的所有哈希目录。
 * 不依赖 async sha256Hex，可安全用于 beforeEach/afterEach。
 */
function cleanSourceDir(filesDir: string, sourceType: string, sourceId: string): void {
  const sourceDir = `${filesDir}/subtitles/${sourceType}_${sourceId}`;
  try {
    const hashDirs = fs.listFileSync(sourceDir);
    for (let i = 0; i < hashDirs.length; i++) {
      cleanDir(`${sourceDir}/${hashDirs[i]}`);
    }
    fs.rmdirSync(sourceDir);
  } catch {
    // 目录不存在时静默
  }
}

// ─────────────────────────────────────────────
// 获取可写目录
// ─────────────────────────────────────────────
// 设备端本地单测环境中，ApplicationContext/UIAbilityContext 的 filesDir/cacheDir 等
// 目录属性均返回空字符串（无完整沙盒路径），导致字幕缓存路径退化为 /subtitles/... 而
// mkdir 失败。这里优先取 context 目录，均不可用时兜底到系统 /tmp（经写入探测验证可用）。
// 仅缓存通过实际写入校验的有效路径，不缓存硬编码的沙盒路径。
// ─────────────────────────────────────────────

let filesDirPromise: Promise<string> | null = null;

function tryProbeDir(dir: string): boolean {
  try {
    const probe = `${dir}/.subtitle_cache_probe_${Date.now()}`;
    const fd = fs.openSync(probe, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    fs.closeSync(fd);
    fs.unlinkSync(probe);
    return true;
  } catch {
    return false;
  }
}

async function resolveFilesDir(): Promise<string> {
  const candidates: string[] = [];
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();

  // 路径1：当前顶部 Ability 的 UIAbilityContext
  try {
    const ability: UIAbility = await delegator.getCurrentTopAbility();
    if (ability && ability.context) {
      candidates.push(ability.context.filesDir);
      candidates.push(ability.context.cacheDir);
      candidates.push(ability.context.tempDir);
      candidates.push(ability.context.databaseDir);
      candidates.push(ability.context.preferencesDir);
    }
  } catch {
    // 本地单测环境可能无顶部 Ability，继续使用 ApplicationContext
  }

  // 路径2：ApplicationContext
  const appCtx = delegator.getAppContext() as Context;
  if (appCtx) {
    candidates.push(appCtx.filesDir);
    candidates.push(appCtx.cacheDir);
    candidates.push(appCtx.tempDir);
    candidates.push(appCtx.databaseDir);
    candidates.push(appCtx.preferencesDir);
  }

  // 路径3：context 目录均不可用时，兜底系统临时目录 /tmp
  candidates.push('/tmp');

  for (let i = 0; i < candidates.length; i++) {
    const dir = candidates[i];
    if (dir && dir.length > 0 && tryProbeDir(dir)) {
      return dir;
    }
  }
  throw new Error('无法获取可写的测试目录');
}

function getFilesDir(): Promise<string> {
  if (filesDirPromise === null) {
    filesDirPromise = resolveFilesDir();
  }
  return filesDirPromise;
}

// ─────────────────────────────────────────────
// 测试套件
// ─────────────────────────────────────────────

export default function subtitleCacheManagerTest() {

  describe('SubtitleCacheManager_saveSubtitle', () => {
    let filesDir: string = '';
    let manager: SubtitleCacheManager;

    beforeEach(async () => {
      SOURCE_ID = `test-${_RUN_EPOCH}-${++_testCounter}`;
      filesDir = await getFilesDir();
      manager = new SubtitleCacheManager();
    });

    afterEach(() => {
      cleanSourceDir(filesDir, SOURCE_TYPE, SOURCE_ID);
    });

    it('saveSubtitle_首次写入_创建metadata', 0, async () => {
      const entry = makeEntry('movie.zh.srt');
      await manager.saveSubtitle(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH, entry);

      const list = await manager.listCachedSubtitles(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH);
      expect(list.length).assertEqual(1);
      expect(list[0].fileName).assertEqual('movie.zh.srt');
      expect(list[0].language).assertEqual('zh');
    });

    it('saveSubtitle_二次写入_追加记录', 0, async () => {
      await manager.saveSubtitle(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH, makeEntry('movie.zh.srt', 'zh'));
      await manager.saveSubtitle(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH, makeEntry('movie.en.srt', 'en'));

      const list = await manager.listCachedSubtitles(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH);
      expect(list.length).assertEqual(2);
    });

    it('saveSubtitle_同名文件_覆盖而非追加', 0, async () => {
      await manager.saveSubtitle(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH, makeEntry('movie.zh.srt', 'zh'));
      await manager.saveSubtitle(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH, makeEntry('movie.zh.srt', 'zh-updated'));

      const list = await manager.listCachedSubtitles(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH);
      expect(list.length).assertEqual(1);
      expect(list[0].language).assertEqual('zh-updated');
    });

    it('saveSubtitle_超过10条_LRU清理最旧', 0, async () => {
      // 写入 11 条，最旧的是 daysAgo=10
      for (let i = 0; i < 11; i++) {
        const e = makeEntry(`sub${i}.srt`, 'zh', 10 - i);
        await manager.saveSubtitle(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH, e);
      }

      const list = await manager.listCachedSubtitles(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH);
      expect(list.length).assertEqual(10);
      // sub0 是最旧的（daysAgo=10），应被清除
      const names = list.map((e: CachedSubtitleEntry) => e.fileName);
      let foundSub0 = false;
      for (let i = 0; i < names.length; i++) {
        if (names[i] === 'sub0.srt') {
          foundSub0 = true;
        }
      }
      expect(foundSub0).assertFalse();
    });

    it('saveSubtitle_中文路径_正确存储', 0, async () => {
      const unicodePath = 'http://192.168.1.1/dav/电影 2024/movie.mkv';
      const entry = makeEntry('zh-subtitle.srt');
      await manager.saveSubtitle(filesDir, SOURCE_TYPE, SOURCE_ID, unicodePath, entry);
      const list = await manager.listCachedSubtitles(filesDir, SOURCE_TYPE, SOURCE_ID, unicodePath);
      expect(list.length).assertEqual(1);
      expect(list[0].fileName).assertEqual('zh-subtitle.srt');
    });

  });

  describe('SubtitleCacheManager_listCachedSubtitles', () => {
    let filesDir: string = '';
    let manager: SubtitleCacheManager;

    beforeEach(async () => {
      SOURCE_ID = `test-${_RUN_EPOCH}-${++_testCounter}`;
      filesDir = await getFilesDir();
      manager = new SubtitleCacheManager();
    });

    afterEach(() => {
      cleanSourceDir(filesDir, SOURCE_TYPE, SOURCE_ID);
    });

    it('listCachedSubtitles_无缓存_返回空数组', 0, async () => {
      const list = await manager.listCachedSubtitles(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH_2);
      expect(list.length).assertEqual(0);
    });
  });

  describe('SubtitleCacheManager_getLastUsedSubtitle', () => {
    let filesDir: string = '';
    let manager: SubtitleCacheManager;

    beforeEach(async () => {
      SOURCE_ID = `test-${_RUN_EPOCH}-${++_testCounter}`;
      filesDir = await getFilesDir();
      manager = new SubtitleCacheManager();
    });

    afterEach(() => {
      cleanSourceDir(filesDir, SOURCE_TYPE, SOURCE_ID);
    });

    it('getLastUsedSubtitle_未设置lastUsed_返回null', 0, async () => {
      const entry = makeEntry('movie.zh.srt');
      await manager.saveSubtitle(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH, entry);
      const result = await manager.getLastUsedSubtitle(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH);
      expect(result === null).assertTrue();
    });

    it('getLastUsedSubtitle_setLastUsed后_返回路径', 0, async () => {
      const entry = makeEntry('movie.zh.srt');
      await manager.saveSubtitle(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH, entry);
      // 创建实际文件（模拟已下载）
      const hash = await sha256Hex(VIDEO_PATH);
      const dir = buildSubtitleDir(filesDir, SOURCE_TYPE, SOURCE_ID, hash);
      const filePath = `${dir}/movie.zh.srt`;
      const fd = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
      fs.closeSync(fd);

      await manager.setLastUsedSubtitle(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH, 'movie.zh.srt');
      const result = await manager.getLastUsedSubtitle(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH);
      expect(result !== null).assertTrue();
      if (result !== null) {
        expect(result.endsWith('movie.zh.srt')).assertTrue();
      }
    });

    it('getLastUsedSubtitle_文件不存在_返回null并清除lastUsed', 0, async () => {
      const entry = makeEntry('missing.srt');
      await manager.saveSubtitle(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH, entry);
      await manager.setLastUsedSubtitle(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH, 'missing.srt');
      // 不创建实际文件

      const result = await manager.getLastUsedSubtitle(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH);
      expect(result === null).assertTrue();

      // lastUsed 应已被清除
      const result2 = await manager.getLastUsedSubtitle(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH);
      expect(result2 === null).assertTrue();
    });
  });

  describe('SubtitleCacheManager_clearSubtitleCache', () => {
    let filesDir: string = '';
    let manager: SubtitleCacheManager;

    beforeEach(async () => {
      SOURCE_ID = `test-${_RUN_EPOCH}-${++_testCounter}`;
      filesDir = await getFilesDir();
      manager = new SubtitleCacheManager();
    });

    afterEach(() => {
      cleanSourceDir(filesDir, SOURCE_TYPE, SOURCE_ID);
    });

    it('clearSubtitleCache_有缓存_清除目录', 0, async () => {
      await manager.saveSubtitle(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH, makeEntry('movie.zh.srt'));
      await manager.clearSubtitleCache(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH);

      const list = await manager.listCachedSubtitles(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH);
      expect(list.length).assertEqual(0);
    });

    it('clearSubtitleCache_无缓存_静默返回', 0, async () => {
      // 目录不存在时不抛出异常
      let threw = false;
      try {
        await manager.clearSubtitleCache(filesDir, SOURCE_TYPE, SOURCE_ID, VIDEO_PATH);
      } catch {
        threw = true;
      }
      expect(threw).assertFalse();
    });
  });
}
