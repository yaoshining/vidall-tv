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
