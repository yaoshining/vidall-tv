import http from '@ohos.net.http';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppPreferences, PrefKey } from '../utils/AppPreferences';

// ─────────────────────────────────────────────
// 公共数据结构
// ─────────────────────────────────────────────

export interface ScrapeCredit {
  name: string;
  role?: string;
  profilePath?: string;
  order?: number;
}

/** 搜索参数 */
export interface ScrapeQuery {
  title: string;
  year?: number;
  mediaType?: 'movie' | 'tv';
  language?: string;
  /** 解析出的季数（仅 tv）*/
  seasonNumber?: number;
  /** 解析出的集数（仅 tv）*/
  episodeNumber?: number;
}

/** 电影刮削结果 */
export interface MovieScrapeResult {
  provider: string;
  providerId: string;
  title: string;
  originalTitle?: string;
  overview?: string;
  releaseDate?: string;
  rating?: number;
  voteCount?: number;
  posterPath?: string;
  backdropPath?: string;
  posterUrl?: string;
  backdropUrl?: string;
  genresJson?: string;
  castJson?: string;
  directorsJson?: string;
  runtime?: number;
  originalLanguage?: string;
  rawJson?: string;
}

/** 电视剧刮削结果（剧级别）*/
export interface TvSeriesScrapeResult {
  provider: string;
  providerId: string;
  title: string;
  originalTitle?: string;
  overview?: string;
  firstAirDate?: string;
  rating?: number;
  voteCount?: number;
  posterPath?: string;
  backdropPath?: string;
  posterUrl?: string;
  backdropUrl?: string;
  genresJson?: string;
  castJson?: string;
  numberOfSeasons?: number;
  originalLanguage?: string;
  rawJson?: string;
}

/** 季刮削结果 */
export interface TvSeasonScrapeResult {
  provider: string;
  /** 格式：{seriesProviderId}_s{seasonNumber} */
  providerId: string;
  seasonNumber: number;
  title?: string;
  overview?: string;
  airDate?: string;
  episodeCount?: number;
  posterPath?: string;
  posterUrl?: string;
  rawJson?: string;
}

/** 集刮削结果 */
export interface TvEpisodeScrapeResult {
  provider: string;
  /** TMDB episode id */
  providerId: string;
  seasonNumber: number;
  episodeNumber: number;
  title?: string;
  overview?: string;
  airDate?: string;
  runtime?: number;
  rating?: number;
  stillPath?: string;
  stillUrl?: string;
  rawJson?: string;
}

/** autoScrapeTvEpisode 的返回值 */
export interface TvEpisodeScrapeBundle {
  series: TvSeriesScrapeResult | null;
  season: TvSeasonScrapeResult | null;
  episode: TvEpisodeScrapeResult | null;
}

// ─────────────────────────────────────────────
// 文件名解析
// ─────────────────────────────────────────────

export interface ParsedFileName {
  title: string;
  year?: number;
  mediaType: 'movie' | 'tv';
  seasonNumber?: number;
  episodeNumber?: number;
  language: string;
}

/**
 * 从视频文件名解析标题、年份、媒体类型、季集信息
 * 例：权力的游戏.Game.of.Thrones.S07E01.mkv → { title: '权力的游戏 Game of Thrones', mediaType: 'tv', seasonNumber: 7, episodeNumber: 1 }
 * 例：Inception.2010.1080p.mkv              → { title: 'Inception', year: 2010, mediaType: 'movie' }
 */
