/**
 * MetricsReporter Interface
 * 
 * Defines the contract for metrics collection operations.
 * Enables dependency injection and future extension without modifying instrumentation code.
 * 
 * Design Decision: Interface-based architecture for extensibility
 * - Default implementation: LocalFileReporter (JSON persistence)
 * - Future: RemoteAnalyticsReporter (upload to analytics service)
 * - Testing: Mock implementations for unit tests
 * 
 * Requirement: MetricsReporter Interface
 * Spec: metrics-instrumentation-api/spec.md
 */

/**
 * Media identity for playback metrics.
 * Enables server-side video identification via external platform IDs.
 *
 * Degradation rules (when TMDB scrape info is unavailable):
 *   provider / provider_id / title / year → null
 *   file_name → always populated from VideoEntity.fileName
 */
export interface MediaIdentity {
  /** Local database ID (videos.id) */
  local_id: number;
  /** External provider name, e.g. 'tmdb'; null when not scraped */
  provider: string | null;
  /** External provider video ID, e.g. TMDB movie/series ID; null when not scraped */
  provider_id: string | null;
  /** Video title from scrape info; null when not scraped */
  title: string | null;
  /** Release year; null (ScrapeInfoEntity has no year field) */
  year: number | null;
  /** File name without path, always set from VideoEntity.fileName */
  file_name: string;
}

/**
 * Core metrics reporting interface
 */
export interface MetricsReporter {
  /**
   * Optional reporter label for diagnostics and observability.
   */
  getReporterName?(): string;

  /**
   * Record a playback attempt and its outcome
   *
   * @param success - Whether the playback attempt succeeded (first frame rendered)
   * @param firstFrameMs - Time from play intent to first frame (milliseconds), 0 if failed
   * @param media - Media identity object for server-side identification (undefined if unavailable)
   * @param sourceType - Source type string, e.g. 'local' (FILE_URI) or 'network' (URL)
   *
   * Requirements:
   * - Must complete in < 1ms (non-blocking)
   * - Called on player thread, must be thread-safe
   * - Failures should be logged but not throw exceptions
   *
   * Example:
   *   reporter.recordPlaybackAttempt(true, 450, media, 'local');   // Successful local file playback
   *   reporter.recordPlaybackAttempt(false, 0, undefined, 'network');  // Failed network playback
   */
  recordPlaybackAttempt(success: boolean, firstFrameMs: number, media?: MediaIdentity, sourceType?: string): void;

  /**
   * Record subtitle language selection or absence
   * 
   * @param language - ISO 639-1/639-2 language code ('zh', 'en'), or null if no subtitles
   * 
   * Requirements:
   * - Called when user explicitly selects subtitle, or on playback start if no selection
   * - Must be thread-safe
   * 
   * Example:
   *   reporter.recordSubtitleUsage('zh');   // User selected Chinese subtitles
   *   reporter.recordSubtitleUsage(null);   // Playback without subtitles
   */
  recordSubtitleUsage(language: string | null): void;

  /**
   * Record media scanning coverage metrics
   * 
   * @param scanned - Number of items successfully scanned in operation
   * @param total - Total number of items attempted to scan
   * 
   * Requirements:
   * - Called at end of each scan operation
   * - Coverage percentage calculated as (scanned / total) * 100
   * 
   * Example:
   *   reporter.recordScanCoverage(450, 500);  // 90% coverage
   */
  recordScanCoverage(scanned: number, total: number): void;

  /**
   * Persist in-memory metrics to storage
   * 
   * Requirements:
   * - Must be asynchronous (non-blocking)
   * - Called on app lifecycle events (background, terminate)
   * - Should be idempotent (safe to call multiple times)
   * - Failures should be logged but not throw exceptions
   * 
   * Returns: Promise that resolves when flush completes (or fails gracefully)
   * 
   * Example:
   *   await reporter.flush();  // Persist metrics before app backgrounds
   */
  flush(): Promise<void>;
}
