import { describe, it, expect, beforeEach, afterEach } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@ohos.abilityAccessCtrl';
import {
  AppPreferences,
  AppPreferencesLoader,
  AppPreferencesStore,
  PrefKey
} from '../main/ets/utils/AppPreferences';
import {
  OpenSubtitlesClient,
  OsHttpExecutor,
  OsHttpResponse,
  ProxyQuotaExceededError,
  ProxyUnavailableError,
  InvalidApiKeyError,
  SubtitleSearchResult
} from '../main/ets/lib/OpenSubtitlesClient';

// ─────────────────────────────────────────────
// 内存 Store 辅助
// ─────────────────────────────────────────────

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

// ─────────────────────────────────────────────
// Fake HTTP Executor 工厂
// ─────────────────────────────────────────────

function makeFakeExecutor(statusCode: number, responseBody: string): OsHttpExecutor {
  const executor: OsHttpExecutor = async (
    _url: string,
    _method: string,
    _headers: Record<string, string>,
    _body?: string
  ): Promise<OsHttpResponse> => {
    const result: OsHttpResponse = {
      responseCode: statusCode,
      result: responseBody
    };
    return result;
  };
  return executor;
}

function makeNetworkErrorExecutor(): OsHttpExecutor {
  const executor: OsHttpExecutor = async (
    _url: string,
    _method: string,
    _headers: Record<string, string>,
    _body?: string
  ): Promise<OsHttpResponse> => {
    throw new Error('网络连接失败');
  };
  return executor;
}

/** 构造最小合法搜索响应 JSON */
function buildSearchResponse(count: number): string {
  const items: string[] = [];
  for (let i = 0; i < count; i++) {
    items.push(
      `{"attributes":{"subtitle_id":"id${i}","release":"file${i}.srt","language":"zh-CN","download_count":${i * 10},"files":[{"file_id":${100 + i},"file_name":"file${i}.srt"}]}}`
    );
  }
  return `{"data":[${items.join(',')}]}`;
}

// ─────────────────────────────────────────────
// 测试套件
// ─────────────────────────────────────────────

export default function openSubtitlesClientTest() {
  describe('OpenSubtitlesClient_channel_selection', () => {
    beforeEach(() => {
      AppPreferences.resetForTesting();
    });

    afterEach(() => {
      AppPreferences.setStoreLoaderForTesting(null);
      AppPreferences.resetForTesting();
    });

    it('should use proxy base url when no api key is set', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      // 无 API Key
      const loader: AppPreferencesLoader = async () => store;
      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      const client = new OpenSubtitlesClient();
      const baseUrl = await client.resolveBaseUrl();

      expect(baseUrl).assertEqual('https://os-proxy.vidall.app/v1');
    });

    it('should use direct base url when api key is configured', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      store.seed(PrefKey.OPENSUBTITLES_API_KEY, 'my-valid-api-key');
      const loader: AppPreferencesLoader = async () => store;
      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      const client = new OpenSubtitlesClient();
      const baseUrl = await client.resolveBaseUrl();

      expect(baseUrl).assertEqual('https://api.opensubtitles.com/api/v1');
    });
  });

  describe('OpenSubtitlesClient_error_mapping', () => {
    beforeEach(() => {
      AppPreferences.resetForTesting();
    });

    afterEach(() => {
      AppPreferences.setStoreLoaderForTesting(null);
      AppPreferences.resetForTesting();
    });

    it('should throw ProxyQuotaExceededError when proxy returns HTTP 429', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      // 代理通道（无 API Key）
      const loader: AppPreferencesLoader = async () => store;
      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      const fakeExecutor = makeFakeExecutor(429, '{}');
      const client = new OpenSubtitlesClient(fakeExecutor);

      let caught: Error | null = null;
      try {
        await client.search('test', 'zh-CN');
      } catch (e) {
        caught = e as Error;
      }

      expect(caught).not().assertNull();
      expect(caught instanceof ProxyQuotaExceededError).assertTrue();
    });

    it('should throw InvalidApiKeyError when direct channel returns HTTP 401', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      // 直连通道（有 API Key）
      store.seed(PrefKey.OPENSUBTITLES_API_KEY, 'invalid-key');
      const loader: AppPreferencesLoader = async () => store;
      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      const fakeExecutor = makeFakeExecutor(401, '{"message":"Invalid API Key"}');
      const client = new OpenSubtitlesClient(fakeExecutor);

      let caught: Error | null = null;
      try {
        await client.search('test', 'zh-CN');
      } catch (e) {
        caught = e as Error;
      }

      expect(caught).not().assertNull();
      expect(caught instanceof InvalidApiKeyError).assertTrue();
    });

    it('should throw ProxyUnavailableError when proxy network is unreachable', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      // 代理通道（无 API Key）
      const loader: AppPreferencesLoader = async () => store;
      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      const fakeExecutor = makeNetworkErrorExecutor();
      const client = new OpenSubtitlesClient(fakeExecutor);

      let caught: Error | null = null;
      try {
        await client.search('test', 'zh-CN');
      } catch (e) {
        caught = e as Error;
      }

      expect(caught).not().assertNull();
      expect(caught instanceof ProxyUnavailableError).assertTrue();
    });

    it('should return empty array when search response has no data', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      store.seed(PrefKey.OPENSUBTITLES_API_KEY, 'valid-key');
      const loader: AppPreferencesLoader = async () => store;
      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      const fakeExecutor = makeFakeExecutor(200, '{"data":[]}');
      const client = new OpenSubtitlesClient(fakeExecutor);

      const results = await client.search('无结果的电影', 'zh-CN');
      expect(results.length).assertEqual(0);
    });

    it('should parse search results correctly', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const store = new InMemoryStore();
      store.seed(PrefKey.OPENSUBTITLES_API_KEY, 'valid-key');
      const loader: AppPreferencesLoader = async () => store;
      AppPreferences.setStoreLoaderForTesting(loader);
      await AppPreferences.init(ctx);

      const fakeExecutor = makeFakeExecutor(200, buildSearchResponse(2));
      const client = new OpenSubtitlesClient(fakeExecutor);

      const results: SubtitleSearchResult[] = await client.search('Inception', 'zh-CN');

      expect(results.length).assertEqual(2);
      expect(results[0].subtitleId).assertEqual('id0');
      expect(results[0].languageCode).assertEqual('zh-CN');
      expect(results[0].fileId).assertEqual(100);
      expect(results[1].subtitleId).assertEqual('id1');
      expect(results[1].fileId).assertEqual(101);
    });
  });
}