export function parseFileName(fileName: string): ParsedFileName {
  const withoutExt = fileName.replace(/\.[^.]+$/, '');

  // 年份
  const yearPattern = /[.\[(]((?:19|20)\d{2})[.)\]]/;
  const yearMatch = withoutExt.match(yearPattern);
  const year = yearMatch ? parseInt(yearMatch[1]) : undefined;

  // 季集
  const episodeMatch = withoutExt.match(/[Ss](\d{1,2})[Ee](\d{1,3})/);
  const seasonNumber = episodeMatch ? parseInt(episodeMatch[1]) : undefined;
  const episodeNumber = episodeMatch ? parseInt(episodeMatch[2]) : undefined;
  const mediaType: 'movie' | 'tv' = episodeMatch ? 'tv' : 'movie';

  let workStr = withoutExt;
  workStr = workStr.replace(new RegExp(yearPattern.source, 'g'), ' ');
  workStr = workStr.replace(/[Ss]\d{1,2}[Ee]\d{1,3}.*/gi, '');

  const qualityPattern = /\b(1080p|720p|4k|2160p|480p|uhd|hdr|hdr10|hdr10plus|bluray|blu-ray|web-?dl|webrip|hdtv|dvdrip|bdrip|x264|x265|hevc|h\.?264|h\.?265|aac|aac\d\.\d|dts|dts-?x|ddp?\d\.\d|dd5\.?1|ac3|atmos|truehd|remux|proper|repack|imax|dv|\d{1,2}bit|\d\.\d)\b/i;
  const qualityMatch = workStr.match(qualityPattern);
  if (qualityMatch && qualityMatch.index !== undefined) {
    workStr = workStr.substring(0, qualityMatch.index);
  }

  const title = workStr
    .replace(/[[\]()]/g, ' ')
    .replace(/[._-]/g, ' ')
    .replace(/\s{2,}/g, ' ')
    .trim();

  return { title, year, mediaType, seasonNumber, episodeNumber, language: 'zh-CN' };
}

/**
 * 从混合标题中生成候选搜索词列表（按优先级排序）
 *
 * 策略：
 * - 纯中文标题（无英文）：中文 → 完整标题
 * - 纯英文标题（无中文）：英文 → 完整标题
 * - 中英混合：只用英文部分，不加中文（中文搜索易命中歧义剧）
 *
 * 例："权力的游戏 Game of Thrones" → ["Game of Thrones"]
 * 例："权力的游戏" → ["权力的游戏"]
 * 例："Game of Thrones" → ["Game of Thrones"]
 */
export function buildSearchTitles(title: string): string[] {
  const candidates: string[] = [];
  const hasChinese = /[\u4e00-\u9fff\u3400-\u4dbf]/.test(title);
  const hasEnglish = /[A-Za-z]{2,}/.test(title);
  const englishMatch = title.match(/[A-Za-z][A-Za-z0-9\s''\-:,!?&.]+/);
  const englishPart = englishMatch ? englishMatch[0].trim() : '';
  const chineseMatch = title.match(/[\u4e00-\u9fff\u3400-\u4dbf\uff00-\uffef\u3000-\u303f：、。，！？《》【】「」\s]+/);
  const chinesePart = chineseMatch ? chineseMatch[0].trim() : '';

  if (hasChinese && hasEnglish) {
    // 混合：只用英文（精度高、不歧义）
    if (englishPart.length >= 2) {
      candidates.push(englishPart);
    } else {
      candidates.push(title.trim());
    }
  } else if (hasEnglish) {
    if (englishPart.length >= 2) { candidates.push(englishPart); }
    if (!candidates.includes(title.trim())) { candidates.push(title.trim()); }
  } else if (hasChinese) {
    if (chinesePart.length >= 1) { candidates.push(chinesePart); }
    if (!candidates.includes(title.trim())) { candidates.push(title.trim()); }
  } else {
    candidates.push(title.trim());
  }
  return candidates;
}

// ─────────────────────────────────────────────
// Provider 接口
// ─────────────────────────────────────────────

