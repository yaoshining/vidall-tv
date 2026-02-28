import { hilog } from '@kit.PerformanceAnalysisKit';
import { CommonConstants } from '../common/constants/CommonConstants';
import { AnalyticsManager } from './AnalyticsManager';
import {
  AnalyticsEvent,
  EventType,
  PlayStartEvent,
  PlayPreparedEvent,
  PlayFailedEvent,
  PlayFirstFrameEvent,
  SubtitleLoadSuccessEvent,
  SubtitleLoadFailedEvent,
  ScanCompletedEvent
} from './AnalyticsTypes';

const TAG = '[AnalyticsReporter]';

/**
 * 播放指标统计
 */
export interface PlayMetrics {
  totalPlayAttempts: number;        // 总播放尝试次数
  successfulPlays: number;          // 成功播放次数
  failedPlays: number;              // 失败播放次数
  successRate: number;              // 播放成功率（0-1）
  firstFrameTimeP50: number;        // 首帧时间 P50 (ms)
  firstFrameTimeP95: number;        // 首帧时间 P95 (ms)
  avgFirstFrameTime: number;        // 平均首帧时间 (ms)
  firstFrameTimes: number[];        // 所有首帧时间数据
}

/**
 * 字幕指标统计
 */
export interface SubtitleMetrics {
  totalLoadAttempts: number;        // 总加载尝试次数
  successfulLoads: number;          // 成功加载次数
  failedLoads: number;              // 失败加载次数
  availabilityRate: number;         // 字幕可用率（0-1）
  avgLoadTime: number;              // 平均加载时间 (ms)
}

/**
 * 扫描指标统计
 */
export interface ScanMetrics {
  totalScans: number;               // 总扫描次数
  totalFiles: number;               // 总文件数
  successFiles: number;             // 成功处理文件数
  failedFiles: number;              // 失败文件数
  coverageRate: number;             // 扫描覆盖率（0-1）
  avgScanTime: number;              // 平均扫描时间 (ms)
}

/**
 * 综合指标报告
 */
export interface MetricsReport {
  reportTime: number;               // 报告生成时间
  timeRange: {
    startTime: number;
    endTime: number;
  };
  playMetrics: PlayMetrics;
  subtitleMetrics: SubtitleMetrics;
  scanMetrics: ScanMetrics;
}

/**
 * 埋点数据聚合报表工具
 */
export class AnalyticsReporter {
  private analyticsManager: AnalyticsManager;

  constructor() {
    this.analyticsManager = AnalyticsManager.getInstance();
  }

