import { describe, it, expect } from '@ohos/hypium';
import {
  PlaybackContext, PlaybackContextItem,
  MediaLibraryContext, FileExplorerContext, BuildItemsResult,
  createMediaLibraryEpisodeGroupMatcher
} from '../../main/ets/components/core/player/PlaybackContext';
import { MediaItem, TvEpisodeEntity } from '../../main/ets/db/models/MediaEntity';

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

interface PlaybackContextItemWithThumbnail extends PlaybackContextItem {
  thumbnailUrl?: string;
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

    it('MediaLibraryContext 实例化与导航', 0, () => {
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

    // ── buildItems 辅助方法测试（不依赖 DB）──
    it('buildItems 按 seasonNumber 过滤并定位 currentIndex', 0, () => {
      const fakeItems: MediaItem[] = [
        {
          id: 1, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
          filePath: '/ep1.mkv', fileName: 'ep1.mkv', seasonNumber: 1, title: 'EP1'
        },
        {
          id: 2, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
          filePath: '/ep2.mkv', fileName: 'ep2.mkv', seasonNumber: 1, title: 'EP2'
        },
        {
          id: 3, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
          filePath: '/s2ep1.mkv', fileName: 's2ep1.mkv', seasonNumber: 2, title: 'S2EP1'
        },
      ];
      const result: BuildItemsResult = MediaLibraryContext.buildItems(fakeItems, 1, '/ep2.mkv');
      // 只保留 season=1 的 2 集
      expect(result.items.length).assertEqual(2);
      // currentVideoPath='/ep2.mkv' 对应 index=1
      expect(result.currentIndex).assertEqual(1);
      expect(result.items[0].videoPath).assertEqual('/ep1.mkv');
      expect(result.items[1].videoPath).assertEqual('/ep2.mkv');
    });

    it('buildItems 会将当前季的可播放条目按集号升序排列', 0, () => {
      const fakeItems: MediaItem[] = [
        {
          id: 2, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
          filePath: '/ep2.mkv', fileName: 'ep2.mkv', seasonNumber: 1, episodeNumber: 2, title: 'EP2'
        },
        {
          id: 1, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
          filePath: '/ep1.mkv', fileName: 'ep1.mkv', seasonNumber: 1, episodeNumber: 1, title: 'EP1'
        },
        {
          id: 3, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
          filePath: '/special.mkv', fileName: 'special.mkv', seasonNumber: 1, title: 'SPECIAL'
        }
      ];

      const result: BuildItemsResult = MediaLibraryContext.buildItems(fakeItems, 1, '/ep2.mkv');

      expect(result.items.length).assertEqual(3);
      expect(result.items[0].videoPath).assertEqual('/ep1.mkv');
      expect(result.items[1].videoPath).assertEqual('/ep2.mkv');
      expect(result.items[2].videoPath).assertEqual('/special.mkv');
      expect(result.currentIndex).assertEqual(1);
    });

    it('buildItems currentVideoPath 不存在时 currentIndex 默认为 0', 0, () => {
      const fakeItems: MediaItem[] = [
        {
          id: 1, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
          filePath: '/ep1.mkv', fileName: 'ep1.mkv', seasonNumber: 1
        },
        {
          id: 2, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
          filePath: '/ep2.mkv', fileName: 'ep2.mkv', seasonNumber: 1
        },
      ];
      const result: BuildItemsResult = MediaLibraryContext.buildItems(fakeItems, 1, '/not-exist.mkv');
      expect(result.items.length).assertEqual(2);
      expect(result.currentIndex).assertEqual(0);
    });

    it('buildItems season 不存在时返回空列表', 0, () => {
      const fakeItems: MediaItem[] = [
        {
          id: 1, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
          filePath: '/ep1.mkv', fileName: 'ep1.mkv', seasonNumber: 1
        },
      ];
      const result: BuildItemsResult = MediaLibraryContext.buildItems(fakeItems, 99, '/ep1.mkv');
      expect(result.items.length).assertEqual(0);
      expect(result.currentIndex).assertEqual(0);
    });

    it('buildItems title 为 undefined 时回退到 fileName', 0, () => {
      const fakeItems: MediaItem[] = [
        {
          id: 1, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
          filePath: '/ep1.mkv', fileName: 'ep1.mkv', seasonNumber: 1
          // title 未设置
        },
      ];
      const result: BuildItemsResult = MediaLibraryContext.buildItems(fakeItems, 1, '/ep1.mkv');
      expect(result.items.length).assertEqual(1);
      expect(result.items[0].title).assertEqual('ep1.mkv');
    });

    it('buildItems 保留播放器切源所需的剧集元数据', 0, () => {
      const fakeItems: MediaItem[] = [
        {
          id: 9, sourceId: 3, directoryPath: '/tv', scannedAt: 0,
          filePath: '/ep9.mkv', fileName: 'ep9.mkv', seasonNumber: 2, episodeNumber: 9,
          durationMs: 2520000, title: '第九集',
          audioTracksJson: '[{\"trackIndex\":0}]',
          videoCodec: 'h264'
        }
      ];

      const result: BuildItemsResult = MediaLibraryContext.buildItems(fakeItems, 2, '/ep9.mkv');
      expect(result.items.length).assertEqual(1);
      expect(result.items[0].videoId).assertEqual(9);
      expect(result.items[0].sourceId).assertEqual(3);
      expect(result.items[0].seasonNumber).assertEqual(2);
      expect(result.items[0].episodeNumber).assertEqual(9);
      expect(result.items[0].durationMs).assertEqual(2520000);
    });

    it('buildItems 优先使用剧集 stillUrl 填充缩略图字段且不再依赖 posterLocalPath', 0, () => {
      const fakeItems: MediaItem[] = [
        {
          id: 1, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
          filePath: '/ep1.mkv', fileName: 'ep1.mkv', seasonNumber: 1, episodeNumber: 1,
          title: 'EP1', posterLocalPath: '/series-poster.jpg'
        },
      ];
      const episodeEntities: TvEpisodeEntity[] = [
        {
          seriesId: 1, provider: 'tmdb', providerId: 'ep1',
          seasonNumber: 1, episodeNumber: 1, scrapedAt: 0,
          stillUrl: 'https://image.tmdb.org/t/p/w342/still-ep1.jpg'
        },
      ];
      const result = MediaLibraryContext.buildItems(fakeItems, 1, '/ep1.mkv', episodeEntities);
      const firstItem = result.items[0] as PlaybackContextItemWithThumbnail;

      expect(firstItem.thumbnailUrl).assertEqual('https://image.tmdb.org/t/p/w342/still-ep1.jpg');
      expect(JSON.stringify(firstItem).indexOf('posterPath')).assertEqual(-1);
    });

    it('buildItems 在 stillUrl 缺失时使用 stillPath 生成与季详情页一致的缩略图 URL', 0, () => {
      const fakeItems: MediaItem[] = [
        {
          id: 1, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
          filePath: '/ep1.mkv', fileName: 'ep1.mkv', seasonNumber: 1, episodeNumber: 1,
          title: 'EP1'
        },
      ];
      const episodeEntities: TvEpisodeEntity[] = [
        {
          seriesId: 1, provider: 'tmdb', providerId: 'ep1',
          seasonNumber: 1, episodeNumber: 1, scrapedAt: 0,
          stillPath: '/still-ep1.jpg'
        },
      ];
      const result = MediaLibraryContext.buildItems(fakeItems, 1, '/ep1.mkv', episodeEntities);
      const firstItem = result.items[0] as PlaybackContextItemWithThumbnail;

      expect(firstItem.thumbnailUrl).assertEqual('https://image.tmdb.org/t/p/w342/still-ep1.jpg');
    });

    it('buildItems 优先使用集标题而不是剧级标题作为播放器展示标题', 0, () => {
      const fakeItems: MediaItem[] = [
        {
          id: 11, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
          filePath: '/s1e2.mkv', fileName: 's1e2.mkv', seasonNumber: 1, episodeNumber: 2,
          title: '长夜余火'
        },
      ];
      const episodeEntities: TvEpisodeEntity[] = [
        {
          seriesId: 7, provider: 'tmdb', providerId: 'ep-2',
          seasonNumber: 1, episodeNumber: 2, scrapedAt: 0,
          title: '突围'
        },
      ];

      const result = MediaLibraryContext.buildItems(fakeItems, 1, '/s1e2.mkv', episodeEntities);
      expect(result.items.length).assertEqual(1);
      expect(result.items[0].title).assertEqual('突围');
    });

    it('buildItems 在缺少合适集标题时回退为第X集而不是剧名', 0, () => {
      const fakeItems: MediaItem[] = [
        {
          id: 12, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
          filePath: '/s1e7.mkv', fileName: 's1e7.mkv', seasonNumber: 1, episodeNumber: 7,
          title: '长夜余火'
        },
      ];

      const result = MediaLibraryContext.buildItems(fakeItems, 1, '/s1e7.mkv');
      expect(result.items.length).assertEqual(1);
      expect(result.items[0].title).assertEqual('第7集');
    });

    it('buildItems 在已知 episodeNumber 未命中元数据时不会按索引错配到其他集', 0, () => {
      const fakeItems: MediaItem[] = [
        {
          id: 1, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
          filePath: '/s1e1.mkv', fileName: 's1e1.mkv', seasonNumber: 1, episodeNumber: 1
        },
        {
          id: 3, sourceId: 1, directoryPath: '/tv', scannedAt: 0,
          filePath: '/s1e3.mkv', fileName: 's1e3.mkv', seasonNumber: 1, episodeNumber: 3
        }
      ];
      const episodeEntities: TvEpisodeEntity[] = [
        {
          seriesId: 7, provider: 'tmdb', providerId: 'ep-1',
          seasonNumber: 1, episodeNumber: 1, scrapedAt: 0, title: '第一集'
        },
        {
          seriesId: 7, provider: 'tmdb', providerId: 'ep-2',
          seasonNumber: 1, episodeNumber: 2, scrapedAt: 0, title: '第二集',
          stillUrl: 'https://image.tmdb.org/t/p/w342/ep2.jpg'
        },
        {
          seriesId: 7, provider: 'tmdb', providerId: 'ep-4',
          seasonNumber: 1, episodeNumber: 4, scrapedAt: 0, title: '第四集'
        }
      ];

      const result = MediaLibraryContext.buildItems(fakeItems, 1, '/s1e3.mkv', episodeEntities);
      const thirdItem = result.items[1] as PlaybackContextItemWithThumbnail;

      expect(result.items.length).assertEqual(2);
      expect(thirdItem.title).assertEqual('第3集');
      expect(thirdItem.thumbnailUrl === undefined).assertTrue();
    });

    it('createMediaLibraryEpisodeGroupMatcher 每次都返回新实例以避免跨 build 复用旧缓存', 0, () => {
      const first = createMediaLibraryEpisodeGroupMatcher();
      const second = createMediaLibraryEpisodeGroupMatcher();

      expect(first === second).assertFalse();
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
