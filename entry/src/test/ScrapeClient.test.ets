import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { ScrapeClient, TmdbProvider, parseFileName, buildSearchTitles, ParsedFileName, MovieScrapeResult } from '../main/ets/lib/ScrapeClient';
import {
  ScriptedFakeScrapeProvider,
  createDeferred,
  createMovieScrapeResult,
  createTvSeriesScrapeResult,
  createTvSeasonScrapeResult,
  createTvEpisodeScrapeResult
} from './helpers/ScrapeClientFakeProvider';

async function flushMicrotasksUntil(predicate: () => boolean, rounds: number = 12): Promise<void> {
  for (let index = 0; index < rounds && !predicate(); index++) {
    await Promise.resolve();
  }
}

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

    it('should parse NAS episode filename with separated season and episode markers', 0, () => {
      const query: ParsedFileName = parseFileName('S01 4K EP 07.mkv');

      expect(query.mediaType).assertEqual('tv');
      expect(query.seasonNumber).assertEqual(1);
      expect(query.episodeNumber).assertEqual(7);
    });

    it('should treat tilde as a title separator for weak semantic filenames', 0, () => {
      const query: ParsedFileName = parseFileName('01~4K.mp4');

      expect(query.title).assertEqual('01');
      expect(query.mediaType).assertEqual('movie');
      expect(query.seasonNumber === undefined).assertTrue();
      expect(query.episodeNumber === undefined).assertTrue();
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
     * 测试用例 8：测试 autoScrapeMovie 搜索失败时的稳定容错结果（fake failure）
     */
    it('should handle autoScrapeMovie search failure deterministically with fake provider', 0, async () => {
      const fake = new ScriptedFakeScrapeProvider('fake-network-failure');
      fake.enqueueSearchMovieThrow('simulated search failure');

      const client = new ScrapeClient({});
      client.registerProvider(fake);

      const result = await client.autoScrapeMovie('NonExistentMovie9999.2099.1080p.mkv');

      expect(result).assertEqual(null);
      expect(fake.getCallCount('searchMovie')).assertEqual(1);
      expect(fake.getCallCount('fetchMovieDetail')).assertEqual(0);
      const searchCall = fake.getLastCall('searchMovie');
      expect(searchCall !== null).assertTrue();
      if (searchCall !== null) {
        expect(searchCall.title).assertEqual('NonExistentMovie9999');
        expect(searchCall.year).assertEqual(2099);
        expect(searchCall.language).assertEqual('zh-CN');
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
      const fake = new ScriptedFakeScrapeProvider('fake-concurrency');
      const deferred1 = createDeferred<MovieScrapeResult[]>();
      const deferred2 = createDeferred<MovieScrapeResult[]>();
      const deferred3 = createDeferred<MovieScrapeResult[]>();

      fake.enqueueSearchMovieDeferred(deferred1);
      fake.enqueueSearchMovieDeferred(deferred2);
      fake.enqueueSearchMovieDeferred(deferred3);
      fake.enqueueFetchMovieDetailResult(createMovieScrapeResult('fake-concurrency', 'First Movie Result', 'movie-1'));
      fake.enqueueFetchMovieDetailResult(createMovieScrapeResult('fake-concurrency', 'Second Movie Result', 'movie-2'));
      fake.enqueueFetchMovieDetailResult(createMovieScrapeResult('fake-concurrency', 'Third Movie Result', 'movie-3'));

      const client = new ScrapeClient({ scrapeConcurrency: 2 });
      client.registerProvider(fake);

      const p1 = client.autoScrapeMovie('First.Movie.(2020).mkv');
      const p2 = client.autoScrapeMovie('Second.Movie.(2021).mkv');
      const p3 = client.autoScrapeMovie('Third.Movie.(2022).mkv');

      await flushMicrotasksUntil(() => fake.getCallCount('searchMovie') === 2);
      expect(fake.getCallCount('searchMovie')).assertEqual(2);
      expect(fake.getCallCount('fetchMovieDetail')).assertEqual(0);

      deferred1.resolve([createMovieScrapeResult('fake-concurrency', 'First Movie Result', 'movie-1')]);
      const result1 = await p1;
      expect(result1 !== null).assertTrue();
      if (result1 !== null) {
        expect(result1.provider).assertEqual('fake-concurrency');
        expect(result1.title).assertEqual('First Movie Result');
        expect(result1.providerId).assertEqual('movie-1');
      }

      await flushMicrotasksUntil(() => fake.getCallCount('searchMovie') === 3);
      expect(fake.getCallCount('searchMovie')).assertEqual(3);
      const thirdSearchCall = fake.getLastCall('searchMovie');
      expect(thirdSearchCall !== null).assertTrue();
      if (thirdSearchCall !== null) {
        expect(thirdSearchCall.title).assertEqual('Third Movie');
        expect(thirdSearchCall.year).assertEqual(2022);
        expect(thirdSearchCall.language).assertEqual('zh-CN');
      }

      deferred2.resolve([createMovieScrapeResult('fake-concurrency', 'Second Movie Result', 'movie-2')]);
      deferred3.resolve([createMovieScrapeResult('fake-concurrency', 'Third Movie Result', 'movie-3')]);

      const results = await Promise.all([p1, p2, p3]);
      expect(results.length).assertEqual(3);
      expect(results[0] !== null).assertTrue();
      expect(results[1] !== null).assertTrue();
      expect(results[2] !== null).assertTrue();
      if (results[0] !== null) {
        expect(results[0].title).assertEqual('First Movie Result');
        expect(results[0].providerId).assertEqual('movie-1');
      }
      if (results[1] !== null) {
        expect(results[1].title).assertEqual('Second Movie Result');
        expect(results[1].providerId).assertEqual('movie-2');
      }
      if (results[2] !== null) {
        expect(results[2].title).assertEqual('Third Movie Result');
        expect(results[2].providerId).assertEqual('movie-3');
      }
      expect(fake.getCallCount('fetchMovieDetail')).assertEqual(3);
    });

    it('should use preclassified tv result and series hint for weak semantic filenames', 0, async () => {
      const fake = new ScriptedFakeScrapeProvider('fake-tv-hint');
      fake.enqueueSearchTvResults([createTvSeriesScrapeResult('fake-tv-hint', '狂飙', 'tv-1')]);
      fake.enqueueFetchTvSeriesDetailResult(createTvSeriesScrapeResult('fake-tv-hint', '狂飙', 'tv-1'));

      const client = new ScrapeClient({});
      client.registerProvider(fake);

      const result = await client.autoScrapeTvEpisode('19 4K.mp4', '狂飙', 'tv');

      expect(result.series !== null).assertTrue();
      expect(fake.getCallCount('searchTv')).assertEqual(1);
      const searchCall = fake.getLastCall('searchTv');
      expect(searchCall !== null).assertTrue();
      if (searchCall !== null) {
        expect(searchCall.title).assertEqual('狂飙');
        expect(searchCall.language).assertEqual('zh-CN');
      }
    });

    it('应按路径剧名和年份选择正确的电视剧候选', 0, async () => {
      const fake = new ScriptedFakeScrapeProvider('fake-issue-234');
      const incorrect = createTvSeriesScrapeResult('fake-issue-234', 'Climax!', 'tv-1954');
      incorrect.firstAirDate = '1954-10-01';
      const expected = createTvSeriesScrapeResult('fake-issue-234', '权欲之巅', 'tv-2026');
      expected.firstAirDate = '2026-01-01';
      fake.enqueueSearchTvResults([incorrect, expected]);
      fake.enqueueFetchTvSeriesDetailResult(expected);
      fake.enqueueFetchSeasonResult(null);
      fake.enqueueFetchEpisodeResult(null);

      const client = new ScrapeClient({});
      client.registerProvider(fake);

      const result = await client.autoScrapeTvEpisode(
        'Climax S01E01 - 第 1 集 - 1080p WEB-DL H264 AAC 2.0.mkv',
        '权欲之巅(2026)',
        'tv'
      );

      expect(result.series !== null).assertTrue();
      if (result.series !== null) {
        expect(result.series.providerId).assertEqual('tv-2026');
        expect(result.series.title).assertEqual('权欲之巅');
      }
      expect(fake.getCallCount('searchTv')).assertEqual(1);
      expect(fake.getCallCount('fetchTvSeriesDetail')).assertEqual(1);
      const searchCall = fake.getLastCall('searchTv');
      expect(searchCall !== null).assertTrue();
      if (searchCall !== null) {
        expect(searchCall.title).assertEqual('权欲之巅');
        expect(searchCall.year).assertEqual(2026);
      }
    });

    it('应使用文件名年份约束同名路径剧集候选', 0, async () => {
      const fake = new ScriptedFakeScrapeProvider('fake-issue-234-file-year');
      const incorrect = createTvSeriesScrapeResult('fake-issue-234-file-year', 'Climax!', 'tv-1954');
      incorrect.firstAirDate = '1954-10-01';
      const expected = createTvSeriesScrapeResult('fake-issue-234-file-year', 'Climax', 'tv-2026');
      expected.firstAirDate = '2026-01-01';
      fake.enqueueSearchTvResults([incorrect, expected]);
      fake.enqueueFetchTvSeriesDetailResult(expected);

      const client = new ScrapeClient({});
      client.registerProvider(fake);

      const result = await client.autoScrapeTvEpisode('Climax.(2026).S01E01.mkv', 'Climax', 'tv');

      expect(result.series !== null).assertTrue();
      if (result.series !== null) {
        expect(result.series.providerId).assertEqual('tv-2026');
      }
      const searchCall = fake.getLastCall('searchTv');
      expect(searchCall !== null).assertTrue();
      if (searchCall !== null) {
        expect(searchCall.title).assertEqual('Climax');
        expect(searchCall.year).assertEqual(2026);
      }
    });

    it('应清理未加括号和方括号包裹的路径年份', 0, async () => {
      const fake = new ScriptedFakeScrapeProvider('fake-issue-234-normalize-year');
      const show = createTvSeriesScrapeResult('fake-issue-234-normalize-year', 'Show', 'show-2026');
      show.firstAirDate = '2026-01-01';
      fake.enqueueSearchTvResults([show]);
      fake.enqueueFetchTvSeriesDetailResult(show);
      fake.enqueueSearchTvResults([show]);
      fake.enqueueFetchTvSeriesDetailResult(show);

      const client = new ScrapeClient({});
      client.registerProvider(fake);

      await client.autoScrapeTvEpisode('Episode S01E01.mkv', 'Show 2026', 'tv');
      const firstSearchCall = fake.getLastCall('searchTv');
      expect(firstSearchCall !== null).assertTrue();
      if (firstSearchCall !== null) {
        expect(firstSearchCall.title).assertEqual('Show');
        expect(firstSearchCall.year).assertEqual(2026);
      }

      await client.autoScrapeTvEpisode('Episode S01E02.mkv', 'Show【2026】', 'tv');
      const secondSearchCall = fake.getLastCall('searchTv');
      expect(secondSearchCall !== null).assertTrue();
      if (secondSearchCall !== null) {
        expect(secondSearchCall.title).assertEqual('Show');
        expect(secondSearchCall.year).assertEqual(2026);
      }
    });

    it('应拒绝与路径年份不一致的电视剧候选', 0, async () => {
      const fake = new ScriptedFakeScrapeProvider('fake-issue-234-year-mismatch');
      const incorrect = createTvSeriesScrapeResult('fake-issue-234-year-mismatch', 'Climax!', 'tv-1954');
      incorrect.firstAirDate = '1954-10-01';
      fake.enqueueSearchTvResults([incorrect]);
      fake.enqueueSearchTvResults([incorrect]);
      fake.enqueueSearchTvResults([]);
      fake.enqueueSearchTvResults([]);

      const client = new ScrapeClient({});
      client.registerProvider(fake);

      const result = await client.autoScrapeTvEpisode('Climax S01E01.mkv', '权欲之巅(2026)', 'tv');

      expect(result.series).assertEqual(null);
      expect(result.season).assertEqual(null);
      expect(result.episode).assertEqual(null);
      expect(fake.getCallCount('fetchTvSeriesDetail')).assertEqual(0);
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
     * 测试用例 20：英文电影文件名边界 - 带发布组标记
     */
    it('应解析 The.Dark.Knight.2008.1080p.BluRay.x264-YIFY.mkv', 0, () => {
      const query: ParsedFileName = parseFileName('The.Dark.Knight.2008.1080p.BluRay.x264-YIFY.mkv');
      expect(query.title).assertEqual('The Dark Knight');
      expect(query.year).assertEqual(2008);
    });

    /**
     * 测试用例 21：电视剧文件名边界 - 含发布组标记
     */
    it('应解析 Breaking.Bad.S01E01.1080p.BluRay-GROUP.mkv', 0, () => {
      const query: ParsedFileName = parseFileName('Breaking.Bad.S01E01.1080p.BluRay-GROUP.mkv');
      expect(query.title).assertEqual('Breaking Bad');
      expect(query.seasonNumber).assertEqual(1);
      expect(query.episodeNumber).assertEqual(1);
    });

    /**
     * 测试用例 22：纯中文文件名无年份
     */
    it('应解析纯中文文件名 流浪地球.4K.mkv', 0, () => {
      const query: ParsedFileName = parseFileName('流浪地球.4K.mkv');
      expect(query.title).assertEqual('流浪地球');
      expect(query.year).assertUndefined();
    });
  });

  describe('buildSearchTitles', () => {
    it('中英混合标题保留中英文候选', 0, () => {
      const titles: string[] = buildSearchTitles('流浪地球 The Wandering Earth');
      expect(titles.length).assertEqual(2);
      expect(titles[0].trim()).assertEqual('The Wandering Earth');
      expect(titles[1].trim()).assertEqual('流浪地球');
    });

    it('纯中文标题返回中文', 0, () => {
      const titles: string[] = buildSearchTitles('流浪地球');
      expect(titles.length).assertLarger(0);
      expect(titles[0]).assertEqual('流浪地球');
    });

    it('纯英文标题返回英文', 0, () => {
      const titles: string[] = buildSearchTitles('The Dark Knight');
      expect(titles.length).assertLarger(0);
      expect(titles[0]).assertEqual('The Dark Knight');
    });
  });


  describe('ScriptedFakeScrapeProvider', () => {
    it('should work with ScrapeClient.registerProvider for immediate success', 0, async () => {
      const fake = new ScriptedFakeScrapeProvider('fake-success');
      fake.enqueueSearchMovieResults([createMovieScrapeResult('fake-success', 'Immediate Success Movie', 'movie-1')]);
      fake.enqueueFetchMovieDetailResult(createMovieScrapeResult('fake-success', 'Immediate Success Movie', 'movie-1'));

      const client = new ScrapeClient({});
      client.registerProvider(fake);

      const result = await client.autoScrapeMovie('Immediate.Success.Movie.2024.1080p.mkv');
      expect(result !== null).assertTrue();
      if (result !== null) {
        expect(result.provider).assertEqual('fake-success');
        expect(result.title).assertEqual('Immediate Success Movie');
        expect(result.providerId).assertEqual('movie-1');
      }
      expect(fake.getCallCount('searchMovie')).assertEqual(1);
      const searchCall = fake.getLastCall('searchMovie');
      expect(searchCall !== null).assertTrue();
      if (searchCall !== null) {
        expect(searchCall.title).assertEqual('Immediate Success Movie');
        expect(searchCall.year).assertEqual(2024);
        expect(searchCall.language).assertEqual('zh-CN');
      }
    });

    it('should throw when scripted searchMovie is exhausted', 0, async () => {
      const fake = new ScriptedFakeScrapeProvider('fake-empty');

      let rejected = false;
      await fake.searchMovie('Missing Title', undefined, 'zh-CN').then(() => {
        rejected = false;
      }).catch(() => {
        rejected = true;
      });

      expect(rejected).assertTrue();
      expect(fake.getCallCount('searchMovie')).assertEqual(1);
    });

    it('should surface scripted failure', 0, async () => {
      const fake = new ScriptedFakeScrapeProvider('fake-failure');
      fake.enqueueSearchMovieThrow('scripted search failure');

      const client = new ScrapeClient({});
      client.registerProvider(fake);

      const result = await client.autoScrapeMovie('Any.Title.2024.1080p.mkv');
      expect(result).assertEqual(null);
      expect(fake.getCallCount('searchMovie')).assertEqual(1);
      const searchCall = fake.getLastCall('searchMovie');
      expect(searchCall !== null).assertTrue();
      if (searchCall !== null) {
        expect(searchCall.title).assertEqual('Any Title');
        expect(searchCall.year).assertEqual(2024);
        expect(searchCall.language).assertEqual('zh-CN');
      }
    });

    it('should keep scripted deferred search pending until released', 0, async () => {
      const fake = new ScriptedFakeScrapeProvider('fake-blocking');
      const deferred = createDeferred<MovieScrapeResult[]>();
      fake.enqueueSearchMovieDeferred(deferred);

      const client = new ScrapeClient({});
      client.registerProvider(fake);

      let settled = false;
      const pending = client.autoScrapeMovie('Blocking.Title.2024.1080p.mkv').then((result) => {
        settled = true;
        return result;
      }).catch(() => {
        settled = true;
        return null;
      });

      await flushMicrotasksUntil(() => fake.getCallCount('searchMovie') === 1);
      expect(settled).assertFalse();
      expect(fake.getCallCount('searchMovie')).assertEqual(1);
      const searchCall = fake.getLastCall('searchMovie');
      expect(searchCall !== null).assertTrue();
      if (searchCall !== null) {
        expect(searchCall.title).assertEqual('Blocking Title');
        expect(searchCall.year).assertEqual(2024);
        expect(searchCall.language).assertEqual('zh-CN');
      }

      deferred.resolve([]);
      const result = await pending;
      expect(settled).assertTrue();
      expect(result).assertEqual(null);
    });

    /**
     * 测试用例 24：#191 显式传入季集号修复弱语义文件名刮削
     * 
     * 场景：不完整 TV 关联修复链路中，文件名 "19 4K.mp4" 无法被 parseFileName 识别 S/E，
     * 但扫描器已通过 extractEpisodeNumberFromWeakSemanticFileName 得到 episode=19。
     * 此时应支持显式传入 episodeNumber=19, seasonNumber=1，刮削时能正确调用 fetchEpisode(S01E19)。
     */
    it('should use explicit episode and season numbers when provided for weak semantic filenames', 0, async () => {
      const fake = new ScriptedFakeScrapeProvider('fake-explicit-episode');
      fake.enqueueSearchTvResults([createTvSeriesScrapeResult('fake-explicit-episode', '蜜语纪', 'tv-100')]);
      fake.enqueueFetchTvSeriesDetailResult(createTvSeriesScrapeResult('fake-explicit-episode', '蜜语纪', 'tv-100'));
      fake.enqueueFetchSeasonResult(createTvSeasonScrapeResult('fake-explicit-episode', 1, 'tv-100_s1', 'Season 1'));
      fake.enqueueFetchEpisodeResult(createTvEpisodeScrapeResult('fake-explicit-episode', 1, 19, 'ep-100-1-19', 'Episode 19'));

      const client = new ScrapeClient({});
      client.registerProvider(fake);

      // 显式传入 episodeNumber=19, seasonNumber=1（模拟修复链路）
      const result = await client.autoScrapeTvEpisode('19 4K.mp4', '蜜语纪', 'tv', 19, 1);

      // 验证：series 成功刮削
      expect(result.series !== null).assertTrue();
      if (result.series !== null) {
        expect(result.series.title).assertEqual('蜜语纪');
      }

      // 验证：season 成功刮削
      expect(result.season !== null).assertTrue();
      if (result.season !== null) {
        expect(result.season.seasonNumber).assertEqual(1);
      }

      // 验证：episode 成功刮削
      expect(result.episode !== null).assertTrue();
      if (result.episode !== null) {
        expect(result.episode.episodeNumber).assertEqual(19);
        expect(result.episode.seasonNumber).assertEqual(1);
        expect(result.episode.title).assertEqual('Episode 19');
      }

      // 验证：provider 按预期被调用
      expect(fake.getCallCount('searchTv')).assertEqual(1);
      expect(fake.getCallCount('fetchTvSeriesDetail')).assertEqual(1);
      expect(fake.getCallCount('fetchSeason')).assertEqual(1);
      expect(fake.getCallCount('fetchEpisode')).assertEqual(1);

      // 验证：fetchEpisode 调用参数正确
      const episodeCall = fake.getLastCall('fetchEpisode');
      expect(episodeCall !== null).assertTrue();
      if (episodeCall !== null) {
        expect(episodeCall.providerId).assertEqual('tv-100');
        expect(episodeCall.seasonNumber).assertEqual(1);
        expect(episodeCall.episodeNumber).assertEqual(19);
      }
    });

    /**
     * 测试用例 25：弱语义文件名"01~4K.mp4"（无季子目录、无 SxxExx）默认按第一季刮削。
     *
     * 场景：`重器/01~4K.mp4`。`extractEpisodeNumberFromWeakSemanticFileName` 现在能从
     * `01~4K`（数字后跟 `~`）提取集数 1；入口层 `processVideoScrape` 在无季号时传季节号 1。
     * 本用例验证 ScrapeClient 收到 explicitEpisodeNumber=1、explicitSeasonNumber=1 后，
     * 正确按 S01E01 拉取 season 与 episode。
     */
    it('should scrape season 1 and episode 1 for tilde-separated weak semantic filename without season info', 0, async () => {
      const fake = new ScriptedFakeScrapeProvider('fake-tilde-season-default');
      fake.enqueueSearchTvResults([createTvSeriesScrapeResult('fake-tilde-season-default', '重器', 'tv-200')]);
      fake.enqueueFetchTvSeriesDetailResult(createTvSeriesScrapeResult('fake-tilde-season-default', '重器', 'tv-200'));
      fake.enqueueFetchSeasonResult(createTvSeasonScrapeResult('fake-tilde-season-default', 1, 'tv-200_s1', 'Season 1'));
      fake.enqueueFetchEpisodeResult(createTvEpisodeScrapeResult('fake-tilde-season-default', 1, 1, 'ep-200-1-1', 'Episode 1'));

      const client = new ScrapeClient({});
      client.registerProvider(fake);

      // 模拟入口层：`01~4K.mp4` 已提取集数 1，无季信息默认季 1
      const result = await client.autoScrapeTvEpisode('01~4K.mp4', '重器', 'tv', 1, 1);

      expect(result.series !== null).assertTrue();
      if (result.series !== null) {
        expect(result.series.title).assertEqual('重器');
      }
      expect(result.season !== null).assertTrue();
      if (result.season !== null) {
        expect(result.season.seasonNumber).assertEqual(1);
      }
      expect(result.episode !== null).assertTrue();
      if (result.episode !== null) {
        expect(result.episode.seasonNumber).assertEqual(1);
        expect(result.episode.episodeNumber).assertEqual(1);
      }
      expect(fake.getCallCount('fetchSeason')).assertEqual(1);
      expect(fake.getCallCount('fetchEpisode')).assertEqual(1);
      const seasonCall = fake.getLastCall('fetchSeason');
      expect(seasonCall !== null).assertTrue();
      if (seasonCall !== null) {
        expect(seasonCall.seasonNumber).assertEqual(1);
      }
    });
  });

}
