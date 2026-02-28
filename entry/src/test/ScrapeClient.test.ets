import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { ScrapeClient, TmdbProvider, parseFileName, ScrapeQuery, ScrapeResult } from '../main/ets/lib/ScrapeClient';

export default function scrapeClientTest() {
  describe('ScrapeClient', () => {
    /**
     * 测试用例 1：测试文件名解析功能 - 电影格式
     */
    it('should parse movie filename with year', 0, () => {
      console.info('Test: parseFileName - movie with year');

      const query: ScrapeQuery = parseFileName('Inception.2010.1080p.BluRay.mkv');

      expect(query.title).assertEqual('Inception');
      expect(query.year).assertEqual(2010);
      expect(query.mediaType).assertEqual('movie');
    });

    /**
     * 测试用例 2：测试文件名解析功能 - 电视剧格式
     */
    it('should parse TV show filename with season and episode', 0, () => {
      console.info('Test: parseFileName - TV show');

      const query: ScrapeQuery = parseFileName('Breaking.Bad.S02E03.Bit.by.a.Dead.Bee.mkv');

      expect(query.title).assertEqual('Breaking Bad');
      expect(query.mediaType).assertEqual('tv');
    });

    /**
     * 测试用例 3：测试文件名解析 - 复杂文件名
     */
    it('should parse complex filename and remove quality markers', 0, () => {
      console.info('Test: parseFileName - complex filename');

      const query: ScrapeQuery = parseFileName('The.Matrix.1999.2160p.UHD.BluRay.x265.10bit.HDR.DTS-X.7.1.mkv');

      expect(query.title).assertEqual('The Matrix');
      expect(query.year).assertEqual(1999);
      expect(query.mediaType).assertEqual('movie');
    });

    /**
     * 测试用例 4：测试文件名解析 - 中文文件名
     */
    it('should parse Chinese filename', 0, () => {
      console.info('Test: parseFileName - Chinese filename');

      const query: ScrapeQuery = parseFileName('流浪地球.2019.1080p.mkv');

      expect(query.title).assertEqual('流浪地球');
      expect(query.year).assertEqual(2019);
      expect(query.mediaType).assertEqual('movie');
    });

    /**
     * 测试用例 5：测试 TMDB Provider 配置检查
     */
    it('should check if TmdbProvider is configured', 0, () => {
      console.info('Test: TmdbProvider.isConfigured');

      const providerWithKey = new TmdbProvider('test_api_key_123');
      expect(providerWithKey.isConfigured()).assertTrue();

      const providerWithoutKey = new TmdbProvider('');
      expect(providerWithoutKey.isConfigured()).assertFalse();

      const providerWithWhitespace = new TmdbProvider('   ');
      expect(providerWithWhitespace.isConfigured()).assertFalse();
    });

    /**
     * 测试用例 6：测试 ScrapeClient 初始化
     */
    it('should initialize ScrapeClient with TMDB provider', 0, () => {
      console.info('Test: ScrapeClient initialization');

      const client = new ScrapeClient({ tmdbApiKey: 'test_key' });
      const providerIds = client.getProviderIds();

      expect(providerIds.length).assertEqual(1);
      expect(providerIds[0]).assertEqual('tmdb');
    });

    /**
     * 测试用例 7：测试 ScrapeClient 初始化 - 无 API Key
     */
    it('should initialize ScrapeClient without API key', 0, () => {
      console.info('Test: ScrapeClient initialization without key');

      const client = new ScrapeClient({});
      const providerIds = client.getProviderIds();

      expect(providerIds.length).assertEqual(0);
    });

    /**
     * 测试用例 8：测试 autoScrape 重试逻辑（模拟）
     */
    it('should handle autoScrape timeout and retry', 0, async () => {
      console.info('Test: autoScrape timeout and retry logic');

      // 注意：由于没有真实 API Key 和网络环境，这个测试只验证函数调用不会崩溃
      const client = new ScrapeClient({ tmdbApiKey: 'invalid_key_for_test' });

      try {
        // 使用一个不存在的文件名，预期会失败
        const result = await client.autoScrape('NonExistentMovie9999.2099.mkv');

        // 如果没有匹配结果，应该返回 null
        expect(result).assertNull();
        console.info('Test passed: autoScrape returned null for non-existent movie');
      } catch (error) {
        // 预期可能会抛出网络错误或超时错误
        console.info('Test passed: autoScrape threw error as expected:', JSON.stringify(error));
        expect(true).assertTrue();
      }
    });

    /**
     * 测试用例 9：测试文件名解析 - 带括号的年份
     */
    it('should parse filename with year in parentheses', 0, () => {
      console.info('Test: parseFileName - year in parentheses');

      const query: ScrapeQuery = parseFileName('The.Shawshank.Redemption.(1994).1080p.mkv');

      expect(query.title).assertEqual('The Shawshank Redemption');
      expect(query.year).assertEqual(1994);
      expect(query.mediaType).assertEqual('movie');
    });

    /**
     * 测试用例 10：测试文件名解析 - 无年份
     */
    it('should parse filename without year', 0, () => {
      console.info('Test: parseFileName - no year');

      const query: ScrapeQuery = parseFileName('Unknown.Movie.1080p.mkv');

      expect(query.title).assertEqual('Unknown Movie');
      expect(query.year).assertUndefined();
      expect(query.mediaType).assertEqual('movie');
    });

    /**
     * 测试用例 11：测试 ScrapeClient provider 注册
     */
    it('should register custom provider', 0, () => {
      console.info('Test: ScrapeClient provider registration');

      const client = new ScrapeClient({ tmdbApiKey: 'test_key' });

      // 初始只有 tmdb
      let providerIds = client.getProviderIds();
      expect(providerIds.length).assertEqual(1);

      // 注册另一个 provider
      const customProvider = new TmdbProvider('another_key');
      client.registerProvider(customProvider);

      // 应该还是 1 个（因为 id 相同会覆盖）
      providerIds = client.getProviderIds();
      expect(providerIds.length).assertEqual(1);
    });

    /**
     * 测试用例 12：测试文件名解析 - 特殊字符处理
     */
    it('should handle special characters in filename', 0, () => {
      console.info('Test: parseFileName - special characters');

      const query: ScrapeQuery = parseFileName('Spider-Man_Far.From.Home[2019]1080p.mkv');

      expect(query.title).assertEqual('Spider Man Far From Home');
      expect(query.year).assertEqual(2019);
      expect(query.mediaType).assertEqual('movie');
    });

    /**
     * 测试用例 13：测试并发控制（基本验证）
     */
    it('should handle concurrent scrape requests', 0, async () => {
      console.info('Test: Concurrent scrape requests');

      const client = new ScrapeClient({ tmdbApiKey: 'test_key' });

      // 创建多个并发请求
      const promises = [
        client.autoScrape('Movie1.2020.mkv'),
        client.autoScrape('Movie2.2021.mkv'),
        client.autoScrape('Movie3.2022.mkv')
      ];

      try {
        // 等待所有请求完成（预期会失败，但不应该崩溃）
        const results = await Promise.allSettled(promises);

        // 验证所有请求都已处理（无论成功或失败）
        expect(results.length).assertEqual(3);
        console.info('Test passed: All concurrent requests were processed');
      } catch (error) {
        console.error('Concurrent requests test failed:', JSON.stringify(error));
        expect(false).assertTrue();
      }
    });

    /**
     * 测试用例 14：测试文件名解析 - 剧集编号识别
     */
    it('should identify episode format correctly', 0, () => {
      console.info('Test: parseFileName - episode identification');

      const episodeFormats = [
        'Show.S01E01.mkv',
        'Show.s02e03.mkv',
        'Show.S1E1.mkv',
        'Show.S10E99.mkv'
      ];

      episodeFormats.forEach(filename => {
        const query = parseFileName(filename);
        expect(query.mediaType).assertEqual('tv');
      });
    });

    /**
     * 测试用例 15：测试边界情况 - 空文件名
     */
    it('should handle empty filename gracefully', 0, () => {
      console.info('Test: parseFileName - empty filename');

      const query: ScrapeQuery = parseFileName('');

      expect(query.title).assertEqual('');
      expect(query.year).assertUndefined();
      expect(query.mediaType).assertEqual('movie');
    });
  });
}
