import { JsonHttpClient } from './JsonHttpClient';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 顶层媒体库 / 视图描述（供媒体库切换后展示）
 */
export interface VideoServerLibrary {
  id: string;
  name: string;
  /** 内容类型，如 'movies' / 'tvshows' / 'mixed'，可能为空 */
  type?: string;
  /** 媒体库封面 / 背景图 URL，可能为空 */
  imageUrl: string;
}

/**
 * 媒体库视频列表的一页（分页加载）。
 */
export interface VideoServerLibraryPage {
  items: VideoServerMediaItem[];
  total: number;
}

/**
 * 影视服务器媒体条目（统一模型，供媒体库各分区渲染）
 */
export interface VideoServerMediaItem {
  id: string;
  title: string;
  /** 'movie' | 'series' | 'episode' | 其他 */
  type: string;
  /** 16:9 背景图 URL */
  backdropUrl: string;
  /** 2:3 海报 URL */
  posterUrl: string;
  /** 播放进度 0~1 */
  progress: number;
  /** 续播位置（毫秒） */
  positionMs: number;
  /** 时长（毫秒），未知为 0 */
  durationMs: number;
  /** 副标题（如「S01E02 · 分集名」或类型标签） */
  subtitle: string;
  /** 剧集所属系列 ID（电视剧集时有效，其余为空） */
  seriesId: string;
  /** 季号（电视剧集时有效，其余为 0） */
  seasonNumber: number;
  /** 集号（电视剧集时有效，其余为 0） */
  episodeNumber: number;
}

/**
 * 影视服务器演职人员（详情页「演职人员」列表用）
 */
export interface VideoServerPerson {
  name: string;
  role: string;
  imageUrl: string;
  /** 服务器侧人员 ID（Jellyfin Person Id / Plex Role id），为空则不可点击 */
  personId: string;
}

/**
 * 影视服务器条目详情（详情页展示用）
 */
export interface VideoServerItemDetail {
  media: VideoServerMediaItem;
  overview: string;
  year: number;
  rating: number;
  genres: string[];
  cast: VideoServerPerson[];
}

/**
 * 影视服务器人员详情（人员详情页展示用）
 */
export interface VideoServerPersonDetail {
  name: string;
  overview: string;
  birthDate: string;
  birthPlace: string;
  imageUrl: string;
  credits: VideoServerMediaItem[];
}

/**
 * 影视服务器季（剧集详情页「季」列表用）
 */
export interface VideoServerSeason {
  id: string;
  seasonNumber: number;
  name: string;
  posterUrl: string;
  overview: string;
}

/**
 * 影视服务器集（季详情页「集」列表用）
 */
export interface VideoServerEpisode {
  id: string;
  episodeNumber: number;
  seasonNumber: number;
  title: string;
  overview: string;
  stillUrl: string;
  durationMs: number;
  rating: number;
  positionMs: number;
  /** 最近播放时间（毫秒时间戳），未知为 0；用于跨季「继续上次观看」选择最近播放的未完播集 */
  lastPlayedDate: number;
}

/**
 * 「最近添加的 {库名}」分区：某个媒体库下的最新条目
 */
export interface VideoServerLatestSection {
  libraryName: string;
  items: VideoServerMediaItem[];
}

/**
 * 影视服务器首页数据（我的媒体库、继续观看、接下来、最近添加）
 */
export interface VideoServerHome {
  continueWatching: VideoServerMediaItem[];
  nextUp: VideoServerMediaItem[];
  latest: VideoServerLatestSection[];
}

/** fetchServerHome 返回的聚合结果，供调用方在序号守卫后统一写入 */
export interface ServerHomeResult {
  libraries: VideoServerLibrary[];
  home: VideoServerHome;
}

/**
 * Jellyfin / Emby 客户端配置（运行时解析，凭据已解密）
 */
export interface JellyfinClientConfig {
  protocol: 'http' | 'https';
  url: string;
  port: number;
  basePath?: string;
  authMethod: 'apikey' | 'password';
  apiKey?: string;
  username?: string;
  password?: string;
}

export interface ConnectionTestResult {
  success: boolean;
  message: string;
}

/**
 * Jellyfin / Emby 服务器客户端。
 * Jellyfin 与 Emby 的 REST 接口同源，共用本客户端。
 */
export class JellyfinClient {
  private config: JellyfinClientConfig;
  private cachedToken: string | undefined = undefined;
  private cachedUserId: string | undefined = undefined;

