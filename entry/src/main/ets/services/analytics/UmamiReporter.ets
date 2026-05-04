import http from '@ohos.net.http';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { i18n } from '@kit.LocalizationKit';
import { AppPreferences } from '../../utils/AppPreferences';
import { MediaIdentity, MetricsReporter } from '../metrics/MetricsReporter';
import { getMetricsTraceLogger } from '../metrics/MetricsTraceLogger';

const TAG = 'UmamiReporter';
const DOMAIN = 0x0001;
const SCREEN_RESOLUTION = '3840x2160';

export interface UmamiConfig {
  baseUrl: string;
  websiteId: string;
  hostname: string;
}

export const DEFAULT_UMAMI_CONFIG: UmamiConfig = {
  baseUrl: 'https://analytics.yaoshining.space',
  websiteId: 'a212474c-ad81-4e9e-80a0-39d735941f44',
  hostname: 'vidall-tv.yaoshining.com'
};

export interface UmamiEventData {
  success?: boolean;
  first_frame_ms?: number;
  source_type?: string | null;
  local_id?: number | null;
  provider?: string | null;
  provider_id?: string | null;
  title?: string | null;
  year?: number | null;
  file_name?: string | null;
  language?: string | null;
  has_subtitle?: boolean;
  scanned?: number;
  total?: number;
  coverage_pct?: number;
  screen?: string;
  total_files?: number;
  duration_ms?: number;
  error_code?: number;
  backend?: string;
  os_version?: string;
  app_version?: string;
  setting_key?: string;
  new_value?: string | number | boolean;
}

export interface UmamiEventRequestPayload {
  website: string;
  hostname: string;
  url: string;
  name: string;
  data: UmamiEventData;
}

export interface UmamiIdentifyRequestPayload {
  website: string;
  hostname: string;
  url: string;
  name: string;
  value: string;
}

export interface UmamiPageViewRequestPayload {
  website: string;
  hostname: string;
  url: string;
  referrer: string;
  title: string;
  language: string;
  screen: string;
}

// Umami v2 新版已移除 type:"pageview"，pageview 通过 type:"event" + 无 name 字段实现
export interface UmamiPageViewRequest {
  type: 'event';
  payload: UmamiPageViewRequestPayload;
}

export interface UmamiEventRequest {
  type: 'event';
  payload: UmamiEventRequestPayload;
}

export interface UmamiIdentifyRequest {
  type: 'identify';
  payload: UmamiIdentifyRequestPayload;
}

export type UmamiSendRequest = UmamiPageViewRequest | UmamiEventRequest | UmamiIdentifyRequest;

export interface UmamiHttpResponse {
  responseCode: number;
  result: string | Object;
}

export interface UmamiHttpRequest {
  request(url: string, options: http.HttpRequestOptions): Promise<UmamiHttpResponse>;
  destroy(): void;
}

export type UmamiHttpRequestFactory = () => UmamiHttpRequest;

function createDefaultUmamiHttpRequest(): UmamiHttpRequest {
  return http.createHttp() as UmamiHttpRequest;
}

function buildUmamiUrl(config: UmamiConfig, feature: string, eventName: string): string {
  return `app://${config.hostname}/${feature}/${eventName}`;
}

function buildBaseFields(): UmamiEventData {
  let lang = 'zh-CN';
  try {
    lang = i18n.System.getSystemLanguage();
  } catch (e) {
    // fallback to zh-CN
  }
  const base: UmamiEventData = {
    screen: SCREEN_RESOLUTION,
    language: lang
  };
  return base;
}

export function buildUmamiEventPayload(
  config: UmamiConfig,
  feature: string,
  eventName: string,
  data: UmamiEventData
): UmamiEventRequest {
  const payload: UmamiEventRequest = {
    type: 'event',
    payload: {
      website: config.websiteId,
      hostname: config.hostname,
      url: buildUmamiUrl(config, feature, eventName),
      name: eventName,
      data
    }
  };
  return payload;
}

export function buildUmamiIdentifyPayload(
  config: UmamiConfig,
  deviceUuid: string
): UmamiIdentifyRequest {
  const payload: UmamiIdentifyRequest = {
    type: 'identify',
    payload: {
      website: config.websiteId,
      hostname: config.hostname,
      url: buildUmamiUrl(config, 'system', 'identify'),
      name: 'device_uuid',
      value: deviceUuid
    }
  };
  return payload;
}

