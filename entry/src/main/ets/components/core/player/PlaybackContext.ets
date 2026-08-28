import { FileSourceDatabase } from '../../../db/files/FileSourceDatabase';
import { MediaItem, TvEpisodeEntity } from '../../../db/models/MediaEntity';
import { EpisodeGroupMatcher, EpisodeGroupMatchResult, EpisodeGroupMatchItem } from './EpisodeGroupMatcher';
import { FileExplorerResource } from '../file/FileExplorerController';
import { isVideoFile } from '../../../utils/VideoFileUtil';
import { tmdbImageUrl } from '../../../utils/MediaFormatUtil';
import { VideoServerEpisode } from '../../../lib/JellyfinClient';

// 播放上下文条目接口
export interface PlaybackContextItem {
  videoPath: string;
  title: string;
  index: number;
  thumbnailUrl?: string;    // 集缩略图 URL（优先 stillUrl/stillPath）
  episodeNumber?: number;   // 集号（如 1, 2, 3...）
  seasonNumber?: number;    // 季号（用于播放器内选集切源）
  sourceId?: number;        // 文件源 ID（用于重建真实播放 URL）
  videoId?: number;         // videos 表主键（用于切换后续播进度上下文）
  durationMs?: number;      // 已探测时长（用于切换时透传 durationHint）
  positionMs?: number;      // 续播位置（服务器剧集用，切集时作为新集起始位置）
}

// 播放上下文抽象基类
@ObservedV2
export abstract class PlaybackContext {
  abstract readonly contextType: string;

  @Trace currentIndex: number = 0;
  @Trace items: PlaybackContextItem[] = [];

  get hasNext(): boolean {
    return this.currentIndex < this.items.length - 1;
  }

  get hasPrev(): boolean {
    return this.currentIndex > 0;
  }

  abstract jumpToNext(): PlaybackContextItem | null;
  abstract jumpToPrev(): PlaybackContextItem | null;
  abstract jumpTo(index: number): PlaybackContextItem | null;
}

// buildItems 辅助方法返回类型（不依赖 DB，可在单测中直接调用）
export interface BuildItemsResult {
  items: PlaybackContextItem[];
  currentIndex: number;
}

export function createMediaLibraryEpisodeGroupMatcher(): EpisodeGroupMatcher {
  return new EpisodeGroupMatcher();
}

// 媒体库播放上下文：基于剧集数据库加载当季集列表
@ObservedV2
export class MediaLibraryContext extends PlaybackContext {
  readonly contextType: string = 'media_library';

  @Trace seriesId: number = 0;
  @Trace seasonNumber: number = 0;
  @Trace episodes: MediaItem[] = [];

  /**
   * 纯函数辅助方法：从所有剧集中按 seasonNumber 过滤并定位 currentIndex。
   * 不依赖 DB，可在单测中直接调用。
   */
  static buildItems(
    allItems: MediaItem[],
    seasonNumber: number,
    currentVideoPath: string,
    episodeEntities: TvEpisodeEntity[] = []
  ): BuildItemsResult {
    const seasonItems = allItems.filter(item => item.seasonNumber === seasonNumber);
    seasonItems.sort((a: MediaItem, b: MediaItem): number => {
      const aEpisode = a.episodeNumber ?? Number.MAX_SAFE_INTEGER;
      const bEpisode = b.episodeNumber ?? Number.MAX_SAFE_INTEGER;
      if (aEpisode !== bEpisode) {
        return aEpisode - bEpisode;
      }
      return a.filePath.localeCompare(b.filePath);
    });
    const episodeEntityByNumber = MediaLibraryContext.buildEpisodeEntityByNumber(episodeEntities);

    const mapped: PlaybackContextItem[] = [];
    for (let i = 0; i < seasonItems.length; i++) {
      const ep = seasonItems[i];
      const episodeEntity = MediaLibraryContext.findEpisodeEntity(ep, i, episodeEntities, episodeEntityByNumber);
      const displayTitle = MediaLibraryContext.getEpisodeDisplayTitle(ep, episodeEntity);
      const item: PlaybackContextItem = {
        videoPath: ep.filePath,
        title: displayTitle,
        index: i,
        thumbnailUrl: MediaLibraryContext.getEpisodeThumbnailUrl(episodeEntity),
        seasonNumber: ep.seasonNumber ?? undefined,
        episodeNumber: ep.episodeNumber ?? undefined,
        sourceId: ep.sourceId,
        videoId: ep.id,
        durationMs: ep.durationMs ?? undefined,
      };
      mapped.push(item);
    }

    let foundIndex = 0;
    for (let i = 0; i < mapped.length; i++) {
      if (mapped[i].videoPath === currentVideoPath) {
        foundIndex = i;
        break;
      }
    }

    const result: BuildItemsResult = { items: mapped, currentIndex: foundIndex };
    return result;
  }

