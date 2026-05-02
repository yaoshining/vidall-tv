/**
 * Test suite for MetricsReporter interface contract
 * Requirement: Interface defines core operations for metrics collection
 * Spec: metrics-instrumentation-api/spec.md
 */

import { describe, it, expect } from '@ohos/hypium';
import { MetricsReporter } from '../../../../main/ets/services/metrics/MetricsReporter';

export default function metricsReporterInterfaceTest() {
  describe('MetricsReporter Interface Contract', () => {
    
    it('should define recordPlaybackAttempt method signature', () => {
      // Verify interface compiles with correct method signature
      const mockReporter: MetricsReporter = {
        recordPlaybackAttempt: (success: boolean, firstFrameMs: number): void => {},
        recordSubtitleUsage: (language: string | null): void => {},
        recordScanCoverage: (scanned: number, total: number): void => {},
        flush: async (): Promise<void> => {}
      };
      
      expect(typeof mockReporter.recordPlaybackAttempt).assertEqual('function');
    });
    
    it('should define recordSubtitleUsage method signature', () => {
      const mockReporter: MetricsReporter = {
        recordPlaybackAttempt: (success: boolean, firstFrameMs: number): void => {},
        recordSubtitleUsage: (language: string | null): void => {},
        recordScanCoverage: (scanned: number, total: number): void => {},
        flush: async (): Promise<void> => {}
      };
      
      expect(typeof mockReporter.recordSubtitleUsage).assertEqual('function');
    });
    
    it('should define recordScanCoverage method signature', () => {
      const mockReporter: MetricsReporter = {
        recordPlaybackAttempt: (success: boolean, firstFrameMs: number): void => {},
        recordSubtitleUsage: (language: string | null): void => {},
        recordScanCoverage: (scanned: number, total: number): void => {},
        flush: async (): Promise<void> => {}
      };
      
      expect(typeof mockReporter.recordScanCoverage).assertEqual('function');
    });
    
    it('should define async flush method signature', () => {
      const mockReporter: MetricsReporter = {
        recordPlaybackAttempt: (success: boolean, firstFrameMs: number): void => {},
        recordSubtitleUsage: (language: string | null): void => {},
        recordScanCoverage: (scanned: number, total: number): void => {},
        flush: async (): Promise<void> => {}
      };
      
      expect(typeof mockReporter.flush).assertEqual('function');
      const flushResult = mockReporter.flush();
      expect(flushResult instanceof Promise).assertTrue();
    });
    
    it('should allow null for subtitle language parameter', () => {
      const mockReporter: MetricsReporter = {
        recordPlaybackAttempt: (success: boolean, firstFrameMs: number): void => {},
        recordSubtitleUsage: (language: string | null): void => {},
        recordScanCoverage: (scanned: number, total: number): void => {},
        flush: async (): Promise<void> => {}
      };
      
      // Test that null is accepted (compiles without error)
      mockReporter.recordSubtitleUsage(null);
      mockReporter.recordSubtitleUsage('zh');
      expect(true).assertTrue(); // If compilation succeeds, test passes
    });
  });
}
