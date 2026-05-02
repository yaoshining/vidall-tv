/**
 * ScanMetrics Test Suite
 * 
 * Tests media scanning coverage metrics instrumentation.
 * Validates scan coverage calculation and recording.
 * 
 * Requirements:
 * - Task 6.2: Tests for scan coverage calculation
 * - Spec: playback-metrics-collection/spec.md - Scanning Coverage Metrics
 */

import { describe, it, expect, beforeEach, afterEach } from '@ohos/hypium';
import { MetricsService } from '../../../../main/ets/services/metrics/MetricsService';
import { MetricsReporter } from '../../../../main/ets/services/metrics/MetricsReporter';

export default function ScanMetricsTest() {
  describe('ScanMetrics', () => {
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
     * Task 6.2: Test scan coverage recording
     * 
     * Scenario: Scan operation recorded
     * - WHEN a media library scan completes
     * - THEN system records total items scanned and items successfully matched with metadata
     */
    it('should record scan coverage with items scanned and total', () => {
      // Arrange
      const itemsScanned = 450;
      const totalItems = 500;

      // Act
      MetricsService.getInstance().recordScanCoverage(itemsScanned, totalItems);

      // Assert
      expect(mockReporter.scanCoverages.length).assertEqual(1);
      expect(mockReporter.scanCoverages[0].scanned).assertEqual(itemsScanned);
      expect(mockReporter.scanCoverages[0].total).assertEqual(totalItems);
    });

    /**
     * Task 6.2: Test scan coverage percentage calculation
     * 
     * Scenario: Coverage calculation
     * - WHEN scan metrics are recorded
     * - THEN coverage is calculated as (items_with_metadata / total_items) * 100
     */
    it('should calculate scan coverage percentage correctly', () => {
      // Arrange & Act
      MetricsService.getInstance().recordScanCoverage(450, 500);

      // Assert
      const coverage = mockReporter.scanCoverages[0];
      const coveragePercentage = (coverage.scanned / coverage.total) * 100;
      expect(coveragePercentage).assertEqual(90.0);
    });

    /**
     * Task 6.2: Test multiple scan operations aggregation
     * 
     * Scenario: Multiple scans aggregated
     * - WHEN multiple scans occur in a day
     * - THEN system records each scan operation separately
     */
    it('should record multiple scan operations correctly', () => {
      // Act
      MetricsService.getInstance().recordScanCoverage(100, 120);
      MetricsService.getInstance().recordScanCoverage(200, 250);
      MetricsService.getInstance().recordScanCoverage(50, 50);

      // Assert
      expect(mockReporter.scanCoverages.length).assertEqual(3);
      
      expect(mockReporter.scanCoverages[0].scanned).assertEqual(100);
      expect(mockReporter.scanCoverages[0].total).assertEqual(120);
      
      expect(mockReporter.scanCoverages[1].scanned).assertEqual(200);
      expect(mockReporter.scanCoverages[1].total).assertEqual(250);
      
      expect(mockReporter.scanCoverages[2].scanned).assertEqual(50);
      expect(mockReporter.scanCoverages[2].total).assertEqual(50);
    });

    /**
     * Task 6.2: Test 100% coverage scenario
     */
    it('should handle 100% coverage correctly', () => {
      // Act
      MetricsService.getInstance().recordScanCoverage(100, 100);

      // Assert
      const coverage = mockReporter.scanCoverages[0];
      const coveragePercentage = (coverage.scanned / coverage.total) * 100;
      expect(coveragePercentage).assertEqual(100.0);
    });

    /**
     * Task 6.2: Test partial coverage scenario
     */
    it('should handle partial coverage correctly', () => {
      // Act
      MetricsService.getInstance().recordScanCoverage(45, 100);

      // Assert
      const coverage = mockReporter.scanCoverages[0];
      const coveragePercentage = (coverage.scanned / coverage.total) * 100;
      expect(coveragePercentage).assertEqual(45.0);
    });
  });
}
