import { SeriesGroup, TvSeriesEntity, TvEpisodeEntity, MediaItem, PlayProgressEntity } from '../../db/models/MediaEntity'
import { FileSourceDatabase } from '../../db/files/FileSourceDatabase'
import { ScrapeCredit } from '../../lib/ScrapeClient'
import { SeasonDetailPage } from './SeasonDetailPage'
import { AppPreferences, PrefKey } from '../../utils/AppPreferences'
import { PlayerPageParam, PlayerPage } from '../player/index'
import http from '@ohos.net.http'
import image from '@ohos.multimedia.image'
import effectKit from '@ohos.effectKit'
import { WebDAVClient, WebDAVConfig } from '../../lib/WebDAVClient'
import { millisecondsToTime } from '../../utils/TimeUtil'
import { FfprobeUtil, FfprobeTrack } from '../../utils/FfprobeUtil'
import { PresetAudioTrack, PresetSubtitleTrack } from '../../components/core/player/VideoData'

// ─────────────────────────────────────────────
// TMDB 图片 URL 工具
// ─────────────────────────────────────────────

/**
 * 按指定宽度档位构造 TMDB 图片 URL。
 * width 取值：'w185' | 'w342' | 'w500' | 'w780' | 'w1280' | 'original'
 */
function tmdbImageUrl(path: string | undefined, width: string): string {
  if (!path || path.length === 0) { return ''; }
  return `https://image.tmdb.org/t/p/${width}${path}`;
}

function formatYear(date: string | undefined): string {
  if (!date || date.length < 4) { return ''; }
  return date.substring(0, 4);
}

function parseGenresArr(json: string | undefined): string[] {
  if (!json) { return []; }
  try { return JSON.parse(json) as string[]; } catch (e) { return []; }
}

// ─────────────────────────────────────────────
// 内部类型定义
// ─────────────────────────────────────────────

/** 从 tv_series.raw_json 解析的单季信息 */
interface TmdbRawSeason {
  air_date?: string;
  episode_count?: number;
  id?: number;
  name?: string;
  overview?: string;
  poster_path?: string;
  season_number?: number;
  vote_average?: number;
}

interface TmdbRawCastItem {
  name?: string;
  character?: string;
  profile_path?: string;
  order?: number;
}

interface TmdbRawCrewItem {
  name?: string;
  job?: string;
  profile_path?: string;
}

interface TmdbRawCredits {
  cast?: TmdbRawCastItem[];
  crew?: TmdbRawCrewItem[];
}

interface TmdbRawDetail {
  seasons?: TmdbRawSeason[];
  credits?: TmdbRawCredits;
}

interface TmdbSimilarItem {
  id?: number;
  name?: string;
  poster_path?: string;
  backdrop_path?: string;
  vote_average?: number;
}

interface TmdbSimilarResponse {
  results?: TmdbSimilarItem[];
}

/** 本地库匹配到的相似剧 */
interface SimilarSeriesItem {
  tvSeriesId: number;
  title: string;
  posterUrl?: string;
  posterLocalPath?: string;
  backdropUrl?: string;
  rating?: number;
}

/** 将 TMDB crew job 翻译为中文职位 */
function translateJob(job: string): string {
  if (job === 'Director') { return '导演'; }
  if (job === 'Writer' || job === 'Screenplay' || job === 'Story') { return '编剧'; }
  if (job === 'Editor') { return '剪辑师'; }
  if (job === 'Director of Photography') { return '摄影指导'; }
  if (job === 'Producer') { return '制片人'; }
  if (job === 'Executive Producer') { return '执行制片人'; }
  if (job === 'Composer' || job === 'Original Music Composer') { return '作曲'; }
  if (job === 'Art Direction' || job === 'Production Design') { return '艺术指导'; }
  if (job === 'Costume Design') { return '服装设计'; }
  if (job === 'Casting') { return '选角导演'; }
  if (job === 'Visual Effects Supervisor') { return '视效总监'; }
  return job;
}

// ─────────────────────────────────────────────
// 详情页
// ─────────────────────────────────────────────

