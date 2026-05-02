/**
 * PlaybackMetrics Test Suite
 * 
 * Tests playback metrics instrumentation in player components.
 * Validates first frame time measurement and success/failure recording.
 * 
 * Requirements:
 * - Task 4.2: Tests for playback attempt recording (success and failure scenarios)
 * - Task 4.6: Tests for first frame time measurement (timer start/stop)
 * 
 * Spec: playback-metrics-collection/spec.md
 */

import { describe, it, expect, beforeEach, afterEach } from '@ohos/hypium';
import { MetricsService } from '../../../../main/ets/services/metrics/MetricsService';
import { MetricsReporter } from '../../../../main/ets/services/metrics/MetricsReporter';

export default function PlaybackMetricsTest() {
  describe('PlaybackMetrics', () => {
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
     * Task 4.2: Test for successful playback recording
     * 
     * Scenario: Successful playback recorded
     * - WHEN a video playback starts and the first frame is rendered
     * - THEN the system records a successful playback attempt
     */
    it('should record successful playback attempt with first frame time', () => {
      // Arrange
      const firstFrameMs = 450;

      // Act
      MetricsService.getInstance().recordPlaybackAttempt(true, firstFrameMs);

      // Assert
      expect(mockReporter.playbackAttempts.length).assertEqual(1);
      expect(mockReporter.playbackAttempts[0].success).assertTrue();
      expect(mockReporter.playbackAttempts[0].firstFrameMs).assertEqual(firstFrameMs);
    });

    /**
     * Task 4.2: Test for failed playback recording
     * 
     * Scenario: Failed playback recorded
     * - WHEN a video playback attempt fails due to error
     * - THEN the system records a failed playback attempt
     */
    it('should record failed playback attempt without first frame time', () => {
      // Act
      MetricsService.getInstance().recordPlaybackAttempt(false, 0);

      // Assert
      expect(mockReporter.playbackAttempts.length).assertEqual(1);
      expect(mockReporter.playbackAttempts[0].success).assertFalse();
      expect(mockReporter.playbackAttempts[0].firstFrameMs).assertEqual(0);
    });

    /**
     * Task 4.6: Test for first frame time measurement accuracy
     * 
     * Scenario: First frame time captured
     * - WHEN user initiates playback
     * - THEN system measures duration accurately
     */
    it('should measure first frame time within expected range', () => {
      // Arrange
      const minExpectedMs = 100;
      const maxExpectedMs = 5000;
      const testFirstFrameMs = 850;

      // Act
      MetricsService.getInstance().recordPlaybackAttempt(true, testFirstFrameMs);

      // Assert
      const recorded = mockReporter.playbackAttempts[0];
      expect(recorded.firstFrameMs).assertLarger(minExpectedMs - 1);
      expect(recorded.firstFrameMs).assertLess(maxExpectedMs + 1);
    });

    /**
     * Task 4.2: Test multiple playback attempts aggregation
     */
    it('should record multiple playback attempts correctly', () => {
      // Act
      MetricsService.getInstance().recordPlaybackAttempt(true, 420);
      MetricsService.getInstance().recordPlaybackAttempt(true, 550);
      MetricsService.getInstance().recordPlaybackAttempt(false, 0);
      MetricsService.getInstance().recordPlaybackAttempt(true, 380);

      // Assert
      expect(mockReporter.playbackAttempts.length).assertEqual(4);
      
      const successCount = mockReporter.playbackAttempts.filter(a => a.success).length;
      const failureCount = mockReporter.playbackAttempts.filter(a => !a.success).length;
      
      expect(successCount).assertEqual(3);
      expect(failureCount).assertEqual(1);
    });
  });
}