export interface IScrapeProvider {
  readonly id: string;
  isConfigured(): boolean;
  searchMovie(title: string, year?: number, language?: string): Promise<MovieScrapeResult[]>;
  searchTv(title: string, year?: number, language?: string): Promise<TvSeriesScrapeResult[]>;
  fetchMovieDetail(providerId: string, language?: string): Promise<MovieScrapeResult | null>;
  fetchTvSeriesDetail(providerId: string, language?: string): Promise<TvSeriesScrapeResult | null>;
  fetchSeason(seriesProviderId: string, seasonNumber: number, language?: string): Promise<TvSeasonScrapeResult | null>;
  fetchEpisode(seriesProviderId: string, seasonNumber: number, episodeNumber: number, language?: string): Promise<TvEpisodeScrapeResult | null>;
}

// ─────────────────────────────────────────────
// TMDB 内部类型
// ─────────────────────────────────────────────

const TMDB_BASE_URL = 'https://api.themoviedb.org/3';
/** 海报（垂直封面）：w500 适合列表卡片 */
const TMDB_IMAGE_BASE = 'https://image.tmdb.org/t/p/w500';
/** 背景图（横幅）：w1280 适合TV大屏全屏展示 */
const TMDB_BACKDROP_BASE = 'https://image.tmdb.org/t/p/w1280';
/** 剧集缩略图 */
const TMDB_STILL_BASE = 'https://image.tmdb.org/t/p/w300';
/** 季海报 */
const TMDB_SEASON_POSTER_BASE = 'https://image.tmdb.org/t/p/w342';

interface TmdbSearchItem {
  id: number;
  title?: string;
  name?: string;
  original_title?: string;
  original_name?: string;
  overview?: string;
  release_date?: string;
  first_air_date?: string;
  vote_average?: number;
  vote_count?: number;
  poster_path?: string;
  backdrop_path?: string;
  original_language?: string;
}

interface TmdbCastItem {
  name?: string;
  character?: string;
  profile_path?: string;
  order?: number;
}

interface TmdbCrewItem {
  name?: string;
  job?: string;
  profile_path?: string;
}

interface TmdbGenre {
  id: number;
  name: string;
}

interface TmdbCredits {
  cast?: TmdbCastItem[];
  crew?: TmdbCrewItem[];
}

interface TmdbMovieDetail {
  id: number;
  title?: string;
  original_title?: string;
  overview?: string;
  release_date?: string;
  vote_average?: number;
  vote_count?: number;
  poster_path?: string;
  backdrop_path?: string;
  genres?: TmdbGenre[];
  original_language?: string;
  runtime?: number;
  credits?: TmdbCredits;
}

interface TmdbTvDetail {
  id: number;
  name?: string;
  original_name?: string;
  overview?: string;
  first_air_date?: string;
  vote_average?: number;
  vote_count?: number;
  poster_path?: string;
  backdrop_path?: string;
  genres?: TmdbGenre[];
  original_language?: string;
  number_of_seasons?: number;
  episode_run_time?: number[];
  credits?: TmdbCredits;
}

interface TmdbSeasonDetail {
  id: number;
  name?: string;
  overview?: string;
  air_date?: string;
  season_number?: number;
  episodes?: TmdbEpisodeItem[];
  poster_path?: string;
}

interface TmdbEpisodeItem {
  id: number;
  name?: string;
  overview?: string;
  air_date?: string;
  season_number?: number;
  episode_number?: number;
  runtime?: number;
  vote_average?: number;
  still_path?: string;
}

interface TmdbSearchResponse {
  results?: TmdbSearchItem[];
}

// ─────────────────────────────────────────────
// TMDB Provider
// ─────────────────────────────────────────────

export class TmdbProvider implements IScrapeProvider {
  readonly id = 'tmdb';
  private apiKey: string;
  /** 上次发出请求的时间戳（ms），用于限速控制 */
  private lastRequestTs: number = 0;
  /** 请求间最小间隔 250ms，即 ≤4 req/s，远低于 TMDB 40 req/10s 上限 */
  private static readonly MIN_REQUEST_INTERVAL_MS = 250;

  constructor(apiKey: string) {
    this.apiKey = apiKey;
  }

