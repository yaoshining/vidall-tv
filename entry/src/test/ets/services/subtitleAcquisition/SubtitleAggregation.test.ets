/**
 * Test suite for SubHub subtitle aggregation
 * Specs: subtitle-acquisition-service, subhub-subtitle-provider
 */

import { describe, it, expect, beforeEach, afterEach } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@ohos.abilityAccessCtrl';
import {
  AppPreferences,
  AppPreferencesLoader,
  AppPreferencesStore,
  PrefKey
} from '../../../../main/ets/utils/AppPreferences';
import {
  classifyAcquisitionError,
  SubtitleSearchResult,
  SubtitleSearchInput,
  SubtitleDownloadOutcome
} from '../../../../main/ets/services/subtitleAcquisition/SubtitleAcquisitionTypes';
import { SubtitleProvider, SubtitleDownloadContext } from '../../../../main/ets/services/subtitleAcquisition/providers/SubtitleProvider';
import { SubtitleProviderResolver } from '../../../../main/ets/services/subtitleAcquisition/providers/SubtitleProviderResolver';
import { SubHubSubtitleProvider } from '../../../../main/ets/services/subtitleAcquisition/providers/SubHubSubtitleProvider';
import {
  SubHubClient,
  SubHubHttpExecutor,
  SubHubHttpResponse,
  SubHubApiError,
  SubHubNetworkError
} from '../../../../main/ets/lib/SubHubClient';
import {
  ProxyQuotaExceededError,
  ProxyUnavailableError,
  InvalidApiKeyError,
  SubtitleDownloadError
} from '../../../../main/ets/lib/OpenSubtitlesClient';
import { aggregateSubtitleSearch } from '../../../../main/ets/services/subtitleAcquisition/SubtitleAcquisitionService';

// SubHub 搜索响应的 mock JSON 结构（显式声明类型，满足 ArkTS 严格模式对无类型对象字面量的限制）
interface MockSubHubRawResult {
  download_count: number;
}

interface MockSubHubSearchResult {
  id: string;
  provider: string;
  language: string | null;
  releaseName: string | null;
  format: string;
  downloadUrl: string;
  score: number | null;
  raw: MockSubHubRawResult | null;
}

interface MockSubHubProviderFailure {
  provider: string;
  reason: string;
  message: string;
}

interface MockSubHubSearchData {
  status: string;
  results: MockSubHubSearchResult[];
  provider_failures: MockSubHubProviderFailure[];
}

interface MockSubHubSearchResponse {
  data: MockSubHubSearchData;
}

class InMemoryStore implements AppPreferencesStore {
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

class FakeProvider implements SubtitleProvider {
  readonly source: 'opensubtitles' | 'subhub';
  private readonly results: SubtitleSearchResult[];
  private readonly error: Error | null;

  constructor(source: 'opensubtitles' | 'subhub', results: SubtitleSearchResult[], error: Error | null) {
    this.source = source;
    this.results = results;
    this.error = error;
  }

  async search(input: SubtitleSearchInput): Promise<SubtitleSearchResult[]> {
    if (this.error !== null) {
      throw this.error;
    }
    return this.results;
  }

