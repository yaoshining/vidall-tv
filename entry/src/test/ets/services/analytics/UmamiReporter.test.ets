import http from '@ohos.net.http';
import { describe, it, expect, beforeEach, afterEach } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@ohos.abilityAccessCtrl';
import { AppPreferences, AppPreferencesLoader, AppPreferencesStore, PrefKey } from '../../../../main/ets/utils/AppPreferences';
import { MediaIdentity } from '../../../../main/ets/services/metrics/MetricsReporter';
import { MetricsTraceLogger, setMetricsTraceLoggerForTesting } from '../../../../main/ets/services/metrics/MetricsTraceLogger';
import {
  DEFAULT_UMAMI_CONFIG,
  buildUmamiEventPayload,
  UmamiHttpRequest,
  UmamiHttpResponse,
  UmamiReporter
} from '../../../../main/ets/services/analytics/UmamiReporter';

class InMemoryAppPreferencesStore implements AppPreferencesStore {
  private readonly values: Map<string, string | number> = new Map<string, string | number>();

  seed(key: string, value: string | number): void {
    this.values.set(key, value);
  }

  async get(key: string, defaultValue: string | number): Promise<string | number> {
    const value = this.values.get(key);
    return value === undefined ? defaultValue : value;
  }

  async put(key: string, value: string | number): Promise<void> {
    this.values.set(key, value);
  }

  async flush(): Promise<void> {
  }
}

interface MockResponse {
  responseCode: number;
  result: string;
}

class DeferredHttpResponse {
  private resolveResponse: ((response: UmamiHttpResponse) => void) | null = null;
  readonly promise: Promise<UmamiHttpResponse> = new Promise<UmamiHttpResponse>((resolve) => {
    this.resolveResponse = resolve;
  });

  succeed(): void {
    if (this.resolveResponse !== null) {
      const resolve = this.resolveResponse;
      this.resolveResponse = null;
      resolve({
        responseCode: 200,
        result: '{"beep":"boop"}'
      });
    }
  }
}

class RequestCountWaiter {
  readonly expectedCount: number;
  private resolveWaiter: (() => void) | null;

  constructor(expectedCount: number, resolveWaiter: () => void) {
    this.expectedCount = expectedCount;
    this.resolveWaiter = resolveWaiter;
  }

  tryResolve(currentCount: number): boolean {
    if (currentCount < this.expectedCount || this.resolveWaiter === null) {
      return false;
    }
    const resolve = this.resolveWaiter;
    this.resolveWaiter = null;
    resolve();
    return true;
  }
}

class MockRequestState {
  readonly urls: string[] = [];
  readonly bodies: string[] = [];
  readonly responses: MockResponse[];
  private readonly deferredResponses: DeferredHttpResponse[] = [];
  private readonly countWaiters: RequestCountWaiter[] = [];

  constructor(responses: MockResponse[]) {
    this.responses = responses;
  }

  createDeferredResponse(): DeferredHttpResponse {
    const deferredResponse = new DeferredHttpResponse();
    this.deferredResponses.push(deferredResponse);
    return deferredResponse;
  }

  async waitForRequestCount(expectedCount: number): Promise<void> {
    if (this.bodies.length >= expectedCount) {
      return;
    }
    return new Promise<void>((resolve) => {
      this.countWaiters.push(new RequestCountWaiter(expectedCount, resolve));
    });
  }

  notifyRequestCountChanged(): void {
    const remainingWaiters: RequestCountWaiter[] = [];
    for (let i = 0; i < this.countWaiters.length; i++) {
      const waiter = this.countWaiters[i];
      if (!waiter.tryResolve(this.bodies.length)) {
        remainingWaiters.push(waiter);
      }
    }
    this.countWaiters.length = 0;
    for (let i = 0; i < remainingWaiters.length; i++) {
      this.countWaiters.push(remainingWaiters[i]);
    }
  }

  takeDeferredResponse(): DeferredHttpResponse | null {
    if (this.deferredResponses.length === 0) {
      return null;
    }
    const deferredResponse = this.deferredResponses.shift();
    return deferredResponse === undefined ? null : deferredResponse;
  }
}