  isConfigured(): boolean {
    return this.apiKey.trim().length > 0;
  }

  async searchMovie(title: string, year?: number, language: string = 'zh-CN'): Promise<MovieScrapeResult[]> {
    let url = `${TMDB_BASE_URL}/search/movie?api_key=${this.apiKey}&language=${language}&query=${encodeURIComponent(title)}`;
    if (year) { url += `&year=${year}`; }
    const rawJson = await this.httpGet(url);
    const data = JSON.parse(rawJson) as TmdbSearchResponse;
    const items = (data.results ?? []).slice(0, 5);
    return items.map(item => {
      const r: MovieScrapeResult = {
        provider: this.id,
        providerId: String(item.id),
        title: item.title ?? '',
        originalTitle: item.original_title ?? undefined,
        overview: item.overview ?? undefined,
        releaseDate: item.release_date ?? undefined,
        rating: item.vote_average ?? undefined,
        voteCount: item.vote_count ?? undefined,
        posterPath: item.poster_path ?? undefined,
        backdropPath: item.backdrop_path ?? undefined,
        posterUrl: item.poster_path ? `${TMDB_IMAGE_BASE}${item.poster_path}` : undefined,
        backdropUrl: item.backdrop_path ? `${TMDB_BACKDROP_BASE}${item.backdrop_path}` : undefined,
        originalLanguage: item.original_language ?? undefined,
        rawJson
      };
      return r;
    });
  }

  async searchTv(title: string, year?: number, language: string = 'zh-CN'): Promise<TvSeriesScrapeResult[]> {
    let url = `${TMDB_BASE_URL}/search/tv?api_key=${this.apiKey}&language=${language}&query=${encodeURIComponent(title)}`;
    if (year) { url += `&year=${year}`; }
    const rawJson = await this.httpGet(url);
    const data = JSON.parse(rawJson) as TmdbSearchResponse;
    const items = (data.results ?? []).slice(0, 5);
    return items.map(item => {
      const r: TvSeriesScrapeResult = {
        provider: this.id,
        providerId: String(item.id),
        title: item.name ?? '',
        originalTitle: item.original_name ?? undefined,
        overview: item.overview ?? undefined,
        firstAirDate: item.first_air_date ?? undefined,
        rating: item.vote_average ?? undefined,
        voteCount: item.vote_count ?? undefined,
        posterPath: item.poster_path ?? undefined,
        backdropPath: item.backdrop_path ?? undefined,
        posterUrl: item.poster_path ? `${TMDB_IMAGE_BASE}${item.poster_path}` : undefined,
        backdropUrl: item.backdrop_path ? `${TMDB_BACKDROP_BASE}${item.backdrop_path}` : undefined,
        originalLanguage: item.original_language ?? undefined,
        rawJson
      };
      return r;
    });
  }

  async fetchMovieDetail(providerId: string, language: string = 'zh-CN'): Promise<MovieScrapeResult | null> {
    const url = `${TMDB_BASE_URL}/movie/${providerId}?api_key=${this.apiKey}&language=${language}&append_to_response=credits`;
    const rawJson = await this.httpGet(url);
    const item = JSON.parse(rawJson) as TmdbMovieDetail;
    const cast: ScrapeCredit[] = (item.credits?.cast ?? []).slice(0, 20).map(c => {
      const cr: ScrapeCredit = { name: c.name ?? '', role: c.character, profilePath: c.profile_path ?? undefined, order: c.order };
      return cr;
    });
    const directors: ScrapeCredit[] = (item.credits?.crew ?? []).filter(c => c.job === 'Director').map(c => {
      const cr: ScrapeCredit = { name: c.name ?? '', role: c.job, profilePath: c.profile_path ?? undefined };
      return cr;
    });
    const r: MovieScrapeResult = {
      provider: this.id,
      providerId: String(item.id),
      title: item.title ?? '',
      originalTitle: item.original_title ?? undefined,
      overview: item.overview ?? undefined,
      releaseDate: item.release_date ?? undefined,
      rating: item.vote_average ?? undefined,
      voteCount: item.vote_count ?? undefined,
      posterPath: item.poster_path ?? undefined,
      backdropPath: item.backdrop_path ?? undefined,
      posterUrl: item.poster_path ? `${TMDB_IMAGE_BASE}${item.poster_path}` : undefined,
      backdropUrl: item.backdrop_path ? `${TMDB_BACKDROP_BASE}${item.backdrop_path}` : undefined,
      genresJson: item.genres && item.genres.length > 0 ? JSON.stringify(item.genres.map(g => g.name)) : undefined,
      castJson: cast.length > 0 ? JSON.stringify(cast) : undefined,
      directorsJson: directors.length > 0 ? JSON.stringify(directors) : undefined,
      runtime: item.runtime ?? undefined,
      originalLanguage: item.original_language ?? undefined,
      rawJson
    };
    return r;
  }

