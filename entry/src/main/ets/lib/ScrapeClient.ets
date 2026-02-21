import http from '@ohos.net.http';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppPreferences, PrefKey } from '../utils/AppPreferences';

// ─────────────────────────────────────────────
// 刮削数据结构
// ─────────────────────────────────────────────

/** 演员 / 工作人员 */
export interface ScrapeCredit {
  name: string;
  role?: string;
  profilePath?: string;
  order?: number;
}

/** 刮削结果 */
export interface ScrapeResult {
  provider: string;
  providerId: string;
  mediaType: 'movie' | 'tv' | 'episode' | 'unknown';
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
  genres?: string[];
  cast?: ScrapeCredit[];
  directors?: ScrapeCredit[];
  seasonNumber?: number;
  episodeNumber?: number;
  originalLanguage?: string;
  runtime?: number;
  rawJson?: string;
}

/** 搜索参数 */
export interface ScrapeQuery {
  title: string;
  year?: number;
  mediaType?: 'movie' | 'tv';
  language?: string;
}

/**
 * 刮削提供商接口
 * 新增数据源只需实现此接口并调用 ScrapeClient.registerProvider() 注册
 */
export interface IScrapeProvider {
  readonly id: string;
  isConfigured(): boolean;
  search(query: ScrapeQuery): Promise<ScrapeResult[]>;
  fetchDetail(providerId: string, mediaType: 'movie' | 'tv', language?: string): Promise<ScrapeResult | null>;
}

// ─────────────────────────────────────────────
// 工具函数
// ─────────────────────────────────────────────

/**
 * 从视频文件名解析标题、年份、媒体类型
 * 例：Inception.2010.1080p.BluRay.mkv  → { title: 'Inception', year: 2010, mediaType: 'movie' }
 * 例：S02E03.Useful.Occupations.mkv    → { title: 'Useful Occupations', mediaType: 'tv' }
 */
export function parseFileName(fileName: string): ScrapeQuery {
  const withoutExt = fileName.replace(/\.[^.]+$/, '');
  const yearMatch = withoutExt.match(/[.(]((?:19|20)\d{2})[.)]/);
  const year = yearMatch ? parseInt(yearMatch[1]) : undefined;
  const episodeMatch = withoutExt.match(/S(\d{1,2})E(\d{1,2})/i);
  const mediaType: 'movie' | 'tv' = episodeMatch ? 'tv' : 'movie';
  let title = withoutExt
    .replace(/[.(]((?:19|20)\d{2})[.)]/g, ' ')
    .replace(/S\d{1,2}E\d{1,2}.*/gi, '')
    .replace(/\b(1080p|720p|4k|2160p|480p|uhd|hdr|bluray|blu-ray|web-?dl|webrip|hdtv|dvdrip|bdrip|x264|x265|hevc|h\.?264|h\.?265|aac|dts|ac3|dd5\.1|atmos|truehd|remux|proper|repack)\b/gi, ' ')
    .replace(/[[\]()]/g, ' ')
    .replace(/[._-]/g, ' ')
    .replace(/\s{2,}/g, ' ')
    .trim();
  return { title, year, mediaType, language: 'zh-CN' };
}

// ─────────────────────────────────────────────
// TMDB 内部类型
// ─────────────────────────────────────────────

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

interface TmdbDetailResult {
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
  genres?: TmdbGenre[];
  original_language?: string;
  runtime?: number;
  episode_run_time?: number[];
  credits?: TmdbCredits;
}

interface TmdbSearchResponse {
  results?: TmdbSearchItem[];
}

// ─────────────────────────────────────────────
// TMDB Provider
// ─────────────────────────────────────────────

const TMDB_BASE_URL = 'https://api.themoviedb.org/3';
const TMDB_IMAGE_BASE_URL = 'https://image.tmdb.org/t/p/w500';

export class TmdbProvider implements IScrapeProvider {
  readonly id = 'tmdb';
  private apiKey: string;

  constructor(apiKey: string) {
    this.apiKey = apiKey;
  }

  isConfigured(): boolean {
    return this.apiKey.trim().length > 0;
  }