  /**
   * 工厂方法：查询数据库获取当季所有剧集并定位 currentIndex。
   * 使用 getMediaItemsByTvSeriesId 获取全季数据，按 seasonNumber 过滤，
   * 以 filePath 映射为 PlaybackContextItem。
   */
  static async build(
    db: FileSourceDatabase,
    seriesId: number,
    seasonNumber: number,
    currentVideoPath: string
  ): Promise<MediaLibraryContext> {
    const episodeGroupMatcher = createMediaLibraryEpisodeGroupMatcher();
    const matchResult = await episodeGroupMatcher.matchSeasonEpisodes(
      seriesId,
      seasonNumber,
      (): Promise<MediaItem[]> => db.getMediaItemsByTvSeriesId(seriesId),
      (): Promise<TvEpisodeEntity[]> => db.getEpisodesBySeriesAndSeason(seriesId, seasonNumber)
    );
    const buildResult = MediaLibraryContext.buildItemsFromMatchResult(matchResult, currentVideoPath);

    const ctx = new MediaLibraryContext();
    ctx.seriesId = seriesId;
    ctx.seasonNumber = seasonNumber;
    ctx.episodes = matchResult.mediaItems;
    ctx.items = buildResult.items;
    ctx.currentIndex = buildResult.currentIndex;
    return ctx;
  }

  private static buildItemsFromMatchResult(
    matchResult: EpisodeGroupMatchResult,
    currentVideoPath: string
  ): BuildItemsResult {
    const mapped: PlaybackContextItem[] = [];
    for (let i = 0; i < matchResult.items.length; i++) {
      const matchItem: EpisodeGroupMatchItem = matchResult.items[i];
      const item: PlaybackContextItem = {
        videoPath: matchItem.videoPath,
        title: matchItem.title,
        index: matchItem.index,
        thumbnailUrl: matchItem.thumbnailUrl,
        episodeNumber: matchItem.episodeNumber,
        seasonNumber: matchItem.seasonNumber,
        sourceId: matchItem.sourceId,
        videoId: matchItem.videoId,
        durationMs: matchItem.durationMs,
      };
      mapped.push(item);
    }

    let foundIndex = 0;
    for (let i = 0; i < mapped.length; i++) {
      if (mapped[i].videoPath === currentVideoPath) {
        foundIndex = i;
        break;
      }
    }

    const result: BuildItemsResult = { items: mapped, currentIndex: foundIndex };
    return result;
  }

  private static buildEpisodeEntityByNumber(episodeEntities: TvEpisodeEntity[]): Map<number, TvEpisodeEntity> {
    const result = new Map<number, TvEpisodeEntity>();
    for (let i = 0; i < episodeEntities.length; i++) {
      const entity = episodeEntities[i];
      result.set(entity.episodeNumber, entity);
    }
    return result;
  }

  private static findEpisodeEntity(
    item: MediaItem,
    index: number,
    episodeEntities: TvEpisodeEntity[],
    episodeEntityByNumber: Map<number, TvEpisodeEntity>
  ): TvEpisodeEntity | undefined {
    if (item.episodeNumber !== undefined) {
      const matchedEntity = episodeEntityByNumber.get(item.episodeNumber);
      if (matchedEntity !== undefined) {
        return matchedEntity;
      }
      return undefined;
    }
    if (index >= 0 && index < episodeEntities.length) {
      return episodeEntities[index];
    }
    return undefined;
  }

  private static getEpisodeDisplayTitle(item: MediaItem, entity: TvEpisodeEntity | undefined): string {
    const entityTitle = (entity?.title ?? '').trim();
    if (entityTitle.length > 0) {
      return entityTitle;
    }
    const episodeNumber = item.episodeNumber ?? 0;
    if (episodeNumber > 0) {
      return `第${episodeNumber}集`;
    }
    const title = (item.title ?? '').trim();
    if (title.length > 0) {
      return title;
    }
    const fileName = (item.fileName ?? '').trim();
    if (fileName.length > 0) {
      return fileName;
    }
    return '未知集名';
  }

