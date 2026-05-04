import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0001;

export interface MetricsTraceLogger {
  info(tag: string, message: string): void;
  warn(tag: string, message: string): void;
  error(tag: string, message: string): void;
}

class HilogMetricsTraceLogger implements MetricsTraceLogger {
  info(tag: string, message: string): void {
    hilog.info(DOMAIN, tag, '%{public}s', message);
  }

  warn(tag: string, message: string): void {
    hilog.warn(DOMAIN, tag, '%{public}s', message);
  }

  error(tag: string, message: string): void {
    hilog.error(DOMAIN, tag, '%{public}s', message);
  }
}

const DEFAULT_METRICS_TRACE_LOGGER: MetricsTraceLogger = new HilogMetricsTraceLogger();
let activeMetricsTraceLogger: MetricsTraceLogger = DEFAULT_METRICS_TRACE_LOGGER;

export function getMetricsTraceLogger(): MetricsTraceLogger {
  return activeMetricsTraceLogger;
}

export function setMetricsTraceLoggerForTesting(logger: MetricsTraceLogger | null): void {
  activeMetricsTraceLogger = logger ?? DEFAULT_METRICS_TRACE_LOGGER;
}
