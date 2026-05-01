/**
 * Test suite for EntryAbility lifecycle metrics integration
 * Requirement: Verify MetricsService is properly initialized and flushed in Ability lifecycle
 * Spec: metrics-instrumentation-api/spec.md - Application Lifecycle Integration
 */

import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { MetricsService } from '../../main/ets/services/metrics/MetricsService';
import { MetricsReporter } from '../../main/ets/services/metrics/MetricsReporter';
import { Context } from '@ohos.abilityAccessCtrl';

export default function entryAbilityLifecycleTest() {
  describe('EntryAbility Metrics Lifecycle Integration', () => {
    
    let mockContext: Context;
    let flushCallCount: number;
    let mockReporter: MetricsReporter;
    
    beforeEach(() => {
      // Reset MetricsService singleton before each test
      MetricsService.resetForTesting();
      
      // Create mock context
      mockContext = {} as Context;
      
      // Create mock reporter with flush tracking
      flushCallCount = 0;
      mockReporter = {
        recordPlaybackAttempt: (): void => {},
        recordSubtitleUsage: (): void => {},
        recordScanCoverage: (): void => {},
        flush: async (): Promise<void> => {
          flushCallCount++;
        }
      };
    });
    
    it('should initialize MetricsService in onCreate', () => {
      // Before initialization
      expect(MetricsService.isInitialized()).assertFalse();
      
      // Simulate onCreate behavior
      MetricsService.initialize(mockContext, mockReporter);
      
      // After initialization
      expect(MetricsService.isInitialized()).assertTrue();
      expect(() => MetricsService.getInstance()).not.assertThrow();
    });
    
    it('should flush metrics in onBackground', async () => {
      // Setup: Initialize service
      MetricsService.initialize(mockContext, mockReporter);
      
      // Simulate onBackground behavior
      await MetricsService.getInstance().flush();
      
      // Verify flush was called
      expect(flushCallCount).assertEqual(1);
    });
    
    it('should flush metrics in onDestroy', async () => {
      // Setup: Initialize service
      MetricsService.initialize(mockContext, mockReporter);
      
      // Simulate onDestroy behavior
      await MetricsService.getInstance().flush();
      
      // Verify flush was called
      expect(flushCallCount).assertEqual(1);
    });
    
    it('should handle multiple flush calls safely', async () => {
      // Setup: Initialize service
      MetricsService.initialize(mockContext, mockReporter);
      
      // Simulate multiple lifecycle transitions
      await MetricsService.getInstance().flush(); // onBackground
      await MetricsService.getInstance().flush(); // onDestroy
      
      // Verify flush was called twice
      expect(flushCallCount).assertEqual(2);
    });
    
    it('should throw error when getInstance called before initialize', () => {
      // Verify fail-fast behavior for developer error
      expect(() => {
        MetricsService.getInstance();
      }).assertThrow();
    });
  });
}