  async search(query: ScrapeQuery): Promise<ScrapeResult[]> {
    const lang = query.language ?? 'zh-CN';
    const type = query.mediaType ?? 'movie';
    const endpoint = type === 'tv' ? 'search/tv' : 'search/movie';
    let url = `${TMDB_BASE_URL}/${endpoint}?api_key=${this.apiKey}&language=${lang}&query=${encodeURIComponent(query.title)}`;
    if (query.year) {
      url += type === 'tv' ? `&first_air_date_year=${query.year}` : `&year=${query.year}`;
    }
    console.info(`[TmdbProvider] 搜索 type=${type} title="${query.title}" year=${query.year ?? '-'}`);
    const rawJson = await this.httpGet(url);
    const data = JSON.parse(rawJson) as TmdbSearchResponse;
    const items = data.results ?? [];
    console.info(`[TmdbProvider] 搜索结果 ${items.length} 条`);
    return items.slice(0, 5).map(item => this.mapSearchItem(item, type, rawJson));
  }

  async fetchDetail(providerId: string, mediaType: 'movie' | 'tv', language: string = 'zh-CN'): Promise<ScrapeResult | null> {
    const endpoint = mediaType === 'tv' ? `tv/${providerId}` : `movie/${providerId}`;
    const url = `${TMDB_BASE_URL}/${endpoint}?api_key=${this.apiKey}&language=${language}&append_to_response=credits`;
    console.info(`[TmdbProvider] 拉详情 id=${providerId} type=${mediaType}`);
    const rawJson = await this.httpGet(url);
    const item = JSON.parse(rawJson) as TmdbDetailResult;
    return this.mapDetail(item, mediaType, rawJson);
  }

  private mapSearchItem(item: TmdbSearchItem, mediaType: 'movie' | 'tv', rawJson: string): ScrapeResult {
    const posterUrl = item.poster_path ? `${TMDB_IMAGE_BASE_URL}${item.poster_path}` : undefined;
    const backdropUrl = item.backdrop_path ? `${TMDB_IMAGE_BASE_URL}${item.backdrop_path}` : undefined;
    return {
      provider: this.id,
      providerId: String(item.id),
      mediaType,
      title: (mediaType === 'tv' ? item.name : item.title) ?? '',
      originalTitle: (mediaType === 'tv' ? item.original_name : item.original_title) ?? undefined,
      overview: item.overview ?? undefined,
      releaseDate: (mediaType === 'tv' ? item.first_air_date : item.release_date) ?? undefined,
      rating: item.vote_average ?? undefined,
      voteCount: item.vote_count ?? undefined,
      posterPath: item.poster_path ?? undefined,
      backdropPath: item.backdrop_path ?? undefined,
      posterUrl,
      backdropUrl,
      originalLanguage: item.original_language ?? undefined,
      rawJson
    };
  }

  private mapDetail(item: TmdbDetailResult, mediaType: 'movie' | 'tv', rawJson: string): ScrapeResult {
    const posterUrl = item.poster_path ? `${TMDB_IMAGE_BASE_URL}${item.poster_path}` : undefined;
    const backdropUrl = item.backdrop_path ? `${TMDB_IMAGE_BASE_URL}${item.backdrop_path}` : undefined;
    const cast: ScrapeCredit[] = (item.credits?.cast ?? []).slice(0, 20).map(c => {
      const credit: ScrapeCredit = {
        name: c.name ?? '',
        role: c.character ?? undefined,
        profilePath: c.profile_path ?? undefined,
        order: c.order ?? undefined
      };
      return credit;
    });
    const directors: ScrapeCredit[] = (item.credits?.crew ?? [])
      .filter(c => c.job === 'Director')
      .map(c => {
        const credit: ScrapeCredit = {
          name: c.name ?? '',
          role: c.job ?? undefined,
          profilePath: c.profile_path ?? undefined
        };
        return credit;
      });
    const genres: string[] = (item.genres ?? []).map(g => g.name);
    const runtimeVal = mediaType === 'tv'
      ? (item.episode_run_time && item.episode_run_time.length > 0 ? item.episode_run_time[0] : undefined)
      : item.runtime;
    return {
      provider: this.id,
      providerId: String(item.id),
      mediaType,
      title: (mediaType === 'tv' ? item.name : item.title) ?? '',
      originalTitle: (mediaType === 'tv' ? item.original_name : item.original_title) ?? undefined,
      overview: item.overview ?? undefined,
      releaseDate: (mediaType === 'tv' ? item.first_air_date : item.release_date) ?? undefined,
      rating: item.vote_average ?? undefined,
      voteCount: item.vote_count ?? undefined,
      posterPath: item.poster_path ?? undefined,
      backdropPath: item.backdrop_path ?? undefined,
      posterUrl,
      backdropUrl,
      genres: genres.length > 0 ? genres : undefined,
      cast: cast.length > 0 ? cast : undefined,
      directors: directors.length > 0 ? directors : undefined,
      originalLanguage: item.original_language ?? undefined,
      runtime: runtimeVal,
      rawJson
    };
  }