@ComponentV2
export struct SeriesDetailPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  @Local group: SeriesGroup | undefined = undefined
  @Local seriesEntity: TvSeriesEntity | undefined = undefined
  @Local seasons: TmdbRawSeason[] = []
  @Local cast: ScrapeCredit[] = []
  @Local similarSeries: SimilarSeriesItem[] = []
  @Local isLoading: boolean = false
  @Local showOverviewDialog: boolean = false
  /** 从 backdrop 提取的深色背景色，格式 #RRGGBB，提取失败保持默认 */
  @Local dominantBgColor: string = '#111111'
  /** 当前选中显示的季号（-1 = 未选） */
  @Local selectedSeasonNumber: number = -1
  /** 播放进度映射（key = videoId） */
  @Local progressMap: Map<number, PlayProgressEntity> = new Map()
  /** 最新播放进度（用于 ContinueWatchingCard） */
  @Local lastProgress: PlayProgressEntity | null = null
  /** 最新播放集信息 */
  @Local lastEpisode: MediaItem | null = null
  /** 默认展示的第一集信息（S01E01 fallback），从 tv_episodes 加载 */
  @Local firstEpisode: TvEpisodeEntity | undefined = undefined
  /** ContinueWatchingCard 主按钮交互状态 */
  @Local focusedContinueActionKey: string = ''
  @Local hoveredContinueActionKey: string = ''

  static PAGE_NAME = 'seriesDetail'

  // ── 属性计算方法 ──────────────────────────────────

  private getBackdropUrl(): string {
    // backdropPath 是 TMDB 原始路径（无尺寸），优先构造 w1280 高清 URL
    const path = this.seriesEntity?.backdropPath;
    if (path !== undefined && path.length > 0) { return tmdbImageUrl(path, 'w1280'); }
    // 回退：数据库存储的 backdropUrl（旧数据可能是 w500），直接用
    const url = this.seriesEntity?.backdropUrl ?? this.group?.backdropUrl;
    if (url !== undefined && url.length > 0) { return url; }
    // 最后回退到海报
    return this.seriesEntity?.posterUrl ?? this.group?.posterUrl ?? '';
  }

  private getTitle(): string { return this.group?.title ?? ''; }

  private getYear(): string { return formatYear(this.seriesEntity?.firstAirDate); }

  private getRatingText(): string {
    const r = this.group?.rating ?? this.seriesEntity?.rating;
    if (r === undefined) { return ''; }
    return r.toFixed(1);
  }

  private getOverview(): string { return this.seriesEntity?.overview ?? ''; }

  private getGenres(): string[] { return parseGenresArr(this.seriesEntity?.genresJson); }

  private getSeasonPosterUrl(s: TmdbRawSeason): string {
    return tmdbImageUrl(s.poster_path, 'w342');
  }

  /** 第N季 / 特别篇 */
  private getSeasonLabel(s: TmdbRawSeason): string {
    const n = s.season_number ?? 0;
    if (n === 0) { return '特别篇'; }
    return `第 ${n} 季`;
  }

  private isGenericSeasonTitle(title: string, n: number): boolean {
    const t = title.trim().toLowerCase();
    if (/^season\s*\d+$/.test(t)) { return true; }
    if (/^第\s*\d+\s*季$/.test(t)) { return true; }
    const chineseNums = ['零','一','二','三','四','五','六','七','八','九','十',
      '十一','十二','十三','十四','十五','十六','十七','十八','十九','二十'];
    if (n >= 0 && n < chineseNums.length) {
      if (t === `第${chineseNums[n]}季`) { return true; }
    }
    return false;
  }

  private toChineseSeasonLabel(n: number): string {
    if (n <= 0) { return '特别篇'; }
    const chineseNums = ['零','一','二','三','四','五','六','七','八','九','十',
      '十一','十二','十三','十四','十五','十六','十七','十八','十九','二十'];
    if (n < chineseNums.length) {
      return `第${chineseNums[n]}季`;
    }
    return `第${n}季`;
  }

  private buildEpisodeCode(seasonNumber: number, episodeNumber: number): string {
    const sn = seasonNumber > 0 ? seasonNumber : 0;
    const en = episodeNumber > 0 ? episodeNumber : 0;
    return `S${sn}:E${en}`;
  }

  private getSeasonNameForPlayer(seasonNumber: number): string {
    for (const s of this.seasons) {
      if ((s.season_number ?? 0) === seasonNumber) {
        const name = (s.name ?? '').trim();
        if (name.length === 0 || this.isGenericSeasonTitle(name, seasonNumber)) {
          return '';
        }
        return name;
      }
    }
    return '';
  }

  private buildPlayerTitle(episode: MediaItem, episodeName: string): string {
    const seriesTitle = this.getTitle().length > 0 ? this.getTitle() : (episode.title ?? episode.fileName);
    const sn = episode.seasonNumber ?? 0;
    const en = episode.episodeNumber ?? 0;
    const seasonLabel = this.toChineseSeasonLabel(sn);
    const seasonName = this.getSeasonNameForPlayer(sn);
    const epName = episodeName.trim();
    const code = this.buildEpisodeCode(sn, en);
    const seasonPart = seasonName.length > 0 ? `${seasonLabel} ${seasonName}` : seasonLabel;
    return `${seriesTitle} ${seasonPart}-${code}-${epName}`;
  }

  private async resolveEpisodeName(db: FileSourceDatabase, episode: MediaItem): Promise<string> {
    const seriesTitle = this.getTitle().trim();
    const current = (episode.title ?? '').trim();
    const fileName = (episode.fileName ?? '').trim();
    const sn = episode.seasonNumber ?? 0;
    const en = episode.episodeNumber ?? 0;

    const seriesId = this.seriesEntity?.id;
    if (seriesId !== undefined && en > 0) {
      const epEntity = await db.getTvEpisode(seriesId, sn, en);
      const dbName = (epEntity?.title ?? '').trim();
      if (dbName.length > 0) {
        return dbName;
      }
    }

    if (current.length > 0 && current !== seriesTitle) {
      return current;
    }
    if (en > 0) {
      return `第${en}集`;
    }
    return fileName.length > 0 ? fileName : '未知集名';
  }

  private getCastProfileUrl(c: ScrapeCredit): string {
    return tmdbImageUrl(c.profilePath, 'w185');
  }

  /** overview 是否超过 100 字 */
  private isOverviewLong(): boolean { return this.getOverview().length > 100; }

  /** 截断后的简介（前100字 + 省略号） */
  private getOverviewShort(): string { return this.getOverview().substring(0, 100) + '...'; }

  /** 将 #RRGGBB 转为完全不透明的 #FFRRGGBB（ARGB 8位），用于渐变颜色 */
  private toOpaqueColor(hex: string): string {
    return '#FF' + hex.substring(1);
  }

  /** 剧集海报 URL（优先 posterPath 构造高质量，否则回退 posterUrl） */
  private getDialogPosterUrl(): string {
    const path = this.seriesEntity?.posterPath;
    if (path !== undefined && path.length > 0) { return tmdbImageUrl(path, 'w342'); }
    return this.seriesEntity?.posterUrl ?? this.group?.posterUrl ?? '';
  }

  /** 风格标签文字，如 "剧情 / 动作" */
  private getGenresText(): string {
    const g = this.getGenres();
    if (g.length === 0) { return ''; }
    return g.slice(0, 3).join(' / ');
  }

  /** 非特别篇的总集数之和 */
  private getTotalEpisodesText(): string {
    let total = 0;
    for (const s of this.seasons) {
      if ((s.season_number ?? 0) > 0) { total += s.episode_count ?? 0; }
    }
    if (total === 0) { return ''; }
    return `共 ${total} 集`;
  }

  private buildSimilarGroup(item: SimilarSeriesItem): SeriesGroup {
    const g: SeriesGroup = {
      title: item.title,
      tvSeriesId: item.tvSeriesId,
      posterUrl: item.posterUrl,
      posterLocalPath: item.posterLocalPath,
      backdropUrl: item.backdropUrl,
      rating: item.rating,
      episodeCount: 0,
      episodes: [],
      latestScannedAt: 0
    };
    return g;
  }

  // ── 数据加载 ──────────────────────────────────

  private async loadData(seriesId: number): Promise<void> {
    this.isLoading = true;
    try {
      const db = FileSourceDatabase.getInstance();
      const entity = await db.getTvSeriesById(seriesId);
      if (entity === null) { return; }
      this.seriesEntity = entity;

      // 从 raw_json 解析季列表（TMDB 原始响应中的 seasons 数组）
      const rawStr = entity.rawJson;
      if (rawStr !== undefined && rawStr.length > 0) {
        try {
          const detail = JSON.parse(rawStr) as TmdbRawDetail;
          const rawSeasons = detail.seasons ?? [];
          // 排序：正数季号升序，第 0 季（特别篇）置尾
          rawSeasons.sort((a: TmdbRawSeason, b: TmdbRawSeason) => {
            const an = a.season_number ?? 0;
            const bn = b.season_number ?? 0;
            if (an === 0 && bn !== 0) { return 1; }
            if (bn === 0 && an !== 0) { return -1; }
            return an - bn;
          });
          // 仅显示 scrape_info 中已刮削的季
          const scrapedNums = await db.getScrapedSeasonNumbers(seriesId);
          const filteredSeasons: TmdbRawSeason[] = [];
          for (const s of rawSeasons) {
            if (scrapedNums.indexOf(s.season_number ?? -1) >= 0) {
              filteredSeasons.push(s);
            }
          }
          this.seasons = filteredSeasons;
        } catch (e) { this.seasons = []; }
      }

      // 从 rawJson.credits 提取演员（cast）+ 幕后人员（crew）
      if (rawStr !== undefined && rawStr.length > 0) {
        try {
          const detail2 = JSON.parse(rawStr) as TmdbRawDetail;
          const allCredits: ScrapeCredit[] = [];
          const castItems = detail2.credits?.cast ?? [];
          for (const c of castItems.slice(0, 20)) {
            const cr: ScrapeCredit = {
              name: c.name ?? '',
              role: c.character,
              profilePath: c.profile_path,
              order: c.order
            };
            allCredits.push(cr);
          }
          const castNames: string[] = [];
          for (const cr of allCredits) { castNames.push(cr.name); }
          const crewItems = detail2.credits?.crew ?? [];
          for (const c of crewItems) {
            const cName = c.name ?? '';
            if (castNames.indexOf(cName) >= 0) { continue; }
            const cr: ScrapeCredit = {
              name: cName,
              role: translateJob(c.job ?? ''),
              profilePath: c.profile_path
            };
            allCredits.push(cr);
            castNames.push(cName);
          }
          if (allCredits.length > 0) { this.cast = allCredits.filter((cr: ScrapeCredit) => cr.name != null && cr.name.length > 0); }
        } catch (e) { /* cast 解析失败不影响页面 */ }
      }

      // 加载默认集信息（最小季最小集）用于续播卡片
      try {
        const ep = await db.getFirstTvEpisode(seriesId);
        if (ep !== null) { this.firstEpisode = ep; }
      } catch (e) { /* 加载失败忽略，保持占位 */ }

      // 异步提取 backdrop 主色（fire-and-forget）
      const bdUrl = this.getBackdropUrl();
      if (bdUrl.length > 0) { this.extractDominantColor(bdUrl); }

      // 异步加载相似剧（fire-and-forget，不阻塞主流程）
      const pid = entity.providerId;
      const apiKey = await AppPreferences.get(PrefKey.TMDB_API_KEY, '');
      if (pid.length > 0 && apiKey.length > 0) {
        this.loadSimilar(pid, apiKey);
      }

      // 加载本剧所有集（含元数据），按季分组
      const allEpisodes = await db.getMediaItemsByTvSeriesId(seriesId);
      // 更新 group.episodes（用于 ContinueWatchingCard 选集）
      if (this.group !== undefined) {
        const updated: SeriesGroup = {
          title: this.group.title,
          tvSeriesId: this.group.tvSeriesId,
          seasonLabel: this.group.seasonLabel,
          posterUrl: this.group.posterUrl,
          posterLocalPath: this.group.posterLocalPath,
          backdropUrl: this.group.backdropUrl,
          seasonNumber: this.group.seasonNumber,
          seasonPosterUrl: this.group.seasonPosterUrl,
          rating: this.group.rating,
          episodeCount: allEpisodes.length,
          episodes: allEpisodes,
          latestScannedAt: this.group.latestScannedAt
        };
        this.group = updated;
      }

      // 加载播放进度（以 seriesProviderId 批量查询整部剧）
      if (pid.length > 0) {
        const progressList = await db.getPlayProgressBySeries(pid);
        const newMap = new Map<number, PlayProgressEntity>();
        for (const p of progressList) {
          newMap.set(p.videoId, p);
        }
        this.progressMap = newMap;
        // 取最近播放记录（updatedAt 最大）
        let latest: PlayProgressEntity | null = null;
        for (const p of progressList) {
          if (latest === null || p.updatedAt > latest.updatedAt) { latest = p; }
        }
        this.lastProgress = latest;
        // 找到对应集信息
        if (latest !== null) {
          for (const ep of allEpisodes) {
            if (ep.id === latest.videoId) {
              this.lastEpisode = ep;
              break;
            }
          }
        }
      }

      // 默认高亮第一季
      if (this.seasons.length > 0) {
        this.selectedSeasonNumber = this.seasons[0].season_number ?? 0;
      }
    } catch (e) {
      console.error('[SeriesDetailPage] loadData failed', JSON.stringify(e));
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 下载 backdrop 图片并用 effectKit 提取最暗主色作为页面背景色。
   * 提取失败时静默忽略，保持默认 #111111。
   */
  private async extractDominantColor(url: string): Promise<void> {
    try {
      const req = http.createHttp();
      let buf: ArrayBuffer | undefined;
      try {
        const resp = await req.request(url, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: 8000,
          readTimeout: 8000
        });
        req.destroy();
        if (resp.responseCode !== 200) { return; }
        buf = resp.result as ArrayBuffer;
      } catch (e) {
        req.destroy();
        return;
      }
      if (buf === undefined || buf.byteLength === 0) { return; }

      // 缩小尺寸加速：从 ArrayBuffer 创建 ImageSource，解码为小尺寸 PixelMap
      const imgSrc = image.createImageSource(buf);
      const pixelMap = await imgSrc.createPixelMap({
        desiredSize: { width: 64, height: 36 },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      imgSrc.release();

      // effectKit 提取主色
      const picker = await effectKit.createColorPicker(pixelMap);
      const mainColor = picker.getMainColorSync();
      pixelMap.release();

      // 将 RGB 分量各减暗 40%，保证背景色足够深
      const darken = (v: number): number => Math.round(v * 0.4);
      const toHex = (v: number): string => {
        const h = v.toString(16);
        return h.length < 2 ? '0' + h : h;
      };
      const r = darken(mainColor.red & 0xFF);
      const g = darken(mainColor.green & 0xFF);
      const b = darken(mainColor.blue & 0xFF);
      this.dominantBgColor = '#' + toHex(r) + toHex(g) + toHex(b);
    } catch (e) {
      // 提取失败，保持默认色
      console.warn('[SeriesDetailPage] extractDominantColor failed', JSON.stringify(e));
    }
  }

  private async loadSimilar(providerId: string, apiKey: string): Promise<void> {
    try {
      const url = `https://api.themoviedb.org/3/tv/${providerId}/similar?api_key=${apiKey}&language=zh-CN`;
      const req = http.createHttp();
      let body: string = '';
      try {
        const resp = await req.request(url, {
          method: http.RequestMethod.GET,
          header: { 'Accept': 'application/json' },
          connectTimeout: 10000,
          readTimeout: 10000
        });
        req.destroy();
        if (resp.responseCode !== 200) { return; }
        body = resp.result as string;
      } catch (e) {
        req.destroy();
        return;
      }
      if (body.length === 0) { return; }
      const data = JSON.parse(body) as TmdbSimilarResponse;
      const results = data.results ?? [];
      const db = FileSourceDatabase.getInstance();
      const similar: SimilarSeriesItem[] = [];
      for (const item of results.slice(0, 20)) {
        const itemId = String(item.id ?? 0);
        const local = await db.getTvSeriesByProviderId('tmdb', itemId);
        if (local !== null && local.id !== undefined) {
          const s: SimilarSeriesItem = {
            tvSeriesId: local.id,
            title: local.title,
            posterUrl: local.posterUrl,
            posterLocalPath: local.posterLocalPath,
            backdropUrl: local.backdropUrl,
            rating: local.rating
          };
          similar.push(s);
        }
      }
      this.similarSeries = similar;
    } catch (e) {
      console.error('[SeriesDetailPage] loadSimilar failed', JSON.stringify(e));
    }
  }



  /** 获取续播卡片图片 URL：优先 firstEpisode.stillUrl，其次 stillPath 构造，最后 fallback 海报 */
  private getResumeCardStillUrl(): string {
    const ep = this.firstEpisode;
    if (ep !== undefined) {
      if (ep.stillUrl !== undefined && ep.stillUrl.length > 0) { return ep.stillUrl; }
      if (ep.stillPath !== undefined && ep.stillPath.length > 0) {
        return tmdbImageUrl(ep.stillPath, 'w342');
      }
    }
    return '';
  }

  /** 续播卡片季集号标签，如 "S01:E01" */
  private getResumeCardEpLabel(): string {
    const ep = this.firstEpisode;
    if (ep !== undefined) {
      const sn = String(ep.seasonNumber).padStart(2, '0');
      const en = String(ep.episodeNumber).padStart(2, '0');
      return `S${sn}:E${en}`;
    }
    return 'S01:E01';
  }

  /** 续播卡片集标题 */
  private getResumeCardTitle(): string {
    const ep = this.firstEpisode;
    if (ep !== undefined && ep.title !== undefined && ep.title.length > 0) { return ep.title; }
    return '第 1 集';
  }

  // ── Builders ──────────────────────────────────

  private selectSeason(seasonNumber: number): void {
    this.selectedSeasonNumber = seasonNumber;
  }

  /**
   * 点击集 → 导航到播放器
   * 构造 WebDAV 完整 URL + Authorization 请求头后传入 PlayerPageParam，
   * 同时从 DB / ffprobe 读取音轨和字幕轨元数据并注入，与文件浏览器行为一致。
   */
  private async playEpisode(episode: MediaItem): Promise<void> {
    try {
      const db = FileSourceDatabase.getInstance();
      const fileSource = await db.getFileSourceById(episode.sourceId);
      if (fileSource === null) {
        console.warn('[SeriesDetailPage] 找不到文件源 sourceId=' + episode.sourceId);
        return;
      }

      const config = JSON.parse(fileSource.configJson) as Record<string, string>;
      const protocol = config['protocol'] ?? 'http';
      const host = config['url'] ?? '';
      const port = config['port'] ?? (protocol === 'https' ? '443' : '80');
      const rootPath = (config['rootPath'] ?? '').replace(/\/$/, '');
      const baseUrl = `${protocol}://${host}:${port}${rootPath}`;
      const webdavConfig: WebDAVConfig = {
        baseUrl,
        username: config['username'] ?? '',
        password: config['password'] ?? '',
        timeout: 30000
      };
      const client = new WebDAVClient(webdavConfig);
      const fullUrl = client.getFullUrl(episode.filePath);
      const authHeader = client.getAuthHeaderPublic();
      const httpHeader: Record<string, string> = authHeader ? { 'Authorization': authHeader } : {};

      // ── 音轨 / 字幕轨 ──────────────────────────
      let presetAudioTracks: PresetAudioTrack[] = [];
      let presetSubtitleTracks: PresetSubtitleTrack[] = [];
      let dbHasAudioData = false;
      let dbHasSubtitleData = false;

      try {
        const videoEntity = await db.getVideoByPath(episode.filePath);
        if (videoEntity) {
          if (videoEntity.audioTracksJson !== null && videoEntity.audioTracksJson !== undefined) {
            dbHasAudioData = true;
            if (videoEntity.audioTracksJson.length > 0) {
              const tracks = JSON.parse(videoEntity.audioTracksJson) as FfprobeTrack[];
              for (let i = 0; i < tracks.length; i++) {
                const t = tracks[i];
                const item: PresetAudioTrack = {
                  trackIndex: t.index,
                  displayName: FfprobeUtil.buildAudioTrackDisplayName(t, i),
                  language: t.language,
                  mimeType: t.codecName
                };
                presetAudioTracks.push(item);
              }
            }
          }
          if (videoEntity.subtitleTracksJson !== null && videoEntity.subtitleTracksJson !== undefined) {
            dbHasSubtitleData = true;
            if (videoEntity.subtitleTracksJson.length > 0) {
              const subTracks = JSON.parse(videoEntity.subtitleTracksJson) as FfprobeTrack[];
              for (let i = 0; i < subTracks.length; i++) {
                const t = subTracks[i];
                const item: PresetSubtitleTrack = {
                  trackIndex: t.index,
                  displayName: FfprobeUtil.buildSubtitleTrackDisplayName(t, i),
                  language: t.language,
                  codecName: t.codecName
                };
                presetSubtitleTracks.push(item);
              }
            }
          }
        }
      } catch (e) {
        console.warn('[SeriesDetailPage] 数据库读取轨道失败，将 fallback 到 ffprobe: ' + JSON.stringify(e));
      }

      if (!dbHasAudioData || !dbHasSubtitleData) {
        try {
          const probeResult = await FfprobeUtil.probe(encodeURI(fullUrl), httpHeader, 15000);
          if (probeResult.success) {
            if (!dbHasAudioData) {
              for (let i = 0; i < probeResult.audioTracks.length; i++) {
                const t = probeResult.audioTracks[i];
                const item: PresetAudioTrack = {
                  trackIndex: t.index,
                  displayName: FfprobeUtil.buildAudioTrackDisplayName(t, i),
                  language: t.language,
                  mimeType: t.codecName
                };
                presetAudioTracks.push(item);
              }
            }
            if (!dbHasSubtitleData) {
              for (let i = 0; i < probeResult.subtitleTracks.length; i++) {
                const t = probeResult.subtitleTracks[i];
                const item: PresetSubtitleTrack = {
                  trackIndex: t.index,
                  displayName: FfprobeUtil.buildSubtitleTrackDisplayName(t, i),
                  language: t.language,
                  codecName: t.codecName
                };
                presetSubtitleTracks.push(item);
              }
            }
          }
        } catch (e) {
          console.warn('[SeriesDetailPage] ffprobe 异常，忽略: ' + JSON.stringify(e));
        }
      }

      const episodeName = await this.resolveEpisodeName(db, episode);
      const param: PlayerPageParam = {
        url: encodeURI(fullUrl),
        httpHeader,
        title: this.buildPlayerTitle(episode, episodeName),
        videoId: episode.id,
        seriesProviderId: this.seriesEntity?.providerId ?? '',
        seasonNumber: episode.seasonNumber ?? 0,
        episodeNumber: episode.episodeNumber ?? 0,
        presetAudioTracks: presetAudioTracks.length > 0 ? presetAudioTracks : undefined,
        presetSubtitleTracks: presetSubtitleTracks.length > 0 ? presetSubtitleTracks : undefined
      };
      this.pageStack.pushPathByName(PlayerPage.PAGE_NAME, param);
    } catch (e) {
      console.error('[SeriesDetailPage] playEpisode failed', JSON.stringify(e));
    }
  }

  /** 进度百分比（0~1） */
  private getEpisodeProgress(episode: MediaItem): number {
    const p = this.progressMap.get(episode.id ?? -1);
    if (p === undefined || p.positionMs <= 0 || p.durationMs <= 0) { return 0; }
    return Math.min(1, p.positionMs / p.durationMs);
  }

  /** 是否已看完（≥95%） */
  private isEpisodeWatched(episode: MediaItem): boolean {
    return this.getEpisodeProgress(episode) >= 0.95;
  }

  private isContinueActionFocused(action: string): boolean {
    return this.focusedContinueActionKey === action;
  }

  private isContinueActionHovered(action: string): boolean {
    return this.hoveredContinueActionKey === action;
  }

  private clearContinueActionFocusIfMatches(action: string): void {
    if (this.focusedContinueActionKey === action) {
      this.focusedContinueActionKey = '';
    }
  }

  private clearContinueActionHoverIfMatches(action: string): void {
    if (this.hoveredContinueActionKey === action) {
      this.hoveredContinueActionKey = '';
    }
  }

  private getContinueActionButtonBgColor(action: string): string {
    if (this.isContinueActionFocused(action)) {
      return '#3C8FF6';
    }
    if (this.isContinueActionHovered(action)) {
      return '#2E82EA';
    }
    return '#1B78F2';
  }

  private getContinueActionButtonBorderColor(action: string): string {
    if (this.isContinueActionFocused(action)) {
      return '#66A9D8FF';
    }
    if (this.isContinueActionHovered(action)) {
      return '#7FB7F4';
    }
    return '#00FFFFFF';
  }

  /** 继续播放卡片（右下角） */
  @Builder
  ContinueWatchingCard() {
    Column({ space: 0 }) {
      Row({ space: 14 }) {
        // 集缩略图：优先 stillPath/stillUrl，无则占位
        if (this.getResumeCardStillUrl().length > 0) {
          Image(this.getResumeCardStillUrl())
            .width(150).height(84)
            .borderRadius(4)
            .objectFit(ImageFit.Cover)
            .border({ width: 1, color: '#2E2E2E' })
        } else {
          Column()
            .width(150).height(84)
            .backgroundColor('#1C1C1C')
            .borderRadius(4)
            .border({ width: 1, color: '#2E2E2E' })
        }

        // 信息部分
        if (this.lastProgress !== null && this.lastEpisode !== null) {
          // ── 有播放记录 ──────────────────────────────────
          Column({ space: 10 }) {
            // 集号标签 + 标题
            Row({ space: 8 }) {
              Text(`S${String(this.lastProgress.seasonNumber).padStart(2, '0')}:E${String(this.lastProgress.episodeNumber).padStart(2, '0')}`)
                .fontSize(12)
                .fontColor('#1B78F2')
                .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                .backgroundColor('#192840')
                .borderRadius(3)
              Text(this.lastEpisode.title ?? this.lastEpisode.fileName)
                .fontSize(14).fontColor('#CCCCCC').fontWeight(FontWeight.Medium)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .alignItems(VerticalAlign.Center)

            // 进度条
            Column() {
              Column()
                .width(`${Math.round(this.getEpisodeProgress(this.lastEpisode) * 100)}%`)
                .height('100%')
                .backgroundColor('#1B78F2').borderRadius(2)
                .alignSelf(ItemAlign.Start)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%').height(4)
            .backgroundColor('#2E2E2E').borderRadius(2)

            // 播放按钮行
            Row({ space: 10 }) {
              Row({ space: 6 }) {
                Text('▶').fontSize(12).fontColor(Color.White)
                Text(this.isEpisodeWatched(this.lastEpisode) ? '重新播放' : '继续播放')
                  .fontSize(14).fontColor(Color.White).fontWeight(FontWeight.Bold)
              }
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.getContinueActionButtonBgColor('resume')).borderRadius(4)
              .border({ width: 2, color: this.getContinueActionButtonBorderColor('resume') })
              .focusable(true)
              .onFocus(() => { this.focusedContinueActionKey = 'resume'; })
              .onBlur(() => { this.clearContinueActionFocusIfMatches('resume'); })
              .onHover((isHover: boolean) => {
                if (isHover) {
                  this.hoveredContinueActionKey = 'resume';
                } else {
                  this.clearContinueActionHoverIfMatches('resume');
                }
              })
              .onClick(() => {
                if (this.lastEpisode !== null) { this.playEpisode(this.lastEpisode); }
              })

              Text(millisecondsToTime(this.lastProgress.positionMs))
                .fontSize(12).fontColor('#888888')
            }
            .alignItems(VerticalAlign.Center)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.SpaceBetween)
          .height(84)
        } else {
          // ── 无播放记录，显示第一集信息 ──────────────────────────────
          Column({ space: 10 }) {
            Row({ space: 8 }) {
              Text(this.getResumeCardEpLabel())
                .fontSize(12)
                .fontColor('#1B78F2')
                .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                .backgroundColor('#192840')
                .borderRadius(3)
              Text(this.getResumeCardTitle())
                .fontSize(14).fontColor('#CCCCCC').fontWeight(FontWeight.Medium)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .alignItems(VerticalAlign.Center)

            Column() {
              Column()
                .width('0%').height('100%')
                .backgroundColor('#1B78F2').borderRadius(2)
                .alignSelf(ItemAlign.Start)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%').height(4)
            .backgroundColor('#2E2E2E').borderRadius(2)

            Row({ space: 10 }) {
              Row({ space: 6 }) {
                Text('▶').fontSize(12).fontColor(Color.White)
                Text('开始播放').fontSize(14).fontColor(Color.White).fontWeight(FontWeight.Bold)
              }
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.getContinueActionButtonBgColor('start')).borderRadius(4)
              .border({ width: 2, color: this.getContinueActionButtonBorderColor('start') })
              .focusable(true)
              .onFocus(() => { this.focusedContinueActionKey = 'start'; })
              .onBlur(() => { this.clearContinueActionFocusIfMatches('start'); })
              .onHover((isHover: boolean) => {
                if (isHover) {
                  this.hoveredContinueActionKey = 'start';
                } else {
                  this.clearContinueActionHoverIfMatches('start');
                }
              })
              .onClick(() => {
                const eps = this.group?.episodes ?? [];
                if (eps.length > 0) { this.playEpisode(eps[0]); }
              })
            }
            .alignItems(VerticalAlign.Center)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.SpaceBetween)
          .height(84)
        }
      }
      .alignItems(VerticalAlign.Center)
    }
    .padding({ left: 16, right: 20, top: 14, bottom: 14 })
    .backgroundColor('#18FFFFFF')
    .borderRadius(8)
    .border({ width: 1, color: '#22FFFFFF' })
    .width(500)
  }

  @Builder
  HeroSection() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // ── 背景图（w1280）/ 渐变占位 ─────────────────
      if (this.getBackdropUrl().length > 0) {
        Image(this.getBackdropUrl())
          .width('100%').height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        Column()
          .width('100%').height('100%')
          .linearGradient({
            angle: 135,
            colors: [['#1A1A2E', 0.0], ['#16213E', 0.5], ['#0F3460', 1.0]]
          })
      }

      // ── 底部渐变遮罩 ──────────────────────────────
      Column()
        .width('100%').height('68%')
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.0], [this.toOpaqueColor(this.dominantBgColor), 1.0]]
        })
        .position({ left: 0, bottom: 0 })

      // ── 左侧渐变遮罩 ──────────────────────────────
      Column()
        .width('55%').height('100%')
        .linearGradient({
          angle: 90,
          colors: [[this.toOpaqueColor(this.dominantBgColor), 0.0], ['#00000000', 1.0]]
        })
        .position({ left: 0, top: 0 })

      // ── 底部内容行 ────────────────────────────────
      Row({ space: 40 }) {
        // 左侧：标题 / 元信息 / 简介
        Column({ space: 14 }) {
          Text(this.getTitle())
            .fontSize(52).fontColor(Color.White).fontWeight(FontWeight.Bold)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .textShadow({ radius: 8, color: '#88000000', offsetX: 2, offsetY: 2 })
            .constraintSize({ maxWidth: 720 })

          // 元信息行：年份 + 评分 + 类型标签
          Row({ space: 12 }) {
            if (this.getYear().length > 0) {
              Text(this.getYear())
                .fontSize(18).fontColor('#CCCCCC').fontWeight(FontWeight.Medium)
            }
            if (this.getRatingText().length > 0) {
              Row({ space: 4 }) {
                Text('★').fontSize(16).fontColor('#FFA500')
                Text(this.getRatingText())
                  .fontSize(18).fontColor('#FFA500').fontWeight(FontWeight.Bold)
              }
            }
            ForEach(this.getGenres().slice(0, 3), (genre: string) => {
              Text(genre)
                .fontSize(14).fontColor('#CCCCCC')
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(4)
                .border({ width: 1, color: '#55FFFFFF' })
            }, (genre: string) => genre)
          }
          .alignItems(VerticalAlign.Center)

          // 简介：超100字截断显示 + 「更多」Span，不超出仅显示原文
          if (this.getOverview().length > 0) {
            if (this.isOverviewLong()) {
              Text() {
                Span(this.getOverviewShort())
                  .fontSize(16).fontColor('#BBBBBB').lineHeight(26)
                Span('更多')
                  .fontSize(14).fontColor('#1B78F2')
                  .fontWeight(FontWeight.Medium)
                  .onClick(() => { this.showOverviewDialog = true; })
              }
              .constraintSize({ maxWidth: 700 })
            } else {
              Text(this.getOverview())
                .fontSize(16).fontColor('#BBBBBB').lineHeight(26)
                .constraintSize({ maxWidth: 700 })
            }
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 右侧：继续播放卡片（占位）
        this.ContinueWatchingCard()
      }
      .width('100%')
      .padding({ left: 80, right: 80, bottom: 52 })
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%').aspectRatio(1.778)
  }

  /** 季列表（横向滚动，带海报）+ 集列表（点击季后展开） */
  @Builder
  SeasonsSection() {
    if (this.seasons.length > 0) {
      Column({ space: 0 }) {
        Text('季')
          .fontSize(26).fontColor(Color.White).fontWeight(FontWeight.Bold)
          .padding({ left: 80, top: 36, bottom: 20 })

        Scroll() {
          Row({ space: 16 }) {
            ForEach(this.seasons, (s: TmdbRawSeason) => {
              Column({ space: 8 }) {
                // 季海报
                Stack({ alignContent: Alignment.Bottom }) {
                  if (this.getSeasonPosterUrl(s).length > 0) {
                    Image(this.getSeasonPosterUrl(s))
                      .width(140).aspectRatio(2 / 3)
                      .objectFit(ImageFit.Cover).borderRadius(6)
                      .hoverEffect(HoverEffect.Scale)
                  } else {
                    Column() {
                      Text(this.getSeasonLabel(s))
                        .fontSize(14).fontColor('#CCCCCC')
                        .textAlign(TextAlign.Center)
                    }
                    .width(140).aspectRatio(2 / 3)
                    .backgroundColor('#2A2A2A').borderRadius(6)
                    .justifyContent(FlexAlign.Center)
                    .hoverEffect(HoverEffect.Scale)
                  }
                }
                .width(140).aspectRatio(2 / 3)
                .borderRadius(6).clip(true)

                // 第N季标签
                Text(this.getSeasonLabel(s))
                  .fontSize(14)
                  .fontColor('#CCCCCC')
                  .fontWeight(FontWeight.Normal)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width(140).textAlign(TextAlign.Center)
              }
              .width(140).alignItems(HorizontalAlign.Start)
              .onClick(() => {
                // 构造 SeriesGroup 跳转季详情页
                const seasonGroup: SeriesGroup = {
                  title: this.getTitle(),
                  tvSeriesId: this.seriesEntity?.id,
                  seasonNumber: s.season_number ?? 0,
                  seasonLabel: this.getSeasonLabel(s),
                  seasonPosterUrl: this.getSeasonPosterUrl(s),
                  posterUrl: this.seriesEntity?.posterUrl ?? this.group?.posterUrl,
                  posterLocalPath: this.seriesEntity?.posterLocalPath ?? this.group?.posterLocalPath,
                  backdropUrl: this.seriesEntity?.backdropUrl ?? this.group?.backdropUrl,
                  rating: this.seriesEntity?.rating ?? this.group?.rating,
                  episodeCount: s.episode_count ?? 0,
                  episodes: [],
                  latestScannedAt: 0
                };
                this.pageStack.pushPathByName(SeasonDetailPage.PAGE_NAME, seasonGroup);
              })
            }, (s: TmdbRawSeason) => String(s.id ?? s.season_number ?? 0))
          }
          .padding({ left: 80, right: 80 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)

        Column().height(36)
      }
      .width('100%').alignItems(HorizontalAlign.Start)
      .backgroundColor(this.dominantBgColor)
    }
  }



  /** 演职人员横向滚动列表 */
  @Builder
  CastSection() {
    if (this.cast.length > 0) {
      Column({ space: 0 }) {
        Text('演职人员')
          .fontSize(26).fontColor(Color.White).fontWeight(FontWeight.Bold)
          .padding({ left: 80, top: 36, bottom: 20 })

        Scroll() {
          Row({ space: 24 }) {
            ForEach(this.cast.slice(0, 15), (c: ScrapeCredit) => {
              Column({ space: 8 }) {
                // 人物照片（长方形）
                if (this.getCastProfileUrl(c).length > 0) {
                  Image(this.getCastProfileUrl(c))
                    .width(110).aspectRatio(2 / 3)
                    .objectFit(ImageFit.Cover).borderRadius(6)
                    .hoverEffect(HoverEffect.Scale)
                } else {
                  Column() {
                    Text((c.name != null && c.name.length > 0) ? c.name.substring(0, 1) : '?')
                      .fontSize(30).fontColor(Color.White).fontWeight(FontWeight.Bold)
                  }
                  .width(110).aspectRatio(2 / 3).borderRadius(6)
                  .backgroundColor('#2A2A2A')
                  .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                  .hoverEffect(HoverEffect.Scale)
                }
                // 演员名
                Text(c.name ?? '')
                  .fontSize(14).fontColor(Color.White)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width(110).textAlign(TextAlign.Center)
                // 饰演角色
                if (c.role != null && c.role.length > 0) {
                  Text(c.role)
                    .fontSize(12).fontColor('#777777')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width(110).textAlign(TextAlign.Center)
                }
              }
              .width(110).alignItems(HorizontalAlign.Center)
            }, (c: ScrapeCredit) => c.name ?? '')
          }
          .padding({ left: 80, right: 80 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)

        Column().height(36)
      }
      .width('100%').alignItems(HorizontalAlign.Start)
      .backgroundColor(this.dominantBgColor)
    }
  }

  /** 相似剧横向滚动（0 条时整个 section 不渲染） */
  @Builder
  SimilarSection() {
    if (this.similarSeries.length > 0) {
      Column({ space: 0 }) {
        Text('更多类似')
          .fontSize(26).fontColor(Color.White).fontWeight(FontWeight.Bold)
          .padding({ left: 80, top: 36, bottom: 20 })

        Scroll() {
          Row({ space: 16 }) {
            ForEach(this.similarSeries, (item: SimilarSeriesItem) => {
              Column({ space: 6 }) {
                Stack({ alignContent: Alignment.BottomEnd }) {
                  if (item.posterUrl !== undefined && item.posterUrl.length > 0) {
                    Image(item.posterUrl)
                      .width(160).aspectRatio(2 / 3)
                      .objectFit(ImageFit.Cover).borderRadius(6)
                  } else if (item.posterLocalPath !== undefined && item.posterLocalPath.length > 0) {
                    Image(item.posterLocalPath)
                      .width(160).aspectRatio(2 / 3)
                      .objectFit(ImageFit.Cover).borderRadius(6)
                  } else {
                    Column() {
                      Text(item.title)
                        .fontSize(11).fontColor('#CCCCCC')
                        .textAlign(TextAlign.Center)
                        .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
                        .padding(8)
                    }
                    .width(160).aspectRatio(2 / 3)
                    .backgroundColor('#2A2A2A').borderRadius(6)
                    .justifyContent(FlexAlign.Center)
                  }
                  if (item.rating !== undefined && item.rating > 0) {
                    Text(item.rating.toFixed(1))
                      .fontSize(11).fontColor('#FFA500').fontWeight(FontWeight.Bold)
                      .padding({ left: 4, right: 4, bottom: 4 })
                  }
                }
                .width(160).aspectRatio(2 / 3)
                .borderRadius(6).clip(true)

                Text(item.title)
                  .fontSize(14).fontColor('#DDDDDD')
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width(160).textAlign(TextAlign.Center)
              }
              .width(160)
              .hoverEffect(HoverEffect.Scale)
              .onClick(() => {
                const g: SeriesGroup = this.buildSimilarGroup(item);
                this.pageStack.pushPathByName('seriesDetail', g);
              })
            }, (item: SimilarSeriesItem) => String(item.tvSeriesId))
          }
          .padding({ left: 80, right: 80 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)

        Column().height(36)
      }
      .width('100%').alignItems(HorizontalAlign.Start)
      .backgroundColor(this.dominantBgColor)
    }
  }

  /** 简介全文弹窗覆盖层 */
  @Builder
  OverviewDialog() {
    if (this.showOverviewDialog) {
      Stack({ alignContent: Alignment.Center }) {
        // 半透明遮罩
        Column()
          .width('100%').height('100%')
          .backgroundColor('#BB000000')
          .onClick(() => { this.showOverviewDialog = false; })

        // 卡片主体
        Column() {
          // ── 标题栏 ──────────────────────────────
          Row() {
            Text('简介')
              .fontSize(26).fontColor('#F0F0F0').fontWeight(FontWeight.Bold)
              .layoutWeight(1).textAlign(TextAlign.Center)
            Text('✕')
              .fontSize(20).fontColor('#888892')
              .width(48).height(48)
              .textAlign(TextAlign.Center)
              .borderRadius(24)
              .backgroundColor('#2A2A2E')
              .onClick(() => { this.showOverviewDialog = false; })
          }
          .alignItems(VerticalAlign.Center)
          .padding({ left: 24, right: 24, top: 0, bottom: 0 })
          .height(80)
          .width('100%')
          .backgroundColor('#1E1E22')

          // 分隔线
          Divider().color('#2E2E34').strokeWidth(1)

          // ── 内容区（左右双面板）────────────────────
          Row() {
            // 左面板：海报 + 剧集元数据
            Column({ space: 20 }) {
              // 海报缩略图
              Image(this.getDialogPosterUrl())
                .width(124).height(174)
                .borderRadius(6)
                .objectFit(ImageFit.Cover)
                .backgroundColor('#2A2A2E')

              // 剧集标题
              Text(this.getTitle())
                .fontSize(22).fontWeight(FontWeight.Bold).fontColor('#F0F0F0')
                .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
                .lineHeight(32)
                .width('100%')

              // 元数据
              Column({ space: 8 }) {
                if (this.getGenresText().length > 0) {
                  Text(`风格：${this.getGenresText()}`)
                    .fontSize(18).fontColor('#AAAAAA')
                }
                if (this.getTotalEpisodesText().length > 0) {
                  Text(`${this.getTotalEpisodesText()}`)
                    .fontSize(18).fontColor('#AAAAAA')
                }
                if (this.getYear().length > 0) {
                  Text(`${this.getYear()}`)
                    .fontSize(18).fontColor('#AAAAAA')
                }
              }
              .alignItems(HorizontalAlign.Start).width('100%')
            }
            .width('28%')
            .padding({ left: 48, right: 32, top: 48, bottom: 48 })
            .alignItems(HorizontalAlign.Start)

            // 垂直分隔线
            Divider().vertical(true).color('#2A2A2E').strokeWidth(1).height('100%')

            // 右面板：全文简介
            Scroll() {
              Text(this.getOverview())
                .fontSize(20).fontColor('#C8C8D0').lineHeight(36)
                .width('100%')
            }
            .scrollable(ScrollDirection.Vertical)
            .scrollBar(BarState.Auto)
            .scrollBarColor('#555560')
            .layoutWeight(1)
            .padding({ left: 40, right: 40, top: 48, bottom: 48 })
          }
          .alignItems(VerticalAlign.Top)
          .layoutWeight(1)
        }
        .width('85%').height('88%')
        .backgroundColor('#18181C')
        .borderRadius(16)
        .border({ width: 1, color: '#2A2A2E' })
        .clip(true)
      }
      .width('100%').height('100%')
    }
  }

  // ── 构建 ──────────────────────────────────────

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 主体滚动内容
        Scroll() {
          Column() {
            this.HeroSection()
            this.SeasonsSection()
            this.CastSection()
            this.SimilarSection()
            Column().height(80)
          }
          .width('100%')
          .backgroundColor(this.dominantBgColor)
        }
        .width('100%').height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)

        // 简介全文弹窗
        this.OverviewDialog()

        // 顶部透明导航栏（后退按钮）
        Row() {
          Text('←')
            .fontSize(30).fontColor(Color.White).fontWeight(FontWeight.Bold)
            .textShadow({ radius: 6, color: '#88000000', offsetX: 1, offsetY: 1 })
            .padding(20)
            .onClick(() => { this.pageStack.pop(); })
        }
        .width('100%')
        .padding({ left: 16, top: 8 })
        .linearGradient({
          angle: 180,
          colors: [['#AA000000', 0.0], ['#00000000', 1.0]]
        })
      }
      .width('100%').height('100%')
      .backgroundColor(this.dominantBgColor)
    }
    .onReady((context: NavDestinationContext) => {
      const param = context.pathInfo.param as SeriesGroup;
      if (param !== undefined && param !== null) {
        this.group = param;
        if (param.tvSeriesId !== undefined) {
          this.loadData(param.tvSeriesId);
        }
      }
    })
    .onBackPressed(() => {
      if (this.showOverviewDialog) {
        this.showOverviewDialog = false;
        return true;
      }
      return false;
    })
    .hideTitleBar(true)
  }
}