  /**
   * 生成指定时间范围的指标报告
   */
  public async generateReport(startTime: number, endTime: number): Promise<MetricsReport> {
    try {
      const events = await this.analyticsManager.getEventsByTimeRange(startTime, endTime);

      const playMetrics = this.calculatePlayMetrics(events);
      const subtitleMetrics = this.calculateSubtitleMetrics(events);
      const scanMetrics = this.calculateScanMetrics(events);

      const report: MetricsReport = {
        reportTime: Date.now(),
        timeRange: { startTime, endTime },
        playMetrics,
        subtitleMetrics,
        scanMetrics
      };

      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'Report generated successfully');
      return report;
    } catch (err) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG, `generateReport failed: ${JSON.stringify(err)}`);
      throw err;
    }
  }

  /**
   * 生成最近24小时的报告
   */
  public async generateLast24HoursReport(): Promise<MetricsReport> {
    const endTime = Date.now();
    const startTime = endTime - 24 * 60 * 60 * 1000; // 24小时前
    return this.generateReport(startTime, endTime);
  }

  /**
   * 生成最近7天的报告
   */
  public async generateLast7DaysReport(): Promise<MetricsReport> {
    const endTime = Date.now();
    const startTime = endTime - 7 * 24 * 60 * 60 * 1000; // 7天前
    return this.generateReport(startTime, endTime);
  }

  /**
   * 计算播放指标
   */
  private calculatePlayMetrics(events: AnalyticsEvent[]): PlayMetrics {
    const playStartEvents = events.filter(e => e.eventType === EventType.PLAY_START) as PlayStartEvent[];
    const playPreparedEvents = events.filter(e => e.eventType === EventType.PLAY_PREPARED) as PlayPreparedEvent[];
    const playFailedEvents = events.filter(e => e.eventType === EventType.PLAY_FAILED) as PlayFailedEvent[];
    const firstFrameEvents = events.filter(e => e.eventType === EventType.PLAY_FIRST_FRAME) as PlayFirstFrameEvent[];

    const totalPlayAttempts = playStartEvents.length;
    const successfulPlays = playPreparedEvents.length;
    const failedPlays = playFailedEvents.length;
    const successRate = totalPlayAttempts > 0 ? successfulPlays / totalPlayAttempts : 0;

    // 提取首帧时间数据
    const firstFrameTimes = firstFrameEvents.map(e => e.firstFrameTime).sort((a, b) => a - b);

    // 计算 P50 和 P95
    const firstFrameTimeP50 = this.calculatePercentile(firstFrameTimes, 0.5);
    const firstFrameTimeP95 = this.calculatePercentile(firstFrameTimes, 0.95);

    // 计算平均值
    const avgFirstFrameTime = firstFrameTimes.length > 0
      ? firstFrameTimes.reduce((sum, time) => sum + time, 0) / firstFrameTimes.length
      : 0;

    return {
      totalPlayAttempts,
      successfulPlays,
      failedPlays,
      successRate,
      firstFrameTimeP50,
      firstFrameTimeP95,
      avgFirstFrameTime,
      firstFrameTimes
    };
  }

  /**
   * 计算字幕指标
   */
  private calculateSubtitleMetrics(events: AnalyticsEvent[]): SubtitleMetrics {
    const subtitleSuccessEvents = events.filter(e =>
      e.eventType === EventType.SUBTITLE_LOAD_SUCCESS
    ) as SubtitleLoadSuccessEvent[];

    const subtitleFailedEvents = events.filter(e =>
      e.eventType === EventType.SUBTITLE_LOAD_FAILED
    ) as SubtitleLoadFailedEvent[];

    const totalLoadAttempts = subtitleSuccessEvents.length + subtitleFailedEvents.length;
    const successfulLoads = subtitleSuccessEvents.length;
    const failedLoads = subtitleFailedEvents.length;
    const availabilityRate = totalLoadAttempts > 0 ? successfulLoads / totalLoadAttempts : 0;

    // 计算平均加载时间
    const loadTimes = subtitleSuccessEvents.map(e => e.loadTime);
    const avgLoadTime = loadTimes.length > 0
      ? loadTimes.reduce((sum, time) => sum + time, 0) / loadTimes.length
      : 0;

    return {
      totalLoadAttempts,
      successfulLoads,
      failedLoads,
      availabilityRate,
      avgLoadTime
    };
  }

  /**
   * 计算扫描指标
   */
  private calculateScanMetrics(events: AnalyticsEvent[]): ScanMetrics {
    const scanCompletedEvents = events.filter(e =>
      e.eventType === EventType.SCAN_COMPLETED
    ) as ScanCompletedEvent[];

    const totalScans = scanCompletedEvents.length;
    let totalFiles = 0;
    let successFiles = 0;
    let failedFiles = 0;
    let totalScanTime = 0;

    for (const event of scanCompletedEvents) {
      totalFiles += event.totalFiles;
      successFiles += event.successFiles;
      failedFiles += event.failedFiles;
      totalScanTime += event.scanTime;
    }

    const coverageRate = totalFiles > 0 ? successFiles / totalFiles : 0;
    const avgScanTime = totalScans > 0 ? totalScanTime / totalScans : 0;

    return {
      totalScans,
      totalFiles,
      successFiles,
      failedFiles,
      coverageRate,
      avgScanTime
    };
  }

  /**
   * 计算百分位数
   */
  private calculatePercentile(sortedValues: number[], percentile: number): number {
    if (sortedValues.length === 0) {
      return 0;
    }

    const index = Math.ceil(sortedValues.length * percentile) - 1;
    return sortedValues[Math.max(0, index)];
  }

  /**
   * 格式化报告为可读字符串
   */
  public formatReport(report: MetricsReport): string {
    const lines: string[] = [];

    lines.push('=== 播放指标埋点报告 ===');
    lines.push('');
    lines.push(`报告生成时间: ${new Date(report.reportTime).toLocaleString()}`);
    lines.push(`统计时间范围: ${new Date(report.timeRange.startTime).toLocaleString()} - ${new Date(report.timeRange.endTime).toLocaleString()}`);
    lines.push('');

    // 播放指标
    lines.push('--- 播放指标 ---');
    lines.push(`总播放尝试次数: ${report.playMetrics.totalPlayAttempts}`);
    lines.push(`成功播放次数: ${report.playMetrics.successfulPlays}`);
    lines.push(`失败播放次数: ${report.playMetrics.failedPlays}`);
    lines.push(`播放成功率: ${(report.playMetrics.successRate * 100).toFixed(2)}% (目标: ≥95%)`);
    lines.push(`首帧时间 P50: ${report.playMetrics.firstFrameTimeP50.toFixed(0)}ms (目标: <1500ms)`);
    lines.push(`首帧时间 P95: ${report.playMetrics.firstFrameTimeP95.toFixed(0)}ms (目标: <3000ms)`);
    lines.push(`首帧平均时间: ${report.playMetrics.avgFirstFrameTime.toFixed(0)}ms`);
    lines.push('');

    // 字幕指标
    lines.push('--- 字幕指标 ---');
    lines.push(`总加载尝试次数: ${report.subtitleMetrics.totalLoadAttempts}`);
    lines.push(`成功加载次数: ${report.subtitleMetrics.successfulLoads}`);
    lines.push(`失败加载次数: ${report.subtitleMetrics.failedLoads}`);
    lines.push(`字幕可用率: ${(report.subtitleMetrics.availabilityRate * 100).toFixed(2)}% (目标: ≥95%)`);
    lines.push(`平均加载时间: ${report.subtitleMetrics.avgLoadTime.toFixed(0)}ms`);
    lines.push('');

    // 扫描指标
    lines.push('--- 扫描指标 ---');
    lines.push(`总扫描次数: ${report.scanMetrics.totalScans}`);
    lines.push(`总文件数: ${report.scanMetrics.totalFiles}`);
    lines.push(`成功处理文件数: ${report.scanMetrics.successFiles}`);
    lines.push(`失败文件数: ${report.scanMetrics.failedFiles}`);
    lines.push(`扫描覆盖率: ${(report.scanMetrics.coverageRate * 100).toFixed(2)}% (目标: ≥98%)`);
    lines.push(`平均扫描时间: ${report.scanMetrics.avgScanTime.toFixed(0)}ms`);
    lines.push('');

    return lines.join('\n');
  }

  /**
   * 导出报告为 JSON
   */
  public async exportReportAsJson(startTime: number, endTime: number): Promise<string> {
    const report = await this.generateReport(startTime, endTime);
    return JSON.stringify(report, null, 2);
  }

  /**
   * 检查指标是否达标
   */
  public checkMetricsTargets(report: MetricsReport): {
    playSuccessRateOk: boolean;
    firstFrameP50Ok: boolean;
    firstFrameP95Ok: boolean;
    subtitleAvailabilityOk: boolean;
    scanCoverageOk: boolean;
    allTargetsMet: boolean;
  } {
    const playSuccessRateOk = report.playMetrics.successRate >= 0.95;
    const firstFrameP50Ok = report.playMetrics.firstFrameTimeP50 < 1500;
    const firstFrameP95Ok = report.playMetrics.firstFrameTimeP95 < 3000;
    const subtitleAvailabilityOk = report.subtitleMetrics.availabilityRate >= 0.95;
    const scanCoverageOk = report.scanMetrics.coverageRate >= 0.98;

    const allTargetsMet = playSuccessRateOk && firstFrameP50Ok && firstFrameP95Ok &&
      subtitleAvailabilityOk && scanCoverageOk;

    return {
      playSuccessRateOk,
      firstFrameP50Ok,
      firstFrameP95Ok,
      subtitleAvailabilityOk,
      scanCoverageOk,
      allTargetsMet
    };
  }
}
