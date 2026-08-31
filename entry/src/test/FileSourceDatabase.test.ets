import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@ohos.abilityAccessCtrl';
import { FileSourceDatabase } from '../main/ets/db/files/FileSourceDatabase';
import { FileSource, FileSourceDirectory, FileSourceType } from '../main/ets/db/models/FileSourceEntity';
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

    describe('FileSourceDatabase_delete_source', () => {
      it('should_delete_source_and_renamed_remote_directory_by_local_id', 0, async () => {
        const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
        const db = FileSourceDatabase.getInstance(ctx);
        await db.init();
        const source: FileSource = {
          name: 'renamed-remote-source',
          type: FileSourceType.WEBDAV,
          configJson: '{"url":"unreachable.invalid","rootPath":"/renamed"}',
          createdAt: Date.now()
        };
        const sourceId = await db.insertFileSource(source);
        const directory: FileSourceDirectory = {
          sourceId,
          directoryPath: '/old-server-name'
        };
        await db.insertDirectories(sourceId, [directory]);

        await db.deleteFileSourceWithData(sourceId);

        expect(await db.getFileSourceById(sourceId) === null).assertTrue();
        expect((await db.getDirectoriesBySourceId(sourceId)).length).assertEqual(0);
      });

      it('should_delete_directory_but_keep_file_source', 0, async () => {
        const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
        const db = FileSourceDatabase.getInstance(ctx);
        await db.init();
        const source: FileSource = {
          name: 'keep-source-after-dir-delete',
          type: FileSourceType.WEBDAV,
          configJson: '{"url":"unreachable.invalid","rootPath":"/renamed"}',
          createdAt: Date.now()
        };
        const sourceId = await db.insertFileSource(source);
        const directory: FileSourceDirectory = {
          sourceId,
          directoryPath: '/one-folder'
        };
        await db.insertDirectories(sourceId, [directory]);

        // 取出目录主键（dirId）
        const dirs = await db.getDirectoriesBySourceId(sourceId);
        expect(dirs.length).assertEqual(1);
        const dirId = dirs[0].id;
        expect(dirId !== undefined).assertTrue();

        // 仅删除该目录，文件源应保留
        await db.clearMediaAndDirectoryForDir(dirId as number, sourceId, directory.directoryPath);

        // 目录已删，但文件源仍在
        expect((await db.getDirectoriesBySourceId(sourceId)).length).assertEqual(0);
        expect((await db.getFileSourceById(sourceId)) !== null).assertTrue();
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