  constructor(config: JellyfinClientConfig) {
    this.config = config;
  }

  static fromConfigJson(configJson: string): JellyfinClient {
    const raw = JSON.parse(configJson) as Record<string, Object>;
    const protocolStr = typeof raw['protocol'] === 'string' ? raw['protocol'] : 'http';
    const protocol = protocolStr === 'https' ? 'https' : 'http';
    const rawPort = raw['port'];
    let port = 8096;
    if (typeof rawPort === 'number' && !isNaN(rawPort)) {
      port = rawPort;
    } else if (typeof rawPort === 'string' && rawPort.trim().length > 0) {
      const parsed = parseInt(rawPort.trim(), 10);
      if (!isNaN(parsed)) {
        port = parsed;
      }
    }
    const authStr = typeof raw['authMethod'] === 'string' ? raw['authMethod'] : 'apikey';
    const urlVal = raw['url'];
    const basePathVal = raw['basePath'];
    const apiKeyVal = raw['apiKey'];
    const usernameVal = raw['username'];
    const passwordVal = raw['password'];
    return new JellyfinClient({
      protocol,
      url: typeof urlVal === 'string' ? urlVal : '',
      port,
      basePath: typeof basePathVal === 'string' ? basePathVal : undefined,
      authMethod: (authStr === 'password' ? 'password' : 'apikey'),
      apiKey: typeof apiKeyVal === 'string' ? apiKeyVal : undefined,
      username: typeof usernameVal === 'string' ? usernameVal : undefined,
      password: typeof passwordVal === 'string' ? passwordVal : undefined
    });
  }

  private buildBaseUrl(): string {
    const scheme = this.config.protocol;
    const host = this.config.url.trim();
    const port = this.config.port;
    const isStdPort = (scheme === 'https' && port === 443) || (scheme === 'http' && port === 80);
    const portStr = isStdPort ? '' : `:${port}`;
    let basePath = this.config.basePath ?? '';
    if (basePath.length > 0 && !basePath.startsWith('/')) {
      basePath = '/' + basePath;
    }
    if (basePath.endsWith('/')) {
      basePath = basePath.slice(0, -1);
    }
    return `${scheme}://${host}${portStr}${basePath}`;
  }

  private authToken(): string {
    if (this.config.authMethod === 'apikey') {
      return this.config.apiKey ?? '';
    }
    return this.cachedToken ?? '';
  }

  private authHeaders(): Record<string, string> {
    const headers: Record<string, string> = {};
    const token = this.authToken();
    if (token.length > 0) {
      headers['X-Emby-Token'] = token;
    }
    return headers;
  }

  /**
   * 构建在浏览器中打开的条目详情页 URL（用于「继续观看」直接播放）。
   */
  buildWebItemUrl(itemId: string): string {
    return `${this.buildBaseUrl()}/web/index.html#!/details?id=${itemId}`;
  }

  /**
   * 获取可在 App 播放器内直接播放的流地址（带 api_key，支持续播 seek）。
   */
  async getStreamUrl(itemId: string): Promise<string> {
    await this.authenticate();
    const token = this.authToken();
    return `${this.buildBaseUrl()}/Videos/${itemId}/stream?static=true&api_key=${token}`;
  }

  /**
   * 播放器请求所需的鉴权头。
   * 流地址已带 api_key 查询参数，无需再传 X-Emby-Token 头；
   * AVPlayer 媒体栈不允许自定义头，会报「Header 'X-Emby-Token' is not allowed」。
   */
  getStreamHeader(): Record<string, string> {
    return {};
  }

