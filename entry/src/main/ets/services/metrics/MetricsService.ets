/**
 * MetricsService - Singleton wrapper for global metrics reporting
 * 
 * Provides centralized access to MetricsReporter instance across the application.
 * Simplifies instrumentation without complex dependency injection setup.
 * 
 * Usage:
 *   MetricsService.getInstance().recordPlaybackAttempt(true, 450);
 * 
 * Initialization:
 *   MetricsService.initialize(context) - Called once in Ability onCreate
 * 
 * Lifecycle:
 *   MetricsService.getInstance().flush() - Called in onBackground/onDestroy
 * 
 * Requirement: Dependency Injection for Reporter, Application Lifecycle Integration
 * Spec: metrics-instrumentation-api/spec.md
 */

import { Context } from '@ohos.abilityAccessCtrl';
import { MetricsReporter } from './MetricsReporter';
import { LocalFileReporter } from './LocalFileReporter';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'MetricsService';
const DOMAIN = 0x0001;

/**
 * Singleton service for metrics reporting
 */
export class MetricsService {
  private static instance: MetricsService | null = null;
  private reporter: MetricsReporter;

  private constructor(reporter: MetricsReporter) {
    this.reporter = reporter;
  }

  /**
   * Initialize the global MetricsService instance
   * Should be called once in Application/Ability onCreate
   * 
   * @param context - Application context for accessing storage
   * @param customReporter - Optional custom reporter (default: LocalFileReporter)
   */
  static initialize(context: Context, customReporter?: MetricsReporter): void {
    if (MetricsService.instance) {
      hilog.warn(DOMAIN, TAG, 'MetricsService already initialized, skipping');
      return;
    }

    const reporter = customReporter || new LocalFileReporter(context);
    MetricsService.instance = new MetricsService(reporter);
    hilog.info(DOMAIN, TAG, 'MetricsService initialized');
  }

  /**
   * Get the global MetricsService instance
   * Throws error if not initialized (fail-fast for developer error)
   * 
   * @returns MetricsService instance
   */
  static getInstance(): MetricsService {
    if (!MetricsService.instance) {
      throw new Error('MetricsService not initialized. Call MetricsService.initialize() first.');
    }
    return MetricsService.instance;
  }

  /**
   * Check if MetricsService is initialized
   * Useful for optional metrics in code that may run before initialization
   * 
   * @returns true if initialized, false otherwise
   */
  static isInitialized(): boolean {
    return MetricsService.instance !== null;
  }

  /**
   * Get the underlying MetricsReporter instance
   * 
   * @returns MetricsReporter instance
   */
  getReporter(): MetricsReporter {
    return this.reporter;
  }

  /**
   * Record a playback attempt (delegates to reporter)
   */
  recordPlaybackAttempt(success: boolean, firstFrameMs: number, mediaId?: number, sourceType?: string): void {
    try {
      this.reporter.recordPlaybackAttempt(success, firstFrameMs, mediaId, sourceType);
    } catch (e) {
      hilog.error(DOMAIN, TAG, `Failed to record playback attempt: ${e}`);
    }
  }

  /**
   * Record subtitle usage (delegates to reporter)
   */
  recordSubtitleUsage(language: string | null): void {
    try {
      this.reporter.recordSubtitleUsage(language);
    } catch (e) {
      hilog.error(DOMAIN, TAG, `Failed to record subtitle usage: ${e}`);
    }
  }

  /**
   * Record scan coverage (delegates to reporter)
   */
  recordScanCoverage(scanned: number, total: number): void {
    try {
      this.reporter.recordScanCoverage(scanned, total);
    } catch (e) {
      hilog.error(DOMAIN, TAG, `Failed to record scan coverage: ${e}`);
    }
  }

  /**
   * Flush metrics to persistent storage (delegates to reporter)
   */
  async flush(): Promise<void> {
    try {
      await this.reporter.flush();
    } catch (e) {
      hilog.error(DOMAIN, TAG, `Failed to flush metrics: ${e}`);
    }
  }

  /**
   * Reset the singleton instance (for testing only)
   * @internal
   */
  static resetForTesting(): void {
    MetricsService.instance = null;
  }
}