  async download(result: SubtitleSearchResult, ctx: SubtitleDownloadContext): Promise<SubtitleDownloadOutcome> {
    const o: SubtitleDownloadOutcome = { localPath: '', fileName: '', languageCode: '' };
    return o;
  }
}

function makeResult(id: string, source: 'opensubtitles' | 'subhub', fileName: string, lang: string): SubtitleSearchResult {
  const r: SubtitleSearchResult = {
    subtitleId: id,
    source: source,
    fileName: fileName,
    languageCode: lang,
    downloadCount: 0
  };
  if (source === 'opensubtitles') {
    r.fileId = 1;
  } else {
    r.subtitleRef = id;
  }
  return r;
}

export default function subtitleAggregationTest() {
  // ── 5.1 SubtitleProviderResolver ──
  describe('SubtitleProviderResolver', () => {
    beforeEach(() => {
      AppPreferences.resetForTesting();
    });

    afterEach(() => {
      AppPreferences.setStoreLoaderForTesting(null);
      AppPreferences.resetForTesting();
    });

    it('returns only SubHub when no OS key', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      const loader: AppPreferencesLoader = async () => store;
      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      const providers = await new SubtitleProviderResolver().resolveProviders();
      expect(providers.length).assertEqual(1);
      expect(providers[0].source).assertEqual('subhub');
    });

    it('returns OpenSubtitles first then SubHub when OS key set', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      store.seed(PrefKey.OPENSUBTITLES_API_KEY, 'test-key');
      const loader: AppPreferencesLoader = async () => store;
      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      const providers = await new SubtitleProviderResolver().resolveProviders();
      expect(providers.length).assertEqual(2);
      expect(providers[0].source).assertEqual('opensubtitles');
      expect(providers[1].source).assertEqual('subhub');
    });
  });

  // ── 5.4 classifyAcquisitionError ──
  describe('classifyAcquisitionError_subhub', () => {
    it('maps CALLER_KEY_INVALID to subhub_auth_invalid', 0, () => {
      expect(classifyAcquisitionError(new SubHubApiError('CALLER_KEY_INVALID', 401, 'bad'))).assertEqual('subhub_auth_invalid');
    });

    it('maps PROVIDER_CREDENTIAL_EXHAUSTED to subhub_quota_exhausted', 0, () => {
      expect(classifyAcquisitionError(new SubHubApiError('PROVIDER_CREDENTIAL_EXHAUSTED', 503, 'x'))).assertEqual('subhub_quota_exhausted');
    });

    it('maps SUBTITLE_NOT_FOUND to subhub_not_found', 0, () => {
      expect(classifyAcquisitionError(new SubHubApiError('SUBTITLE_NOT_FOUND', 404, 'x'))).assertEqual('subhub_not_found');
    });

    it('maps TIMEOUT to subhub_unavailable', 0, () => {
      expect(classifyAcquisitionError(new SubHubApiError('TIMEOUT', 503, 'x'))).assertEqual('subhub_unavailable');
    });

    it('maps SubHubNetworkError to subhub_unavailable', 0, () => {
      expect(classifyAcquisitionError(new SubHubNetworkError('network'))).assertEqual('subhub_unavailable');
    });

    it('keeps existing OS error mappings', 0, () => {
      expect(classifyAcquisitionError(new ProxyQuotaExceededError('q'))).assertEqual('proxy_quota_exceeded');
      expect(classifyAcquisitionError(new ProxyUnavailableError('u'))).assertEqual('proxy_unavailable');
      expect(classifyAcquisitionError(new InvalidApiKeyError('k'))).assertEqual('invalid_api_key');
      expect(classifyAcquisitionError(new SubtitleDownloadError('d'))).assertEqual('download_failed');
    });
  });

  // ── 5.3 SubHubSubtitleProvider search 字段映射 ──
  describe('SubHubSubtitleProvider_search_mapping', () => {
    it('maps SubHub results to unified results with source=subhub', 0, async () => {
      let capturedUrl = '';
      const executor: SubHubHttpExecutor = async (
        url: string, method: string, headers: Record<string, string>, expectArrayBuffer: boolean
      ): Promise<SubHubHttpResponse> => {
        capturedUrl = url;
        const response: MockSubHubSearchResponse = {
          data: {
            status: 'success',
            results: [{
              id: 'opensubtitles:p:123',
              provider: 'opensubtitles',
              language: 'zh-CN',
              releaseName: 'Inception',
              format: 'srt',
              downloadUrl: '/api/subtitles/download?subtitleId=x',
              score: null,
              raw: { download_count: 42 }
            }],
            provider_failures: []
          }
        };
        const body = JSON.stringify(response);
        return { responseCode: 200, result: body, headers: {} };
      };
      const client = new SubHubClient(undefined, 'test-caller-key', executor);
      const provider = new SubHubSubtitleProvider(client);
      const results = await provider.search({ query: 'Inception', languages: 'zh-CN,en' });

      expect(results.length).assertEqual(1);
      expect(results[0].source).assertEqual('subhub');
      expect(results[0].subtitleId).assertEqual('opensubtitles:p:123');
      expect(results[0].subtitleRef).assertEqual('opensubtitles:p:123');
      expect(results[0].fileName).assertEqual('Inception');
      expect(results[0].languageCode).assertEqual('zh-CN');
      expect(results[0].downloadCount).assertEqual(42);
      // 只传首个语言码给 SubHub
      expect(capturedUrl.indexOf('language=zh-CN') >= 0).assertTrue();
    });

    it('passes Chinese displayTitle as query for xunlei matching', 0, async () => {
      let capturedUrl = '';
      const executor: SubHubHttpExecutor = async (
        url: string, method: string, headers: Record<string, string>, expectArrayBuffer: boolean
      ): Promise<SubHubHttpResponse> => {
        capturedUrl = url;
        const response: MockSubHubSearchResponse = {
          data: { status: 'success', results: [], provider_failures: [] }
        };
        const body = JSON.stringify(response);
        return { responseCode: 200, result: body, headers: {} };
      };
      const client = new SubHubClient(undefined, 'test-caller-key', executor);
      const provider = new SubHubSubtitleProvider(client);
      await provider.search({
        query: 'Climax',
        displayTitle: '权欲之巅',
        languages: 'zh-CN'
      });

      // 英文原名走 title 给 opensubtitles，中文显示名走 query 给 xunlei
      expect(capturedUrl.indexOf('title=Climax') >= 0).assertTrue();
      expect(capturedUrl.indexOf('query=%E6%9D%83%E6%AC%B2%E4%B9%8B%E5%B7%85') >= 0).assertTrue();
    });
  });

  // ── 5.4.1 SubHubClient 空 Caller Key 拒绝 ──
  describe('SubHubClient_empty_caller_key', () => {
    it('throws AUTHENTICATION_REQUIRED when caller key is empty on search', 0, async () => {
      let executorCalled = false;
      const executor: SubHubHttpExecutor = async (
        url: string, method: string, headers: Record<string, string>, expectArrayBuffer: boolean
      ): Promise<SubHubHttpResponse> => {
        executorCalled = true;
        return { responseCode: 200, result: '{}', headers: {} };
      };
      const client = new SubHubClient(undefined, '', executor);
      let caughtCode = '';
      let caughtStatus = -1;
      try {
        await client.search({ title: 'Inception' });
      } catch (e) {
        caughtCode = (e as SubHubApiError).code;
        caughtStatus = (e as SubHubApiError).statusCode;
      }
      expect(caughtCode).assertEqual('AUTHENTICATION_REQUIRED');
      expect(caughtStatus).assertEqual(0);
      // 空 key 时不得发起请求（不得静默省略 Authorization 头）
      expect(executorCalled).assertFalse();
    });

    it('throws AUTHENTICATION_REQUIRED when caller key is empty on download', 0, async () => {
      const client = new SubHubClient(undefined, '');
      let caughtCode = '';
      try {
        await client.download('opensubtitles:p:123', 'subtitle.srt');
      } catch (e) {
        caughtCode = (e as SubHubApiError).code;
      }
      expect(caughtCode).assertEqual('AUTHENTICATION_REQUIRED');
    });

    it('classifies empty-key AUTHENTICATION_REQUIRED as subhub_auth_invalid', 0, () => {
      expect(classifyAcquisitionError(new SubHubApiError('AUTHENTICATION_REQUIRED', 0, '未配置')))
        .assertEqual('subhub_auth_invalid');
    });
  });

  // ── 5.5 aggregateSubtitleSearch ──
  describe('aggregateSubtitleSearch', () => {
    it('keeps OpenSubtitles first, SubHub after', 0, async () => {
      const os = new FakeProvider('opensubtitles', [makeResult('os1', 'opensubtitles', 'MovieA.srt', 'zh-CN')], null);
      const sh = new FakeProvider('subhub', [makeResult('sh1', 'subhub', 'MovieB', 'zh-CN')], null);
      const results = await aggregateSubtitleSearch([os, sh], { query: 'Movie', languages: 'zh-CN' });
      expect(results.length).assertEqual(2);
      expect(results[0].subtitleId).assertEqual('os1');
      expect(results[1].subtitleId).assertEqual('sh1');
    });

    it('does not fail when one provider fails', 0, async () => {
      const os = new FakeProvider('opensubtitles', [], new Error('os fail'));
      const sh = new FakeProvider('subhub', [makeResult('sh1', 'subhub', 'MovieB', 'zh-CN')], null);
      const results = await aggregateSubtitleSearch([os, sh], { query: 'Movie', languages: 'zh-CN' });
      expect(results.length).assertEqual(1);
      expect(results[0].subtitleId).assertEqual('sh1');
    });

    it('throws when all providers fail', 0, async () => {
      const os = new FakeProvider('opensubtitles', [], new Error('os fail'));
      const sh = new FakeProvider('subhub', [], new Error('sh fail'));
      let threw = false;
      try {
        await aggregateSubtitleSearch([os, sh], { query: 'Movie', languages: 'zh-CN' });
      } catch {
        threw = true;
      }
      expect(threw).assertTrue();
    });
  });
}
