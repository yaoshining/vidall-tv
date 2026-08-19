import { JsonHttpClient } from './JsonHttpClient';
import {
  VideoServerLibrary,
  VideoServerMediaItem,
  VideoServerLatestSection,
  VideoServerHome,
  VideoServerItemDetail,
  VideoServerSeason,
  VideoServerEpisode,
  VideoServerPerson,
  VideoServerPersonDetail,
  VideoServerLibraryPage
} from './JellyfinClient';

/**
 * Plex 客户端配置（运行时解析，凭据已解密）
 */
export interface PlexClientConfig {
  protocol: 'http' | 'https';
  url: string;
  port: number;
  token: string;
}

export interface ConnectionTestResult {
  success: boolean;
  message: string;
}

/**
 * Plex 服务器客户端。实现「服务信息 / 顶层媒体库 / 首页分区」所需能力。
 */
export class PlexClient {
  private config: PlexClientConfig;
  private machineIdentifier: string = '';

  constructor(config: PlexClientConfig) {
    this.config = config;
  }

  static fromConfigJson(configJson: string): PlexClient {
    const raw = JSON.parse(configJson) as Record<string, string>;
    const protocol = (raw['protocol'] === 'https' ? 'https' : 'http');
    const port = parseInt(raw['port'] ?? '', 10);
    return new PlexClient({
      protocol,
      url: raw['url'] ?? '',
      port: isNaN(port) ? 32400 : port,
      token: raw['token'] ?? ''
    });
  }

  private buildBaseUrl(): string {
    const scheme = this.config.protocol;
    const host = this.config.url.trim();
    const port = this.config.port;
    const isStdPort = (scheme === 'https' && port === 443) || (scheme === 'http' && port === 80);
    const portStr = isStdPort ? '' : `:${port}`;
    return `${scheme}://${host}${portStr}`;
  }

  private headers(): Record<string, string> {
    return {
      'Accept': 'application/json',
      'X-Plex-Token': this.config.token
    };
  }

  async testConnection(): Promise<ConnectionTestResult> {
    try {
      await this.getLibraries();
      return { success: true, message: '连接成功' };
    } catch (e) {
      const message = (e as Error).message ?? '未知错误';
      return { success: false, message };
    }
  }

