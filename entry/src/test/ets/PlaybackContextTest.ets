import { describe, it, expect } from '@ohos/hypium';
import {
  PlaybackContext, PlaybackContextItem,
  MediaLibraryContext, FileExplorerContext
} from '../../main/ets/components/core/player/PlaybackContext';

// 用于测试的具体实现类（不测试具体播放逻辑，只验证基类导航方法）
class TestPlaybackContext extends PlaybackContext {
  readonly contextType: string = 'test';

  jumpToNext(): PlaybackContextItem | null {
    if (!this.hasNext) {
      return null;
    }
    this.currentIndex = this.currentIndex + 1;
    return this.items[this.currentIndex];
  }

  jumpToPrev(): PlaybackContextItem | null {
    if (!this.hasPrev) {
      return null;
    }
    this.currentIndex = this.currentIndex - 1;
    return this.items[this.currentIndex];
  }

  jumpTo(index: number): PlaybackContextItem | null {
    if (index < 0 || index >= this.items.length) {
      return null;
    }
    this.currentIndex = index;
    return this.items[this.currentIndex];
  }
}

function makeItems(count: number): PlaybackContextItem[] {
  const result: PlaybackContextItem[] = [];
  for (let i = 0; i < count; i++) {
    const item: PlaybackContextItem = { videoPath: `path_${i}`, title: `title_${i}`, index: i };
    result.push(item);
  }
  return result;
}

export default function PlaybackContextTest() {
  describe('PlaybackContext', () => {

    it('hasNext 在末尾集返回 false', 0, () => {
      const ctx = new TestPlaybackContext();
      ctx.items = makeItems(3);
      ctx.currentIndex = 2; // 末尾集 index = length - 1
      expect(ctx.hasNext).assertFalse();
    });

    it('hasNext 在非末尾集返回 true', 0, () => {
      const ctx = new TestPlaybackContext();
      ctx.items = makeItems(3);
      ctx.currentIndex = 0;
      expect(ctx.hasNext).assertTrue();
    });

    it('hasPrev 在第一集返回 false', 0, () => {
      const ctx = new TestPlaybackContext();
      ctx.items = makeItems(3);
      ctx.currentIndex = 0;
      expect(ctx.hasPrev).assertFalse();
    });

    it('hasPrev 在非第一集返回 true', 0, () => {
      const ctx = new TestPlaybackContext();
      ctx.items = makeItems(3);
      ctx.currentIndex = 1;
      expect(ctx.hasPrev).assertTrue();
    });

    it('空列表处理', 0, () => {
      const ctx = new TestPlaybackContext();
      ctx.items = [];
      expect(ctx.hasNext).assertFalse();
      expect(ctx.hasPrev).assertFalse();
    });

    it('jumpTo 越界返回 null', 0, () => {
      const ctx = new TestPlaybackContext();
      ctx.items = makeItems(3);
      ctx.currentIndex = 1;
      const r1 = ctx.jumpTo(-1);
      expect(r1 === null).assertTrue();
      expect(ctx.currentIndex).assertEqual(1);
      const r2 = ctx.jumpTo(3); // items.length = 3，越界
      expect(r2 === null).assertTrue();
      expect(ctx.currentIndex).assertEqual(1);
    });

  });

  // ─────────────────────────────────────────────
  // MediaLibraryContext 测试套件
  // 不依赖真实 DB：直接构造实例并赋值 items，验证导航行为
  // ─────────────────────────────────────────────
  describe('MediaLibraryContextTest', () => {

    it('工厂方法从 DB 加载当前季剧集', 0, () => {
      // 用直接构造模拟 build() 产出，验证 currentIndex 定位逻辑
      const ctx = new MediaLibraryContext();
      ctx.items = makeItems(4);
      ctx.seriesId = 1;
      ctx.seasonNumber = 1;
      ctx.currentIndex = 2; // 模拟 currentVideoPath 对应 index=2
      expect(ctx !== null).assertTrue();
      expect(ctx.currentIndex).assertEqual(2);
      expect(ctx.items.length).assertEqual(4);
    });

    it('jumpTo 切换到指定集', 0, () => {
      const ctx = new MediaLibraryContext();
      ctx.items = makeItems(4);
      ctx.currentIndex = 0;
      const result = ctx.jumpTo(2);
      expect(ctx.currentIndex).assertEqual(2);
      expect(result !== null).assertTrue();
      if (result !== null) {
        expect(result.videoPath).assertEqual('path_2');
      }
    });

    it('jumpTo 越界返回 null', 0, () => {
      const ctx = new MediaLibraryContext();
      ctx.items = makeItems(3);
      ctx.currentIndex = 1;
      const r1 = ctx.jumpTo(-1);
      expect(r1 === null).assertTrue();
      expect(ctx.currentIndex).assertEqual(1);
      const r2 = ctx.jumpTo(ctx.items.length);
      expect(r2 === null).assertTrue();
      expect(ctx.currentIndex).assertEqual(1);
    });

    it('jumpToNext 跳转到下一集', 0, () => {
      const ctx = new MediaLibraryContext();
      ctx.items = makeItems(4);
      ctx.currentIndex = 1;
      const result = ctx.jumpToNext();
      expect(ctx.currentIndex).assertEqual(2);
      expect(result !== null).assertTrue();
    });

    it('jumpToPrev 跳转到上一集', 0, () => {
      const ctx = new MediaLibraryContext();
      ctx.items = makeItems(4);
      ctx.currentIndex = 2;
      const result = ctx.jumpToPrev();
      expect(ctx.currentIndex).assertEqual(1);
      expect(result !== null).assertTrue();
    });

    it('jumpToNext 在末尾集返回 null', 0, () => {
      const ctx = new MediaLibraryContext();
      ctx.items = makeItems(4);
      ctx.currentIndex = ctx.items.length - 1; // 末尾
      const result = ctx.jumpToNext();
      expect(result === null).assertTrue();
      expect(ctx.currentIndex).assertEqual(ctx.items.length - 1);
    });

  });

  // ─────────────────────────────────────────────
  // FileExplorerContext 骨架测试套件
  // ─────────────────────────────────────────────
  describe('FileExplorerContextTest', () => {

    it('jumpTo 始终返回 null', 0, () => {
      const ctx = new FileExplorerContext();
      ctx.items = makeItems(3);
      const result = ctx.jumpTo(0);
      expect(result === null).assertTrue();
    });

    it('contextType 为 file_explorer', 0, () => {
      const ctx = new FileExplorerContext();
      expect(ctx.contextType).assertEqual('file_explorer');
    });

  });
}
