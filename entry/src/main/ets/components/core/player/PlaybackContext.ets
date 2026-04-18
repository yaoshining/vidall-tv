import { FileSourceDatabase } from '../../../db/files/FileSourceDatabase';
import { MediaItem } from '../../../db/models/MediaEntity';

// 播放上下文条目接口
export interface PlaybackContextItem {
  videoPath: string;
  title: string;
  index: number;
  posterPath?: string;  // 集的封面图本地路径（可选）
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
    currentVideoPath: string
  ): BuildItemsResult {
    const seasonItems = allItems.filter(item => item.seasonNumber === seasonNumber);

    const mapped: PlaybackContextItem[] = [];
    for (let i = 0; i < seasonItems.length; i++) {
      const ep = seasonItems[i];
      const item: PlaybackContextItem = {
        videoPath: ep.filePath,
        title: ep.title ?? ep.fileName,
        index: i,
        posterPath: ep.posterLocalPath ?? undefined,
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
    const allItems = await db.getMediaItemsByTvSeriesId(seriesId);
    const buildResult = MediaLibraryContext.buildItems(allItems, seasonNumber, currentVideoPath);

    const ctx = new MediaLibraryContext();
    ctx.seriesId = seriesId;
    ctx.seasonNumber = seasonNumber;
    ctx.episodes = allItems.filter(item => item.seasonNumber === seasonNumber);
    ctx.items = buildResult.items;
    ctx.currentIndex = buildResult.currentIndex;
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