  async getLibraries(): Promise<VideoServerLibrary[]> {
    if (this.config.token.length === 0) {
      throw new Error('缺少 X-Plex-Token');
    }
    const resp = await JsonHttpClient.get(`${this.buildBaseUrl()}/library/sections`, this.headers());
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw new Error(JsonHttpClient.classifyError(resp.statusCode, '获取媒体库失败'));
    }
    const parsed = JSON.parse(resp.body) as Record<string, Object>;
    const mediaContainer = parsed['MediaContainer'] as Record<string, Object> | undefined;
    if (mediaContainer !== undefined) {
      const machineId = mediaContainer['machineIdentifier'];
      if (typeof machineId === 'string') {
        this.machineIdentifier = machineId;
      }
    }
    const dirs = mediaContainer?.['Directory'] as Array<Record<string, Object>> | undefined;
    const result: VideoServerLibrary[] = [];
    if (dirs) {
      for (const dir of dirs) {
        const title = (dir['title'] ?? '') as string;
        if (title.length > 0) {
          const composite = String(dir['composite'] ?? '');
          result.push({
            id: String(dir['key'] ?? dir['uuid'] ?? ''),
            name: title,
            type: (dir['type'] as string | undefined) ?? undefined,
            imageUrl: composite.length > 0 ? this.absoluteImageUrl(this.buildBaseUrl(), composite, this.config.token) : ''
          });
        }
      }
    }
    return result;
  }

  /**
   * 获取某个媒体库下的视频列表（分页）。
   */
  async getLibraryItems(libraryId: string, startIndex: number, limit: number): Promise<VideoServerLibraryPage> {
    const resp = await JsonHttpClient.get(
      `${this.buildBaseUrl()}/library/sections/${encodeURIComponent(libraryId)}/all` +
        `?X-Plex-Container-Start=${startIndex}&X-Plex-Container-Size=${limit}`,
      this.headers()
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw new Error(JsonHttpClient.classifyError(resp.statusCode, '获取媒体库内容失败'));
    }
    const parsed = JSON.parse(resp.body) as Record<string, Object>;
    const mediaContainer = parsed['MediaContainer'] as Record<string, Object> | undefined;
    const total = mediaContainer !== undefined ? (mediaContainer['totalSize'] as number | undefined ?? 0) : 0;
    const items = this.parseMetadata(resp.body);
    return { items, total };
  }

  /**
   * 构建在浏览器中打开的条目详情页 URL（用于「继续观看」直接播放）。
   */
  buildWebItemUrl(itemId: string): string {
    const base = this.buildBaseUrl();
    if (this.machineIdentifier.length > 0) {
      return `${base}/web/index.html#!/server/${this.machineIdentifier}/details?key=${itemId}`;
    }
    return `${base}/web/index.html`;
  }

  /**
   * 获取可在 App 播放器内直接播放的流地址（Plex 直连媒体文件）。
   */
  async getStreamUrl(itemId: string): Promise<string> {
    const resp = await JsonHttpClient.get(`${this.buildBaseUrl()}/library/metadata/${itemId}`, this.headers());
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw new Error(JsonHttpClient.classifyError(resp.statusCode, '获取播放地址失败'));
    }
    const parsed = JSON.parse(resp.body) as Record<string, Object>;
    const mediaContainer = parsed['MediaContainer'] as Record<string, Object> | undefined;
    const metadata = mediaContainer?.['Metadata'] as Array<Record<string, Object>> | undefined;
    if (metadata && metadata.length > 0) {
      const media = metadata[0]['Media'] as Array<Record<string, Object>> | undefined;
      if (media && media.length > 0) {
        const part = media[0]['Part'] as Array<Record<string, Object>> | undefined;
        if (part && part.length > 0) {
          const key = String(part[0]['key'] ?? '');
          if (key.length > 0) {
            return this.absoluteImageUrl(this.buildBaseUrl(), key, this.config.token);
          }
        }
      }
    }
    throw new Error('无法获取播放地址');
  }

  /**
   * 播放器请求所需的鉴权头。
   * 流地址已带 X-Plex-Token 查询参数，无需再传自定义头。
   */
  getStreamHeader(): Record<string, string> {
    return {};
  }

  /**
   * 上报播放开始。
   */
  async reportPlaying(itemId: string, positionMs: number, durationMs: number): Promise<void> {
    const url = `${this.buildBaseUrl()}/:/timeline?ratingKey=${itemId}&state=playing` +
      `&time=${Math.round(positionMs)}&duration=${Math.round(durationMs)}`;
    await JsonHttpClient.get(url, this.headers());
  }

  /**
   * 上报播放停止（退出播放器）时的进度，供服务器「继续观看」续播使用。
   */
  async reportStopped(itemId: string, positionMs: number, durationMs: number): Promise<void> {
    const url = `${this.buildBaseUrl()}/:/timeline?ratingKey=${itemId}&state=stopped` +
      `&time=${Math.round(positionMs)}&duration=${Math.round(durationMs)}`;
    await JsonHttpClient.get(url, this.headers());
  }

  /**
   * 周期性上报播放进度（Plex 以 state=playing 的 timeline 请求带 time 实现）。
   */
  async reportProgress(itemId: string, positionMs: number, durationMs: number): Promise<void> {
    const url = `${this.buildBaseUrl()}/:/timeline?ratingKey=${itemId}&state=playing` +
      `&time=${Math.round(positionMs)}&duration=${Math.round(durationMs)}`;
    await JsonHttpClient.get(url, this.headers());
  }

  async getHome(): Promise<VideoServerHome> {
    const baseUrl = this.buildBaseUrl();
    const headers = this.headers();

    // 继续观看（onDeck）
    let continueWatching: VideoServerMediaItem[] = [];
    try {
      const resp = await JsonHttpClient.get(`${baseUrl}/library/onDeck`, headers);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        continueWatching = this.parseMetadata(resp.body);
      }
    } catch (e) {
      console.warn('[PlexClient] onDeck 获取失败', (e as Error).message);
    }

    // 最近添加（按媒体库）
    const latest: VideoServerLatestSection[] = [];
    const libraries = await this.getLibraries();
    for (const lib of libraries) {
      try {
        const resp = await JsonHttpClient.get(
          `${baseUrl}/library/sections/${encodeURIComponent(lib.id)}/recentlyAdded`,
          headers
        );
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          const items = this.parseMetadata(resp.body);
          if (items.length > 0) {
            latest.push({ libraryName: lib.name, items });
          }
        }
      } catch (e) {
        console.warn(`[PlexClient] 媒体库 ${lib.name} 最近添加获取失败`, (e as Error).message);
      }
    }

    return { continueWatching, nextUp: [], latest };
  }

  private parseMetadata(body: string): VideoServerMediaItem[] {
    const parsed = JSON.parse(body) as Record<string, Object>;
    const mediaContainer = parsed['MediaContainer'] as Record<string, Object> | undefined;
    const items = mediaContainer?.['Metadata'] as Array<Record<string, Object>> | undefined;
    const result: VideoServerMediaItem[] = [];
    if (!items) {
      return result;
    }
    for (const item of items) {
      result.push(this.mapMetadataItem(item));
    }
    return result;
  }

  private mapMetadataItem(item: Record<string, Object>): VideoServerMediaItem {
    const baseUrl = this.buildBaseUrl();
    const token = this.config.token;
    const id = String(item['ratingKey'] ?? '');
    const name = String(item['title'] ?? '');
    const type = String(item['type'] ?? '').toLowerCase();
    const seriesName = String(item['grandparentTitle'] ?? '');
    const parentIndex = item['parentIndex'] as number | undefined;
    const index = item['index'] as number | undefined;

    const isEpisode = type === 'episode';
    const thumb = String(item['thumb'] ?? '');
    const art = String(item['art'] ?? '');
    let posterUrl = '';
    if (isEpisode) {
      // 剧集：优先季海报（parentThumb），其次剧集海报（grandparentThumb），最后回退到集截图
      const parentThumb = String(item['parentThumb'] ?? '');
      const grandparentThumb = String(item['grandparentThumb'] ?? '');
      if (parentThumb.length > 0) {
        posterUrl = this.absoluteImageUrl(baseUrl, parentThumb, token);
      } else if (grandparentThumb.length > 0) {
        posterUrl = this.absoluteImageUrl(baseUrl, grandparentThumb, token);
      }
    }
    if (posterUrl.length === 0 && thumb.length > 0) {
      posterUrl = this.absoluteImageUrl(baseUrl, thumb, token);
    }
    let backdropUrl = '';
    if (isEpisode) {
      // 16:9 横版缩略图：优先剧集背景（grandparentArt），其次季背景（parentArt）
      const parentArt = String(item['parentArt'] ?? '');
      const grandparentArt = String(item['grandparentArt'] ?? '');
      if (grandparentArt.length > 0) {
        backdropUrl = this.absoluteImageUrl(baseUrl, grandparentArt, token);
      } else if (parentArt.length > 0) {
        backdropUrl = this.absoluteImageUrl(baseUrl, parentArt, token);
      }
    }
    if (backdropUrl.length === 0 && art.length > 0) {
      backdropUrl = this.absoluteImageUrl(baseUrl, art, token);
    }
    if (backdropUrl.length === 0) {
      backdropUrl = posterUrl;
    }

    const title = isEpisode && seriesName.length > 0 ? seriesName : name;
    let subtitle = '';
    if (isEpisode) {
      subtitle = `S${parentIndex ?? 0}E${index ?? 0}${name.length > 0 ? ' · ' + name : ''}`;
    } else if (type === 'show') {
      subtitle = '电视剧';
    } else if (type === 'movie') {
      subtitle = '电影';
    }

    let progress = 0;
    let positionMs = 0;
    let durationMs = 0;
    const viewOffset = item['viewOffset'] as number | undefined;
    const duration = item['duration'] as number | undefined;
    if (viewOffset !== undefined) {
      positionMs = viewOffset;
    }
    if (duration !== undefined) {
      durationMs = duration;
      if (duration > 0 && viewOffset !== undefined) {
        progress = viewOffset / duration;
      }
    }

    const seriesId = String(item['grandparentRatingKey'] ?? '');

    return {
      id, title, type, backdropUrl, posterUrl, progress, positionMs, durationMs, subtitle, seriesId,
      seasonNumber: parentIndex ?? 0,
      episodeNumber: index ?? 0
    };
  }

  /**
   * 获取单条条目的详情（详情页展示用）。
   */
  async getItemDetail(itemId: string): Promise<VideoServerItemDetail> {
    const resp = await JsonHttpClient.get(`${this.buildBaseUrl()}/library/metadata/${itemId}`, this.headers());
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw new Error(JsonHttpClient.classifyError(resp.statusCode, '获取详情失败'));
    }
    const parsed = JSON.parse(resp.body) as Record<string, Object>;
    const mediaContainer = parsed['MediaContainer'] as Record<string, Object> | undefined;
    const metadata = mediaContainer?.['Metadata'] as Array<Record<string, Object>> | undefined;
    if (!metadata || metadata.length === 0) {
      throw new Error('获取详情失败');
    }
    const item = metadata[0];
    const media = this.mapMetadataItem(item);
    const overview = String(item['summary'] ?? '');
    let year = 0;
    const py = item['year'];
    if (typeof py === 'number') {
      year = py;
    }
    let rating = 0;
    const cr = item['rating'];
    if (typeof cr === 'number') {
      rating = cr;
    }
    const genres: string[] = [];
    const g = item['Genre'] as Array<Record<string, Object>> | undefined;
    if (g) {
      for (const x of g) {
        genres.push(String(x['tag'] ?? ''));
      }
    }
    const cast: VideoServerPerson[] = [];
    const roles = item['Role'] as Array<Record<string, Object>> | undefined;
    if (roles) {
      for (const r of roles) {
        const name = String(r['tag'] ?? '');
        if (name.length === 0) {
          continue;
        }
        const role = String(r['role'] ?? '');
        const personId = String(r['id'] ?? '');
        const thumb = String(r['thumb'] ?? '');
        const imageUrl = thumb.length > 0 ? this.absoluteImageUrl(this.buildBaseUrl(), thumb, this.config.token) : '';
        cast.push({ name, role, imageUrl, personId });
      }
    }
    return { media, overview, year, rating, genres, cast };
  }

  /**
   * 获取人员详情（照片、简介、出生信息、作品列表）。
   */
  async getPersonDetail(personId: string): Promise<VideoServerPersonDetail> {
    const result: VideoServerPersonDetail = {
      name: '', overview: '', birthDate: '', birthPlace: '', imageUrl: '', credits: []
    };
    try {
      const resp = await JsonHttpClient.get(`${this.buildBaseUrl()}/library/metadata/${personId}`, this.headers());
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        const parsed = JSON.parse(resp.body) as Record<string, Object>;
        const mediaContainer = parsed['MediaContainer'] as Record<string, Object> | undefined;
        const metadata = mediaContainer?.['Metadata'] as Array<Record<string, Object>> | undefined;
        if (metadata !== undefined && metadata.length > 0) {
          const item = metadata[0];
          result.name = String(item['title'] ?? '');
          result.overview = String(item['summary'] ?? '');
          const born = item['originallyAvailableAt'] ?? item['birthday'];
          if (typeof born === 'string' && born.length >= 10) {
            result.birthDate = born.substring(0, 10);
          }
          const country = item['country'];
          if (typeof country === 'string' && country.length > 0) {
            result.birthPlace = country;
          }
          const thumb = String(item['thumb'] ?? '');
          result.imageUrl = thumb.length > 0 ? this.absoluteImageUrl(this.buildBaseUrl(), thumb, this.config.token) : '';
          const roles = item['Role'] as Array<Record<string, Object>> | undefined;
          if (roles !== undefined) {
            for (const r of roles) {
              const id = String(r['id'] ?? r['ratingKey'] ?? '');
              const title = String(r['tag'] ?? '');
              const rThumb = String(r['thumb'] ?? '');
              const type = String(r['type'] ?? '');
              result.credits.push({
                id,
                title,
                type: type.toLowerCase(),
                backdropUrl: '',
                posterUrl: rThumb.length > 0 ? this.absoluteImageUrl(this.buildBaseUrl(), rThumb, this.config.token) : '',
                progress: 0,
                positionMs: 0,
                durationMs: 0,
                subtitle: '',
                seriesId: '',
                seasonNumber: 0,
                episodeNumber: 0
              });
            }
          }
        }
      }
    } catch (e) {
      console.warn('[PlexClient] 人员详情获取失败', (e as Error).message);
    }
    return result;
  }

  /**
   * 获取剧集的「接下来」单集（续播集，或未开始观看时的第一集）。
   */
  async getNextUp(seriesId: string): Promise<VideoServerMediaItem | null> {
    // 先在 onDeck（续播）里找属于该剧的集
    try {
      const resp = await JsonHttpClient.get(`${this.buildBaseUrl()}/library/onDeck`, this.headers());
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        const items = this.parseMetadata(resp.body);
        for (const it of items) {
          if (it.type === 'episode' && it.seriesId === seriesId) {
            return it;
          }
        }
      }
    } catch (e) {
      console.warn('[PlexClient] onDeck 获取失败', (e as Error).message);
    }
    // 回退：第一季第一集
    try {
      const seasons = await this.getSeasons(seriesId);
      if (seasons.length > 0) {
        const eps = await this.getEpisodes(seriesId, seasons[0].id);
        if (eps.length > 0) {
          const first = eps[0];
          return {
            id: first.id,
            title: first.title,
            type: 'episode',
            backdropUrl: '',
            posterUrl: seasons[0].posterUrl,
            progress: 0,
            positionMs: first.positionMs,
            durationMs: first.durationMs,
            subtitle: `S${first.seasonNumber}E${first.episodeNumber}${first.title.length > 0 ? ' · ' + first.title : ''}`,
            seriesId: seriesId,
            seasonNumber: first.seasonNumber,
            episodeNumber: first.episodeNumber
          };
        }
      }
    } catch (e) {
      console.warn('[PlexClient] 获取首集失败', (e as Error).message);
    }
    return null;
  }

  /**
   * 获取剧集的所有季（show 的 children）。
   */
  async getSeasons(seriesId: string): Promise<VideoServerSeason[]> {
    const resp = await JsonHttpClient.get(`${this.buildBaseUrl()}/library/metadata/${seriesId}/children`, this.headers());
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw new Error(JsonHttpClient.classifyError(resp.statusCode, '获取季列表失败'));
    }
    const parsed = JSON.parse(resp.body) as Record<string, Object>;
    const mediaContainer = parsed['MediaContainer'] as Record<string, Object> | undefined;
    const metadata = mediaContainer?.['Metadata'] as Array<Record<string, Object>> | undefined;
    const result: VideoServerSeason[] = [];
    if (!metadata) {
      return result;
    }
    for (const item of metadata) {
      const id = String(item['ratingKey'] ?? '');
      const seasonNumber = (item['index'] as number | undefined) ?? 0;
      const name = String(item['title'] ?? '');
      const overview = String(item['summary'] ?? '');
      const thumb = String(item['thumb'] ?? '');
      const posterUrl = thumb.length > 0 ? this.absoluteImageUrl(this.buildBaseUrl(), thumb, this.config.token) : '';
      result.push({ id, seasonNumber, name, posterUrl, overview });
    }
    return result;
  }

  /**
   * 获取某季的所有集（season 的 children）。
   */
  async getEpisodes(seriesId: string, seasonId: string): Promise<VideoServerEpisode[]> {
    const resp = await JsonHttpClient.get(`${this.buildBaseUrl()}/library/metadata/${seasonId}/children`, this.headers());
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw new Error(JsonHttpClient.classifyError(resp.statusCode, '获取集列表失败'));
    }
    const parsed = JSON.parse(resp.body) as Record<string, Object>;
    const mediaContainer = parsed['MediaContainer'] as Record<string, Object> | undefined;
    const metadata = mediaContainer?.['Metadata'] as Array<Record<string, Object>> | undefined;
    const result: VideoServerEpisode[] = [];
    if (!metadata) {
      return result;
    }
    for (const item of metadata) {
      const id = String(item['ratingKey'] ?? '');
      const episodeNumber = (item['index'] as number | undefined) ?? 0;
      const seasonNumber = (item['parentIndex'] as number | undefined) ?? 0;
      const title = String(item['title'] ?? '');
      const overview = String(item['summary'] ?? '');
      const thumb = String(item['thumb'] ?? '');
      const stillUrl = thumb.length > 0 ? this.absoluteImageUrl(this.buildBaseUrl(), thumb, this.config.token) : '';
      let durationMs = 0;
      const duration = item['duration'] as number | undefined;
      if (typeof duration === 'number') {
        durationMs = duration;
      }
      let rating = 0;
      const cr = item['rating'];
      if (typeof cr === 'number') {
        rating = cr;
      }
      let positionMs = 0;
      const viewOffset = item['viewOffset'] as number | undefined;
      if (typeof viewOffset === 'number') {
        positionMs = viewOffset;
      }
      result.push({ id, episodeNumber, seasonNumber, title, overview, stillUrl, durationMs, rating, positionMs });
    }
    return result;
  }

  private absoluteImageUrl(baseUrl: string, path: string, token: string): string {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    const sep = path.includes('?') ? '&' : '?';
    const full = path.startsWith('/') ? baseUrl + path : baseUrl + '/' + path;
    return `${full}${sep}X-Plex-Token=${token}`;
  }
}
