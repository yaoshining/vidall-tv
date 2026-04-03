import { SeriesGroup, TvSeriesEntity, TvSeasonEntity, TvEpisodeEntity, MediaItem, PlayProgressEntity, MediaProgressEntry } from '../../db/models/MediaEntity'
import { CastDetailPage, CastDetailPageParam } from './CastDetailPage'
import { FileSourceDatabase } from '../../db/files/FileSourceDatabase'
import { ScrapeCredit } from '../../lib/ScrapeClient'
import { PlayerPageParam, PlayerPage } from '../player/index'
import { MediaProgressStore } from '../../db/MediaProgressStore'
import http from '@ohos.net.http'
import image from '@ohos.multimedia.image'
import effectKit from '@ohos.effectKit'
import { WebDAVClient, WebDAVConfig } from '../../lib/WebDAVClient'
import { FileSourceType, SMBSourceConfig } from '../../db/models/FileSourceEntity'
import { FfprobeUtil, FfprobeTrack } from '../../utils/FfprobeUtil'
import { PresetAudioTrack, PresetSubtitleTrack } from '../../components/core/player/VideoData'

// ─────────────────────────────────────────────
// 工具函数
// ─────────────────────────────────────────────

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
  @Local focusedEpisodeActionKey: string = ''
  @Local hoveredEpisodeActionKey: string = ''
  @Local focusedHeroActionKey: string = ''
  @Local hoveredHeroActionKey: string = ''
  @Local focusedEpisodeRowId: number = -1
  @Local hoveredEpisodeRowId: number = -1
  /** 当前季是否存在播放进度（用于主按钮文案判断） */
  @Local hasCurrentSeasonProgress: boolean = false
  /** 主按钮目标集：有进度时为最近观看集，无进度时为第一集 */
  @Local resumeEpisode: MediaItem | undefined = undefined
  /** 跨季最近观看指针（当前季无进度且其他季有最近观看时才有值） */
  @Local crossSeasonEntry: MediaProgressEntry | null = null
  /** 跨季目标集 MediaItem（用于跨季次级入口点击直接播放） */
  @Local crossSeasonEpisode: MediaItem | undefined = undefined

  static PAGE_NAME = 'seasonDetail'

  // ── 属性计算方法 ──────────────────────────────────

  private getSeasonNumber(): number { return this.group?.seasonNumber ?? 0; }

  private getSeasonLabel(): string {
    const n = this.getSeasonNumber();
    const base = n === 0 ? '特别篇' : `第 ${n} 季`;
    if (this.seasonTitle.length > 0 && !this.isGenericSeasonTitle(this.seasonTitle, n)) {
      return `${base}：${this.seasonTitle}`;
    }
    if (this.group?.seasonLabel !== undefined && this.group.seasonLabel.length > 0) {
      return this.group.seasonLabel;
    }
    return base;
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

  private getSeasonNameForPlayer(): string {
    const n = this.getSeasonNumber();
    const title = this.seasonTitle.trim();
    if (title.length > 0 && !this.isGenericSeasonTitle(title, n)) {
      return title;
    }
    return '';
  }

  private buildPlayerTitle(episode: MediaItem, episodeName: string): string {
    const seriesTitle = this.getSeriesTitle().length > 0 ? this.getSeriesTitle() : (episode.title ?? episode.fileName);
    const sn = episode.seasonNumber ?? this.getSeasonNumber();
    const en = episode.episodeNumber ?? 0;
    const seasonLabel = this.toChineseSeasonLabel(sn);
    const seasonName = this.getSeasonNameForPlayer();
    const epName = episodeName.trim();
    const code = this.buildEpisodeCode(sn, en);
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

  /** 判断季名是否是通用季名（即和 base 含义相同，不需要拼接显示） */
  private isGenericSeasonTitle(title: string, n: number): boolean {
    const t = title.trim().toLowerCase();
    // 匹配 "season 1"、"season1"、"第1季"、"第一季"、"第 1 季" 等
    if (/^season\s*\d+$/.test(t)) { return true; }
    if (/^第\s*\d+\s*季$/.test(t)) { return true; }
    const chineseNums = ['零','一','二','三','四','五','六','七','八','九','十',
      '十一','十二','十三','十四','十五','十六','十七','十八','十九','二十'];
    if (n >= 0 && n < chineseNums.length) {
      if (t === `第${chineseNums[n]}季`) { return true; }
    }
    return false;
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

  private isOverviewLong(): boolean { return this.getOverview().length > 100; }

  private getOverviewShort(): string { return this.getOverview().substring(0, 100) + '...'; }

  private toOpaqueColor(hex: string): string { return '#FF' + hex.substring(1); }

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

  private getEpisodeCount(): string {
    const cnt = this.seasonEpisodes.length;
    if (cnt <= 0) { return ''; }
    return `${cnt} 集`;
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

  private getEpisodeRowId(ep: SeasonEpisodeItem): number {
    return ep.mediaItem.id ?? -1;
  }

  private isEpisodeRowFocused(ep: SeasonEpisodeItem): boolean {
    return this.focusedEpisodeRowId === this.getEpisodeRowId(ep);
  }

  private isEpisodeRowHovered(ep: SeasonEpisodeItem): boolean {
    return this.hoveredEpisodeRowId === this.getEpisodeRowId(ep);
  }

  private isEpisodeRowActive(ep: SeasonEpisodeItem): boolean {
    return this.isEpisodeRowFocused(ep) || this.isEpisodeRowHovered(ep);
  }

  private clearEpisodeRowFocusIfMatches(ep: SeasonEpisodeItem): void {
    const id = this.getEpisodeRowId(ep);
    if (this.focusedEpisodeRowId === id) {
      this.focusedEpisodeRowId = -1;
    }
  }

  private clearEpisodeRowHoverIfMatches(ep: SeasonEpisodeItem): void {
    const id = this.getEpisodeRowId(ep);
    if (this.hoveredEpisodeRowId === id) {
      this.hoveredEpisodeRowId = -1;
    }
  }

  private getEpisodeRowBgColor(ep: SeasonEpisodeItem): string {
    if (this.isEpisodeRowFocused(ep)) {
      return 'rgba(255, 255, 255, 0.10)';
    }
    if (this.isEpisodeRowHovered(ep)) {
      return 'rgba(255, 255, 255, 0.06)';
    }
    return '#00000000';
  }

  private getEpisodeRowBorderColor(ep: SeasonEpisodeItem): string {
    if (this.isEpisodeRowFocused(ep)) {
      return '#66A9D8FF';
    }
    if (this.isEpisodeRowHovered(ep)) {
      return 'rgba(255, 255, 255, 0.32)';
    }
    return '#00FFFFFF';
  }

  private buildEpisodeActionKey(ep: SeasonEpisodeItem, action: string): string {
    const id = ep.mediaItem.id ?? -1;
    return `${id}-${action}`;
  }

  private isEpisodeActionFocused(ep: SeasonEpisodeItem, action: string): boolean {
    return this.focusedEpisodeActionKey === this.buildEpisodeActionKey(ep, action);
  }

  private isEpisodeActionHovered(ep: SeasonEpisodeItem, action: string): boolean {
    return this.hoveredEpisodeActionKey === this.buildEpisodeActionKey(ep, action);
  }

  private clearEpisodeActionFocusIfMatches(ep: SeasonEpisodeItem, action: string): void {
    const key = this.buildEpisodeActionKey(ep, action);
    if (this.focusedEpisodeActionKey === key) {
      this.focusedEpisodeActionKey = '';
    }
  }

  private clearEpisodeActionHoverIfMatches(ep: SeasonEpisodeItem, action: string): void {
    const key = this.buildEpisodeActionKey(ep, action);
    if (this.hoveredEpisodeActionKey === key) {
      this.hoveredEpisodeActionKey = '';
    }
  }

  private getEpisodeActionCircleBg(ep: SeasonEpisodeItem, action: string): string {
    if (this.isEpisodeActionFocused(ep, action)) {
      return 'rgba(27, 120, 242, 0.36)';
    }
    if (this.isEpisodeActionHovered(ep, action)) {
      return 'rgba(255, 255, 255, 0.20)';
    }
    return this.getEpisodeActionButtonBgColor();
  }

  private getEpisodeActionCircleBorder(ep: SeasonEpisodeItem, action: string): string {
    if (this.isEpisodeActionFocused(ep, action)) {
      return '#66A9D8FF';
    }
    if (this.isEpisodeActionHovered(ep, action)) {
      return 'rgba(255, 255, 255, 0.38)';
    }
    return 'rgba(255, 255, 255, 0.18)';
  }

  private isHeroActionFocused(action: string): boolean {
    return this.focusedHeroActionKey === action;
  }

  private isHeroActionHovered(action: string): boolean {
    return this.hoveredHeroActionKey === action;
  }

  private isHeroActionActive(action: string): boolean {
    return this.isHeroActionFocused(action) || this.isHeroActionHovered(action);
  }

  private clearHeroActionFocusIfMatches(action: string): void {
    if (this.focusedHeroActionKey === action) {
      this.focusedHeroActionKey = '';
    }
  }

  private clearHeroActionHoverIfMatches(action: string): void {
    if (this.hoveredHeroActionKey === action) {
      this.hoveredHeroActionKey = '';
    }
  }

  private getHeroPlayButtonBgColor(): string {
    if (this.isHeroActionFocused('play')) {
      return '#3C8FF6';
    }
    if (this.isHeroActionHovered('play')) {
      return '#2E82EA';
    }
    return '#1B78F2';
  }

  private getHeroPlayButtonShadowColor(): string {
    if (this.isHeroActionFocused('play')) {
      return 'rgba(27, 120, 242, 0.46)';
    }
    if (this.isHeroActionHovered('play')) {
      return 'rgba(27, 120, 242, 0.30)';
    }
    return 'rgba(27, 120, 242, 0.20)';
  }

  private getHeroSecondaryButtonBgColor(action: string): string {
    if (this.isHeroActionFocused(action)) {
      return 'rgba(27, 120, 242, 0.26)';
    }
    if (this.isHeroActionHovered(action)) {
      return 'rgba(255, 255, 255, 0.14)';
    }
    return 'rgba(33, 37, 43, 0.90)';
  }

  private getHeroSecondaryButtonBorderColor(action: string): string {
    if (this.isHeroActionFocused(action)) {
      return '#66A9D8FF';
    }
    if (this.isHeroActionHovered(action)) {
      return 'rgba(255, 255, 255, 0.38)';
    }
    return '#00FFFFFF';
  }

  private getHeroSecondaryButtonShadowColor(action: string): string {
    if (this.isHeroActionFocused(action)) {
      return 'rgba(102, 169, 216, 0.24)';
    }
    if (this.isHeroActionHovered(action)) {
      return 'rgba(0, 0, 0, 0.26)';
    }
    return 'rgba(0, 0, 0, 0.18)';
  }

  private getHeroSecondaryTitleColor(action: string): string {
    if (this.isHeroActionActive(action)) {
      return '#FFFFFF';
    }
    return '#DDE3EB';
  }

  private getHeroSecondaryMetaColor(action: string): string {
    if (this.isHeroActionFocused(action)) {
      return '#D3E7FF';
    }
    if (this.isHeroActionHovered(action)) {
      return '#C7CDD6';
    }
    return '#9AA3AF';
  }

  private getHeroPrimaryButtonScale(): number {
    return this.isHeroActionActive('play') ? 1.03 : 1.0;
  }

  private getHeroSecondaryButtonScale(action: string): number {
    return this.isHeroActionActive(action) ? 1.02 : 1.0;
  }

  private getHeroPlayButtonBorderColor(): string {
    if (this.isHeroActionFocused('play')) {
      return '#66A9D8FF';
    }
    if (this.isHeroActionHovered('play')) {
      return '#7FB7F4';
    }
    return '#00FFFFFF';
  }

  private getEpisodeActionButtonBgColor(): string {
    return '#662C2F33';
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
    return '继续上次观看';
  }

  private getCrossSeasonMetaLabel(): string {
    const entry = this.crossSeasonEntry;
    if (entry === null) { return ''; }
    const seasonText = `第 ${entry.seasonNumber} 季`;
    const episodeText = `第 ${entry.episodeNumber} 集`;
    const progressText = formatProgressTime(entry.positionMs);
    if (progressText.length > 0) {
      return `${seasonText} · ${episodeText} ${progressText}`;
    }
    return `${seasonText} · ${episodeText}`;
  }

  /** 是否显示跨季次级入口 */
  private shouldShowCrossSeasonEntry(): boolean {
    return !this.hasCurrentSeasonProgress
      && this.crossSeasonEntry !== null
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
      this.resumeEpisode = found;
    } else {
      // 从本季开始：排序后首集
      this.resumeEpisode = this.seasonEpisodes.length > 0 ? this.seasonEpisodes[0].mediaItem : undefined;
    }

    // ── 跨季次级入口：读整剧最近观看指针 ────────────────────────────────
    const seriesKey = MediaProgressStore.seriesKey(seriesProviderId);
    const latestEntry = await MediaProgressStore.get(seriesKey);
    const currentSeason = this.getSeasonNumber();
    if (latestEntry !== null
        && latestEntry.seasonNumber !== currentSeason
        && latestEntry.seasonNumber > 0
        && latestEntry.episodeNumber > 0) {
      this.crossSeasonEntry = latestEntry;
      // 仅在当前季无未看完进度时，才需要查找跨季目标集（UI 才会展示跨季入口）
      if (!this.hasCurrentSeasonProgress) {
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
        // 当前季有进度：不需要展示跨季入口，清空残留
        this.crossSeasonEpisode = undefined;
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

      // 查询该集的历史播放进度（per-episode，不影响其他集/季进度）
      let startPositionMs: number = 0;
      const episodeId = episode.id ?? 0;
      if (episodeId > 0) {
        const epProgress = await db.getPlayProgress(episodeId);
        if (epProgress !== null && epProgress.positionMs > 0) {
          const isWatched = epProgress.durationMs > 0
            && epProgress.positionMs >= epProgress.durationMs * 0.95;
          if (!isWatched) {
            startPositionMs = epProgress.positionMs;
          }
        }
      }

      const fileSource = await db.getFileSourceById(episode.sourceId);
      if (fileSource === null) {
        console.warn('[SeasonDetailPage] 找不到文件源 sourceId=' + episode.sourceId);
        return;
      }
      const config = JSON.parse(fileSource.configJson) as Record<string, string>;

      let fullUrl: string;
      let httpHeader: Record<string, string>;

      if (fileSource.type === FileSourceType.SMB) {
        const smbConfig = JSON.parse(fileSource.configJson) as SMBSourceConfig;
        const port = smbConfig.port ?? 445;
        const user = encodeURIComponent(smbConfig.username);
        const pass = encodeURIComponent(smbConfig.password);
        const encodedPath = episode.filePath.split('/').map((seg: string): string => {
          if (seg.length === 0) { return ''; }
          let decoded: string = seg;
          try { decoded = decodeURIComponent(seg); } catch { decoded = seg; }
          return encodeURIComponent(decoded);
        }).join('/');
        fullUrl = `smb://${user}:${pass}@${smbConfig.host}:${port}${encodedPath}`;
        httpHeader = {};
      } else {
        const protocol = config['protocol'] ?? 'http';
        const host = config['url'] ?? '';
        const port = config['port'] ?? (protocol === 'https' ? '443' : '80');
        const rootPath = (config['rootPath'] ?? '').replace(/\/$/, '');
        const baseUrl = `${protocol}://${host}:${port}${rootPath}`;
        const webdavConfig: WebDAVConfig = {
          baseUrl, username: config['username'] ?? '', password: config['password'] ?? '', timeout: 30000
        };
        const client = new WebDAVClient(webdavConfig);
        fullUrl = client.getFullUrl(episode.filePath);
        const authHeader = client.getAuthHeaderPublic();
        httpHeader = authHeader ? { 'Authorization': authHeader } : {};
      }

      // ── 音轨 / 字幕轨 ──────────────────────────
      let presetAudioTracks: PresetAudioTrack[] = [];
      let presetSubtitleTracks: PresetSubtitleTrack[] = [];
      let durationHintMs: number = episode.durationMs ?? 0;
      let dbHasAudioData = false;
      let dbHasSubtitleData = false;

      try {
        const videoEntity = await db.getVideoByPath(episode.filePath);
        if (videoEntity) {
          if (videoEntity.durationMs !== undefined && videoEntity.durationMs !== null && videoEntity.durationMs > 0) {
            durationHintMs = videoEntity.durationMs;
          }
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
        console.warn('[SeasonDetailPage] 数据库读取轨道失败，将 fallback 到 ffprobe: ' + JSON.stringify(e));
      }

      if (!dbHasAudioData || !dbHasSubtitleData || durationHintMs <= 0) {
        try {
          // getFullUrl() 已完成编码，这里禁止再次 encodeURI，避免 % -> %25。
          const probeResult = await FfprobeUtil.probe(fullUrl, httpHeader, 15000);
          if (probeResult.success) {
            if (durationHintMs <= 0 && probeResult.durationMs > 0) {
              durationHintMs = probeResult.durationMs;
            }
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
          console.warn('[SeasonDetailPage] ffprobe 异常，忽略: ' + JSON.stringify(e));
        }
      }

      const episodeName = await this.resolveEpisodeName(db, episode);
      const seriesProviderId = this.seriesEntity?.providerId ?? '';
      const mKey = seriesProviderId.length > 0 ? MediaProgressStore.seriesKey(seriesProviderId) : undefined;
      const param: PlayerPageParam = {
        // getFullUrl() 已编码，传给播放页时保持原值，避免二次编码。
        url: fullUrl,
        httpHeader,
        title: this.buildPlayerTitle(episode, episodeName),
        durationHintMs: durationHintMs > 0 ? durationHintMs : undefined,
        videoId: episode.id,
        seriesProviderId,
        seasonNumber: episode.seasonNumber ?? 0,
        episodeNumber: episode.episodeNumber ?? 0,
        presetAudioTracks: presetAudioTracks.length > 0 ? presetAudioTracks : undefined,
        presetSubtitleTracks: presetSubtitleTracks.length > 0 ? presetSubtitleTracks : undefined,
        mediaKey: mKey,
        startPositionMs: startPositionMs > 0 ? startPositionMs : undefined
      };
      this.pageStack.pushPathByName(PlayerPage.PAGE_NAME, param);
    } catch (e) {
      console.error('[SeasonDetailPage] playEpisode failed', JSON.stringify(e));
    }
  }

  // ── Builders ──────────────────────────────────

  @Builder
  HeroSection() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 背景图
      if (this.getBackdropUrl().length > 0) {
        Image(this.getBackdropUrl())
          .width('100%').height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        Column()
          .width('100%').height('100%')
          .linearGradient({ angle: 135, colors: [['#1A1A2E', 0.0], ['#16213E', 0.5], ['#0F3460', 1.0]] })
      }

      // 底部渐变遮罩
      Column()
        .width('100%').height('68%')
        .linearGradient({ angle: 180, colors: [['#00000000', 0.0], [this.toOpaqueColor(this.dominantBgColor), 1.0]] })
        .position({ left: 0, bottom: 0 })

      // 左侧渐变遮罩
      Column()
        .width('55%').height('100%')
        .linearGradient({ angle: 90, colors: [[this.toOpaqueColor(this.dominantBgColor), 0.0], ['#00000000', 1.0]] })
        .position({ left: 0, top: 0 })

      // 底部内容：左侧标题/元信息/简介
      Column({ space: 14 }) {
        // 剧名副标题
        if (this.getSeriesTitle().length > 0) {
          Text(this.getSeriesTitle())
            .fontSize(18).fontColor('#BBBBBB').fontWeight(FontWeight.Medium)
        }

        // 季标题（大）
        Text(this.getSeasonLabel())
          .fontSize(52).fontColor(Color.White).fontWeight(FontWeight.Bold)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .textShadow({ radius: 8, color: '#88000000', offsetX: 2, offsetY: 2 })
          .constraintSize({ maxWidth: 720 })

        // 元信息行：年份 + 评分 + 集数 + 类型标签
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
          if (this.getEpisodeCount().length > 0) {
            Text(this.getEpisodeCount())
              .fontSize(14).fontColor('#CCCCCC')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(4).border({ width: 1, color: '#55FFFFFF' })
          }
          ForEach(this.getGenres().slice(0, 2), (genre: string) => {
            Text(genre)
              .fontSize(14).fontColor('#CCCCCC')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(4).border({ width: 1, color: '#55FFFFFF' })
          }, (genre: string) => genre)
        }
        .alignItems(VerticalAlign.Center)

        // 简介
        if (this.getOverview().length > 0) {
          if (this.isOverviewLong()) {
            Row({ space: 4 }) {
              Text(this.getOverviewShort())
                .fontSize(16).fontColor('#BBBBBB').lineHeight(26)
              Text('更多')
                .fontSize(14).fontColor('#1B78F2').fontWeight(FontWeight.Medium)
                .focusable(true)
                .onClick(() => { this.showOverviewDialog = true; })
            }
            .alignItems(VerticalAlign.Bottom)
            .constraintSize({ maxWidth: 700 })
          } else {
            Text(this.getOverview())
              .fontSize(16).fontColor('#BBBBBB').lineHeight(26)
              .constraintSize({ maxWidth: 700 })
          }
        }

        // 操作区：主入口与辅助动作分层，突出当前季播放动作
        Column({ space: 12 }) {
          Row({ space: 14 }) {
            Row({ space: 10 }) {
              Text('▶').fontSize(16).fontColor(Color.White).fontWeight(FontWeight.Bold)
              Text(this.getHeroPlayLabel()).fontSize(17).fontColor(Color.White).fontWeight(FontWeight.Bold)
            }
            .height(64)
            .padding({ left: 26, right: 26, top: 14, bottom: 14 })
            .backgroundColor(this.getHeroPlayButtonBgColor()).borderRadius(10)
            .border({ width: 2, color: this.getHeroPlayButtonBorderColor() })
            .shadow({ radius: 18, color: this.getHeroPlayButtonShadowColor(), offsetX: 0, offsetY: 10 })
            .scale({ x: this.getHeroPrimaryButtonScale(), y: this.getHeroPrimaryButtonScale() })
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .focusable(true)
            .onFocus(() => { this.focusedHeroActionKey = 'play'; })
            .onBlur(() => { this.clearHeroActionFocusIfMatches('play'); })
            .onHover((isHover: boolean) => {
              if (isHover) {
                this.hoveredHeroActionKey = 'play';
              } else {
                this.clearHeroActionHoverIfMatches('play');
              }
            })
            .onClick(() => { this.handleHeroPlayClick(); })

            if (this.shouldShowCrossSeasonEntry()) {
              Column({ space: 4 }) {
                Row({ space: 8 }) {
                  Text('↩').fontSize(14).fontColor(this.getHeroSecondaryTitleColor('cross'))
                  Text(this.getCrossSeasonLabel())
                    .fontSize(14).fontColor(this.getHeroSecondaryTitleColor('cross')).fontWeight(FontWeight.Bold)
                }
                .alignItems(VerticalAlign.Center)

                Text(this.getCrossSeasonMetaLabel())
                  .fontSize(12).fontColor(this.getHeroSecondaryMetaColor('cross'))
              }
              .alignItems(HorizontalAlign.Start)
              .height(64)
              .padding({ left: 18, right: 18, top: 12, bottom: 12 })
              .backgroundColor(this.getHeroSecondaryButtonBgColor('cross')).borderRadius(10)
              .border({ width: 2, color: this.getHeroSecondaryButtonBorderColor('cross') })
              .shadow({ radius: 14, color: this.getHeroSecondaryButtonShadowColor('cross'), offsetX: 0, offsetY: 8 })
              .scale({ x: this.getHeroSecondaryButtonScale('cross'), y: this.getHeroSecondaryButtonScale('cross') })
              .justifyContent(FlexAlign.Center)
              .focusable(true)
              .onFocus(() => { this.focusedHeroActionKey = 'cross'; })
              .onBlur(() => { this.clearHeroActionFocusIfMatches('cross'); })
              .onHover((isHover: boolean) => {
                if (isHover) {
                  this.hoveredHeroActionKey = 'cross';
                } else {
                  this.clearHeroActionHoverIfMatches('cross');
                }
              })
              .onClick(() => { this.handleCrossSeasonClick(); })
            }
          }
          .alignItems(VerticalAlign.Center)
          .alignSelf(ItemAlign.Start)

          Row({ space: 12 }) {
            Row({ space: 8 }) {
              Text('✓').fontSize(16).fontColor(this.getHeroSecondaryTitleColor('wish'))
              Text('想看').fontSize(14).fontColor(this.getHeroSecondaryTitleColor('wish')).fontWeight(FontWeight.Medium)
            }
            .height(44)
            .padding({ left: 18, right: 18, top: 10, bottom: 10 })
            .backgroundColor(this.getHeroSecondaryButtonBgColor('wish')).borderRadius(8)
            .border({ width: 2, color: this.getHeroSecondaryButtonBorderColor('wish') })
            .shadow({ radius: 12, color: this.getHeroSecondaryButtonShadowColor('wish'), offsetX: 0, offsetY: 6 })
            .scale({ x: this.getHeroSecondaryButtonScale('wish'), y: this.getHeroSecondaryButtonScale('wish') })
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .focusable(true)
            .onFocus(() => { this.focusedHeroActionKey = 'wish'; })
            .onBlur(() => { this.clearHeroActionFocusIfMatches('wish'); })
            .onHover((isHover: boolean) => {
              if (isHover) {
                this.hoveredHeroActionKey = 'wish';
              } else {
                this.clearHeroActionHoverIfMatches('wish');
              }
            })

            Row({ space: 8 }) {
              Text('♥').fontSize(16).fontColor(this.getHeroSecondaryTitleColor('favorite'))
              Text('收藏').fontSize(14).fontColor(this.getHeroSecondaryTitleColor('favorite')).fontWeight(FontWeight.Medium)
            }
            .height(44)
            .padding({ left: 18, right: 18, top: 10, bottom: 10 })
            .backgroundColor(this.getHeroSecondaryButtonBgColor('favorite')).borderRadius(8)
            .border({ width: 2, color: this.getHeroSecondaryButtonBorderColor('favorite') })
            .shadow({ radius: 12, color: this.getHeroSecondaryButtonShadowColor('favorite'), offsetX: 0, offsetY: 6 })
            .scale({ x: this.getHeroSecondaryButtonScale('favorite'), y: this.getHeroSecondaryButtonScale('favorite') })
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .focusable(true)
            .onFocus(() => { this.focusedHeroActionKey = 'favorite'; })
            .onBlur(() => { this.clearHeroActionFocusIfMatches('favorite'); })
            .onHover((isHover: boolean) => {
              if (isHover) {
                this.hoveredHeroActionKey = 'favorite';
              } else {
                this.clearHeroActionHoverIfMatches('favorite');
              }
            })
          }
          .alignItems(VerticalAlign.Center)
          .alignSelf(ItemAlign.Start)
        }
        .alignItems(HorizontalAlign.Start)
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 80, right: 80, bottom: 52 })
      .width('65%')
    }
    .width('100%').aspectRatio(1.778)
  }

  /** 集列表区 */
  @Builder
  EpisodesSection() {
    if (this.seasonEpisodes.length > 0) {
      Column({ space: 0 }) {
        // 标题行
        Row() {
          Text('集')
            .fontSize(26).fontColor(Color.White).fontWeight(FontWeight.Bold)
          Blank()
          Row({ space: 8 }) {
            Text('‹')
              .fontSize(22).fontColor('#CCCCCC')
              .width(36).height(36)
              .textAlign(TextAlign.Center)
              .backgroundColor(this.getEpisodeActionButtonBgColor()).borderRadius(18)
            Text('›')
              .fontSize(22).fontColor('#CCCCCC')
              .width(36).height(36)
              .textAlign(TextAlign.Center)
              .backgroundColor(this.getEpisodeActionButtonBgColor()).borderRadius(18)
          }
        }
        .width('100%')
        .padding({ left: 80, right: 80, top: 36, bottom: 20 })
        .alignItems(VerticalAlign.Center)

        // 集条目列表
        ForEach(this.seasonEpisodes, (ep: SeasonEpisodeItem, idx: number) => {
          Column({ space: 0 }) {
            // 分割线（首条不加）
            if (idx > 0) {
              Divider().color('#24282D').strokeWidth(1)
            }

            // 集条目行
            Row({ space: 28 }) {
              // 缩略图 + 播放覆盖
              Stack({ alignContent: Alignment.Center }) {
                if (this.getEpisodeStillUrl(ep).length > 0) {
                  Image(this.getEpisodeStillUrl(ep))
                    .width(310).height(174)
                    .borderRadius(6).objectFit(ImageFit.Cover)
                } else {
                  Column() {
                    Text(String(ep.mediaItem.episodeNumber ?? 0))
                      .fontSize(28).fontColor('#555555').fontWeight(FontWeight.Bold)
                  }
                  .width(310).height(174)
                  .backgroundColor('#1E1E1E').borderRadius(6)
                  .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                }
                // 播放按钮覆盖
                Column() {
                  SymbolGlyph($r('sys.symbol.play_fill'))
                    .fontColor([Color.White])
                    .fontSize(28)
                }
                .backgroundColor('rgba(200, 200, 200, 0.2)')
                .backdropBlur(40)
                .padding(14)
                .borderRadius(99)
                .border({ width: 1, color: 'rgba(255, 255, 255, 0.2)' })
                .shadow({ radius: 20, color: 'rgba(0, 0, 0, 0.4)' })
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .hitTestBehavior(HitTestMode.Transparent)

                // 进度条（有进度时显示）
                if (this.getEpisodeProgress(ep.mediaItem) > 0) {
                  Column() {
                    Column()
                      .width(this.getProgressPercent(ep))
                      .height('100%')
                      .backgroundColor('#1B78F2').borderRadius(2)
                      .alignSelf(ItemAlign.Start)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .width(310).height(4)
                  .backgroundColor('#2E2E2E').borderRadius(2)
                  .position({ left: 0, bottom: 0 })
                  .hitTestBehavior(HitTestMode.Transparent)
                }
              }
              .width(310).height(174)
              .borderRadius(6).clip(true)
              .onClick(() => { this.playEpisode(ep.mediaItem); })

              // 信息列
              Column({ space: 12 }) {
                // 集标题
                Text(this.getEpisodeLabel(ep))
                  .fontSize(20).fontColor(Color.White).fontWeight(FontWeight.Bold)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })

                // 元数据行：时长 + 评分
                Row({ space: 16 }) {
                  if (this.getEpisodeDuration(ep).length > 0) {
                    Text(this.getEpisodeDuration(ep))
                      .fontSize(15).fontColor('#888888')
                  }
                  if (this.getEpisodeRatingText(ep).length > 0) {
                    Row({ space: 4 }) {
                      Text('★').fontSize(14).fontColor('#F5B942')
                      Text(this.getEpisodeRatingText(ep))
                        .fontSize(15).fontColor('#CCCCCC').fontWeight(FontWeight.Medium)
                    }
                  }
                  if (this.isEpisodeWatched(ep.mediaItem)) {
                    Text('✓ 已看')
                      .fontSize(13).fontColor('#1B78F2')
                      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                      .backgroundColor('#192840').borderRadius(3)
                  }
                }
                .alignItems(VerticalAlign.Center)

                // 简介
                if (this.getEpisodeOverview(ep).length > 0) {
                  Text(this.getEpisodeOverview(ep))
                    .fontSize(15).fontColor('#AAAAAA').lineHeight(24)
                    .height(96)
                    .maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .justifyContent(FlexAlign.Start)
              .onClick(() => { this.playEpisode(ep.mediaItem); })

              // 操作按钮行
              Row({ space: 8 }) {
                Text('ⓘ')
                  .fontSize(18).fontColor('#B5BBC4')
                  .width(44).height(44)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(this.getEpisodeActionCircleBg(ep, 'info')).borderRadius(22)
                  .border({ width: this.isEpisodeActionFocused(ep, 'info') ? 2 : 1, color: this.getEpisodeActionCircleBorder(ep, 'info') })
                  .focusable(true)
                  .onFocus(() => { this.focusedEpisodeActionKey = this.buildEpisodeActionKey(ep, 'info'); })
                  .onBlur(() => { this.clearEpisodeActionFocusIfMatches(ep, 'info'); })
                  .onHover((isHover: boolean) => {
                    if (isHover) {
                      this.hoveredEpisodeActionKey = this.buildEpisodeActionKey(ep, 'info');
                    } else {
                      this.clearEpisodeActionHoverIfMatches(ep, 'info');
                    }
                  })
                Text('✓')
                  .fontSize(18).fontColor('#B5BBC4')
                  .width(44).height(44)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(this.getEpisodeActionCircleBg(ep, 'check')).borderRadius(22)
                  .border({ width: this.isEpisodeActionFocused(ep, 'check') ? 2 : 1, color: this.getEpisodeActionCircleBorder(ep, 'check') })
                  .focusable(true)
                  .onFocus(() => { this.focusedEpisodeActionKey = this.buildEpisodeActionKey(ep, 'check'); })
                  .onBlur(() => { this.clearEpisodeActionFocusIfMatches(ep, 'check'); })
                  .onHover((isHover: boolean) => {
                    if (isHover) {
                      this.hoveredEpisodeActionKey = this.buildEpisodeActionKey(ep, 'check');
                    } else {
                      this.clearEpisodeActionHoverIfMatches(ep, 'check');
                    }
                  })
                Text('♥')
                  .fontSize(18).fontColor('#B5BBC4')
                  .width(44).height(44)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(this.getEpisodeActionCircleBg(ep, 'heart')).borderRadius(22)
                  .border({ width: this.isEpisodeActionFocused(ep, 'heart') ? 2 : 1, color: this.getEpisodeActionCircleBorder(ep, 'heart') })
                  .focusable(true)
                  .onFocus(() => { this.focusedEpisodeActionKey = this.buildEpisodeActionKey(ep, 'heart'); })
                  .onBlur(() => { this.clearEpisodeActionFocusIfMatches(ep, 'heart'); })
                  .onHover((isHover: boolean) => {
                    if (isHover) {
                      this.hoveredEpisodeActionKey = this.buildEpisodeActionKey(ep, 'heart');
                    } else {
                      this.clearEpisodeActionHoverIfMatches(ep, 'heart');
                    }
                  })
                Text('⋮')
                  .fontSize(18).fontColor('#C6CCD4')
                  .width(44).height(44)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(this.getEpisodeActionCircleBg(ep, 'more')).borderRadius(22)
                  .border({ width: this.isEpisodeActionFocused(ep, 'more') ? 2 : 1, color: this.getEpisodeActionCircleBorder(ep, 'more') })
                  .focusable(true)
                  .onFocus(() => { this.focusedEpisodeActionKey = this.buildEpisodeActionKey(ep, 'more'); })
                  .onBlur(() => { this.clearEpisodeActionFocusIfMatches(ep, 'more'); })
                  .onHover((isHover: boolean) => {
                    if (isHover) {
                      this.hoveredEpisodeActionKey = this.buildEpisodeActionKey(ep, 'more');
                    } else {
                      this.clearEpisodeActionHoverIfMatches(ep, 'more');
                    }
                  })
              }
              .alignSelf(ItemAlign.Center)
            }
            .width('100%')
            .padding({ left: 80, right: 80, top: 20, bottom: 20 })
            .backgroundColor(this.getEpisodeRowBgColor(ep))
            .borderRadius(8)
            .border({ width: 2, color: this.getEpisodeRowBorderColor(ep) })
            .alignItems(VerticalAlign.Top)
            .focusable(true)
            .onFocus(() => { this.focusedEpisodeRowId = this.getEpisodeRowId(ep); })
            .onBlur(() => { this.clearEpisodeRowFocusIfMatches(ep); })
            .onHover((isHover: boolean) => {
              if (isHover) {
                this.hoveredEpisodeRowId = this.getEpisodeRowId(ep);
              } else {
                this.clearEpisodeRowHoverIfMatches(ep);
              }
            })
            .animation({ duration: 140, curve: Curve.EaseInOut })
          }
          .width('100%')
        }, (ep: SeasonEpisodeItem) => String(ep.mediaItem.id))

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
                if ((c.profilePath ?? '').length > 0) {
                  Image(tmdbImageUrl(c.profilePath, 'w185'))
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
                Text(c.name ?? '')
                  .fontSize(14).fontColor(Color.White)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width(110).textAlign(TextAlign.Center)
                if (c.role != null && c.role.length > 0) {
                  Text(c.role)
                    .fontSize(12).fontColor('#777777')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width(110).textAlign(TextAlign.Center)
                }
              }
              .width(110).alignItems(HorizontalAlign.Center)
              .focusable(true)
              .onClick(() => {
                const name = c.name ?? '';
                const profilePath = c.profilePath ?? '';
                if (name.length === 0 && profilePath.length === 0) { return; }
                const param: CastDetailPageParam = {
                  personId: c.personId ?? 0,
                  name: name
                };
                this.pageStack.pushPathByName(CastDetailPage.PAGE_NAME, param);
              })
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

  /** 简介全文弹窗 */
  @Builder
  OverviewDialog() {
    if (this.showOverviewDialog) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%').height('100%')
          .backgroundColor('#BB000000')
          .onClick(() => { this.showOverviewDialog = false; })

        Column() {
          Row() {
            Text('简介')
              .fontSize(26).fontColor('#F0F0F0').fontWeight(FontWeight.Bold)
              .layoutWeight(1).textAlign(TextAlign.Center)
            Text('✕')
              .fontSize(20).fontColor('#888892')
              .width(48).height(48)
              .textAlign(TextAlign.Center)
              .borderRadius(24).backgroundColor('#2A2A2E')
              .onClick(() => { this.showOverviewDialog = false; })
          }
          .alignItems(VerticalAlign.Center)
          .padding({ left: 24, right: 24 })
          .height(80).width('100%')
          .backgroundColor('#1E1E22')

          Divider().color('#2E2E34').strokeWidth(1)

          Row() {
            Column({ space: 20 }) {
              Image(this.getDialogPosterUrl())
                .width(124).height(174).borderRadius(6)
                .objectFit(ImageFit.Cover).backgroundColor('#2A2A2E')
              Text(this.getSeasonLabel())
                .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#F0F0F0')
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                .lineHeight(28).width('100%')
              if (this.getSeriesTitle().length > 0) {
                Text(this.getSeriesTitle())
                  .fontSize(14).fontColor('#888888')
                  .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
              Column({ space: 8 }) {
                if (this.getGenresText().length > 0) {
                  Text(`风格：${this.getGenresText()}`).fontSize(18).fontColor('#AAAAAA')
                }
                if (this.getYear().length > 0) {
                  Text(this.getYear()).fontSize(18).fontColor('#AAAAAA')
                }
              }
              .alignItems(HorizontalAlign.Start).width('100%')
            }
            .width('28%').padding({ left: 48, right: 32, top: 48, bottom: 48 })
            .alignItems(HorizontalAlign.Start)

            Divider().vertical(true).color('#2A2A2E').strokeWidth(1).height('100%')

            Scroll() {
              Text(this.getOverview())
                .fontSize(20).fontColor('#C8C8D0').lineHeight(36).width('100%')
            }
            .scrollable(ScrollDirection.Vertical)
            .scrollBar(BarState.Auto)
            .scrollBarColor('#555560')
            .layoutWeight(1)
            .padding({ left: 40, right: 40, top: 48, bottom: 48 })
          }
          .alignItems(VerticalAlign.Top).layoutWeight(1)
        }
        .width('85%').height('88%')
        .backgroundColor('#18181C').borderRadius(16)
        .border({ width: 1, color: '#2A2A2E' }).clip(true)
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
            this.EpisodesSection()
            this.CastSection()
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
