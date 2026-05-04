import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { Context } from '@ohos.abilityAccessCtrl';
import { CompositeMetricsReporter } from '../../../../main/ets/services/metrics/CompositeMetricsReporter';
import { MetricsReporter } from '../../../../main/ets/services/metrics/MetricsReporter';
import { MetricsService } from '../../../../main/ets/services/metrics/MetricsService';
import { MetricsTraceLogger, setMetricsTraceLoggerForTesting } from '../../../../main/ets/services/metrics/MetricsTraceLogger';

class CapturingMetricsTraceLogger implements MetricsTraceLogger {
  readonly entries: string[] = [];

  info(tag: string, message: string): void {
    this.entries.push(`${tag}:${message}`);
  }

  warn(tag: string, message: string): void {
    this.entries.push(`${tag}:${message}`);
  }

  error(tag: string, message: string): void {
    this.entries.push(`${tag}:${message}`);
  }

  contains(keyword: string): boolean {
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].indexOf(keyword) >= 0) {
        return true;
      }
    }
    return false;
  }
}

class RecordingReporter implements MetricsReporter {
  private readonly reporterName: string;
  playbackCalls: number = 0;
  subtitleCalls: number = 0;
  scanCalls: number = 0;
  flushCalls: number = 0;

  constructor(reporterName: string = 'RecordingReporter') {
    this.reporterName = reporterName;
  }

  getReporterName(): string {
    return this.reporterName;
  }

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
      const first = new RecordingReporter('LocalFileReporter');
      const second = new RecordingReporter('UmamiReporter');
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

    it('should emit forwarding traces for both child reporters', 0, async () => {
      const logger = new CapturingMetricsTraceLogger();
      setMetricsTraceLoggerForTesting(logger);
      const first = new RecordingReporter('LocalFileReporter');
      const second = new RecordingReporter('UmamiReporter');
      const reporter = new CompositeMetricsReporter([first, second]);

      reporter.recordPlaybackAttempt(true, 450);
      reporter.recordSubtitleUsage('zh');
      await reporter.flush();

      expect(logger.contains('Composite forward event=playback_attempt target=LocalFileReporter')).assertTrue();
      expect(logger.contains('Composite forward event=playback_attempt target=UmamiReporter')).assertTrue();
      expect(logger.contains('Composite forward event=subtitle_usage target=UmamiReporter')).assertTrue();
      expect(logger.contains('Composite forward event=flush target=UmamiReporter')).assertTrue();
      setMetricsTraceLoggerForTesting(null);
    });
  });

  describe('MetricsService_default_dual_write', () => {
    beforeEach(() => {
      MetricsService.resetForTesting();
      setMetricsTraceLoggerForTesting(null);
    });

    it('should initialize default reporter as composite reporter', 0, () => {
      MetricsService.initialize({} as Context);
      const reporter = MetricsService.getInstance().getReporter();

      expect(reporter instanceof CompositeMetricsReporter).assertTrue();
    });

    it('should emit default reporter type trace during initialization', 0, () => {
      const logger = new CapturingMetricsTraceLogger();
      setMetricsTraceLoggerForTesting(logger);

      MetricsService.initialize({} as Context);

      expect(logger.contains('MetricsService initialized reporter=CompositeMetricsReporter')).assertTrue();
      setMetricsTraceLoggerForTesting(null);
    });
  });
}
