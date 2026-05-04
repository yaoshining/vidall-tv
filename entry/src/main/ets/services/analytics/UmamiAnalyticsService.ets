import { hilog } from '@kit.PerformanceAnalysisKit';
import { UmamiReporter, UmamiEventData } from './UmamiReporter';

const TAG = 'UmamiAnalyticsService';
const DOMAIN = 0x0001;

export class UmamiAnalyticsService {
  private static instance: UmamiAnalyticsService | null = null;
  private reporter: UmamiReporter | null = null;

  private constructor() {}

  static initialize(reporter: UmamiReporter): void {
    if (UmamiAnalyticsService.instance) {
      hilog.warn(DOMAIN, TAG, 'UmamiAnalyticsService already initialized, skipping');
      return;
    }
    const svc = new UmamiAnalyticsService();
    svc.reporter = reporter;
    UmamiAnalyticsService.instance = svc;
    hilog.info(DOMAIN, TAG, 'UmamiAnalyticsService initialized');
  }

  static getInstance(): UmamiAnalyticsService {
    if (!UmamiAnalyticsService.instance) {
      throw new Error('UmamiAnalyticsService not initialized. Call initialize() first.');
    }
    return UmamiAnalyticsService.instance;
  }

  static isInitialized(): boolean {
    return UmamiAnalyticsService.instance !== null;
  }

  trackPageView(path: string): void {
    if (this.reporter === null) {
      return;
    }
    this.reporter.trackPageView(path);
  }

  trackEvent(feature: string, name: string, data: UmamiEventData): void {
    if (this.reporter === null) {
      return;
    }
    this.reporter.trackCustomEvent(feature, name, data);
  }

  static resetForTesting(): void {
    UmamiAnalyticsService.instance = null;
  }
}