  async fetchTvSeriesDetail(providerId: string, language: string = 'zh-CN'): Promise<TvSeriesScrapeResult | null> {
    const url = `${TMDB_BASE_URL}/tv/${providerId}?api_key=${this.apiKey}&language=${language}&append_to_response=credits`;
    const rawJson = await this.httpGet(url);
    const item = JSON.parse(rawJson) as TmdbTvDetail;
    const cast: ScrapeCredit[] = (item.credits?.cast ?? []).slice(0, 20).map(c => {
      const cr: ScrapeCredit = { name: c.name ?? '', role: c.character, profilePath: c.profile_path ?? undefined, order: c.order };
      return cr;
    });
    const r: TvSeriesScrapeResult = {
      provider: this.id,
      providerId: String(item.id),
      title: item.name ?? '',
      originalTitle: item.original_name ?? undefined,
      overview: item.overview ?? undefined,
      firstAirDate: item.first_air_date ?? undefined,
      rating: item.vote_average ?? undefined,
      voteCount: item.vote_count ?? undefined,
      posterPath: item.poster_path ?? undefined,
      backdropPath: item.backdrop_path ?? undefined,
      posterUrl: item.poster_path ? `${TMDB_IMAGE_BASE}${item.poster_path}` : undefined,
      backdropUrl: item.backdrop_path ? `${TMDB_BACKDROP_BASE}${item.backdrop_path}` : undefined,
      genresJson: item.genres && item.genres.length > 0 ? JSON.stringify(item.genres.map(g => g.name)) : undefined,
      castJson: cast.length > 0 ? JSON.stringify(cast) : undefined,
      numberOfSeasons: item.number_of_seasons ?? undefined,
      originalLanguage: item.original_language ?? undefined,
      rawJson
    };
    return r;
  }

  async fetchSeason(seriesProviderId: string, seasonNumber: number, language: string = 'zh-CN'): Promise<TvSeasonScrapeResult | null> {
    const url = `${TMDB_BASE_URL}/tv/${seriesProviderId}/season/${seasonNumber}?api_key=${this.apiKey}&language=${language}`;
    const rawJson = await this.httpGet(url);
    const item = JSON.parse(rawJson) as TmdbSeasonDetail;
    const r: TvSeasonScrapeResult = {
      provider: this.id,
      providerId: `${seriesProviderId}_s${seasonNumber}`,
      seasonNumber,
      title: item.name ?? undefined,
      overview: item.overview ?? undefined,
      airDate: item.air_date ?? undefined,
      episodeCount: item.episodes ? item.episodes.length : undefined,
      posterPath: item.poster_path ?? undefined,
      posterUrl: item.poster_path ? `${TMDB_SEASON_POSTER_BASE}${item.poster_path}` : undefined,
      rawJson
    };
    return r;
  }

