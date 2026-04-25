import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@ohos.abilityAccessCtrl';
import { FileSourceDatabase } from '../main/ets/db/files/FileSourceDatabase';
import { FileSource, FileSourceType } from '../main/ets/db/models/FileSourceEntity';
import { ScrapeInfoEntity, TvEpisodeEntity, TvSeasonEntity, TvSeriesEntity, VideoEntity } from '../main/ets/db/models/MediaEntity';

async function waitForTvSeriesId(db: FileSourceDatabase, provider: string, providerId: string): Promise<number> {
  for (let attempt = 0; attempt < 10; attempt++) {
    const persistedSeries = await db.getTvSeriesByProviderId(provider, providerId);
    if (persistedSeries && persistedSeries.id !== undefined) {
      return persistedSeries.id;
    }
    await new Promise<void>((resolve) => setTimeout(resolve, 50));
  }
  return -1;
}

/**
 * FileSourceDatabase 集成测试（运行在 UnitTestBuild，context 通过 abilityDelegatorRegistry 获取）
 *
 * 测试目标：
 *   1. init() 并发安全 — 多次并发调用不会触发双初始化 (SIGBUS 崩溃回归场景)
 *   2. 基础 DB 可用性 — 初始化后可正常读取文件源列表
 */
export default function fileSourceDatabaseTest() {
  const isolatedDatabaseName = `FILE_SOURCES_DB_TEST_${Date.now()}`;

  beforeAll(() => {
    FileSourceDatabase.setDatabaseNameForTesting(isolatedDatabaseName);
  });

  afterAll(() => {
    FileSourceDatabase.setDatabaseNameForTesting(null);
  });

  describe('FileSourceDatabase_concurrent_init', () => {

    /**
     * 回归：并发 init() 不崩溃
     * 修复前：两路并发都过 rdbStore===null 检查 → 双 getRdbStore → SIGBUS(BUS_ADRALN)
     * 修复后：initPromise 保证只有一路执行 doInit，其余复用 Promise
     */
    it('concurrent_init_does_not_crash', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const db = FileSourceDatabase.getInstance(ctx);
      // 5 路同时触发，全部应 resolve
      const results = await Promise.allSettled([
        db.init(), db.init(), db.init(), db.init(), db.init()
      ]);
      const failures = results.filter(r => r.status === 'rejected');
      expect(failures.length).assertEqual(0);
    });

    /**
     * init() 幂等性 — 多次串行调用正常
     */
    it('sequential_init_is_idempotent', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const db = FileSourceDatabase.getInstance(ctx);
      await db.init();
      await db.init();
      expect(true).assertTrue();
    });

  });

  describe('FileSourceDatabase_basic_availability', () => {

    /**
     * 初始化后 getAllFileSources 返回数组（空也算通过，关键是不抛异常）
     */
    it('get_all_file_sources_returns_array', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const db = FileSourceDatabase.getInstance(ctx);
      await db.init();
      const sources = await db.getAllFileSources();
      expect(Array.isArray(sources)).assertTrue();
      console.info(`[FileSourceDatabase.test] 环境中共有 ${sources.length} 个文件源`);
    });

  });

  describe('FileSourceDatabase_distinct_tv_series_groups', () => {
    it('should_count_episode_rows_without_duplicate_tv_rows', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const db = FileSourceDatabase.getInstance(ctx);
      await db.init();

      const suffix = `${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
      const now = Date.now();
      const fileSource: FileSource = {
        name: `测试文件源-${suffix}`,
        type: FileSourceType.WEBDAV,
        configJson: JSON.stringify({
          url: '127.0.0.1',
          username: 'tester',
          password: 'secret',
          protocol: 'http',
          port: 80,
          rootPath: '/dav'
        }),
        createdAt: now
      };
      const sourceId = await db.insertFileSource(fileSource);
      const seriesProviderId = `series-${suffix}`;

      const seriesId = await db.upsertTvSeries({
        provider: 'tmdb',
        providerId: seriesProviderId,
        title: `测试剧集-${suffix}`,
        numberOfSeasons: 1,
        scrapedAt: now
      } as TvSeriesEntity);
      const persistedSeriesId = seriesId > 0 ? seriesId : await waitForTvSeriesId(db, 'tmdb', seriesProviderId);
      expect(persistedSeriesId).assertLarger(0);

      const seasonId = await db.upsertTvSeason({
        seriesId: persistedSeriesId,
        provider: 'tmdb',
        providerId: `series-${suffix}-s1`,
        seasonNumber: 1,
        title: '第 1 季',
        episodeCount: 1,
        scrapedAt: now
      } as TvSeasonEntity);

      const episodeId = await db.upsertTvEpisode({
        seriesId: persistedSeriesId,
        seasonId,
        provider: 'tmdb',
        providerId: `series-${suffix}-s1e1`,
        seasonNumber: 1,
        episodeNumber: 1,
        title: '第 1 集',
        scrapedAt: now
      } as TvEpisodeEntity);

      const episodeVideoId = await db.upsertVideo({
        sourceId,
        directoryPath: `/电视剧/测试剧集-${suffix}`,
        filePath: `/电视剧/测试剧集-${suffix}/S01E01.mkv`,
        fileName: 'S01E01.mkv',
        scannedAt: now
      } as VideoEntity);
      await db.upsertScrapeInfo({
        videoId: episodeVideoId,
        provider: 'tmdb',
        providerId: `scrape-episode-${suffix}`,
        mediaType: 'episode',
        title: `测试剧集-${suffix}`,
        tvSeriesId: persistedSeriesId,
        episodeId,
        seasonNumber: 1,
        episodeNumber: 1,
        scrapedAt: now
      } as ScrapeInfoEntity);

      const tvVideoId = await db.upsertVideo({
        sourceId,
        directoryPath: `/电视剧/测试剧集-${suffix}`,
        filePath: `/电视剧/测试剧集-${suffix}/21 4K.mp4`,
        fileName: '21 4K.mp4',
        scannedAt: now + 1
      } as VideoEntity);
      await db.upsertScrapeInfo({
        videoId: tvVideoId,
        provider: 'tmdb',
        providerId: `scrape-tv-${suffix}`,
        mediaType: 'tv',
        title: `测试剧集-${suffix}`,
        tvSeriesId: persistedSeriesId,
        scrapedAt: now + 1
      } as ScrapeInfoEntity);

      const groups = await db.getDistinctTvSeriesGroups(5000);
      const targetGroup = groups.find(group => group.tvSeriesId === persistedSeriesId);
      expect(targetGroup !== undefined).assertTrue();
      expect(targetGroup!.episodeCount).assertEqual(1);
    });
  });
}