function buildPlaybackAttemptData(
  success: boolean,
  firstFrameMs: number,
  media?: MediaIdentity,
  sourceType?: string
): UmamiEventData {
  const base = buildBaseFields();
  const data: UmamiEventData = {
    success,
    first_frame_ms: firstFrameMs,
    source_type: sourceType ?? null,
    local_id: media?.local_id ?? null,
    provider: media?.provider ?? null,
    provider_id: media?.provider_id ?? null,
    title: media?.title ?? null,
    year: media?.year ?? null,
    file_name: media?.file_name ?? null,
    screen: base.screen,
    language: base.language
  };
  return data;
}

function buildSubtitleUsageData(language: string | null): UmamiEventData {
  const base = buildBaseFields();
  const data: UmamiEventData = {
    language,
    has_subtitle: language !== null,
    screen: base.screen
  };
  return data;
}

function buildScanCoverageData(scanned: number, total: number): UmamiEventData {
  const coverage = total > 0 ? Math.round((scanned / total) * 10000) / 100 : 0;
  const base = buildBaseFields();
  const data: UmamiEventData = {
    scanned,
    total,
    coverage_pct: coverage,
    screen: base.screen,
    language: base.language
  };
  return data;
}

export class UmamiReporter implements MetricsReporter {
  private readonly config: UmamiConfig;
  private readonly requestFactory: UmamiHttpRequestFactory;
  private readonly pendingQueue: UmamiSendRequest[] = [];
  private isSending: boolean = false;
  private activeDrainPromise: Promise<void> | null = null;
  private identifyQueuePromise: Promise<void> | null = null;
  private identifyQueued: boolean = false;
  private identifySent: boolean = false;

  constructor(
    config: UmamiConfig = DEFAULT_UMAMI_CONFIG,
    requestFactory: UmamiHttpRequestFactory = createDefaultUmamiHttpRequest
  ) {
    this.config = config;
    this.requestFactory = requestFactory;
  }

  getReporterName(): string {
    return 'UmamiReporter';
  }

  recordPlaybackAttempt(success: boolean, firstFrameMs: number, media?: MediaIdentity, sourceType?: string): void {
    getMetricsTraceLogger().info(TAG,
      `Umami record playback_attempt success=${success ? 1 : 0} queue=${this.pendingQueue.length}`);
    const payload = buildUmamiEventPayload(
      this.config,
      'player',
      'playback_attempt',
      buildPlaybackAttemptData(success, firstFrameMs, media, sourceType)
    );
    this.enqueue(payload);
  }

  recordSubtitleUsage(language: string | null): void {
    getMetricsTraceLogger().info(TAG,
      `Umami record subtitle_usage subtitle=${language === null ? 'off' : 'on'} queue=${this.pendingQueue.length}`);
    const payload = buildUmamiEventPayload(
      this.config,
      'player',
      'subtitle_usage',
      buildSubtitleUsageData(language)
    );
    this.enqueue(payload);
  }

  recordScanCoverage(scanned: number, total: number): void {
    getMetricsTraceLogger().info(TAG,
      `Umami record scan_coverage scanned=${scanned} total=${total} queue=${this.pendingQueue.length}`);
    const payload = buildUmamiEventPayload(
      this.config,
      'scanner',
      'scan_coverage',
      buildScanCoverageData(scanned, total)
    );
    this.enqueue(payload);
  }

  trackPageView(path: string): void {
    getMetricsTraceLogger().info(TAG, `Umami trackPageView path=${path} queue=${this.pendingQueue.length}`);
    let lang = 'zh-CN';
    try {
      lang = i18n.System.getSystemLanguage();
    } catch (e) {
      // fallback to zh-CN
    }
    const payload: UmamiPageViewRequest = {
      type: 'event',
      payload: {
        website: this.config.websiteId,
        hostname: this.config.hostname,
        url: path,
        referrer: '',
        title: '',
        language: lang,
        screen: SCREEN_RESOLUTION
      }
    };
    this.enqueue(payload);
  }

  trackCustomEvent(feature: string, name: string, data: UmamiEventData): void {
    getMetricsTraceLogger().info(TAG,
      `Umami trackCustomEvent feature=${feature} name=${name} queue=${this.pendingQueue.length}`);
    const payload = buildUmamiEventPayload(this.config, feature, name, data);
    this.enqueue(payload);
  }

