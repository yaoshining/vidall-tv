import { MediaIdentity, MetricsReporter } from './MetricsReporter';

export class CompositeMetricsReporter implements MetricsReporter {
  private readonly reporters: MetricsReporter[];

  constructor(reporters: MetricsReporter[]) {
    this.reporters = reporters;
  }

  recordPlaybackAttempt(success: boolean, firstFrameMs: number, media?: MediaIdentity, sourceType?: string): void {
    for (let i = 0; i < this.reporters.length; i++) {
      this.reporters[i].recordPlaybackAttempt(success, firstFrameMs, media, sourceType);
    }
  }

  recordSubtitleUsage(language: string | null): void {
    for (let i = 0; i < this.reporters.length; i++) {
      this.reporters[i].recordSubtitleUsage(language);
    }
  }

  recordScanCoverage(scanned: number, total: number): void {
    for (let i = 0; i < this.reporters.length; i++) {
      this.reporters[i].recordScanCoverage(scanned, total);
    }
  }

  async flush(): Promise<void> {
    for (let i = 0; i < this.reporters.length; i++) {
      await this.reporters[i].flush();
    }
  }
}