  async fetchEpisode(seriesProviderId: string, seasonNumber: number, episodeNumber: number, language: string = 'zh-CN'): Promise<TvEpisodeScrapeResult | null> {
    const url = `${TMDB_BASE_URL}/tv/${seriesProviderId}/season/${seasonNumber}/episode/${episodeNumber}?api_key=${this.apiKey}&language=${language}`;
    const rawJson = await this.httpGet(url);
    const item = JSON.parse(rawJson) as TmdbEpisodeItem;
    const r: TvEpisodeScrapeResult = {
      provider: this.id,
      providerId: String(item.id),
      seasonNumber,
      episodeNumber,
      title: item.name ?? undefined,
      overview: item.overview ?? undefined,
      airDate: item.air_date ?? undefined,
      runtime: item.runtime ?? undefined,
      rating: item.vote_average ?? undefined,
      stillPath: item.still_path ?? undefined,
      stillUrl: item.still_path ? `${TMDB_STILL_BASE}${item.still_path}` : undefined,
      rawJson
    };
    return r;
  }

  private async httpGet(url: string): Promise<string> {
    const maxRetries = 3;
    let lastError: Error = new Error('未知错误');
    for (let attempt = 0; attempt < maxRetries; attempt++) {
      // 请求频率限制：确保上次请求后至少间隔 MIN_REQUEST_INTERVAL_MS
      const now = Date.now();
      const elapsed = now - this.lastRequestTs;
      if (elapsed < TmdbProvider.MIN_REQUEST_INTERVAL_MS) {
        await new Promise<void>((resolve) => setTimeout(resolve, TmdbProvider.MIN_REQUEST_INTERVAL_MS - elapsed));
      }
      this.lastRequestTs = Date.now();

      if (attempt > 0) {
        // 重试额外等待：1s, 2s
        await new Promise<void>((resolve) => setTimeout(resolve, 1000 * attempt));
      }
      const req = http.createHttp();
      try {
        const resp = await req.request(url, {
          method: http.RequestMethod.GET,
          header: { 'Accept': 'application/json' },
          connectTimeout: 15000,
          readTimeout: 15000
        });
        if (resp.responseCode === 429) {
          console.warn(`[TmdbProvider] 限速 429，第 ${attempt + 1} 次重试: ${url}`);
          req.destroy();
          lastError = new Error(`TMDB 429 限速`);
          continue;
        }
        if (resp.responseCode !== 200) {
          req.destroy();
          throw new Error(`TMDB HTTP ${resp.responseCode}`);
        }
        req.destroy();
        return resp.result as string;
      } catch (e) {
        req.destroy();
        const err = e as BusinessError;
        lastError = new Error(`TMDB 请求失败: ${err.message ?? JSON.stringify(e)}`);
        if (attempt < maxRetries - 1) {
          console.warn(`[TmdbProvider] 请求异常，第 ${attempt + 1} 次重试: ${lastError.message}`);
        }
      }
    }
    throw lastError;
  }
}

// ─────────────────────────────────────────────
// ScrapeClient — 统一入口
// ─────────────────────────────────────────────

export interface ScrapeClientConfig {
  tmdbApiKey?: string;
}

export class ScrapeClient {
  private providers: Map<string, IScrapeProvider> = new Map();
  private runningCount: number = 0;
  private waitQueue: Array<() => void> = [];

  constructor(config: ScrapeClientConfig) {
    if (config.tmdbApiKey && config.tmdbApiKey.trim().length > 0) {
      this.registerProvider(new TmdbProvider(config.tmdbApiKey));
    }
  }

  registerProvider(provider: IScrapeProvider): void {
    this.providers.set(provider.id, provider);
  }

  getProviderIds(): string[] {
    return Array.from(this.providers.keys());
  }