class MockUmamiHttpRequest implements UmamiHttpRequest {
  private readonly state: MockRequestState;

  constructor(state: MockRequestState) {
    this.state = state;
  }

  async request(url: string, options: http.HttpRequestOptions): Promise<UmamiHttpResponse> {
    this.state.urls.push(url);
    const body = typeof options.extraData === 'string' ? options.extraData : '';
    this.state.bodies.push(body);
    this.state.notifyRequestCountChanged();

    const deferredResponse = this.state.takeDeferredResponse();
    if (deferredResponse !== null) {
      return deferredResponse.promise;
    }

    if (this.state.responses.length === 0) {
      return {
        responseCode: 200,
        result: '{"beep":"boop"}'
      };
    }

    const nextResponse = this.state.responses.shift();
    if (nextResponse === undefined) {
      return {
        responseCode: 200,
        result: '{"beep":"boop"}'
      };
    }
    return nextResponse;
  }

  destroy(): void {
  }
}

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

function buildMediaIdentity(): MediaIdentity {
  return {
    local_id: 123,
    provider: 'tmdb',
    provider_id: '550',
    title: 'Fight Club',
    year: null,
    file_name: 'Fight Club.mkv'
  };
}

async function initPreferences(deviceUuid?: string): Promise<InMemoryAppPreferencesStore> {
  const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
  const store = new InMemoryAppPreferencesStore();
  if (deviceUuid !== undefined) {
    store.seed(PrefKey.METRICS_DEVICE_UUID, deviceUuid);
  }
  const loader: AppPreferencesLoader = async () => store;
  AppPreferences.setStoreLoaderForTesting(loader);
  await AppPreferences.init(ctx);
  return store;
}