  /**
   * 获取条目的 MediaSourceId（用于建立播放会话）。
   */
  async getPlaybackInfo(itemId: string): Promise<string> {
    await this.authenticate();
    const userId = await this.ensureUserId();
    const headers = this.authHeaders();
    headers['Content-Type'] = 'application/json';
    const body = JSON.stringify({
      UserId: userId,
      ItemId: itemId,
      StartTimeTicks: 0,
      AutoOpenLiveStream: false,
      MaxStreamingBitrate: 100000000
    });
    const resp = await JsonHttpClient.post(`${this.buildBaseUrl()}/Items/${itemId}/PlaybackInfo`, headers, body);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw new Error(JsonHttpClient.classifyError(resp.statusCode, '获取播放信息失败'));
    }
    const parsed = JSON.parse(resp.body) as Record<string, Object>;
    const mediaSources = parsed['MediaSources'] as Array<Record<string, Object>> | undefined;
    if (mediaSources && mediaSources.length > 0) {
      const id = mediaSources[0]['Id'];
      if (typeof id === 'string' && id.length > 0) {
        return id;
      }
    }
    return '';
  }

  /**
   * 上报播放开始（会话建立）。
   */
  async reportPlaying(playSessionId: string, itemId: string, mediaSourceId: string, positionMs: number): Promise<void> {
    await this.authenticate();
    const headers = this.authHeaders();
    headers['Content-Type'] = 'application/json';
    const body = JSON.stringify({
      ItemId: itemId,
      PlaySessionId: playSessionId,
      MediaSourceId: mediaSourceId,
      PlayMethod: 'DirectPlay',
      CanSeek: true,
      PositionTicks: Math.round(positionMs * 10000)
    });
    const resp = await JsonHttpClient.post(`${this.buildBaseUrl()}/Sessions/Playing`, headers, body);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      console.warn(`[JellyfinClient] reportPlaying 失败 status=${resp.statusCode} body=${resp.body}`);
    }
  }

  /**
   * 上报播放停止（退出播放器）时的进度，供服务器「继续观看」续播使用。
   */
  async reportStopped(playSessionId: string, itemId: string, positionMs: number): Promise<void> {
    await this.authenticate();
    const headers = this.authHeaders();
    headers['Content-Type'] = 'application/json';
    const body = JSON.stringify({
      ItemId: itemId,
      PlaySessionId: playSessionId,
      PositionTicks: Math.round(positionMs * 10000)
    });
    const resp = await JsonHttpClient.post(`${this.buildBaseUrl()}/Sessions/Playing/Stopped`, headers, body);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      console.warn(`[JellyfinClient] reportStopped 失败 status=${resp.statusCode} body=${resp.body}`);
    }
  }

  /**
   * 周期性上报播放进度（不结束会话）。
   */
  async reportProgress(playSessionId: string, itemId: string, positionMs: number, isPaused: boolean): Promise<void> {
    await this.authenticate();
    const headers = this.authHeaders();
    headers['Content-Type'] = 'application/json';
    const body = JSON.stringify({
      ItemId: itemId,
      PlaySessionId: playSessionId,
      PositionTicks: Math.round(positionMs * 10000),
      IsPaused: isPaused
    });
    const resp = await JsonHttpClient.post(`${this.buildBaseUrl()}/Sessions/Playing/Progress`, headers, body);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      console.warn(`[JellyfinClient] reportProgress 失败 status=${resp.statusCode}`);
    }
  }

  /**
   * 认证（用户名密码方式）：换取 AccessToken 与 UserId。
   */
  async authenticate(): Promise<void> {
    if (this.cachedToken) {
      return;
    }
    if (this.config.authMethod === 'apikey') {
      this.cachedToken = this.config.apiKey;
      return;
    }
    const username = this.config.username ?? '';
    const password = this.config.password ?? '';
    if (username.length === 0 || password.length === 0) {
      throw new Error('缺少用户名或密码');
    }

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'X-Emby-Authorization':
        'MediaBrowser Client="VidAll", Device="TV", DeviceId="vidall-tv", Version="1.0.0"'
    };
    const body = JSON.stringify({ Username: username, Pw: password });
    const resp = await JsonHttpClient.post(`${this.buildBaseUrl()}/Users/AuthenticateByName`, headers, body);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw new Error(JsonHttpClient.classifyError(resp.statusCode, '认证失败'));
    }
    const parsed = JSON.parse(resp.body) as Record<string, Object>;
    const accessToken = parsed['AccessToken'] as string | undefined;
    const user = parsed['User'] as Record<string, Object> | undefined;
    if (!accessToken) {
      throw new Error('认证响应缺少 AccessToken');
    }
    this.cachedToken = accessToken;
    if (user !== undefined) {
      this.cachedUserId = user['Id'] as string | undefined;
    }
  }

  /** 获取一个 userId（用户名密码取登录用户，API Key 取用户列表首个） */
  private async ensureUserId(): Promise<string> {
    if (this.cachedUserId) {
      return this.cachedUserId;
    }
    const resp = await JsonHttpClient.get(`${this.buildBaseUrl()}/Users`, this.authHeaders());
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw new Error(JsonHttpClient.classifyError(resp.statusCode, '获取用户失败'));
    }
    const users = JSON.parse(resp.body) as Array<Record<string, Object>>;
    if (users.length > 0) {
      this.cachedUserId = String(users[0]['Id'] ?? '');
      return this.cachedUserId;
    }
    throw new Error('服务器上无可用用户');
  }

  /**
   * 获取服务器公开信息（无鉴权），用于测试连接与识别服务器。
   */
  async getServerInfo(): Promise<Record<string, Object>> {
    const resp = await JsonHttpClient.get(`${this.buildBaseUrl()}/System/Info/Public`, {});
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw new Error(JsonHttpClient.classifyError(resp.statusCode, '服务不可达'));
    }
    return JSON.parse(resp.body) as Record<string, Object>;
  }

  /**
   * 测试连接：校验服务可达 + 认证通过。
   */
  async testConnection(): Promise<ConnectionTestResult> {
    try {
      await this.getServerInfo();
      await this.authenticate();
      return { success: true, message: '连接成功' };
    } catch (e) {
      const message = (e as Error).message ?? '未知错误';
      return { success: false, message };
    }
  }

  /**
   * 获取顶层媒体库 / 视图列表。
   * 用户名密码方式：认证后按 userId 请求 Views；API Key 方式：请求 VirtualFolders。
   */
  async getLibraries(): Promise<VideoServerLibrary[]> {
    await this.authenticate();

    const baseUrl = this.buildBaseUrl();
    const headers = this.authHeaders();

    if (this.config.authMethod === 'password' && this.cachedUserId) {
      const resp = await JsonHttpClient.get(`${baseUrl}/Users/${this.cachedUserId}/Views`, headers);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return this.parseViews(resp.body);
      }
      throw new Error(JsonHttpClient.classifyError(resp.statusCode, '获取媒体库失败'));
    }

    // API Key 方式：管理端 VirtualFolders
    const resp = await JsonHttpClient.get(`${baseUrl}/Library/VirtualFolders`, headers);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return this.parseVirtualFolders(resp.body);
    }
    throw new Error(JsonHttpClient.classifyError(resp.statusCode, '获取媒体库失败'));
  }

  /**
   * 获取首页数据：继续观看、接下来、每个媒体库的最近添加。
   */
  async getHome(): Promise<VideoServerHome> {
    await this.authenticate();
    const userId = await this.ensureUserId();
    const baseUrl = this.buildBaseUrl();
    const headers = this.authHeaders();

    // 继续观看
    let continueWatching: VideoServerMediaItem[] = [];
    try {
      const resumeResp = await JsonHttpClient.get(
        `${baseUrl}/Users/${userId}/Items/Resume?Limit=20&Recursive=true&ImageTypeLimit=1&MediaTypes=Video` +
          `&EnableImageTypes=Primary,Backdrop,Thumb`,
        headers
      );
      if (resumeResp.statusCode >= 200 && resumeResp.statusCode < 300) {
        continueWatching = this.parseItems(resumeResp.body);
      }
    } catch (e) {
      console.warn('[JellyfinClient] 继续观看获取失败', (e as Error).message);
    }

    // 接下来
    let nextUp: VideoServerMediaItem[] = [];
    try {
      const nextResp = await JsonHttpClient.get(
        `${baseUrl}/Shows/NextUp?userId=${userId}&Limit=20&ImageTypeLimit=1&EnableImageTypes=Primary,Backdrop,Thumb`,
        headers
      );
      if (nextResp.statusCode >= 200 && nextResp.statusCode < 300) {
        nextUp = this.parseItems(nextResp.body);
      }
    } catch (e) {
      console.warn('[JellyfinClient] 接下来获取失败', (e as Error).message);
    }

    // 最近添加（按媒体库，并发请求）
    const libraries = await this.getLibraries();
    const latestTasks: Promise<VideoServerLatestSection | null>[] = libraries.map((lib: VideoServerLibrary) =>
      this.fetchLatestForLibrary(baseUrl, userId, headers, lib.id, lib.name)
    );
    const latestResults = await Promise.all(latestTasks);
    const latest: VideoServerLatestSection[] = [];
    for (const result of latestResults) {
      if (result !== null) {
        latest.push(result);
      }
    }

    return { continueWatching, nextUp, latest };
  }

  /**
   * 获取单个媒体库的「最近添加」数据（供 Promise.all 并发调用）。
   */
  private async fetchLatestForLibrary(
    baseUrl: string, userId: string, headers: Record<string, string>,
    libraryId: string, libraryName: string
  ): Promise<VideoServerLatestSection | null> {
    try {
      const latestResp = await JsonHttpClient.get(
        `${baseUrl}/Users/${userId}/Items/Latest?Limit=16&Fields=PrimaryImageAspectRatio%2CPath` +
          `&ImageTypeLimit=1&EnableImageTypes=Primary%2CBackdrop%2CThumb&ParentId=${encodeURIComponent(libraryId)}`,
        headers
      );
      if (latestResp.statusCode >= 200 && latestResp.statusCode < 300) {
        const items = this.parseItems(latestResp.body);
        if (items.length > 0) {
          const section: VideoServerLatestSection = { libraryName, items };
          return section;
        }
      }
    } catch (e) {
      console.warn(`[JellyfinClient] 媒体库 ${libraryName} 最近添加获取失败`, (e as BusinessError).message);
    }
    return null;
  }

  /**
   * 获取某个媒体库下的视频列表（分页，按 DateCreated 倒序）。
   */
  async getLibraryItems(libraryId: string, libraryType: string, startIndex: number, limit: number): Promise<VideoServerLibraryPage> {
    await this.authenticate();
    const userId = await this.ensureUserId();
    let includeItemTypes = 'Movie,Series';
    if (libraryType === 'movies') {
      includeItemTypes = 'Movie';
    } else if (libraryType === 'tvshows') {
      includeItemTypes = 'Series';
    }
    const resp = await JsonHttpClient.get(
      `${this.buildBaseUrl()}/Users/${userId}/Items?SortBy=DateCreated,SortName,ProductionYear&SortOrder=Descending` +
        `&IncludeItemTypes=${includeItemTypes}&Recursive=true&Fields=PrimaryImageAspectRatio,MediaSourceCount` +
        `&ImageTypeLimit=1&EnableImageTypes=Primary,Backdrop,Banner,Thumb&StartIndex=${startIndex}` +
        `&ParentId=${encodeURIComponent(libraryId)}&Limit=${limit}`,
      this.authHeaders()
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw new Error(JsonHttpClient.classifyError(resp.statusCode, '获取媒体库内容失败'));
    }
    const parsed = JSON.parse(resp.body) as Record<string, Object>;
    const total = (parsed['TotalRecordCount'] as number | undefined) ?? 0;
    const items = this.parseItems(resp.body);
    return { items, total };
  }

  /**
   * 获取单条条目的详情（详情页展示用）。
   */
  async getItemDetail(itemId: string): Promise<VideoServerItemDetail> {
    await this.authenticate();
    const userId = await this.ensureUserId();
    const resp = await JsonHttpClient.get(
      `${this.buildBaseUrl()}/Users/${userId}/Items/${itemId}`,
      this.authHeaders()
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw new Error(JsonHttpClient.classifyError(resp.statusCode, '获取详情失败'));
    }
    const item = JSON.parse(resp.body) as Record<string, Object>;
    const media = this.mapItem(item);
    const overview = String(item['Overview'] ?? '');
    let year = 0;
    const py = item['ProductionYear'];
    if (typeof py === 'number') {
      year = py;
    }
    let rating = 0;
    const cr = item['CommunityRating'];
    if (typeof cr === 'number') {
      rating = cr;
    }
    const genres: string[] = [];
    const g = item['Genres'] as Array<string> | undefined;
    if (g) {
      for (const x of g) {
        genres.push(x);
      }
    }
    const cast: VideoServerPerson[] = [];
    const people = item['People'] as Array<Record<string, Object>> | undefined;
    if (people) {
      for (const p of people) {
        const name = String(p['Name'] ?? '');
        if (name.length === 0) {
          continue;
        }
        const role = String(p['Role'] ?? p['Type'] ?? '');
        const personId = String(p['Id'] ?? '');
        let tag = '';
        const pt = p['PrimaryImageTag'];
        if (typeof pt === 'string') {
          tag = pt;
        }
        const imageUrl = personId.length > 0
          ? `${this.buildBaseUrl()}/Items/${personId}/Images/Primary?maxWidth=200&quality=90&tag=${tag}&api_key=${this.authToken()}`
          : '';
        cast.push({ name, role, imageUrl, personId });
      }
    }
    return { media, overview, year, rating, genres, cast };
  }

  /**
   * 获取人员详情（照片、简介、出生信息、作品列表）。
   */
  async getPersonDetail(personId: string): Promise<VideoServerPersonDetail> {
    await this.authenticate();
    const userId = await this.ensureUserId();
    const result: VideoServerPersonDetail = {
      name: '', overview: '', birthDate: '', birthPlace: '', imageUrl: '', credits: []
    };
    try {
      const resp = await JsonHttpClient.get(
        `${this.buildBaseUrl()}/Users/${userId}/Items/${personId}`,
        this.authHeaders()
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        const item = JSON.parse(resp.body) as Record<string, Object>;
        result.name = String(item['Name'] ?? '');
        result.overview = String(item['Overview'] ?? '');
        const pd = item['PremiereDate'];
        if (typeof pd === 'string' && pd.length >= 10) {
          result.birthDate = pd.substring(0, 10);
        }
        const locations = item['ProductionLocations'] as Array<string> | undefined;
        if (locations !== undefined && locations.length > 0) {
          result.birthPlace = locations[0];
        }
        const imageTags = item['ImageTags'] as Record<string, Object> | undefined;
        const primaryTag = imageTags !== undefined ? imageTags['Primary'] : undefined;
        if (typeof primaryTag === 'string' && primaryTag.length > 0) {
          result.imageUrl = `${this.buildBaseUrl()}/Items/${personId}/Images/Primary?maxWidth=400&quality=90&tag=${primaryTag}&api_key=${this.authToken()}`;
        }
      }
    } catch (e) {
      console.warn('[JellyfinClient] 人员详情获取失败', (e as Error).message);
    }
    try {
      const resp = await JsonHttpClient.get(
        `${this.buildBaseUrl()}/Users/${userId}/Items?PersonIds=${encodeURIComponent(personId)}` +
          `&Recursive=true&IncludeItemTypes=Movie,Series&SortBy=PremiereDate&SortOrder=Descending&Limit=50&ImageTypeLimit=1`,
        this.authHeaders()
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        result.credits = this.parseItems(resp.body);
      }
    } catch (e) {
      console.warn('[JellyfinClient] 人员作品获取失败', (e as Error).message);
    }
    return result;
  }

  /**
   * 获取剧集的「接下来」单集（续播集，或未开始观看时的第一集）。
   */
  async getNextUp(seriesId: string): Promise<VideoServerMediaItem | null> {
    await this.authenticate();
    const userId = await this.ensureUserId();
    const resp = await JsonHttpClient.get(
      `${this.buildBaseUrl()}/Shows/NextUp?SeriesId=${encodeURIComponent(seriesId)}&UserId=${userId}&Limit=1&ImageTypeLimit=1`,
      this.authHeaders()
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      return null;
    }
    const items = this.parseItems(resp.body);
    return items.length > 0 ? items[0] : null;
  }

  /**
   * 获取剧集的所有季。
   */
  async getSeasons(seriesId: string): Promise<VideoServerSeason[]> {
    await this.authenticate();
    const userId = await this.ensureUserId();
    const resp = await JsonHttpClient.get(
      `${this.buildBaseUrl()}/Shows/${seriesId}/Seasons?userId=${userId}&Fields=Overview`,
      this.authHeaders()
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw new Error(JsonHttpClient.classifyError(resp.statusCode, '获取季列表失败'));
    }
    const parsed = JSON.parse(resp.body) as Record<string, Object>;
    const items = parsed['Items'] as Array<Record<string, Object>> | undefined;
    const result: VideoServerSeason[] = [];
    if (!items) {
      return result;
    }
    for (const item of items) {
      const id = String(item['Id'] ?? '');
      const seasonNumber = (item['IndexNumber'] as number | undefined) ?? 0;
      const name = String(item['Name'] ?? '');
      const overview = String(item['Overview'] ?? '');
      const imageTags = item['ImageTags'] as Record<string, Object> | undefined;
      let tag = '';
      if (imageTags !== undefined) {
        const p = imageTags['Primary'];
        if (typeof p === 'string') {
          tag = p;
        }
      }
      const posterUrl = this.primaryImageUrl(id, tag);
      result.push({ id, seasonNumber, name, posterUrl, overview });
    }
    return result;
  }

  /**
   * 获取某季的所有集。
   */
  async getEpisodes(seriesId: string, seasonId: string): Promise<VideoServerEpisode[]> {
    await this.authenticate();
    const userId = await this.ensureUserId();
    const resp = await JsonHttpClient.get(
      `${this.buildBaseUrl()}/Shows/${seriesId}/Episodes?userId=${userId}&SeasonId=${seasonId}&Fields=Overview&enableUserData=true`,
      this.authHeaders()
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw new Error(JsonHttpClient.classifyError(resp.statusCode, '获取集列表失败'));
    }
    const parsed = JSON.parse(resp.body) as Record<string, Object>;
    const items = parsed['Items'] as Array<Record<string, Object>> | undefined;
    const result: VideoServerEpisode[] = [];
    if (!items) {
      return result;
    }
    for (const item of items) {
      const id = String(item['Id'] ?? '');
      const episodeNumber = (item['IndexNumber'] as number | undefined) ?? 0;
      const seasonNumber = (item['ParentIndexNumber'] as number | undefined) ?? 0;
      const title = String(item['Name'] ?? '');
      const overview = String(item['Overview'] ?? '');
      const imageTags = item['ImageTags'] as Record<string, Object> | undefined;
      let tag = '';
      if (imageTags !== undefined) {
        const p = imageTags['Primary'];
        if (typeof p === 'string') {
          tag = p;
        }
      }
      const stillUrl = this.primaryImageUrl(id, tag);
      let durationMs = 0;
      const ticks = item['RunTimeTicks'];
      if (typeof ticks === 'number') {
        durationMs = Math.round(ticks / 10000);
      }
      let rating = 0;
      const cr = item['CommunityRating'];
      if (typeof cr === 'number') {
        rating = cr;
      }
      let positionMs = 0;
      let lastPlayedDate = 0;
      const userData = item['UserData'] as Record<string, Object> | undefined;
      if (userData !== undefined) {
        const pt = userData['PlaybackPositionTicks'];
        if (typeof pt === 'number') {
          positionMs = Math.round(pt / 10000);
        }
        const lp = userData['LastPlayedDate'];
        if (typeof lp === 'string' && lp.length >= 19) {
          const t = Date.parse(lp.substring(0, 19));
          if (!isNaN(t)) {
            lastPlayedDate = t;
          }
        }
      }
      result.push({ id, episodeNumber, seasonNumber, title, overview, stillUrl, durationMs, rating, positionMs, lastPlayedDate });
    }
    return result;
  }

  private parseItems(body: string): VideoServerMediaItem[] {
    const parsed = JSON.parse(body) as Object;
    const result: VideoServerMediaItem[] = [];
    let items: Array<Record<string, Object>> | undefined;
    if (parsed instanceof Array) {
      // /Items/Latest 直接返回数组
      items = parsed as Array<Record<string, Object>>;
    } else {
      items = (parsed as Record<string, Object>)['Items'] as Array<Record<string, Object>> | undefined;
    }
    if (!items) {
      return result;
    }
    for (const item of items) {
      result.push(this.mapItem(item));
    }
    return result;
  }

  private mapItem(item: Record<string, Object>): VideoServerMediaItem {
    const id = String(item['Id'] ?? '');
    const name = String(item['Name'] ?? '');
    const type = String(item['Type'] ?? '').toLowerCase();
    const seriesName = String(item['SeriesName'] ?? '');
    const parentIndex = item['ParentIndexNumber'] as number | undefined;
    const index = item['IndexNumber'] as number | undefined;
    const imageTags = item['ImageTags'] as Record<string, Object> | undefined;
    const backdropTags = item['BackdropImageTags'] as Array<string> | undefined;
    const userData = item['UserData'] as Record<string, Object> | undefined;

    const token = this.authToken();
    const isEpisode = type === 'episode';
    const seriesId = String(item['SeriesId'] ?? '');
    const seasonId = String(item['SeasonId'] ?? item['ParentId'] ?? '');

    let posterUrl = '';
    if (isEpisode) {
      // 剧集：优先季海报，其次剧集海报（继续观看/接下来缩略图用），最后回退到集截图
      const seasonTag = item['ParentPrimaryImageTag'];
      const seriesTag = item['SeriesPrimaryImageTag'];
      if (seasonId.length > 0 && typeof seasonTag === 'string' && seasonTag.length > 0) {
        posterUrl = `${this.buildBaseUrl()}/Items/${seasonId}/Images/Primary?maxWidth=400&quality=90&tag=${seasonTag}&api_key=${token}`;
      } else if (seriesId.length > 0 && typeof seriesTag === 'string' && seriesTag.length > 0) {
        posterUrl = `${this.buildBaseUrl()}/Items/${seriesId}/Images/Primary?maxWidth=400&quality=90&tag=${seriesTag}&api_key=${token}`;
      }
    }
    if (posterUrl.length === 0 && imageTags !== undefined) {
      const primaryTag = imageTags['Primary'];
      if (typeof primaryTag === 'string' && primaryTag.length > 0) {
        posterUrl = `${this.buildBaseUrl()}/Items/${id}/Images/Primary?maxWidth=400&quality=90&tag=${primaryTag}&api_key=${token}`;
      }
    }
    let backdropUrl = '';
    if (backdropTags !== undefined && backdropTags.length > 0) {
      backdropUrl = `${this.buildBaseUrl()}/Items/${id}/Images/Backdrop?maxWidth=1280&quality=90&tag=${backdropTags[0]}&api_key=${token}`;
    }
    if (isEpisode && backdropUrl.length === 0 && seriesId.length > 0) {
      // 16:9 缩略图：用剧集的 Thumb（与 Jellyfin Web 的继续观看/接下来一致）
      const seriesThumbTag = item['SeriesThumbImageTag'];
      if (typeof seriesThumbTag === 'string' && seriesThumbTag.length > 0) {
        backdropUrl = `${this.buildBaseUrl()}/Items/${seriesId}/Images/Thumb?fillWidth=700&fillHeight=394&quality=96&tag=${seriesThumbTag}&api_key=${token}`;
      } else {
        backdropUrl = `${this.buildBaseUrl()}/Items/${seriesId}/Images/Thumb?fillWidth=700&fillHeight=394&quality=96&api_key=${token}`;
      }
    }

    const title = isEpisode && seriesName.length > 0 ? seriesName : name;
    let subtitle = '';
    if (isEpisode) {
      const season = parentIndex ?? 0;
      const episode = index ?? 0;
      subtitle = `S${season}E${episode}${name.length > 0 ? ' · ' + name : ''}`;
    } else if (type === 'series') {
      subtitle = '电视剧';
    } else if (type === 'movie') {
      subtitle = '电影';
    }

    let progress = 0;
    let positionMs = 0;
    if (userData !== undefined) {
      const pct = userData['PlayedPercentage'];
      if (typeof pct === 'number') {
        progress = pct / 100;
      }
      const ticks = userData['PlaybackPositionTicks'];
      if (typeof ticks === 'number') {
        positionMs = Math.round(ticks / 10000);
      }
    }
    let durationMs = 0;
    const runTimeTicks = item['RunTimeTicks'];
    if (typeof runTimeTicks === 'number') {
      durationMs = Math.round(runTimeTicks / 10000);
    }

    return {
      id, title, type, backdropUrl, posterUrl, progress, positionMs, durationMs, subtitle, seriesId,
      seasonNumber: parentIndex ?? 0,
      episodeNumber: index ?? 0
    };
  }

  private primaryImageUrl(itemId: string, tag: string): string {
    if (itemId.length === 0) {
      return '';
    }
    const token = this.authToken();
    let url = `${this.buildBaseUrl()}/Items/${itemId}/Images/Primary?maxWidth=720&quality=90`;
    if (tag.length > 0) {
      url += `&tag=${tag}`;
    }
    if (token.length > 0) {
      url += `&api_key=${token}`;
    }
    return url;
  }

  private parseViews(body: string): VideoServerLibrary[] {
    const parsed = JSON.parse(body) as Record<string, Object>;
    const items = parsed['Items'] as Array<Record<string, Object>> | undefined;
    const result: VideoServerLibrary[] = [];
    if (items) {
      for (const item of items) {
        const id = (item['Id'] ?? item['ItemId'] ?? '') as string;
        const name = (item['Name'] ?? '') as string;
        if (name.length > 0) {
          const imageTags = item['ImageTags'] as Record<string, Object> | undefined;
          let tag = '';
          if (imageTags !== undefined) {
            const primary = imageTags['Primary'];
            if (typeof primary === 'string') {
              tag = primary;
            }
          }
          result.push({
            id: String(id),
            name,
            type: (item['CollectionType'] as string | undefined) ?? undefined,
            imageUrl: this.primaryImageUrl(String(id), tag)
          });
        }
      }
    }
    return result;
  }

  private parseVirtualFolders(body: string): VideoServerLibrary[] {
    const items = JSON.parse(body) as Array<Record<string, Object>>;
    const result: VideoServerLibrary[] = [];
    for (const item of items) {
      const name = (item['Name'] ?? '') as string;
      if (name.length > 0) {
        const itemId = String(item['ItemId'] ?? item['Id'] ?? '');
        result.push({
          id: itemId,
          name,
          type: (item['CollectionType'] as string | undefined) ?? undefined,
          imageUrl: this.primaryImageUrl(itemId, '')
        });
      }
    }
    return result;
  }
}
