/**
 * LocalFileReporter - Default implementation of MetricsReporter
 * 
 * Stores metrics in JSON files with daily granularity (YYYY-MM-DD.json).
 * Uses in-memory aggregation for performance, persists on app lifecycle events.
 * Implements 30-day retention policy.
 * 
 * Design Decisions:
 * - In-memory aggregation: Minimize I/O overhead, flush on background/terminate
 * - JSON format: Human-readable, extensible, platform-agnostic
 * - Daily rotation: Natural retention boundary, keeps files small
 * - Preferences directory: App-private, survives updates
 * 
 * Requirements:
 * - Thread-safe operations (concurrent recording from player/scanner)
 * - Non-blocking recording (< 1ms per call)
 * - Graceful error handling (never crash app)
 * - 30-day retention policy enforcement
 * 
 * Spec: metrics-instrumentation-api/spec.md, playback-metrics-collection/spec.md
 */

import { MetricsReporter } from './MetricsReporter';
import fs from '@ohos.file.fs';
import { Context } from '@ohos.abilityAccessCtrl';
import { hilog } from '@kit.PerformanceAnalysisKit';
import util from '@ohos.util';

const TAG = 'LocalFileReporter';
const DOMAIN = 0x0001;
const RETENTION_DAYS = 30;
const SCHEMA_VERSION = 1;

/**
 * Playback metrics data
 */
interface PlaybackMetricsData {
  attempts: number;
  success: number;
  failures: number;
  firstFrameTimes: number[];
}

/**
 * Subtitle metrics data
 */
interface SubtitleMetricsData {
  total_playbacks: number;
  with_subtitles: number;
  languages: Map<string, number>;
}

/**
 * Scanning metrics data
 */
interface ScanningMetricsData {
  scans_triggered: number;
  items_scanned: number;
  items_available: number;
}

/**
 * In-memory metrics aggregation structure
 */
interface MetricsData {
  playback: PlaybackMetricsData;
  subtitles: SubtitleMetricsData;
  scanning: ScanningMetricsData;
}

/**
 * First frame time percentiles
 */
interface FirstFrameTimePercentiles {
  p50: number;
  p90: number;
  p99: number;
}

/**
 * Playback metrics for JSON
 */
interface PlaybackMetricsJSON {
  attempts: number;
  success: number;
  failures: number;
  firstFrameTimeMs: FirstFrameTimePercentiles;
}

/**
 * Subtitle metrics for JSON
 */
interface SubtitleMetricsJSON {
  total_playbacks: number;
  with_subtitles: number;
  languages: Record<string, number>;
}

/**
 * Scanning metrics for JSON
 */
interface ScanningMetricsJSON {
  scans_triggered: number;
  items_scanned: number;
  items_available: number;
  coverage_pct: number;
}

/**
 * JSON schema for metrics file
 */
interface MetricsJSON {
  schema_version: number;
  date: string;
  playback: PlaybackMetricsJSON;
  subtitles: SubtitleMetricsJSON;
  scanning: ScanningMetricsJSON;
}

/**
 * Default implementation of MetricsReporter using local JSON files
 */
export class LocalFileReporter implements MetricsReporter {
  private context: Context;
  private metricsData: MetricsData;
  private lock: Promise<void> = Promise.resolve();

  constructor(context: Context) {
    this.context = context;
    this.metricsData = this.initializeMetricsData();
    
    // Enforce retention policy on initialization
    this.cleanupOldFiles();
  }

  /**
   * Initialize empty metrics data structure
   */
  private initializeMetricsData(): MetricsData {
    const playback: PlaybackMetricsData = {
      attempts: 0,
      success: 0,
      failures: 0,
      firstFrameTimes: []
    };
    
    const subtitles: SubtitleMetricsData = {
      total_playbacks: 0,
      with_subtitles: 0,
      languages: new Map<string, number>()
    };
    
    const scanning: ScanningMetricsData = {
      scans_triggered: 0,
      items_scanned: 0,
      items_available: 0
    };
    
    const result: MetricsData = {
      playback: playback,
      subtitles: subtitles,
      scanning: scanning
    };
    
    return result;
  }

