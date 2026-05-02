/**
 * SubtitleMetrics Test Suite
 * 
 * Tests subtitle usage tracking instrumentation.
 * Validates language selection recording and no-subtitle scenarios.
 * 
 * Requirements:
 * - Task 5.2: Tests for subtitle language selection recording
 * - Spec: playback-metrics-collection/spec.md - Subtitle Usage Tracking
 */

import { describe, it, expect, beforeEach, afterEach } from '@ohos/hypium';
import { MetricsService } from '../../../../main/ets/services/metrics/MetricsService';
import { MetricsReporter } from '../../../../main/ets/services/metrics/MetricsReporter';

export default function SubtitleMetricsTest() {
  describe('SubtitleMetrics', () => {
    // Mock MetricsReporter for testing
    class MockMetricsReporter implements MetricsReporter {
      public playbackAttempts: Array<{ success: boolean, firstFrameMs: number }> = [];
      public subtitleUsages: Array<string | null> = [];
      public scanCoverages: Array<{ scanned: number, total: number }> = [];
      public flushCalls: number = 0;

      recordPlaybackAttempt(success: boolean, firstFrameMs: number): void {
        this.playbackAttempts.push({ success, firstFrameMs });
      }

      recordSubtitleUsage(language: string | null): void {
        this.subtitleUsages.push(language);
      }

      recordScanCoverage(scanned: number, total: number): void {
        this.scanCoverages.push({ scanned, total });
      }

      async flush(): Promise<void> {
        this.flushCalls++;
      }

      reset(): void {
        this.playbackAttempts = [];
        this.subtitleUsages = [];
        this.scanCoverages = [];
        this.flushCalls = 0;
      }
    }

    let mockReporter: MockMetricsReporter;

    beforeEach(() => {
      mockReporter = new MockMetricsReporter();
      MetricsService.resetForTesting();
      MetricsService.initialize({} as Context, mockReporter);
    });

    afterEach(() => {
      MetricsService.resetForTesting();
    });

    /**
     * Task 5.2: Test subtitle language selection recording
     * 
     * Scenario: Subtitle language recorded
     * - WHEN user manually selects a subtitle language during playback
     * - THEN system records the selected language code (ISO 639-1 or 639-2)
     */
    it('should record subtitle language selection', () => {
      // Act
      MetricsService.getInstance().recordSubtitleUsage('zh');

      // Assert
      expect(mockReporter.subtitleUsages.length).assertEqual(1);
      expect(mockReporter.subtitleUsages[0]).assertEqual('zh');
    });

    /**
     * Task 5.2: Test different language codes
     */
    it('should record different ISO language codes correctly', () => {
      // Act
      MetricsService.getInstance().recordSubtitleUsage('en');
      MetricsService.getInstance().recordSubtitleUsage('zh');
      MetricsService.getInstance().recordSubtitleUsage('ja');
      MetricsService.getInstance().recordSubtitleUsage('chi'); // ISO 639-2

      // Assert
      expect(mockReporter.subtitleUsages.length).assertEqual(4);
      expect(mockReporter.subtitleUsages[0]).assertEqual('en');
      expect(mockReporter.subtitleUsages[1]).assertEqual('zh');
      expect(mockReporter.subtitleUsages[2]).assertEqual('ja');
      expect(mockReporter.subtitleUsages[3]).assertEqual('chi');
    });

    /**
     * Task 5.2: Test no subtitle usage recording
     * 
     * Scenario: No subtitle usage recorded
     * - WHEN user plays video without selecting subtitles
     * - THEN system records subtitle usage as null/none
     */
    it('should record null when no subtitle is selected', () => {
      // Act
      MetricsService.getInstance().recordSubtitleUsage(null);

      // Assert
      expect(mockReporter.subtitleUsages.length).assertEqual(1);
      expect(mockReporter.subtitleUsages[0]).assertEqual(null);
    });

    /**
     * Task 5.2: Test multiple playback sessions with mixed subtitle usage
     */
    it('should record mixed subtitle usage across multiple playbacks', () => {
      // Act
      MetricsService.getInstance().recordSubtitleUsage('zh');
      MetricsService.getInstance().recordSubtitleUsage(null);
      MetricsService.getInstance().recordSubtitleUsage('en');
      MetricsService.getInstance().recordSubtitleUsage(null);
      MetricsService.getInstance().recordSubtitleUsage('zh');

      // Assert
      expect(mockReporter.subtitleUsages.length).assertEqual(5);
      
      const withSubtitles = mockReporter.subtitleUsages.filter(lang => lang !== null).length;
      const withoutSubtitles = mockReporter.subtitleUsages.filter(lang => lang === null).length;
      
      expect(withSubtitles).assertEqual(3);
      expect(withoutSubtitles).assertEqual(2);
    });
  });
}