  private static getEpisodeThumbnailUrl(entity: TvEpisodeEntity | undefined): string | undefined {
    if (entity === undefined) {
      return undefined;
    }
    if (entity.stillUrl !== undefined && entity.stillUrl.length > 0) {
      return entity.stillUrl;
    }
    if (entity.stillPath !== undefined && entity.stillPath.length > 0) {
      return tmdbImageUrl(entity.stillPath, 'w342');
    }
    return undefined;
  }

  jumpTo(index: number): PlaybackContextItem | null {
    if (index < 0 || index >= this.items.length) {
      return null;
    }
    this.currentIndex = index;
    return this.items[index];
  }

  jumpToNext(): PlaybackContextItem | null {
    if (!this.hasNext) {
      return null;
    }
    return this.jumpTo(this.currentIndex + 1);
  }

  jumpToPrev(): PlaybackContextItem | null {
    if (!this.hasPrev) {
      return null;
    }
    return this.jumpTo(this.currentIndex - 1);
  }
}

// 服务器媒体库上下文构建元信息（切集解析流地址与进度上报所需）
export interface ServerMediaLibraryMeta {
  serverType: string;      // 'jellyfin' | 'plex' 等（VideoServerType 值）
  serverId: number;        // 影视服务器配置主键
  seriesId: string;        // 剧集在服务器侧的条目 ID
  seriesTitle: string;     // 系列名（用于切集标题）
  seasonNumber: number;    // 季号
  seasonName: string;      // 季名（如「第 1 季」，可为空）
  posterUrl: string;       // 海报（切集后系统媒体中心展示，可为空）
  backdropUrl: string;     // 背景图（可为空）
}

// 服务器媒体库播放上下文：由影视服务器（Jellyfin/Plex）季集列表构建，支持自动连播下一集
@ObservedV2
export class ServerMediaLibraryContext extends PlaybackContext {
  readonly contextType: string = 'server_media_library';

  @Trace serverType: string = '';
  @Trace serverId: number = 0;
  @Trace seriesId: string = '';
  @Trace seriesTitle: string = '';
  @Trace seasonNumber: number = 0;
  @Trace seasonName: string = '';
  @Trace posterUrl: string = '';
  @Trace backdropUrl: string = '';

  /** 集展示标题：与季详情页播放标题的「第N集 分集名」段一致 */
  private static getEpisodeDisplayTitle(ep: VideoServerEpisode): string {
    const epTitle = ep.title.trim();
    if (epTitle.length > 0) {
      return `第${ep.episodeNumber}集 ${epTitle}`;
    }
    return `第${ep.episodeNumber}集`;
  }

  /**
   * 纯函数：把服务器季集列表映射为播放条目并定位当前集。
   * 按 episodeNumber 升序排列；当前条目不在列表时索引回退 0（与既有上下文一致）。
   */
  static buildItems(episodes: VideoServerEpisode[], currentItemKey: string): BuildItemsResult {
    const sorted = episodes.slice();
    sorted.sort((a: VideoServerEpisode, b: VideoServerEpisode): number => a.episodeNumber - b.episodeNumber);

    const items: PlaybackContextItem[] = [];
    for (let i = 0; i < sorted.length; i++) {
      const ep = sorted[i];
      const item: PlaybackContextItem = {
        videoPath: ep.id,
        title: ServerMediaLibraryContext.getEpisodeDisplayTitle(ep),
        index: i,
        thumbnailUrl: ep.stillUrl.length > 0 ? ep.stillUrl : undefined,
        episodeNumber: ep.episodeNumber,
        seasonNumber: ep.seasonNumber,
        durationMs: ep.durationMs > 0 ? ep.durationMs : undefined,
        positionMs: ep.positionMs > 0 ? ep.positionMs : undefined
      };
      items.push(item);
    }

    let foundIndex = 0;
    for (let i = 0; i < items.length; i++) {
      if (items[i].videoPath === currentItemKey) {
        foundIndex = i;
        break;
      }
    }

    const result: BuildItemsResult = { items: items, currentIndex: foundIndex };
    return result;
  }