  private async httpGet(url: string): Promise<string> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: { 'Accept': 'application/json' },
        connectTimeout: 15000,
        readTimeout: 15000
      });
      if (resp.responseCode !== 200) {
        throw new Error(`TMDB HTTP ${resp.responseCode}`);
      }
      return resp.result as string;
    } catch (e) {
      const err = e as BusinessError;
      throw new Error(`TMDB 请求失败: ${err.message ?? JSON.stringify(e)}`);
    } finally {
      req.destroy();
    }
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
    console.info(`[ScrapeClient] 注册 provider: ${provider.id}`);
  }

  getProviderIds(): string[] {
    return Array.from(this.providers.keys());
  }

  async search(query: ScrapeQuery, providerOrder?: string[]): Promise<ScrapeResult[]> {
    const order = providerOrder ?? await this.loadProviderOrder();
    const orderedProviders = this.getOrderedProviders(order);
    console.info(`[ScrapeClient] 搜索 title="${query.title}" providers=[${orderedProviders.map(p => p.id).join(',')}]`);
    for (const provider of orderedProviders) {
      await this.acquire();
      try {
        const results = await provider.search(query);
        if (results.length > 0) {
          console.info(`[ScrapeClient] provider=${provider.id} 命中 ${results.length} 条`);
          return results;
        }
        console.info(`[ScrapeClient] provider=${provider.id} 无结果，继续`);
      } catch (e) {
        const err = e as BusinessError;
        console.warn(`[ScrapeClient] provider=${provider.id} 失败: ${err.message ?? JSON.stringify(e)}`);
      } finally {
        this.releaseSlot();
      }
    }
    return [];
  }

  async fetchDetail(
    providerId: string,
    resourceId: string,
    mediaType: 'movie' | 'tv',
    language: string = 'zh-CN'
  ): Promise<ScrapeResult | null> {
    const provider = this.providers.get(providerId);
    if (!provider) {
      throw new Error(`[ScrapeClient] 未找到 Provider: ${providerId}`);
    }
    await this.acquire();
    try {
      return await provider.fetchDetail(resourceId, mediaType, language);
    } finally {
      this.releaseSlot();
    }
  }

  async autoScrape(fileName: string, providerOrder?: string[]): Promise<ScrapeResult | null> {
    const query = parseFileName(fileName);
    console.info(`[ScrapeClient] autoScrape "${fileName}" → title="${query.title}" year=${query.year ?? '-'} type=${query.mediaType}`);
    const results = await this.search(query, providerOrder);
    if (results.length === 0) {
      console.warn(`[ScrapeClient] autoScrape 无匹配: "${fileName}"`);
      return null;
    }
    const top = results[0];
    console.info(`[ScrapeClient] 命中 provider=${top.provider} id=${top.providerId} title="${top.title}"`);
    const mt: 'movie' | 'tv' = (top.mediaType === 'movie' || top.mediaType === 'tv') ? top.mediaType : 'movie';
    return this.fetchDetail(top.provider, top.providerId, mt, query.language ?? 'zh-CN');
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

  private async loadProviderOrder(): Promise<string[]> {
    const raw = await AppPreferences.get(PrefKey.SCRAPE_PROVIDER_ORDER, '["tmdb"]');
    try {
      return JSON.parse(raw) as string[];
    } catch {
      return ['tmdb'];
    }
  }

  private getOrderedProviders(order: string[]): IScrapeProvider[] {
    const all = Array.from(this.providers.values()).filter(p => p.isConfigured());
    const ordered: IScrapeProvider[] = [];
    for (const id of order) {
      const found = all.find(x => x.id === id);
      if (found) {
        ordered.push(found);
      }
    }
    for (const p of all) {
      if (!ordered.find(x => x.id === p.id)) {
        ordered.push(p);
      }
    }
    return ordered;
  }
}


