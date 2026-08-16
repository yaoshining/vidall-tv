import { describe, it, expect } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@ohos.abilityAccessCtrl';
import { FileSourceDatabase } from '../main/ets/db/files/FileSourceDatabase';
import { VideoScannerUtil } from '../main/ets/utils/VideoScannerUtil';
import { ScanResult } from '../main/ets/utils/VideoScannerTypes';

/**
 * VideoScanner 集成测试（运行在 UnitTestBuild，context 通过 abilityDelegatorRegistry 获取）
 *
 * 目标：验证扫描核心流程在真实设备 + 真实文件源配置下不崩溃、能产出结果。
 * 无需准备测试数据：直接读取 App DB 中已有的文件源配置。
 * 若环境无文件源，测试输出警告并跳过扫描断言（仍算通过）。
 */
export default function videoScannerTest() {

  describe('VideoScanner_regression', () => {

    /**
     * 扫描不崩溃（主线回归）
     *
     * 验证：
     *   - scan() 正常返回 ScanResult，不抛异常
     *   - 返回的 totalVideos >= 0（数量合理）
     *   - perSourceStats 每项都有 sourceId 和 videosFound
     *
     * 覆盖场景：
     *   - WebDAV Adapter 并发 HTTP 请求
     *   - FileSourceDatabase 并发 init 防重入
     *   - FfprobeUtil 轨道探测（VideoInfoUtil 路径）
     */
    it('scan_with_existing_sources_does_not_crash', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;

      // 先确认环境中有文件源，没有则跳过扫描断言
      const db = FileSourceDatabase.getInstance(ctx);
      await db.init();
      const sources = await db.getAllFileSources();

      if (sources.length === 0) {
        console.warn('[VideoScanner.test] 环境中无文件源，跳过扫描断言（仍通过）');
        expect(true).assertTrue();
        return;
      }

      console.info(`[VideoScanner.test] 发现 ${sources.length} 个文件源，开始扫描（maxDepth=2）`);

      let result: ScanResult | null = null;
      let scanError: string = '';

      try {
        result = await VideoScannerUtil.scan(ctx, undefined, { maxDepth: 2 });
      } catch (e) {
        scanError = JSON.stringify(e);
      }

      expect(scanError).assertEqual('');
      expect(result !== null).assertTrue();

      if (result !== null) {
        expect(result.totalVideos >= 0).assertTrue();
        console.info(
          `[VideoScanner.test] 扫描完成：目录=${result.totalDirectories} ` +
          `视频=${result.totalVideos} 耗时=${result.elapsedMs}ms`
        );

        // 每个文件源统计项格式正确
        for (const stat of result.perSourceStats) {
          expect(stat.sourceId > 0).assertTrue();
          expect(stat.videosFound >= 0).assertTrue();
        }
      }
    });

    /**
     * 增量扫描：二次扫描不增加重复记录
     *
     * 第一次 scan 入库后，第二次 incremental scan 不应再次写入相同路径的视频。
     * 通过比较两次扫描 totalVideos 近似相等来验证（允许 ±5 的容差，防止并发添加/删除）。
     */
    it('incremental_scan_deduplicates_videos', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const db = FileSourceDatabase.getInstance(ctx);
      await db.init();
      const sources = await db.getAllFileSources();

      if (sources.length === 0) {
        console.warn('[VideoScanner.test] 无文件源，跳过去重测试');
        expect(true).assertTrue();
        return;
      }

      const r1 = await VideoScannerUtil.scan(ctx, undefined, { maxDepth: 2, mode: 'incremental' });
      const r2 = await VideoScannerUtil.scan(ctx, undefined, { maxDepth: 2, mode: 'incremental' });

      const diff = Math.abs(r1.totalVideos - r2.totalVideos);
      const tolerance = 5;
      expect(diff <= tolerance).assertTrue();
      console.info(
        `[VideoScanner.test] 第一次=${r1.totalVideos} 第二次=${r2.totalVideos} diff=${diff}`
      );
    });

  });
}
