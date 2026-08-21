import { SeriesGroup, TvSeriesEntity, TvSeasonEntity, TvEpisodeEntity, MediaItem, PlayProgressEntity, MediaProgressEntry } from '../../db/models/MediaEntity'
import { CastDetailPage, CastDetailPageParam } from './CastDetailPage'
import {
  DetailCastSection,
  DetailOverviewDialog,
  DetailCastMember,
  DetailHeroSection,
  DetailHeroData,
  DetailEpisodesSection,
  DetailEpisode
} from '../../components/detail/DetailSections'
import { FileSourceDatabase } from '../../db/files/FileSourceDatabase'
import { ScrapeCredit, extractImdbIdFromRawJson } from '../../lib/ScrapeClient'
import { PlayerPageParam, PlayerPage } from '../player/index'
import { MediaProgressStore } from '../../db/MediaProgressStore'
import http from '@ohos.net.http'
import image from '@ohos.multimedia.image'
import effectKit from '@ohos.effectKit'
import { defaultSourceAdapterService as sourceAdapter, identityToPlayerPageParams } from '../../services/sourceAdapter/SourceAdapterService'
import { FfprobeUtil, FfprobeTrack } from '../../utils/FfprobeUtil'
import { PresetAudioTrack, PresetSubtitleTrack } from '../../components/core/player/VideoData'
import { emitter } from "@kit.BasicServicesKit"
import { PlayerEvents } from '../../components/core/player/Constants'
import { MediaLibraryContext } from '../../components/core/player/PlaybackContext'
import { tmdbImageUrl, formatYear, parseGenresArr, translateJob, toChineseSeasonLabel, buildEpisodeCode, isGenericSeasonTitle, toOpaqueColor } from '../../utils/MediaFormatUtil'

// ─────────────────────────────────────────────
// 工具函数
// ─────────────────────────────────────────────

/** 将毫秒格式化为 "Xh Ym" 或 "Ym" */
function formatDuration(ms: number | undefined): string {
  if (ms === undefined || ms <= 0) { return ''; }
  const totalMins = Math.round(ms / 60000);
  const h = Math.floor(totalMins / 60);
  const m = totalMins % 60;
  if (h > 0) { return `${h}h ${m}m`; }
  return `${m}m`;
}

