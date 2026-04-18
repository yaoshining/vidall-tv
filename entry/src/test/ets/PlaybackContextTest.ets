import { describe, it, expect } from '@ohos/hypium';
import { PlaybackContext, PlaybackContextItem } from '../../main/ets/components/core/player/PlaybackContext';

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
}
