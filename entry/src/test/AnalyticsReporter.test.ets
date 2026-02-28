import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { AnalyticsManager } from '../../../main/ets/analytics/AnalyticsManager';
import { AnalyticsReporter } from '../../../main/ets/analytics/AnalyticsReporter';
import { EventType, SourceType, SubtitleFormatType } from '../../../main/ets/analytics/AnalyticsTypes';

/**
 * 埋点报表单元测试
 */
export default function AnalyticsReporterTest() {
  describe('AnalyticsReporter', () => {
    let analyticsManager: AnalyticsManager;
    let reporter: AnalyticsReporter;

    beforeAll(() => {
      console.info('[AnalyticsReporterTest] beforeAll');
    });

    beforeEach(() => {
      console.info('[AnalyticsReporterTest] beforeEach');
      analyticsManager = AnalyticsManager.getInstance();
      reporter = new AnalyticsReporter();
    });

    afterEach(async () => {
      console.info('[AnalyticsReporterTest] afterEach');
      await analyticsManager.clearAllEvents();
    });

    afterAll(() => {
      console.info('[AnalyticsReporterTest] afterAll');
    });

    /**
     * 测试生成播放指标报告
     */
    it('test_generate_play_metrics_report', 0, async () => {
      // 模拟播放流程
      analyticsManager.track({
        eventType: EventType.PLAY_START,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL
      });

      analyticsManager.track({
        eventType: EventType.PLAY_PREPARED,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL,
        prepareTime: 500
      });

      analyticsManager.track({
        eventType: EventType.PLAY_FIRST_FRAME,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL,
        firstFrameTime: 1200
      });

      const startTime = Date.now() - 10000;
      const endTime = Date.now() + 1000;
      const report = await reporter.generateReport(startTime, endTime);

      expect(report.playMetrics.totalPlayAttempts).assertEqual(1);
      expect(report.playMetrics.successfulPlays).assertEqual(1);
      expect(report.playMetrics.successRate).assertEqual(1.0);
      expect(report.playMetrics.firstFrameTimes.length).assertEqual(1);
      expect(report.playMetrics.firstFrameTimes[0]).assertEqual(1200);
    });

    /**
     * 测试播放成功率计算
     */
    it('test_play_success_rate_calculation', 0, async () => {
      // 3次成功，1次失败
      for (let i = 0; i < 3; i++) {
        analyticsManager.track({
          eventType: EventType.PLAY_START,
          mediaId: `video${i}.mp4`,
          sourceType: SourceType.LOCAL
        });

        analyticsManager.track({
          eventType: EventType.PLAY_PREPARED,
          mediaId: `video${i}.mp4`,
          sourceType: SourceType.LOCAL,
          prepareTime: 500
        });
      }

      // 1次失败
      analyticsManager.track({
        eventType: EventType.PLAY_START,
        mediaId: 'video_fail.mp4',
        sourceType: SourceType.LOCAL
      });

      const startTime = Date.now() - 10000;
      const endTime = Date.now() + 1000;
      const report = await reporter.generateReport(startTime, endTime);

      expect(report.playMetrics.totalPlayAttempts).assertEqual(4);
      expect(report.playMetrics.successfulPlays).assertEqual(3);
      expect(report.playMetrics.failedPlays).assertEqual(0);
      expect(report.playMetrics.successRate).assertEqual(0.75);
    });

    /**
     * 测试首帧时间P50和P95计算
     */
    it('test_first_frame_time_percentiles', 0, async () => {
      // 添加多个首帧时间数据
      const firstFrameTimes = [800, 1000, 1200, 1500, 2000, 2500, 3000, 3500, 4000, 5000];

      for (let i = 0; i < firstFrameTimes.length; i++) {
        analyticsManager.track({
          eventType: EventType.PLAY_START,
          mediaId: `video${i}.mp4`,
          sourceType: SourceType.LOCAL
        });

        analyticsManager.track({
          eventType: EventType.PLAY_FIRST_FRAME,
          mediaId: `video${i}.mp4`,
          sourceType: SourceType.LOCAL,
          firstFrameTime: firstFrameTimes[i]
        });
      }

      const startTime = Date.now() - 10000;
      const endTime = Date.now() + 1000;
      const report = await reporter.generateReport(startTime, endTime);

      // P50 应该在中位数附近
      expect(report.playMetrics.firstFrameTimeP50).assertLarger(1000);
      expect(report.playMetrics.firstFrameTimeP50).assertLess(3000);

      // P95 应该在高百分位附近
      expect(report.playMetrics.firstFrameTimeP95).assertLarger(3000);
    });

    /**
     * 测试字幕指标报告
     */
    it('test_generate_subtitle_metrics_report', 0, async () => {
      // 2次成功，1次失败
      analyticsManager.track({
        eventType: EventType.SUBTITLE_LOAD_SUCCESS,
        mediaId: 'video1.mp4',
        trackIndex: 0,
        subtitleFormat: SubtitleFormatType.SRT,
        loadTime: 300
      });

      analyticsManager.track({
        eventType: EventType.SUBTITLE_LOAD_SUCCESS,
        mediaId: 'video2.mp4',
        trackIndex: 0,
        subtitleFormat: SubtitleFormatType.EMBEDDED,
        loadTime: 200
      });

      analyticsManager.track({
        eventType: EventType.SUBTITLE_LOAD_FAILED,
        mediaId: 'video3.mp4',
        trackIndex: 0,
        subtitleFormat: SubtitleFormatType.SRT,
        errorCode: '2001',
        errorMessage: 'Load failed',
        errorLevel: 'warning' as any
      });

      const startTime = Date.now() - 10000;
      const endTime = Date.now() + 1000;
      const report = await reporter.generateReport(startTime, endTime);

      expect(report.subtitleMetrics.totalLoadAttempts).assertEqual(3);
      expect(report.subtitleMetrics.successfulLoads).assertEqual(2);
      expect(report.subtitleMetrics.failedLoads).assertEqual(1);
      expect(Math.abs(report.subtitleMetrics.availabilityRate - 0.667)).assertLess(0.01);
      expect(report.subtitleMetrics.avgLoadTime).assertEqual(250);
    });

    /**
     * 测试扫描指标报告
     */
    it('test_generate_scan_metrics_report', 0, async () => {
      analyticsManager.track({
        eventType: EventType.SCAN_COMPLETED,
        sourceId: '1',
        sourceName: 'Source 1',
        totalFiles: 100,
        successFiles: 98,
        failedFiles: 2,
        scanTime: 5000,
        coverageRate: 0.98
      });

      analyticsManager.track({
        eventType: EventType.SCAN_COMPLETED,
        sourceId: '2',
        sourceName: 'Source 2',
        totalFiles: 50,
        successFiles: 50,
        failedFiles: 0,
        scanTime: 3000,
        coverageRate: 1.0
      });

      const startTime = Date.now() - 10000;
      const endTime = Date.now() + 1000;
      const report = await reporter.generateReport(startTime, endTime);

      expect(report.scanMetrics.totalScans).assertEqual(2);
      expect(report.scanMetrics.totalFiles).assertEqual(150);
      expect(report.scanMetrics.successFiles).assertEqual(148);
      expect(report.scanMetrics.failedFiles).assertEqual(2);
      expect(Math.abs(report.scanMetrics.coverageRate - 0.987)).assertLess(0.01);
      expect(report.scanMetrics.avgScanTime).assertEqual(4000);
    });

    /**
     * 测试格式化报告
     */
    it('test_format_report', 0, async () => {
      analyticsManager.track({
        eventType: EventType.PLAY_START,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL
      });

      analyticsManager.track({
        eventType: EventType.PLAY_PREPARED,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL,
        prepareTime: 500
      });

      analyticsManager.track({
        eventType: EventType.PLAY_FIRST_FRAME,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL,
        firstFrameTime: 1200
      });

      const startTime = Date.now() - 10000;
      const endTime = Date.now() + 1000;
      const report = await reporter.generateReport(startTime, endTime);
      const formatted = reporter.formatReport(report);

      expect(formatted.length).assertLarger(0);
      expect(formatted).assertContain('播放指标埋点报告');
      expect(formatted).assertContain('播放指标');
      expect(formatted).assertContain('字幕指标');
      expect(formatted).assertContain('扫描指标');
    });

    /**
     * 测试导出报告为 JSON
     */
    it('test_export_report_as_json', 0, async () => {
      analyticsManager.track({
        eventType: EventType.PLAY_START,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL
      });

      const startTime = Date.now() - 10000;
      const endTime = Date.now() + 1000;
      const jsonReport = await reporter.exportReportAsJson(startTime, endTime);

      expect(jsonReport.length).assertLarger(0);

      // 验证可以解析为 JSON
      const parsed = JSON.parse(jsonReport);
      expect(parsed.reportTime).assertInstanceOf('number');
      expect(parsed.playMetrics).assertInstanceOf('object');
      expect(parsed.subtitleMetrics).assertInstanceOf('object');
      expect(parsed.scanMetrics).assertInstanceOf('object');
    });

    /**
     * 测试检查指标是否达标
     */
    it('test_check_metrics_targets', 0, async () => {
      // 模拟达标的数据
      for (let i = 0; i < 100; i++) {
        analyticsManager.track({
          eventType: EventType.PLAY_START,
          mediaId: `video${i}.mp4`,
          sourceType: SourceType.LOCAL
        });

        analyticsManager.track({
          eventType: EventType.PLAY_PREPARED,
          mediaId: `video${i}.mp4`,
          sourceType: SourceType.LOCAL,
          prepareTime: 500
        });

        analyticsManager.track({
          eventType: EventType.PLAY_FIRST_FRAME,
          mediaId: `video${i}.mp4`,
          sourceType: SourceType.LOCAL,
          firstFrameTime: 1000  // P50 和 P95 都小于目标
        });
      }

      // 字幕数据
      for (let i = 0; i < 100; i++) {
        analyticsManager.track({
          eventType: EventType.SUBTITLE_LOAD_SUCCESS,
          mediaId: `video${i}.mp4`,
          trackIndex: 0,
          subtitleFormat: SubtitleFormatType.SRT,
          loadTime: 300
        });
      }

      // 扫描数据
      analyticsManager.track({
        eventType: EventType.SCAN_COMPLETED,
        sourceId: '1',
        sourceName: 'Source 1',
        totalFiles: 100,
        successFiles: 99,
        failedFiles: 1,
        scanTime: 5000,
        coverageRate: 0.99
      });

      const startTime = Date.now() - 10000;
      const endTime = Date.now() + 1000;
      const report = await reporter.generateReport(startTime, endTime);
      const targets = reporter.checkMetricsTargets(report);

      expect(targets.playSuccessRateOk).assertTrue();
      expect(targets.firstFrameP50Ok).assertTrue();
      expect(targets.firstFrameP95Ok).assertTrue();
      expect(targets.subtitleAvailabilityOk).assertTrue();
      expect(targets.scanCoverageOk).assertTrue();
      expect(targets.allTargetsMet).assertTrue();
    });

    /**
     * 测试生成最近24小时报告
     */
    it('test_generate_last_24_hours_report', 0, async () => {
      analyticsManager.track({
        eventType: EventType.PLAY_START,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL
      });

      const report = await reporter.generateLast24HoursReport();

      expect(report.reportTime).assertLarger(0);
      expect(report.timeRange.endTime - report.timeRange.startTime).assertEqual(24 * 60 * 60 * 1000);
    });

    /**
     * 测试生成最近7天报告
     */
    it('test_generate_last_7_days_report', 0, async () => {
      analyticsManager.track({
        eventType: EventType.PLAY_START,
        mediaId: 'video1.mp4',
        sourceType: SourceType.LOCAL
      });

      const report = await reporter.generateLast7DaysReport();

      expect(report.reportTime).assertLarger(0);
      expect(report.timeRange.endTime - report.timeRange.startTime).assertEqual(7 * 24 * 60 * 60 * 1000);
    });
  });
}