  /**
   * Record a playback attempt
   * Requirement: Playback Success Rate Tracking, First Frame Time Measurement
   */
  recordPlaybackAttempt(success: boolean, firstFrameMs: number): void {
    try {
      this.metricsData.playback.attempts++;
      
      if (success) {
        this.metricsData.playback.success++;
        if (firstFrameMs > 0) {
          this.metricsData.playback.firstFrameTimes.push(firstFrameMs);
        }
      } else {
        this.metricsData.playback.failures++;
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, `Failed to record playback attempt: ${e}`);
    }
  }

  /**
   * Record subtitle usage
   * Requirement: Subtitle Usage Tracking
   */
  recordSubtitleUsage(language: string | null): void {
    try {
      this.metricsData.subtitles.total_playbacks++;
      
      if (language) {
        this.metricsData.subtitles.with_subtitles++;
        const currentCount = this.metricsData.subtitles.languages.get(language) || 0;
        this.metricsData.subtitles.languages.set(language, currentCount + 1);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, `Failed to record subtitle usage: ${e}`);
    }
  }

  /**
   * Record scan coverage metrics
   * Requirement: Scanning Coverage Metrics
   */
  recordScanCoverage(scanned: number, total: number): void {
    try {
      this.metricsData.scanning.scans_triggered++;
      this.metricsData.scanning.items_scanned += scanned;
      this.metricsData.scanning.items_available += total;
    } catch (e) {
      hilog.error(DOMAIN, TAG, `Failed to record scan coverage: ${e}`);
    }
  }

  /**
   * Flush in-memory metrics to JSON file
   * Requirement: Local Metrics Persistence
   */
  async flush(): Promise<void> {
    // Serialize flush operations to prevent concurrent writes
    this.lock = this.lock.then(async () => {
      try {
        const today = new Date();
        const dateStr = this.formatDate(today);
        const filePath = `${this.context.preferencesDir}/${dateStr}.json`;

        // Read existing file if present (for incremental updates)
        let existingData: MetricsJSON | null = null;
        try {
          if (fs.accessSync(filePath)) {
            const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
            const buffer = new ArrayBuffer(10240); // 10KB buffer
            const readLen = fs.readSync(file.fd, buffer);
            fs.closeSync(file);
            
            const decoder = new util.TextDecoder('utf-8', { fatal: false, ignoreBOM: true });
            const content = decoder.decodeWithStream(new Uint8Array(buffer, 0, readLen));
            existingData = JSON.parse(content) as MetricsJSON;
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, `Could not read existing metrics file: ${e}`);
        }

        // Merge with existing data if present
        const metricsJSON: MetricsJSON = this.toJSON(dateStr, existingData);

        // Write to file
        const jsonContent = JSON.stringify(metricsJSON, null, 2);
        const encoder = new util.TextEncoder();
        const uint8Array = encoder.encodeInto(jsonContent);
        
        const file = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, uint8Array.buffer);
        fs.closeSync(file);
        
        hilog.info(DOMAIN, TAG, `Metrics flushed to ${filePath}`);
        
        // Reset in-memory data after successful flush
        this.metricsData = this.initializeMetricsData();
      } catch (e) {
        hilog.error(DOMAIN, TAG, `Failed to flush metrics: ${e}`);
        // Don't throw - graceful degradation
      }
    });

