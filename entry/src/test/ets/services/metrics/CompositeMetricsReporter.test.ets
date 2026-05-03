import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { Context } from '@ohos.abilityAccessCtrl';
import { CompositeMetricsReporter } from '../../../../main/ets/services/metrics/CompositeMetricsReporter';
import { MetricsReporter } from '../../../../main/ets/services/metrics/MetricsReporter';
import { MetricsService } from '../../../../main/ets/services/metrics/MetricsService';

class RecordingReporter implements MetricsReporter {
  playbackCalls: number = 0;
  subtitleCalls: number = 0;
  scanCalls: number = 0;
  flushCalls: number = 0;

  recordPlaybackAttempt(): void {
    this.playbackCalls++;
  }

  recordSubtitleUsage(): void {
    this.subtitleCalls++;
  }

  recordScanCoverage(): void {
    this.scanCalls++;
  }

  async flush(): Promise<void> {
    this.flushCalls++;
  }
}

export default function compositeMetricsReporterTest() {
  describe('CompositeMetricsReporter', () => {
    it('should delegate playback, subtitle, scan and flush to both reporters', 0, async () => {
      const first = new RecordingReporter();
      const second = new RecordingReporter();
      const reporter = new CompositeMetricsReporter([first, second]);

      reporter.recordPlaybackAttempt(true, 450);
      reporter.recordSubtitleUsage('zh');
      reporter.recordScanCoverage(4, 5);
      await reporter.flush();

      expect(first.playbackCalls).assertEqual(1);
      expect(second.playbackCalls).assertEqual(1);
      expect(first.subtitleCalls).assertEqual(1);
      expect(second.subtitleCalls).assertEqual(1);
      expect(first.scanCalls).assertEqual(1);
      expect(second.scanCalls).assertEqual(1);
      expect(first.flushCalls).assertEqual(1);
      expect(second.flushCalls).assertEqual(1);
    });
  });

  describe('MetricsService_default_dual_write', () => {
    beforeEach(() => {
      MetricsService.resetForTesting();
    });

    it('should initialize default reporter as composite reporter', 0, () => {
      MetricsService.initialize({} as Context);
      const reporter = MetricsService.getInstance().getReporter();

      expect(reporter instanceof CompositeMetricsReporter).assertTrue();
    });
  });
}