  /** 搜索电影，返回第一个命中的详情 */
  async autoScrapeMovie(fileName: string): Promise<MovieScrapeResult | null> {
    const parsed = parseFileName(fileName);
    await this.acquire();
    try {
      for (const provider of this.getActiveProviders()) {
        try {
          const searchTitles = buildSearchTitles(parsed.title);
          for (const candidate of searchTitles) {
            const results = await provider.searchMovie(candidate, parsed.year, 'zh-CN');
            if (results.length > 0) {
              console.info(`[ScrapeClient] autoScrapeMovie 命中候选标题="${candidate}" providerId=${results[0].providerId}`);
              return await provider.fetchMovieDetail(results[0].providerId, 'zh-CN');
            }
          }
        } catch (e) {
          console.warn(`[ScrapeClient] searchMovie provider=${provider.id} 失败: ${JSON.stringify(e)}`);
        }
      }
      return null;
    } finally {
      this.releaseSlot();
    }
  }

  /**
   * 自动刮削电视剧集
   * 返回 TvEpisodeScrapeBundle，每项均可能为 null（查不到时）
   */
  async autoScrapeTvEpisode(fileName: string): Promise<TvEpisodeScrapeBundle> {
    const parsed = parseFileName(fileName);
    const empty: TvEpisodeScrapeBundle = { series: null, season: null, episode: null };
    if (parsed.mediaType !== 'tv') {
      console.warn(`[ScrapeClient] autoScrapeTvEpisode 跳过: mediaType=${parsed.mediaType} title="${parsed.title}" file=${fileName}`);
      return empty;
    }
    console.info(`[ScrapeClient] autoScrapeTvEpisode 开始: file="${fileName}" → title="${parsed.title}" S${parsed.seasonNumber ?? '?'}E${parsed.episodeNumber ?? '?'} year=${parsed.year ?? '?'}`);
    const searchTitlesLog = buildSearchTitles(parsed.title);
    console.info(`[ScrapeClient] autoScrapeTvEpisode 候选标题: ${JSON.stringify(searchTitlesLog)}`);

    await this.acquire();
    try {
      for (const provider of this.getActiveProviders()) {
        try {
          const searchTitles = buildSearchTitles(parsed.title);
          let topSearch: TvSeriesScrapeResult | null = null;
          for (const candidate of searchTitles) {
            // 第一轮：带年份搜索（year= 参数，过滤精确）
            let results = await provider.searchTv(candidate, parsed.year, 'zh-CN');
            console.info(`[ScrapeClient] searchTv("${candidate}" year=${parsed.year ?? 'none'}) → ${results.length} 条结果${results.length > 0 ? ' 首条: ' + results[0].title + '(id=' + results[0].providerId + ')' : ''}`);
            // 第二轮：带年份无结果时，降级为只用剧名搜索
            if (results.length === 0 && parsed.year !== undefined) {
              results = await provider.searchTv(candidate, undefined, 'zh-CN');
              console.info(`[ScrapeClient] searchTv("${candidate}" 无年份降级) → ${results.length} 条结果${results.length > 0 ? ' 首条: ' + results[0].title + '(id=' + results[0].providerId + ')' : ''}`);
            }
            if (results.length > 0) {
              topSearch = results[0];
              console.info(`[ScrapeClient] autoScrapeTvEpisode 命中候选标题="${candidate}" providerId=${topSearch.providerId}`);
              break;
            }
          }
          if (!topSearch) {
            console.warn(`[ScrapeClient] autoScrapeTvEpisode 所有候选标题均无结果，跳过 provider=${provider.id}`);
            continue;
          }
          const series = await provider.fetchTvSeriesDetail(topSearch.providerId, 'zh-CN');
          if (!series) {
            console.warn(`[ScrapeClient] autoScrapeTvEpisode fetchTvSeriesDetail(${topSearch.providerId}) 返回 null`);
            continue;
          }
          console.info(`[ScrapeClient] autoScrapeTvEpisode fetchTvSeriesDetail OK: title="${series.title}" posterUrl=${series.posterUrl ? 'Y' : 'N'}`);

          let season: TvSeasonScrapeResult | null = null;
          let episode: TvEpisodeScrapeResult | null = null;

          if (parsed.seasonNumber !== undefined) {
            season = await provider.fetchSeason(series.providerId, parsed.seasonNumber, 'zh-CN').catch((e: BusinessError) => {
              console.warn(`[ScrapeClient] fetchSeason(${series.providerId}, ${parsed.seasonNumber}) 失败: ${JSON.stringify(e)}`);
              return null;
            });
            console.info(`[ScrapeClient] fetchSeason S${parsed.seasonNumber} → ${season ? 'OK posterUrl=' + (season.posterUrl ? 'Y' : 'N') : 'null'}`);
            if (parsed.episodeNumber !== undefined) {
              episode = await provider.fetchEpisode(series.providerId, parsed.seasonNumber, parsed.episodeNumber, 'zh-CN').catch((e: BusinessError) => {
                console.warn(`[ScrapeClient] fetchEpisode(${series.providerId}, S${parsed.seasonNumber}E${parsed.episodeNumber}) 失败: ${JSON.stringify(e)}`);
                return null;
              });
              console.info(`[ScrapeClient] fetchEpisode E${parsed.episodeNumber} → ${episode ? 'OK title="' + (episode.title ?? '') + '"' : 'null'}`);
            }
          }

          const bundle: TvEpisodeScrapeBundle = { series, season, episode };
          return bundle;
        } catch (e) {
          console.warn(`[ScrapeClient] autoScrapeTvEpisode provider=${provider.id} 失败: ${JSON.stringify(e)}`);
        }
      }
      return empty;
    } finally {
      this.releaseSlot();
    }
  }