    return this.lock;
  }

  /**
   * Convert in-memory metrics to JSON format
   */
  private toJSON(dateStr: string, existingData: MetricsJSON | null): MetricsJSON {
    // Calculate percentiles for first frame time
    const percentiles: FirstFrameTimePercentiles = this.calculatePercentiles(this.metricsData.playback.firstFrameTimes);
    
    // Calculate scanning coverage
    const totalScanned = (existingData?.scanning.items_scanned || 0) + this.metricsData.scanning.items_scanned;
    const totalAvailable = (existingData?.scanning.items_available || 0) + this.metricsData.scanning.items_available;
    const coveragePct = totalAvailable > 0 ? (totalScanned / totalAvailable) * 100 : 0;

    // Merge language counts
    const languages: Record<string, number> = existingData?.subtitles.languages || {};
    this.metricsData.subtitles.languages.forEach((count: number, lang: string) => {
      languages[lang] = (languages[lang] || 0) + count;
    });

    const playback: PlaybackMetricsJSON = {
      attempts: (existingData?.playback.attempts || 0) + this.metricsData.playback.attempts,
      success: (existingData?.playback.success || 0) + this.metricsData.playback.success,
      failures: (existingData?.playback.failures || 0) + this.metricsData.playback.failures,
      firstFrameTimeMs: percentiles
    };
    
    const subtitles: SubtitleMetricsJSON = {
      total_playbacks: (existingData?.subtitles.total_playbacks || 0) + this.metricsData.subtitles.total_playbacks,
      with_subtitles: (existingData?.subtitles.with_subtitles || 0) + this.metricsData.subtitles.with_subtitles,
      languages: languages
    };
    
    const scanning: ScanningMetricsJSON = {
      scans_triggered: (existingData?.scanning.scans_triggered || 0) + this.metricsData.scanning.scans_triggered,
      items_scanned: totalScanned,
      items_available: totalAvailable,
      coverage_pct: Math.round(coveragePct * 100) / 100
    };

    const result: MetricsJSON = {
      schema_version: SCHEMA_VERSION,
      date: dateStr,
      playback: playback,
      subtitles: subtitles,
      scanning: scanning
    };
    
    return result;
  }

  /**
   * Calculate percentiles from array of values
   * Uses bucket histogram for simplicity (good enough for p50/p90/p99)
   */
  private calculatePercentiles(values: number[]): FirstFrameTimePercentiles {
    if (values.length === 0) {
      const empty: FirstFrameTimePercentiles = { p50: 0, p90: 0, p99: 0 };
      return empty;
    }

    const sorted = [...values].sort((a: number, b: number) => a - b);
    const p50Index = Math.floor(sorted.length * 0.50);
    const p90Index = Math.floor(sorted.length * 0.90);
    const p99Index = Math.floor(sorted.length * 0.99);

    const result: FirstFrameTimePercentiles = {
      p50: sorted[p50Index] || 0,
      p90: sorted[p90Index] || 0,
      p99: sorted[p99Index] || 0
    };
    
    return result;
  }

  /**
   * Format date as YYYY-MM-DD
   */
  private formatDate(date: Date): string {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
  }

  /**
   * Delete metrics files older than 30 days
   * Requirement: 30-day retention policy enforcement
   */
  private cleanupOldFiles(): void {
    try {
      const prefsDir = this.context.preferencesDir;
      const now = new Date();
      const cutoffDate = new Date(now.getTime() - RETENTION_DAYS * 24 * 60 * 60 * 1000);

      const files = fs.listFileSync(prefsDir);
      files.forEach(fileName => {
        if (fileName.match(/^\d{4}-\d{2}-\d{2}\.json$/)) {
          const fileDateStr = fileName.replace('.json', '');
          const fileDate = new Date(fileDateStr);
          
          if (fileDate < cutoffDate) {
            const filePath = `${prefsDir}/${fileName}`;
            try {
              fs.unlinkSync(filePath);
              hilog.info(DOMAIN, TAG, `Deleted old metrics file: ${fileName}`);
            } catch (e) {
              hilog.warn(DOMAIN, TAG, `Could not delete old file ${fileName}: ${e}`);
            }
          }
        }
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, `Failed to cleanup old files: ${e}`);
      // Don't throw - initialization should continue
    }
  }
}
