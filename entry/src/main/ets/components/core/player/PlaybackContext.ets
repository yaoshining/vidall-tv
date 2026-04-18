import { FileSourceDatabase } from '../../../db/files/FileSourceDatabase';
import { MediaItem } from '../../../db/models/MediaEntity';

// 播放上下文条目接口
export interface PlaybackContextItem {
  videoPath: string;
  title: string;
  index: number;
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

// 媒体库播放上下文：基于剧集数据库加载当季集列表
@ObservedV2
export class MediaLibraryContext extends PlaybackContext {
  readonly contextType: string = 'media_library';

  @Trace seriesId: number = 0;
  @Trace seasonNumber: number = 0;
  @Trace episodes: MediaItem[] = [];

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
    const seasonItems = allItems.filter(item => item.seasonNumber === seasonNumber);

    const ctx = new MediaLibraryContext();
    ctx.seriesId = seriesId;
    ctx.seasonNumber = seasonNumber;
    ctx.episodes = seasonItems;

    const mapped: PlaybackContextItem[] = [];
    for (let i = 0; i < seasonItems.length; i++) {
      const ep = seasonItems[i];
      const item: PlaybackContextItem = {
        videoPath: ep.filePath,
        title: ep.title ?? ep.fileName,
        index: i
      };
      mapped.push(item);
    }
    ctx.items = mapped;

    // 定位当前集
    let foundIndex = 0;
    for (let i = 0; i < mapped.length; i++) {
      if (mapped[i].videoPath === currentVideoPath) {
        foundIndex = i;
        break;
      }
    }
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
