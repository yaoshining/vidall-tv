import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@ohos.abilityAccessCtrl';
import { FileSourceDatabase } from '../main/ets/db/files/FileSourceDatabase';
import { countSeriesEpisodeRows, SeriesEpisodeCountSource } from '../main/ets/db/files/SeriesGroupCountUtil';

/**
 * FileSourceDatabase 集成测试（运行在 UnitTestBuild，context 通过 abilityDelegatorRegistry 获取）
 *
 * 测试目标：
 *   1. init() 并发安全 — 多次并发调用不会触发双初始化 (SIGBUS 崩溃回归场景)
 *   2. 基础 DB 可用性 — 初始化后可正常读取文件源列表
 */
export default function fileSourceDatabaseTest() {
  const isolatedDatabaseName = `FILE_SOURCES_DB_TEST_${Date.now()}`;

  describe('FileSourceDatabase_integration', () => {
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

    describe('FileSourceDatabase_distinct_tv_series_group_logic', () => {
      it('should_count_episode_rows_without_duplicate_tv_rows', 0, () => {
        const items: SeriesEpisodeCountSource[] = [
          { episodeId: 101 },
          {}
        ];
        expect(countSeriesEpisodeRows(items)).assertEqual(1);
      });

      it('should_fallback_to_tv_row_count_when_episode_ids_are_absent', 0, () => {
        const items: SeriesEpisodeCountSource[] = [
          {},
          {}
        ];
        expect(countSeriesEpisodeRows(items)).assertEqual(2);
      });
    });
  });
}
