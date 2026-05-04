import { MediaIdentity, MetricsReporter } from './MetricsReporter';
import { getMetricsTraceLogger } from './MetricsTraceLogger';

const TAG = 'CompositeMetricsReporter';

export class CompositeMetricsReporter implements MetricsReporter {
  private readonly reporters: MetricsReporter[];

  constructor(reporters: MetricsReporter[]) {
    this.reporters = reporters;
  }

  getReporterName(): string {
    return 'CompositeMetricsReporter';
  }

  recordPlaybackAttempt(success: boolean, firstFrameMs: number, media?: MediaIdentity, sourceType?: string): void {
    for (let i = 0; i < this.reporters.length; i++) {
      getMetricsTraceLogger().info(TAG,
        `Composite forward event=playback_attempt target=${this.describeReporter(this.reporters[i], i)} index=${i + 1}/${this.reporters.length}`);
      this.reporters[i].recordPlaybackAttempt(success, firstFrameMs, media, sourceType);
    }
  }

  recordSubtitleUsage(language: string | null): void {
    for (let i = 0; i < this.reporters.length; i++) {
      getMetricsTraceLogger().info(TAG,
        `Composite forward event=subtitle_usage target=${this.describeReporter(this.reporters[i], i)} index=${i + 1}/${this.reporters.length}`);
      this.reporters[i].recordSubtitleUsage(language);
    }
  }

  recordScanCoverage(scanned: number, total: number): void {
    for (let i = 0; i < this.reporters.length; i++) {
      getMetricsTraceLogger().info(TAG,
        `Composite forward event=scan_coverage target=${this.describeReporter(this.reporters[i], i)} index=${i + 1}/${this.reporters.length}`);
      this.reporters[i].recordScanCoverage(scanned, total);
    }
  }

  async flush(): Promise<void> {
    for (let i = 0; i < this.reporters.length; i++) {
      getMetricsTraceLogger().info(TAG,
        `Composite forward event=flush target=${this.describeReporter(this.reporters[i], i)} index=${i + 1}/${this.reporters.length}`);
      await this.reporters[i].flush();
    }
  }

  private describeReporter(reporter: MetricsReporter, index: number): string {
    if (reporter.getReporterName !== undefined) {
      return reporter.getReporterName();
    }
    return `reporter_${index + 1}`;
  }
}
