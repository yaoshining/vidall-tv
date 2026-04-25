import { FileSourceDatabase } from '../../../db/files/FileSourceDatabase';
import { MediaItem, TvEpisodeEntity } from '../../../db/models/MediaEntity';
import { EpisodeGroupMatcher, EpisodeGroupMatchResult, EpisodeGroupMatchItem } from './EpisodeGroupMatcher';

function tmdbImageUrl(path: string | undefined, width: string): string {
  if (path === undefined || path.length === 0) {
    return '';
  }
  return `https://image.tmdb.org/t/p/${width}${path}`;
}

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

// 媒体库播放上下文：基于剧集数据库加载当季集列表
@ObservedV2
export class MediaLibraryContext extends PlaybackContext {
  readonly contextType: string = 'media_library';
  private static readonly episodeGroupMatcher: EpisodeGroupMatcher = new EpisodeGroupMatcher();

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
    const matchResult = await MediaLibraryContext.episodeGroupMatcher.matchSeasonEpisodes(
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

// 文件浏览器播放上下文：骨架实现，jumpTo 系列均返回 null（待后续 Phase 实现）
@ObservedV2
export class FileExplorerContext extends PlaybackContext {
  readonly contextType: string = 'file_explorer';

  jumpTo(_index: number): PlaybackContextItem | null {
    return null;
  }

  jumpToNext(): PlaybackContextItem | null {
    return null;
  }

  jumpToPrev(): PlaybackContextItem | null {
    return null;
  }
}