  async flush(): Promise<void> {
    getMetricsTraceLogger().info(TAG, `Umami flush entered: queue=${this.pendingQueue.length} sending=${this.isSending}`);
    if (this.pendingQueue.length > 0) {
      await this.ensureIdentifyQueued();
    }
    if (this.activeDrainPromise !== null) {
      getMetricsTraceLogger().info(TAG, 'Umami flush waiting for in-flight send');
    }
    await this.processQueue();
  }

  private enqueue(payload: UmamiSendRequest): void {
    this.pendingQueue.push(payload);
    getMetricsTraceLogger().info(TAG,
      `Umami enqueue: type=${payload.type} queue=${this.pendingQueue.length}`);
    void this.kickoffProcessing();
  }

  private async kickoffProcessing(): Promise<void> {
    await this.ensureIdentifyQueued();
    await this.processQueue();
  }

  private async ensureIdentifyQueued(): Promise<void> {
    if (this.identifySent || this.identifyQueued) {
      return;
    }
    if (this.identifyQueuePromise !== null) {
      return this.identifyQueuePromise;
    }
    const queuePromise = this.queueIdentifyPayload();
    this.identifyQueuePromise = queuePromise;
    return queuePromise;
  }

  private async queueIdentifyPayload(): Promise<void> {
    try {
      if (this.identifySent || this.identifyQueued) {
        return;
      }
      const deviceUuid = await AppPreferences.getOrCreateDeviceUuid();
      if (this.identifySent || this.identifyQueued || deviceUuid.length === 0) {
        return;
      }
      this.pendingQueue.unshift(buildUmamiIdentifyPayload(this.config, deviceUuid));
      this.identifyQueued = true;
      getMetricsTraceLogger().info(TAG, `Umami identify queued: queue=${this.pendingQueue.length}`);
    } finally {
      this.identifyQueuePromise = null;
    }
  }

  private async processQueue(): Promise<void> {
    if (this.activeDrainPromise !== null) {
      return this.activeDrainPromise;
    }
    const drainPromise = this.drainQueue();
    this.activeDrainPromise = drainPromise;
    return drainPromise;
  }

  private async drainQueue(): Promise<void> {
    this.isSending = true;
    let sendFailed = false;
    try {
      while (this.pendingQueue.length > 0) {
        const payload = this.pendingQueue[0];
        const sent = await this.sendPayload(payload);
        if (!sent) {
          if (payload.type === 'identify') {
            // identify 不被服务器支持时直接丢弃，避免阻塞后续 pageview/event
            this.pendingQueue.shift();
            this.identifyQueued = false;
            // 标记为已处理，防止被重新入队
            this.identifySent = true;
            getMetricsTraceLogger().warn(TAG, 'Umami identify failed, dropping to unblock event queue');
            continue;
          }
          sendFailed = true;
          break;
        }
        this.pendingQueue.shift();
        if (payload.type === 'identify') {
          this.identifySent = true;
          this.identifyQueued = false;
        }
      }
    } finally {
      this.isSending = false;
      this.activeDrainPromise = null;
      if (this.pendingQueue.length > 0 && !sendFailed) {
        void this.processQueue();
      }
    }
  }

  private async sendPayload(payload: UmamiSendRequest): Promise<boolean> {
    const request = this.requestFactory();
    try {
      getMetricsTraceLogger().info(TAG,
        `Umami send start: type=${payload.type} queue=${this.pendingQueue.length}`);
      const response = await request.request(`${this.config.baseUrl}/api/send`, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'User-Agent': 'Mozilla/5.0 (HarmonyOS; TV) VidAll/1.0'
        },
        extraData: JSON.stringify(payload),
        connectTimeout: 15000,
        readTimeout: 15000
      });
      const ok = response.responseCode >= 200 && response.responseCode < 300;
      if (ok) {
        getMetricsTraceLogger().info(TAG, `Umami send success: type=${payload.type}`);
      }
      if (!ok) {
        getMetricsTraceLogger().warn(TAG, `Umami send failed: type=${payload.type} code=${response.responseCode}`);
      }
      return ok;
    } catch (e) {
      const err = e as BusinessError;
      getMetricsTraceLogger().warn(TAG, `Umami send failed: type=${payload.type} message=${err.message ?? String(e)}`);
      return false;
    } finally {
      request.destroy();
    }
  }
}