  /** 直接拉取电视剧详情（已知 providerId） */
  async fetchTvSeriesDetail(providerId: string, provider: string = 'tmdb'): Promise<TvSeriesScrapeResult | null> {
    const p = this.providers.get(provider);
    if (!p) { return null; }
    await this.acquire();
    try {
      return await p.fetchTvSeriesDetail(providerId, 'zh-CN');
    } finally {
      this.releaseSlot();
    }
  }

  /** 直接拉取季详情 */
  async fetchSeason(seriesProviderId: string, seasonNumber: number, provider: string = 'tmdb'): Promise<TvSeasonScrapeResult | null> {
    const p = this.providers.get(provider);
    if (!p) { return null; }
    await this.acquire();
    try {
      return await p.fetchSeason(seriesProviderId, seasonNumber, 'zh-CN');
    } finally {
      this.releaseSlot();
    }
  }

  /** 直接拉取集详情 */
  async fetchEpisode(seriesProviderId: string, seasonNumber: number, episodeNumber: number, provider: string = 'tmdb'): Promise<TvEpisodeScrapeResult | null> {
    const p = this.providers.get(provider);
    if (!p) { return null; }
    await this.acquire();
    try {
      return await p.fetchEpisode(seriesProviderId, seasonNumber, episodeNumber, 'zh-CN');
    } finally {
      this.releaseSlot();
    }
  }

  private getActiveProviders(): IScrapeProvider[] {
    const result: IScrapeProvider[] = [];
    this.providers.forEach((p) => { if (p.isConfigured()) { result.push(p); } });
    return result;
  }

  private async acquire(): Promise<void> {
    const maxConcurrent = await AppPreferences.getNumber(PrefKey.SCRAPE_CONCURRENCY, 2);
    if (this.runningCount < maxConcurrent) {
      this.runningCount++;
      return Promise.resolve();
    }
    return new Promise<void>((resolve) => {
      this.waitQueue.push(resolve);
    });
  }

  private releaseSlot(): void {
    this.runningCount--;
    if (this.waitQueue.length > 0) {
      const next = this.waitQueue.shift()!;
      this.runningCount++;
      next();
    }
  }
}