  /** 工厂方法：构建携带服务器标识的上下文实例 */
  static build(
    episodes: VideoServerEpisode[],
    currentItemKey: string,
    meta: ServerMediaLibraryMeta
  ): ServerMediaLibraryContext {
    const buildResult = ServerMediaLibraryContext.buildItems(episodes, currentItemKey);
    const ctx = new ServerMediaLibraryContext();
    ctx.serverType = meta.serverType;
    ctx.serverId = meta.serverId;
    ctx.seriesId = meta.seriesId;
    ctx.seriesTitle = meta.seriesTitle;
    ctx.seasonNumber = meta.seasonNumber;
    ctx.seasonName = meta.seasonName;
    ctx.posterUrl = meta.posterUrl;
    ctx.backdropUrl = meta.backdropUrl;
    ctx.items = buildResult.items;
    ctx.currentIndex = buildResult.currentIndex;
    return ctx;
  }

  /** 切集播放标题：与季详情页格式一致「系列名 季名 第N集 分集名」，缺省段自动省略 */
  buildEpisodeSwitchTitle(selectedItem: PlaybackContextItem, fallbackTitle?: string): string {
    const itemTitle = selectedItem.title.trim();
    const title = itemTitle.length > 0 ? itemTitle : (fallbackTitle ?? '');
    const prefixParts: string[] = [];
    const seriesTitle = this.seriesTitle.trim();
    if (seriesTitle.length > 0) {
      prefixParts.push(seriesTitle);
    }
    const seasonName = this.seasonName.trim();
    if (seasonName.length > 0) {
      prefixParts.push(seasonName);
    }
    if (prefixParts.length === 0 || title.length === 0) {
      return title;
    }
    return `${prefixParts.join(' ')} ${title}`;
  }

  jumpTo(index: number): PlaybackContextItem | null {
    if (index < 0 || index >= this.items.length) {
      return null;
    }
    this.currentIndex = index;
    return this.items[index];
  }

  jumpToNext(): PlaybackContextItem | null {
    if (!this.hasNext) {
      return null;
    }
    return this.jumpTo(this.currentIndex + 1);
  }

  jumpToPrev(): PlaybackContextItem | null {
    if (!this.hasPrev) {
      return null;
    }
    return this.jumpTo(this.currentIndex - 1);
  }
}

// 文件浏览器播放上下文：从 FileExplorerResource 列表过滤视频文件，支持同目录连播
@ObservedV2
export class FileExplorerContext extends PlaybackContext {
  readonly contextType: string = 'file_explorer';

  /**
   * 工厂方法：从当前目录的资源列表构建文件浏览器上下文。
   * @param resources 当前目录的所有资源（已排序）
   * @param currentVideoPath 当前视频的 raw 路径（resource.path），用于定位 currentIndex
   * @param urlMapper 可选路径映射器，将 raw path 转为实际播放 URL；默认 identity
   */
  static build(
    resources: FileExplorerResource[],
    currentVideoPath: string,
    urlMapper: (path: string) => string = (p: string): string => p
  ): FileExplorerContext {
    const videoResources = resources.filter((r: FileExplorerResource) => {
      if (r.isDirectory) {
        return false;
      }
      return isVideoFile(r.name);
    });

    const items: PlaybackContextItem[] = [];
    for (let i = 0; i < videoResources.length; i++) {
      const r = videoResources[i];
      const item: PlaybackContextItem = {
        videoPath: urlMapper(r.path),
        title: r.name,
        index: i
      };
      items.push(item);
    }

    let foundIndex = 0;
    for (let i = 0; i < videoResources.length; i++) {
      if (videoResources[i].path === currentVideoPath) {
        foundIndex = i;
        break;
      }
    }

    const ctx = new FileExplorerContext();
    ctx.items = items;
    ctx.currentIndex = foundIndex;
    return ctx;
  }

  jumpTo(index: number): PlaybackContextItem | null {
    if (index < 0 || index >= this.items.length) {
      return null;
    }
    this.currentIndex = index;
    return this.items[index];
  }

  jumpToNext(): PlaybackContextItem | null {
    if (!this.hasNext) {
      return null;
    }
    return this.jumpTo(this.currentIndex + 1);
  }

  jumpToPrev(): PlaybackContextItem | null {
    if (!this.hasPrev) {
      return null;
    }
    return this.jumpTo(this.currentIndex - 1);
  }
}
