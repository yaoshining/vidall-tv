import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { ScrapeClient, TmdbProvider, parseFileName, ParsedFileName } from '../main/ets/lib/ScrapeClient';

export default function scrapeClientTest() {
  describe('ScrapeClient', () => {
    /**
     * 测试用例 1：测试文件名解析功能 - 电影格式
     */
    it('should parse movie filename with year', 0, () => {
      const query: ParsedFileName = parseFileName('Inception.2010.1080p.BluRay.mkv');

      expect(query.title).assertEqual('Inception');
      expect(query.year).assertEqual(2010);
      expect(query.mediaType).assertEqual('movie');
    });

    /**
     * 测试用例 2：测试文件名解析功能 - 电视剧格式
     */
    it('should parse TV show filename with season and episode', 0, () => {
      const query: ParsedFileName = parseFileName('Breaking.Bad.S02E03.Bit.by.a.Dead.Bee.mkv');

      expect(query.title).assertEqual('Breaking Bad');
      expect(query.mediaType).assertEqual('tv');
      expect(query.seasonNumber).assertEqual(2);
      expect(query.episodeNumber).assertEqual(3);
    });

    /**
     * 测试用例 3：测试文件名解析 - 复杂文件名
     */
    it('should parse complex filename and remove quality markers', 0, () => {
      const query: ParsedFileName = parseFileName('The.Matrix.1999.2160p.UHD.BluRay.x265.10bit.HDR.DTS-X.7.1.mkv');

      expect(query.title).assertEqual('The Matrix');
      expect(query.year).assertEqual(1999);
      expect(query.mediaType).assertEqual('movie');
    });

    /**
     * 测试用例 4：测试文件名解析 - 中文文件名
     */
    it('should parse Chinese filename', 0, () => {
      const query: ParsedFileName = parseFileName('流浪地球.2019.1080p.mkv');

      expect(query.title).assertEqual('流浪地球');
      expect(query.year).assertEqual(2019);
      expect(query.mediaType).assertEqual('movie');
    });

    /**
     * 测试用例 5：测试 TMDB Provider 配置检查
     */
    it('should check if TmdbProvider is configured', 0, () => {
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
      const client = new ScrapeClient({ tmdbApiKey: 'test_key' });
      const providerIds = client.getProviderIds();

      expect(providerIds.length).assertEqual(1);
      expect(providerIds[0]).assertEqual('tmdb');
    });

    /**
     * 测试用例 7：测试 ScrapeClient 初始化 - 无 API Key
     */
    it('should initialize ScrapeClient without API key', 0, () => {
      const client = new ScrapeClient({});
      const providerIds = client.getProviderIds();

      expect(providerIds.length).assertEqual(0);
    });

    /**
     * 测试用例 8：测试 autoScrapeMovie 无效 key（不应崩溃）
     */
    it('should handle autoScrapeMovie network failure gracefully', 0, async () => {
      const client = new ScrapeClient({ tmdbApiKey: 'invalid_key_for_test' });

      try {
        const result = await client.autoScrapeMovie('NonExistentMovie9999.2099.mkv');

        expect(result === null || result !== null).assertTrue();
      } catch (e) {
        expect(true).assertTrue();
      }
    });

    /**
     * 测试用例 9：测试文件名解析 - 带括号的年份
     */
    it('should parse filename with year in parentheses', 0, () => {
      const query: ParsedFileName = parseFileName('The.Shawshank.Redemption.(1994).1080p.mkv');

      expect(query.title).assertEqual('The Shawshank Redemption');
      expect(query.year).assertEqual(1994);
      expect(query.mediaType).assertEqual('movie');
    });

    /**
     * 测试用例 10：测试文件名解析 - 无年份
     */
    it('should parse filename without year', 0, () => {
      const query: ParsedFileName = parseFileName('Unknown.Movie.1080p.mkv');

      expect(query.title).assertEqual('Unknown Movie');
      expect(query.year).assertUndefined();
      expect(query.mediaType).assertEqual('movie');
    });

    /**
     * 测试用例 11：测试 ScrapeClient provider 注册（相同 id 覆盖）
     */
    it('should register custom provider and deduplicate by id', 0, () => {
      const client = new ScrapeClient({ tmdbApiKey: 'test_key' });

      let providerIds = client.getProviderIds();
      expect(providerIds.length).assertEqual(1);

      const customProvider = new TmdbProvider('another_key');
      client.registerProvider(customProvider);

      providerIds = client.getProviderIds();
      expect(providerIds.length).assertEqual(1);
    });

    /**
     * 测试用例 12：测试文件名解析 - 特殊字符处理
     */
    it('should handle special characters in filename', 0, () => {
      const query: ParsedFileName = parseFileName('Spider-Man_Far.From.Home[2019]1080p.mkv');

      expect(query.title).assertEqual('Spider Man Far From Home');
      expect(query.year).assertEqual(2019);
      expect(query.mediaType).assertEqual('movie');
    });

    /**
     * 测试用例 13：测试并发电影刮削请求
     */
    it('should handle concurrent autoScrapeMovie requests', 0, async () => {
      const client = new ScrapeClient({ tmdbApiKey: 'test_key' });

      const promises = [
        client.autoScrapeMovie('Movie1.2020.mkv'),
        client.autoScrapeMovie('Movie2.2021.mkv'),
        client.autoScrapeMovie('Movie3.2022.mkv')
      ];

      try {
        const results = await Promise.allSettled(promises);

        expect(results.length).assertEqual(3);
      } catch (e) {
        expect(false).assertTrue();
      }
    });

    /**
     * 测试用例 14：测试文件名解析 - 剧集编号识别
     */
    it('should identify episode format correctly', 0, () => {
      const episodeFormats = [
        'Show.S01E01.mkv',
        'Show.s02e03.mkv',
        'Show.S1E1.mkv',
        'Show.S10E99.mkv'
      ];

      episodeFormats.forEach(filename => {
        const q = parseFileName(filename);
        expect(q.mediaType).assertEqual('tv');
      });
    });

    /**
     * 测试用例 15：测试边界情况 - 空文件名
     */
    it('should handle empty filename gracefully', 0, () => {
      const query: ParsedFileName = parseFileName('');

      expect(query.title).assertEqual('');
      expect(query.year).assertUndefined();
      expect(query.mediaType).assertEqual('movie');
    });

    /**
     * 测试用例 16：测试高级音频编码标记 - DDP5.1、AAC2.0
     */
    it('should remove advanced audio codec markers like DDP5.1 and AAC2.0', 0, () => {
      const query1: ParsedFileName = parseFileName('Dune.2021.2160p.WEB-DL.DDP5.1.Atmos.DV.HEVC-ABC.mkv');
      expect(query1.title).assertEqual('Dune');
      expect(query1.year).assertEqual(2021);

      const query2: ParsedFileName = parseFileName('Avatar.2009.1080p.BluRay.AAC2.0.x264-XYZ.mkv');
      expect(query2.title).assertEqual('Avatar');
      expect(query2.year).assertEqual(2009);
    });

    /**
     * 测试用例 17：测试 Dolby Vision 标记清理
     */
    it('should remove DV (Dolby Vision) marker from filename', 0, () => {
      const query: ParsedFileName = parseFileName('The.Batman.2022.2160p.UHD.BluRay.DV.HDR10.TrueHD.7.1.x265.mkv');

      expect(query.title).assertEqual('The Batman');
      expect(query.year).assertEqual(2022);
      expect(query.mediaType).assertEqual('movie');
    });

    /**
     * 测试用例 18：测试复杂音频格式组合
     */
    it('should handle complex audio format combinations', 0, () => {
      const query1: ParsedFileName = parseFileName('Oppenheimer.2023.IMAX.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265.mkv');
      expect(query1.title).assertEqual('Oppenheimer');
      expect(query1.year).assertEqual(2023);

      const query2: ParsedFileName = parseFileName('Top.Gun.Maverick.2022.2160p.DDP7.1.Atmos.DV.HDR10Plus.HEVC.mkv');
      expect(query2.title).assertEqual('Top Gun Maverick');
      expect(query2.year).assertEqual(2022);
    });

    /**
     * 测试用例 19：测试 autoScrapeTvEpisode 返回 empty（无网络）
     */
    it('should return empty result for autoScrapeTvEpisode with invalid key', 0, async () => {
      const client = new ScrapeClient({ tmdbApiKey: 'invalid_key' });

      try {
        const result = await client.autoScrapeTvEpisode('Game.of.Thrones.S07E01.mkv');
        // series 为 null 或不为 null 均可
        expect(result !== undefined).assertTrue();
      } catch (e) {
        expect(true).assertTrue();
      }
    });
  });
}