async function flushMicrotasks(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

function countBodiesContaining(bodies: string[], keyword: string): number {
  let count = 0;
  for (let i = 0; i < bodies.length; i++) {
    if (bodies[i].indexOf(keyword) >= 0) {
      count++;
    }
  }
  return count;
}

export default function umamiReporterTest() {
  describe('UmamiReporter_http_behavior', () => {
    beforeEach(() => {
      AppPreferences.resetForTesting();
      setMetricsTraceLoggerForTesting(null);
    });

    afterEach(() => {
      AppPreferences.setStoreLoaderForTesting(null);
      AppPreferences.resetForTesting();
      setMetricsTraceLoggerForTesting(null);
    });

    it('should send identify once and reuse persisted device uuid', 0, async () => {
      await initPreferences('persisted-device-uuid');
      const state = new MockRequestState([]);
      const reporter = new UmamiReporter(
        DEFAULT_UMAMI_CONFIG,
        () => new MockUmamiHttpRequest(state)
      );

      reporter.recordPlaybackAttempt(true, 450, buildMediaIdentity(), 'network');
      await reporter.flush();
      reporter.recordSubtitleUsage('zh');
      await reporter.flush();

      expect(state.urls.length).assertEqual(3);
      expect(state.urls[0]).assertEqual('https://analytics.yaoshining.space/api/send');
      expect(countBodiesContaining(state.bodies, '"type":"identify"')).assertEqual(1);
      expect(state.bodies[0].indexOf('"value":"persisted-device-uuid"') >= 0).assertTrue();
      expect(state.bodies[1].indexOf('"name":"playback_attempt"') >= 0).assertTrue();
      expect(state.bodies[1].indexOf('"source_type":"network"') >= 0).assertTrue();
      expect(state.bodies[2].indexOf('"name":"subtitle_usage"') >= 0).assertTrue();
    });

    it('should generate and persist device uuid before first send when missing', 0, async () => {
      const store = await initPreferences();
      const state = new MockRequestState([]);
      const reporter = new UmamiReporter(
        DEFAULT_UMAMI_CONFIG,
        () => new MockUmamiHttpRequest(state)
      );

      reporter.recordScanCoverage(4, 5);
      await reporter.flush();

      const persisted = await store.get(PrefKey.METRICS_DEVICE_UUID, '');
      const persistedUuid = persisted as string;

      expect(persistedUuid.length > 0).assertTrue();
      expect(state.bodies.length).assertEqual(2);
      expect(state.bodies[0].indexOf(`"value":"${persistedUuid}"`) >= 0).assertTrue();
      expect(state.bodies[1].indexOf('"name":"scan_coverage"') >= 0).assertTrue();
      expect(state.bodies[1].indexOf('"coverage_pct":80') >= 0).assertTrue();
    });

    it('should retain failed payload and retry on next flush', 0, async () => {
      await initPreferences('retry-device-uuid');
      const state = new MockRequestState([
        { responseCode: 200, result: '{"beep":"boop"}' },
        { responseCode: 500, result: '{"error":"temporary"}' },
        { responseCode: 200, result: '{"beep":"boop"}' }
      ]);
      const reporter = new UmamiReporter(
        DEFAULT_UMAMI_CONFIG,
        () => new MockUmamiHttpRequest(state)
      );

      reporter.recordPlaybackAttempt(false, 0, undefined, 'network');
      await reporter.flush();
      await reporter.flush();

      expect(countBodiesContaining(state.bodies, '"type":"identify"')).assertEqual(1);
      expect(countBodiesContaining(state.bodies, '"name":"playback_attempt"')).assertEqual(2);
      expect(state.bodies.length).assertEqual(3);
    });

    it('should wait for in-flight send when flush follows enqueue', 0, async () => {
      await initPreferences('waiting-device-uuid');
      const state = new MockRequestState([]);
      const firstResponse = state.createDeferredResponse();
      const reporter = new UmamiReporter(
        DEFAULT_UMAMI_CONFIG,
        () => new MockUmamiHttpRequest(state)
      );

      reporter.recordPlaybackAttempt(true, 450, buildMediaIdentity(), 'network');
      await state.waitForRequestCount(1);

      let flushResolved = false;
      const flushPromise = reporter.flush().then(() => {
        flushResolved = true;
      });
      await flushMicrotasks();

      expect(flushResolved).assertFalse();

      firstResponse.succeed();
      await flushPromise;

      expect(countBodiesContaining(state.bodies, '"type":"identify"')).assertEqual(1);
      expect(countBodiesContaining(state.bodies, '"name":"playback_attempt"')).assertEqual(1);
      expect(state.bodies.length).assertEqual(2);
    });

    it('should keep queued playback and subtitle events until background flush completes', 0, async () => {
      await initPreferences('background-flush-device-uuid');
      const state = new MockRequestState([]);
      const identifyResponse = state.createDeferredResponse();
      const playbackResponse = state.createDeferredResponse();
      const reporter = new UmamiReporter(
        DEFAULT_UMAMI_CONFIG,
        () => new MockUmamiHttpRequest(state)
      );

      reporter.recordPlaybackAttempt(true, 320, buildMediaIdentity(), 'network');
      await state.waitForRequestCount(1);

      reporter.recordSubtitleUsage('zh-CN');

      let flushResolved = false;
      const flushPromise = reporter.flush().then(() => {
        flushResolved = true;
      });
      await flushMicrotasks();
      expect(flushResolved).assertFalse();

      identifyResponse.succeed();
      await state.waitForRequestCount(2);
      await flushMicrotasks();
      expect(flushResolved).assertFalse();

      playbackResponse.succeed();
      await state.waitForRequestCount(3);
      await flushPromise;

      expect(countBodiesContaining(state.bodies, '"type":"identify"')).assertEqual(1);
      expect(countBodiesContaining(state.bodies, '"name":"playback_attempt"')).assertEqual(1);
      expect(countBodiesContaining(state.bodies, '"name":"subtitle_usage"')).assertEqual(1);
      expect(state.bodies.length).assertEqual(3);
    });

    it('should not issue duplicate requests while flush joins the active send path', 0, async () => {
      await initPreferences('joined-send-device-uuid');
      const state = new MockRequestState([]);
      const identifyResponse = state.createDeferredResponse();
      const reporter = new UmamiReporter(
        DEFAULT_UMAMI_CONFIG,
        () => new MockUmamiHttpRequest(state)
      );

      reporter.recordPlaybackAttempt(true, 180, undefined, 'network');
      await state.waitForRequestCount(1);

      const flushPromise = reporter.flush();
      await flushMicrotasks();
      expect(state.bodies.length).assertEqual(1);

      identifyResponse.succeed();
      await flushPromise;

      expect(countBodiesContaining(state.bodies, '"type":"identify"')).assertEqual(1);
      expect(countBodiesContaining(state.bodies, '"name":"playback_attempt"')).assertEqual(1);
      expect(state.bodies.length).assertEqual(2);
    });

    it('should emit observable traces from record through send success', 0, async () => {
      await initPreferences('observable-device-uuid');
      const logger = new CapturingMetricsTraceLogger();
      setMetricsTraceLoggerForTesting(logger);
      const state = new MockRequestState([]);
      const reporter = new UmamiReporter(
        DEFAULT_UMAMI_CONFIG,
        () => new MockUmamiHttpRequest(state)
      );

      reporter.recordPlaybackAttempt(true, 450, buildMediaIdentity(), 'network');
      reporter.recordSubtitleUsage('zh');
      await reporter.flush();

      expect(logger.contains('Umami record playback_attempt')).assertTrue();
      expect(logger.contains('Umami record subtitle_usage')).assertTrue();
      expect(logger.contains('Umami flush entered')).assertTrue();
      expect(logger.contains('Umami send start')).assertTrue();
      expect(logger.contains('Umami send success')).assertTrue();
    });
  });

  describe('UmamiReporter_config', () => {
    it('should expose default Umami config', 0, () => {
      expect(DEFAULT_UMAMI_CONFIG.baseUrl).assertEqual('https://analytics.yaoshining.space');
      expect(DEFAULT_UMAMI_CONFIG.websiteId).assertEqual('a212474c-ad81-4e9e-80a0-39d735941f44');
      expect(DEFAULT_UMAMI_CONFIG.hostname).assertEqual('vidall-tv');
    });
  });

  describe('UmamiReporter_payload_mapping', () => {
    it('should build playback_attempt event payload', 0, () => {
      const payload = buildUmamiEventPayload(
        DEFAULT_UMAMI_CONFIG,
        'player',
        'playback_attempt',
        {
          success: true,
          first_frame_ms: 450,
          source_type: 'network',
          local_id: 123,
          provider: 'tmdb',
          provider_id: '550',
          title: 'Fight Club',
          year: null,
          file_name: 'Fight Club.mkv'
        }
      );

      expect(payload.type).assertEqual('event');
      expect(payload.payload.website).assertEqual('a212474c-ad81-4e9e-80a0-39d735941f44');
      expect(payload.payload.hostname).assertEqual('vidall-tv');
      expect(payload.payload.url).assertEqual('app://vidall-tv/player/playback_attempt');
      expect(payload.payload.name).assertEqual('playback_attempt');
      expect(payload.payload.data.success as boolean).assertTrue();
      expect(payload.payload.data.first_frame_ms as number).assertEqual(450);
      expect(payload.payload.data.file_name as string).assertEqual('Fight Club.mkv');
    });

    it('should include media identity fields when mapping playback metrics', 0, () => {
      const media = buildMediaIdentity();
      const payload = buildUmamiEventPayload(
        DEFAULT_UMAMI_CONFIG,
        'player',
        'playback_attempt',
        {
          local_id: media.local_id,
          provider: media.provider,
          provider_id: media.provider_id,
          title: media.title,
          year: media.year,
          file_name: media.file_name
        }
      );

      expect(payload.payload.data.local_id as number).assertEqual(123);
      expect(payload.payload.data.provider as string).assertEqual('tmdb');
      expect(payload.payload.data.provider_id as string).assertEqual('550');
      expect(payload.payload.data.title as string).assertEqual('Fight Club');
    });
  });
}
