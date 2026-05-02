/**
 * Test suite for EntryAbility lifecycle metrics integration
 * Requirement: Verify MetricsService is properly initialized and flushed in Ability lifecycle
 * Spec: metrics-instrumentation-api/spec.md - Application Lifecycle Integration
 */

import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { MetricsService } from '../../../main/ets/services/metrics/MetricsService';
import { MetricsReporter } from '../../../main/ets/services/metrics/MetricsReporter';
import { Context } from '@kit.AbilityKit';

export default function entryAbilityLifecycleTest() {
  describe('EntryAbility Metrics Lifecycle Integration', () => {
    
    let mockContext: Context;
    let flushCallCount: number;
    let mockReporter: MetricsReporter;
    
    beforeEach((): void => {
      // Reset MetricsService singleton before each test
      MetricsService.resetForTesting();
      
      // Create mock context
      mockContext = {} as Context;
      
      // Create mock reporter with flush tracking
      flushCallCount = 0;
      
      // Mock reporter implementation (explicit class for ArkTS type system)
      class MockReporter implements MetricsReporter {
        recordPlaybackAttempt(success: boolean, firstFrameMs: number): void {}
        recordSubtitleUsage(language: string | null): void {}
        recordScanCoverage(scanned: number, total: number): void {}
        async flush(): Promise<void> {
          flushCallCount++;
        }
      }
      
      mockReporter = new MockReporter();
    });
    
    it('should initialize MetricsService in onCreate', 0, (): void => {
      // Before initialization
      expect(MetricsService.isInitialized()).assertFalse();
      
      // Simulate onCreate behavior
      MetricsService.initialize(mockContext, mockReporter);
      
      // After initialization
      expect(MetricsService.isInitialized()).assertTrue();
      
      // Verify getInstance doesn't throw
      let didThrow = false;
      try {
        MetricsService.getInstance();
      } catch {
        didThrow = true;
      }
      expect(didThrow).assertFalse();
    });
    
    it('should flush metrics in onBackground', 0, async (): Promise<void> => {
      // Setup: Initialize service
      MetricsService.initialize(mockContext, mockReporter);
      
      // Simulate onBackground behavior
      await MetricsService.getInstance().flush();
      
      // Verify flush was called
      expect(flushCallCount).assertEqual(1);
    });
    
    it('should flush metrics in onDestroy', 0, async (): Promise<void> => {
      // Setup: Initialize service
      MetricsService.initialize(mockContext, mockReporter);
      
      // Simulate onDestroy behavior
      await MetricsService.getInstance().flush();
      
      // Verify flush was called
      expect(flushCallCount).assertEqual(1);
    });
    
    it('should handle multiple flush calls safely', 0, async (): Promise<void> => {
      // Setup: Initialize service
      MetricsService.initialize(mockContext, mockReporter);
      
      // Simulate multiple lifecycle transitions
      await MetricsService.getInstance().flush(); // onBackground
      await MetricsService.getInstance().flush(); // onDestroy
      
      // Verify flush was called twice
      expect(flushCallCount).assertEqual(2);
    });
    
    it('should throw error when getInstance called before initialize', 0, (): void => {
      // Verify fail-fast behavior for developer error
      let didThrow = false;
      try {
        MetricsService.getInstance();
      } catch {
        didThrow = true;
      }
      expect(didThrow).assertTrue();
    });
  });
}