function formatProgressTime(ms: number): string {
  if (ms <= 0) { return ''; }
  const totalSeconds = Math.floor(ms / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  const mm = String(minutes).padStart(2, '0');
  const ss = String(seconds).padStart(2, '0');
  if (hours > 0) {
    const hh = String(hours).padStart(2, '0');
    return `${hh}:${mm}:${ss}`;
  }
  return `${mm}:${ss}`;
}

// ─────────────────────────────────────────────
// 内部类型
// ─────────────────────────────────────────────

/** season raw_json 中 guest_stars 条目 */
interface GuestStarRaw {
  name?: string;
  character?: string;
  profile_path?: string;
  order?: number;
}

/** season raw_json 中 crew 条目 */
interface CrewRaw {
  name?: string;
  job?: string;
  profile_path?: string;
}

/** season raw_json 顶层结构（TMDB TV Season detail） */
interface SeasonRawJson {
  name?: string;
  overview?: string;
  guest_stars?: GuestStarRaw[];
  crew?: CrewRaw[];
}

/** tv_series.raw_json 中 credits.cast 条目 */
interface TmdbSeriesCastItem {
  id?: number;
  name?: string;
  character?: string;
  profile_path?: string;
  order?: number;
}

/** tv_series.raw_json 中 credits.crew 条目 */
interface TmdbSeriesCrewItem {
  id?: number;
  name?: string;
  job?: string;
  profile_path?: string;
}

/** tv_series.raw_json 顶层 credits 节点 */
interface TmdbSeriesCredits {
  cast?: TmdbSeriesCastItem[];
  crew?: TmdbSeriesCrewItem[];
}

/** tv_series.raw_json 顶层结构（仅取 credits 字段） */
interface TmdbSeriesRawJson {
  credits?: TmdbSeriesCredits;
}

/** 集条目：持有文件媒体信息（播放用）+ 集元数据（展示用） */
interface SeasonEpisodeItem {
  mediaItem: MediaItem;
  episodeEntity: TvEpisodeEntity | undefined;
}

// ─────────────────────────────────────────────
// 季详情页
// ─────────────────────────────────────────────

@ComponentV2
export struct SeasonDetailPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  @Local group: SeriesGroup | undefined = undefined
  @Local seriesEntity: TvSeriesEntity | undefined = undefined
  @Local seasonEpisodes: SeasonEpisodeItem[] = []
  @Local cast: ScrapeCredit[] = []
  @Local isLoading: boolean = false
  @Local showOverviewDialog: boolean = false
  @Local dominantBgColor: string = '#111111'
  @Local progressMap: Map<number, PlayProgressEntity> = new Map()
  @Local seasonOverview: string = ''
  @Local seasonTitle: string = ''
  @Local seasonEntity: TvSeasonEntity | null = null
  /** 当前季是否存在播放进度（用于主按钮文案判断） */
  @Local hasCurrentSeasonProgress: boolean = false
  /** 主按钮目标集：有进度时为最近观看集，无进度时为第一集 */
  @Local resumeEpisode: MediaItem | undefined = undefined
  /** 跨季最近观看指针（整剧最近观看指针指向其他季时有值，与当前季是否有进度无关） */
  @Local crossSeasonEntry: MediaProgressEntry | null = null
  /** 跨季目标集 MediaItem（用于跨季次级入口点击直接播放） */
  @Local crossSeasonEpisode: MediaItem | undefined = undefined

  static PAGE_NAME = 'seasonDetail'

  private progressRefreshCallback: () => void = () => {};

  // ── 属性计算方法 ──────────────────────────────────

  private getSeasonNumber(): number { return this.group?.seasonNumber ?? 0; }

  private getSeasonLabel(): string {
    const n = this.getSeasonNumber();
    const base = n === 0 ? '特别篇' : `第 ${n} 季`;
    if (this.seasonTitle.length > 0 && !isGenericSeasonTitle(this.seasonTitle, n)) {
      return `${base}：${this.seasonTitle}`;
    }
    if (this.group?.seasonLabel !== undefined && this.group.seasonLabel.length > 0) {
      return this.group.seasonLabel;
    }
    return base;
  }

  private getSeasonNameForPlayer(): string {
    const n = this.getSeasonNumber();
    const title = this.seasonTitle.trim();
    if (title.length > 0 && !isGenericSeasonTitle(title, n)) {
      return title;
    }
    return '';
  }

  private buildPlayerTitle(episode: MediaItem, episodeName: string): string {
    const seriesTitle = this.getSeriesTitle().length > 0 ? this.getSeriesTitle() : (episode.title ?? episode.fileName);
    const sn = episode.seasonNumber ?? this.getSeasonNumber();
    const en = episode.episodeNumber ?? 0;
    const seasonLabel = toChineseSeasonLabel(sn);
    const seasonName = this.getSeasonNameForPlayer();
    const epName = episodeName.trim();
    const code = buildEpisodeCode(sn, en);
    const seasonPart = seasonName.length > 0 ? `${seasonLabel} ${seasonName}` : seasonLabel;
    return `${seriesTitle} ${seasonPart}-${code}-${epName}`;
  }

  private async resolveEpisodeName(db: FileSourceDatabase, episode: MediaItem): Promise<string> {
    const seriesTitle = this.getSeriesTitle().trim();
    const current = (episode.title ?? '').trim();
    const fileName = (episode.fileName ?? '').trim();
    const sn = episode.seasonNumber ?? this.getSeasonNumber();
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

  private getBackdropUrl(): string {
    const path = this.seriesEntity?.backdropPath;
    if (path !== undefined && path.length > 0) { return tmdbImageUrl(path, 'w1280'); }
    const url = this.seriesEntity?.backdropUrl ?? this.group?.backdropUrl;
    if (url !== undefined && url.length > 0) { return url; }
    return this.seriesEntity?.posterUrl ?? this.group?.posterUrl ?? '';
  }

  private getSeriesTitle(): string { return this.group?.title ?? ''; }

  private getYear(): string { return formatYear(this.seriesEntity?.firstAirDate); }

  private getRatingText(): string {
    const r = this.group?.rating ?? this.seriesEntity?.rating;
    if (r === undefined) { return ''; }
    return r.toFixed(1);
  }

  private getOverview(): string {
    if (this.seasonOverview.length > 0) { return this.seasonOverview; }
    return this.seriesEntity?.overview ?? '';
  }

  private getGenres(): string[] { return parseGenresArr(this.seriesEntity?.genresJson); }

  private getDialogPosterUrl(): string {
    // 优先用季海报
    const seasonUrl = this.seasonEntity?.posterUrl ?? this.group?.seasonPosterUrl;
    if (seasonUrl !== undefined && seasonUrl.length > 0) { return seasonUrl; }
    const seasonPath = this.seasonEntity?.posterPath;
    if (seasonPath !== undefined && seasonPath.length > 0) { return tmdbImageUrl(seasonPath, 'w342'); }
    // 回退到剧集海报
    const seriesPath = this.seriesEntity?.posterPath;
    if (seriesPath !== undefined && seriesPath.length > 0) { return tmdbImageUrl(seriesPath, 'w342'); }
    return this.seriesEntity?.posterUrl ?? this.group?.posterUrl ?? '';
  }

  private getGenresText(): string {
    const g = this.getGenres();
    if (g.length === 0) { return ''; }
    return g.slice(0, 3).join(' / ');
  }

  /** 演职人员统一展示数据（映射到公用组件） */
  private castMembers(): DetailCastMember[] {
    const result: DetailCastMember[] = []
    for (const c of this.cast) {
      result.push({
        name: c.name ?? '',
        role: c.role ?? '',
        imageUrl: (c.profilePath ?? '').length > 0 ? tmdbImageUrl(c.profilePath ?? '', 'w185') : '',
        personId: c.personId !== undefined && c.personId !== null && c.personId > 0 ? String(c.personId) : ''
      })
    }
    return result
  }

  private getEpisodeCount(): string {
    const cnt = this.seasonEpisodes.length;
    if (cnt <= 0) { return ''; }
    return `${cnt} 集`;
  }

  /** 集列表统一展示数据（映射到公用组件） */
  private episodeList(): DetailEpisode[] {
    const result: DetailEpisode[] = []
    for (const ep of this.seasonEpisodes) {
      const mediaItem = ep.mediaItem
      const progress = this.getEpisodeProgress(mediaItem)
      result.push({
        id: String(mediaItem.id ?? -1),
        label: this.getEpisodeLabel(ep),
        overview: this.getEpisodeOverview(ep),
        stillUrl: this.getEpisodeStillUrl(ep),
        durationText: this.getEpisodeDuration(ep),
        ratingText: this.getEpisodeRatingText(ep),
        progressPercent: progress,
        watched: this.isEpisodeWatched(mediaItem),
        placeholderText: String(mediaItem.episodeNumber ?? 0)
      })
    }
    return result
  }

  /** Hero 区统一数据（映射到公用组件） */
  private heroData(): DetailHeroData {
    const showCross = this.shouldShowCrossSeasonEntry();
    return {
      backdropUrl: this.getBackdropUrl(),
      dominantBgColor: this.dominantBgColor,
      supertitle: this.getSeriesTitle(),
      title: this.getSeasonLabel(),
      year: this.getYear(),
      ratingText: this.getRatingText(),
      countText: this.getEpisodeCount(),
      genres: this.getGenres(),
      overview: this.getOverview(),
      playLabel: this.getHeroPlayLabel(),
      onPlayClick: () => { this.handleHeroPlayClick(); },
      crossSeasonLabel: showCross ? this.getCrossSeasonLabel() : '',
      crossSeasonMetaLabel: showCross ? this.getCrossSeasonMetaLabel() : '',
      onCrossSeasonClick: () => { this.handleCrossSeasonClick(); },
      onShowOverview: () => { this.showOverviewDialog = true; }
    }
  }

  // ── 集条目辅助 ──────────────────────────────────

  private getEpisodeStillUrl(ep: SeasonEpisodeItem): string {
    const entity = ep.episodeEntity;
    if (entity !== undefined) {
      if (entity.stillUrl !== undefined && entity.stillUrl.length > 0) { return entity.stillUrl; }
      if (entity.stillPath !== undefined && entity.stillPath.length > 0) {
        return tmdbImageUrl(entity.stillPath, 'w342');
      }
    }
    return '';
  }

  private getEpisodeLabel(ep: SeasonEpisodeItem): string {
    const n = ep.mediaItem.episodeNumber ?? 0;
    const entity = ep.episodeEntity;
    if (entity !== undefined && entity.title !== undefined && entity.title.length > 0) {
      return `${n}. ${entity.title}`;
    }
    return `第 ${n} 集`;
  }

  private getEpisodeOverview(ep: SeasonEpisodeItem): string {
    const entity = ep.episodeEntity;
    if (entity !== undefined && entity.overview !== undefined && entity.overview.length > 0) {
      return entity.overview;
    }
    return ep.mediaItem.overview ?? '';
  }

  private getEpisodeRatingText(ep: SeasonEpisodeItem): string {
    const r = ep.episodeEntity?.rating ?? 0;
    if (r <= 0) { return ''; }
    return r.toFixed(1);
  }

  private getEpisodeDuration(ep: SeasonEpisodeItem): string {
    return formatDuration(ep.mediaItem.durationMs);
  }

  /** 播放进度百分比（0~1） */
  private getEpisodeProgress(mediaItem: MediaItem): number {
    const p = this.progressMap.get(mediaItem.id ?? -1);
    if (p === undefined || p.positionMs <= 0 || p.durationMs <= 0) { return 0; }
    return Math.min(1, p.positionMs / p.durationMs);
  }

  /** 是否已看完（≥95%） */
  private isEpisodeWatched(mediaItem: MediaItem): boolean {
    return this.getEpisodeProgress(mediaItem) >= 0.95;
  }

  private getProgressPercent(ep: SeasonEpisodeItem): string {
    const pct = Math.round(this.getEpisodeProgress(ep.mediaItem) * 100);
    return `${pct}%`;
  }

  // ── 主按钮 / 跨季次级入口 辅助 ──────────────────────────────────────

  /** 主按钮文案：有进度 → 继续本季；无进度 → 从本季开始 */
  private getHeroPlayLabel(): string {
    return this.hasCurrentSeasonProgress ? '继续本季' : '从本季开始';
  }

  /** 跨季次级入口文案，如"继续观看 S1E8" */
  private getCrossSeasonLabel(): string {
    const entry = this.crossSeasonEntry;
    if (entry === null) { return ''; }
    return `继续上次观看 S${entry.seasonNumber}E${entry.episodeNumber}`;
  }

  private getCrossSeasonMetaLabel(): string {
    const entry = this.crossSeasonEntry;
    if (entry === null) { return ''; }
    const episodeCode = `S${entry.seasonNumber}E${entry.episodeNumber}`;
    const progressText = formatProgressTime(entry.positionMs);
    if (progressText.length > 0) {
      return `${episodeCode} · ${progressText}`;
    }
    return episodeCode;
  }

  /** 是否显示跨季次级入口 */
  private shouldShowCrossSeasonEntry(): boolean {
    return this.crossSeasonEntry !== null
      && this.crossSeasonEpisode !== undefined;
  }

  /** 主按钮点击处理 */
  private handleHeroPlayClick(): void {
    const ep = this.resumeEpisode;
    if (ep !== undefined) {
      this.playEpisode(ep).catch(() => {
        console.warn('[SeasonDetailPage] handleHeroPlayClick playEpisode failed');
      });
    }
  }

  /** 跨季次级入口点击处理 */
  private handleCrossSeasonClick(): void {
    const ep = this.crossSeasonEpisode;
    if (ep !== undefined) {
      this.playEpisode(ep).catch(() => {
        console.warn('[SeasonDetailPage] handleCrossSeasonClick playEpisode failed');
      });
    }
  }

  private async refreshProgressState(): Promise<void> {
    const seriesProviderId = this.seriesEntity?.providerId ?? '';
    if (seriesProviderId.length === 0) {
      return;
    }
    const db = FileSourceDatabase.getInstance();
    const progressList = await db.getPlayProgressBySeriesContext(seriesProviderId, this.getSeasonNumber());
    const newMap = new Map<number, PlayProgressEntity>();
    for (const progress of progressList) {
      newMap.set(progress.videoId, progress);
    }
    this.progressMap = newMap;

    // ── 当前季进度计算：找 updatedAt 最大的有进度且未看完（<95%）的集 ─────
    let bestProgress: PlayProgressEntity | undefined;
    for (const ep of this.seasonEpisodes) {
      const p = newMap.get(ep.mediaItem.id ?? -1);
      if (p !== undefined && p.positionMs > 0) {
        // 若有 durationMs，排除已看完（≥95%）的集，保持与 playEpisode() 逻辑一致
        const isWatched = p.durationMs > 0 && (p.positionMs / p.durationMs) >= 0.95;
        if (!isWatched) {
          if (bestProgress === undefined || p.updatedAt > bestProgress.updatedAt) {
            bestProgress = p;
          }
        }
      }
    }
    this.hasCurrentSeasonProgress = bestProgress !== undefined;

    if (bestProgress !== undefined) {
      // 继续本季：找对应 MediaItem
      let found: MediaItem | undefined;
      for (const ep of this.seasonEpisodes) {
        if ((ep.mediaItem.id ?? -1) === bestProgress.videoId) {
          found = ep.mediaItem;
          break;
        }
      }
      // 若有进度记录但集已被删除/找不到，回退到首集，避免按钮失效
      this.resumeEpisode = found ?? (this.seasonEpisodes.length > 0 ? this.seasonEpisodes[0].mediaItem : undefined);
    } else {
      // 从本季开始：排序后首集
      this.resumeEpisode = this.seasonEpisodes.length > 0 ? this.seasonEpisodes[0].mediaItem : undefined;
    }

    // ── 跨季次级入口：读整剧最近观看指针（集级进度）────────────────────────────────
    const latestEntry = await MediaProgressStore.getLatestForSeries(seriesProviderId);
    const currentSeason = this.getSeasonNumber();
    if (latestEntry !== null
        && latestEntry.seasonNumber !== currentSeason
        && latestEntry.episodeNumber > 0) {
      this.crossSeasonEntry = latestEntry;
      // 跨季目标集查询：只取决于 latestEntry 是否指向其他季，与当前季是否有进度无关
      const seriesId = this.seriesEntity?.id ?? -1;
      if (seriesId > 0) {
        const allEpisodes = await db.getMediaItemsByTvSeriesId(seriesId);
        let found: MediaItem | undefined;
        for (const m of allEpisodes) {
          if ((m.seasonNumber ?? -1) === latestEntry.seasonNumber
              && (m.episodeNumber ?? -1) === latestEntry.episodeNumber) {
            found = m;
            break;
          }
        }
        this.crossSeasonEpisode = found;
      } else {
        // seriesId 缺失：清空残留，避免误判跨季入口可展示
        this.crossSeasonEpisode = undefined;
        this.crossSeasonEntry = null;
      }
    } else {
      this.crossSeasonEntry = null;
      this.crossSeasonEpisode = undefined;
    }
  }

  aboutToAppear(): void {
    this.refreshProgressState().catch(() => {
      console.warn('[SeasonDetailPage] aboutToAppear refresh failed');
    });
    this.progressRefreshCallback = () => {
      this.refreshProgressState().catch(() => {
        console.warn('[SeasonDetailPage] progress refresh on event failed');
      });
    };
    emitter.on(PlayerEvents.MEDIA_PROGRESS_SAVED, this.progressRefreshCallback);
  }

  aboutToDisappear(): void {
    emitter.off(PlayerEvents.MEDIA_PROGRESS_SAVED.eventId, this.progressRefreshCallback);
  }

  // ── 数据加载 ──────────────────────────────────

  private async loadData(seriesId: number, seasonNumber: number): Promise<void> {
    this.isLoading = true;
    try {
      const db = FileSourceDatabase.getInstance();

      // 加载剧集总信息（backdrop / overview 兜底）
      const entity = await db.getTvSeriesById(seriesId);
      if (entity !== null) {
        this.seriesEntity = entity;
        const bdUrl = this.getBackdropUrl();
        if (bdUrl.length > 0) { this.extractDominantColor(bdUrl); }
      }

      // 加载本季信息（overview / name 来自 season raw_json）
      this.seasonEntity = await db.getTvSeason(seriesId, seasonNumber);
      const seasonRawStr = this.seasonEntity?.rawJson;
      if (seasonRawStr !== undefined && seasonRawStr.length > 0) {
        try {
          const sJson = JSON.parse(seasonRawStr) as SeasonRawJson;
          const sOverview = sJson.overview;
          if (sOverview !== undefined && sOverview.length > 0) {
            this.seasonOverview = sOverview;
          }
          const sName = sJson.name;
          if (sName !== undefined && sName.length > 0) {
            this.seasonTitle = sName;
          }
        } catch (e) {
          console.warn('[SeasonDetailPage] 解析 season raw_json 失败', JSON.stringify(e));
        }
      }

      // 演职人员：从剧集 rawJson.credits 取 cast（演员）+ crew（幕后）
      const seriesRawStr = this.seriesEntity?.rawJson;
      if (seriesRawStr !== undefined && seriesRawStr.length > 0) {
        try {
          const seriesJson = JSON.parse(seriesRawStr) as TmdbSeriesRawJson;
          const allCredits: ScrapeCredit[] = [];
          const castItems = seriesJson.credits?.cast ?? [];
          for (const c of castItems.slice(0, 20)) {
            const cr: ScrapeCredit = {
              name: c.name ?? '',
              role: c.character,
              profilePath: c.profile_path,
              order: c.order,
              personId: c.id
            };
            allCredits.push(cr);
          }
          const castNames: string[] = [];
          for (const cr of allCredits) { castNames.push(cr.name); }
          const crewItems = seriesJson.credits?.crew ?? [];
          for (const c of crewItems) {
            const cName = c.name ?? '';
            if (castNames.indexOf(cName) >= 0) { continue; }
            const cr: ScrapeCredit = {
              name: cName,
              role: translateJob(c.job ?? ''),
              profilePath: c.profile_path,
              personId: c.id
            };
            allCredits.push(cr);
            castNames.push(cName);
          }
          if (allCredits.length > 0) { this.cast = allCredits.filter((cr: ScrapeCredit) => cr.name != null && cr.name.length > 0); }
        } catch (e) {
          console.warn('[SeasonDetailPage] 解析演职人员失败', JSON.stringify(e));
        }
      }

      // 加载本季 MediaItem（含 sourceId、filePath，用于播放）
      const allEpisodes = await db.getMediaItemsByTvSeriesId(seriesId);
      const seasonItems: MediaItem[] = allEpisodes.filter((m: MediaItem) => (m.seasonNumber ?? -1) === seasonNumber);

      // 加载本季 TvEpisodeEntity（含 title、still、overview、rating）
      const episodeEntities = await db.getEpisodesBySeriesAndSeason(seriesId, seasonNumber);
      const epMap = new Map<number, TvEpisodeEntity>();
      for (const e of episodeEntities) {
        epMap.set(e.episodeNumber, e);
      }

      // 合并 MediaItem + TvEpisodeEntity
      const items: SeasonEpisodeItem[] = seasonItems.map((m: MediaItem) => {
        const item: SeasonEpisodeItem = {
          mediaItem: m,
          episodeEntity: epMap.get(m.episodeNumber ?? -1)
        };
        return item;
      });
      this.seasonEpisodes = items;

      await this.refreshProgressState();
    } catch (e) {
      console.error('[SeasonDetailPage] loadData failed', JSON.stringify(e));
    } finally {
      this.isLoading = false;
    }
  }

  /** 下载 backdrop 并提取深色主色作为页面背景 */
  private async extractDominantColor(url: string): Promise<void> {
    try {
      const req = http.createHttp();
      let buf: ArrayBuffer | undefined;
      try {
        const resp = await req.request(url, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: 8000, readTimeout: 8000
        });
        req.destroy();
        if (resp.responseCode !== 200) { return; }
        buf = resp.result as ArrayBuffer;
      } catch (e) { req.destroy(); return; }
      if (buf === undefined || buf.byteLength === 0) { return; }

      const imgSrc = image.createImageSource(buf);
      const pixelMap = await imgSrc.createPixelMap({
        desiredSize: { width: 64, height: 36 },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      imgSrc.release();

      const picker = await effectKit.createColorPicker(pixelMap);
      const mainColor = picker.getMainColorSync();
      pixelMap.release();

      const darken = (v: number): number => Math.round(v * 0.4);
      const toHex = (v: number): string => { const h = v.toString(16); return h.length < 2 ? '0' + h : h; };
      const r = darken(mainColor.red & 0xFF);
      const g = darken(mainColor.green & 0xFF);
      const b = darken(mainColor.blue & 0xFF);
      this.dominantBgColor = '#' + toHex(r) + toHex(g) + toHex(b);
    } catch (e) {
      console.warn('[SeasonDetailPage] extractDominantColor failed', JSON.stringify(e));
    }
  }

  /** 点击集 → 导航到播放器 */
  private async playEpisode(episode: MediaItem): Promise<void> {
    try {
      const db = FileSourceDatabase.getInstance();

      const fileSource = await db.getFileSourceById(episode.sourceId);
      if (fileSource === null) {
        console.warn('[SeasonDetailPage] 找不到文件源 sourceId=' + episode.sourceId);
        return;
      }
      // 协议拼装与 DB 落库元数据已统一收口到 SourceAdapterService。
      const resolved = await sourceAdapter.resolveFromFileSource(fileSource, episode.filePath, episode.id ?? 0);
      if (resolved === null) {
        console.warn('[SeasonDetailPage] 暂不支持的文件源类型: ' + fileSource.type);
        return;
      }
      const identityParams = identityToPlayerPageParams(resolved.sourceIdentity);
      const fileSourceType = identityParams.fileSourceType;
      const fileSourceId = identityParams.fileSourceId;

      // ── ffprobe 回填：DB 缺数据时再补探测（页面级关注点，留在 page 层） ──
      // 注意：`resolved.url` 与 `resolved.httpHeader` 已编码，传给 ffprobe 时禁止再次 encodeURI。
      let presetAudioTracks: PresetAudioTrack[] = resolved.presetAudioTracks ?? [];
      let presetSubtitleTracks: PresetSubtitleTrack[] = resolved.presetSubtitleTracks ?? [];
      let durationHintMs: number = resolved.durationHintMs ?? episode.durationMs ?? 0;
      let dbHasAudioData: boolean = resolved.presetAudioTracks !== undefined
        && resolved.presetAudioTracks.length > 0;
      let dbHasSubtitleData: boolean = resolved.presetSubtitleTracks !== undefined
        && resolved.presetSubtitleTracks.length > 0;

      if (!dbHasAudioData || !dbHasSubtitleData || durationHintMs <= 0) {
        try {
          const probeResult = await FfprobeUtil.probe(resolved.url, resolved.httpHeader, 15000);
          if (probeResult.success) {
            if (durationHintMs <= 0 && probeResult.durationMs > 0) {
              durationHintMs = probeResult.durationMs;
            }
            if (!dbHasAudioData) {
              presetAudioTracks = FfprobeUtil.toPresetAudioTracks(probeResult.audioTracks);
            }
            if (!dbHasSubtitleData) {
              presetSubtitleTracks = FfprobeUtil.toPresetSubtitleTracks(probeResult.subtitleTracks);
            }
          }
        } catch (e) {
          console.warn('[SeasonDetailPage] ffprobe 异常，忽略: ' + JSON.stringify(e));
        }
      }

      const startPositionMs: number = resolved.startPositionMs ?? 0;

      const episodeName = await this.resolveEpisodeName(db, episode);
      const seriesProviderId = this.seriesEntity?.providerId ?? '';
      const episodeSeason = episode.seasonNumber ?? 0;
      const episodeNum = episode.episodeNumber ?? 0;
      // 集级 key：每集独立存储进度，避免跨集覆盖
      const mKey = (seriesProviderId.length > 0 && episodeNum > 0)
        ? MediaProgressStore.episodeKey(seriesProviderId, episodeSeason, episodeNum)
        : undefined;

      // 构建播放上下文：查询当季集列表并定位当前集，供播放器内连播使用
      const seriesDbId = this.seriesEntity?.id ?? 0;
      let playbackContext: MediaLibraryContext | undefined = undefined;
      // episodeSeason=0 表示 seasonNumber 缺失，跳过无意义的 DB 查询
      if (seriesDbId > 0 && episodeSeason > 0) {
        try {
          playbackContext = await MediaLibraryContext.build(db, seriesDbId, episodeSeason, episode.filePath);
        } catch (e) {
          console.warn('[SeasonDetailPage] MediaLibraryContext.build 失败，跳过: ' + JSON.stringify(e));
        }
      }

      const param: PlayerPageParam = {
        // getFullUrl() 已编码，传给播放页时保持原值，避免二次编码。
        url: resolved.url,
        httpHeader: resolved.httpHeader,
        title: this.buildPlayerTitle(episode, episodeName),
        durationHintMs: durationHintMs > 0 ? durationHintMs : undefined,
        videoId: episode.id,
        seriesProviderId,
        seasonNumber: episodeSeason,
        episodeNumber: episodeNum,
        presetAudioTracks: presetAudioTracks.length > 0 ? presetAudioTracks : undefined,
        presetSubtitleTracks: presetSubtitleTracks.length > 0 ? presetSubtitleTracks : undefined,
        mediaKey: mKey,
        startPositionMs: startPositionMs > 0 ? startPositionMs : undefined,
        playbackContext,
        scrapeOriginalTitle: this.seriesEntity?.originalTitle,
        tmdbId: this.seriesEntity?.providerId,
        imdbId: extractImdbIdFromRawJson(this.seriesEntity?.rawJson),
        fileSourceType,
        fileSourceId,
        // 透传封面字段，供系统媒体中心（AVSession）展示海报
        posterLocalPath: this.seriesEntity?.posterLocalPath ?? undefined,
        posterUrl: this.seriesEntity?.posterUrl ?? undefined,
        backdropLocalPath: this.seriesEntity?.backdropLocalPath ?? undefined,
        backdropUrl: this.seriesEntity?.backdropUrl ?? undefined
      };
      this.pageStack.pushPathByName(PlayerPage.PAGE_NAME, param, (popInfo: PopInfo) => {
        if (popInfo.result !== null && popInfo.result !== undefined) {
          const r = popInfo.result as Record<string, Object>;
          if (r['fileNotFound'] === true) {
            const vid = r['videoId'] as number;
            if (vid > 0) { this.confirmDeleteEpisodeRecord(vid); }
          }
        }
      });
    } catch (e) {
      console.error('[SeasonDetailPage] playEpisode failed', JSON.stringify(e));
    }
  }

  /** 弹窗询问用户是否删除文件不存在的集记录 */
  private confirmDeleteEpisodeRecord(videoId: number): void {
    this.getUIContext().showAlertDialog({
      title: '文件无法播放',
      message: '视频文件可能已被删除或移动，无法打开。是否删除该集的本地记录和元数据？',
      autoCancel: true,
      primaryButton: {
        value: '删除记录',
        fontColor: '#FF5252',
        action: () => {
          FileSourceDatabase.getInstance().deleteVideoWithScrapeInfo(videoId)
            .then(() => { this.reloadSeasonEpisodes(); })
            .catch(() => {});
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {}
      }
    });
  }

  /** 删除后重新从 DB 加载本季集列表 */
  private reloadSeasonEpisodes(): void {
    const seriesId = this.seriesEntity?.id;
    if (seriesId === undefined) { return; }
    const seasonNumber = this.getSeasonNumber();
    const db = FileSourceDatabase.getInstance();
    db.getMediaItemsByTvSeriesId(seriesId).then((allEpisodes) => {
      const seasonItems: MediaItem[] = allEpisodes.filter((m: MediaItem) => (m.seasonNumber ?? -1) === seasonNumber);
      db.getEpisodesBySeriesAndSeason(seriesId, seasonNumber).then((episodeEntities) => {
        const epMap = new Map<number, TvEpisodeEntity>();
        for (const e of episodeEntities) {
          epMap.set(e.episodeNumber, e);
        }
        const items: SeasonEpisodeItem[] = seasonItems.map((m: MediaItem) => {
          const item: SeasonEpisodeItem = {
            mediaItem: m,
            episodeEntity: epMap.get(m.episodeNumber ?? -1)
          };
          return item;
        });
        this.seasonEpisodes = items;
      }).catch(() => {});
    }).catch(() => {});
  }

  // ── 构建 ──────────────────────────────────────

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 主体滚动内容
        Scroll() {
          Column() {
            DetailHeroSection({ data: this.heroData() })
            DetailEpisodesSection({
              episodes: this.episodeList(),
              onEpisodeClick: (e: DetailEpisode) => {
                const orig = this.seasonEpisodes.find(x => String(x.mediaItem.id ?? -1) === e.id)
                if (orig !== undefined) {
                  this.playEpisode(orig.mediaItem)
                }
              }
            })
            DetailCastSection({
              members: this.castMembers(),
              onCastClick: (c: DetailCastMember) => {
                const personId = parseInt(c.personId)
                if (personId > 0) {
                  const param: CastDetailPageParam = { personId: personId, name: c.name }
                  this.pageStack.pushPathByName(CastDetailPage.PAGE_NAME, param)
                }
              }
            })
            Column().height(80)
          }
          .width('100%')
          .backgroundColor(this.dominantBgColor)
        }
        .width('100%').height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)

        // 简介全文弹窗
        DetailOverviewDialog({
          visible: this.showOverviewDialog,
          title: this.getSeriesTitle(),
          posterUrl: this.getDialogPosterUrl(),
          overview: this.getOverview(),
          genresText: this.getGenresText(),
          runtimeText: '',
          year: this.getYear(),
          onClose: () => { this.showOverviewDialog = false }
        })


      }
      .width('100%').height('100%')
      .backgroundColor(this.dominantBgColor)
    }
    .onReady((context: NavDestinationContext) => {
      const param = context.pathInfo.param as SeriesGroup;
      if (param !== undefined && param !== null) {
        this.group = param;
        const tvSeriesId = param.tvSeriesId;
        const seasonNumber = param.seasonNumber;
        if (tvSeriesId !== undefined && seasonNumber !== undefined) {
          this.loadData(tvSeriesId, seasonNumber);
        }
      }
    })
    .onShown(() => {
      this.refreshProgressState().catch(() => {});
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
