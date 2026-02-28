import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { MediaLibraryModel, SortType, FilterCriteria } from '../main/ets/stores/media/MediaLibraryModel';
import { MediaListItem, MediaItem, SeriesGroup } from '../main/ets/db/models/MediaEntity';

export default function mediaLibraryFilterTest() {
  describe('MediaLibraryFilter', () => {
    let model: MediaLibraryModel;

    beforeEach(() => {
      model = MediaLibraryModel.getState();
      // 重置筛选条件
      model.resetFilters();
    });

    it('初始筛选条件应为默认值', 0, () => {
      expect(model.filterCriteria.searchKeyword).assertEqual('');
      expect(model.filterCriteria.mediaType).assertEqual('all');
      expect(model.filterCriteria.year).assertEqual('');
      expect(model.filterCriteria.watchStatus).assertEqual('all');
      expect(model.filterCriteria.genre).assertEqual('');
      expect(model.filterCriteria.sortType).assertEqual(SortType.RECENT);
    });

    it('更新筛选条件应正确更新状态', 0, () => {
      model.updateFilter({ searchKeyword: '测试' });
      expect(model.filterCriteria.searchKeyword).assertEqual('测试');

      model.updateFilter({ mediaType: 'movie' });
      expect(model.filterCriteria.mediaType).assertEqual('movie');

      model.updateFilter({ sortType: SortType.NAME });
      expect(model.filterCriteria.sortType).assertEqual(SortType.NAME);
    });

    it('重置筛选条件应恢复默认值', 0, () => {
      model.updateFilter({ searchKeyword: '测试', mediaType: 'movie', sortType: SortType.NAME });
      model.resetFilters();

      expect(model.filterCriteria.searchKeyword).assertEqual('');
      expect(model.filterCriteria.mediaType).assertEqual('all');
      expect(model.filterCriteria.sortType).assertEqual(SortType.RECENT);
    });

    it('搜索功能应正确过滤结果', 0, () => {
      // 模拟数据
      const mockVideo1: MediaItem = {
        id: 1,
        sourceId: 1,
        directoryPath: '/test',
        filePath: '/test/movie1.mp4',
        fileName: 'movie1.mp4',
        title: '复仇者联盟',
        mediaType: 'movie',
        scannedAt: Date.now()
      };

      const mockVideo2: MediaItem = {
        id: 2,
        sourceId: 1,
        directoryPath: '/test',
        filePath: '/test/movie2.mp4',
        fileName: 'movie2.mp4',
        title: '星球大战',
        mediaType: 'movie',
        scannedAt: Date.now()
      };

      const mockList: MediaListItem[] = [
        { kind: 'video', video: mockVideo1, sortTs: mockVideo1.scannedAt },
        { kind: 'video', video: mockVideo2, sortTs: mockVideo2.scannedAt }
      ];

      model.recentlyAddedList = mockList;
      model.updateFilter({ searchKeyword: '复仇' });

      expect(model.filteredList.length).assertEqual(1);
      expect(model.filteredList[0].video?.title).assertEqual('复仇者联盟');
    });

    it('类型筛选应正确过滤电影', 0, () => {
      const mockMovie: MediaItem = {
        id: 1,
        sourceId: 1,
        directoryPath: '/test',
        filePath: '/test/movie.mp4',
        fileName: 'movie.mp4',
        title: '测试电影',
        mediaType: 'movie',
        scannedAt: Date.now()
      };

      const mockTv: MediaItem = {
        id: 2,
        sourceId: 1,
        directoryPath: '/test',
        filePath: '/test/tv.mp4',
        fileName: 'tv.mp4',
        title: '测试电视剧',
        mediaType: 'tv',
        scannedAt: Date.now()
      };

      const mockList: MediaListItem[] = [
        { kind: 'video', video: mockMovie, sortTs: mockMovie.scannedAt },
        { kind: 'video', video: mockTv, sortTs: mockTv.scannedAt }
      ];

      model.recentlyAddedList = mockList;
      model.updateFilter({ mediaType: 'movie' });

      expect(model.filteredList.length).assertEqual(1);
      expect(model.filteredList[0].video?.mediaType).assertEqual('movie');
    });

    it('排序功能应正确排序（按名称）', 0, () => {
      const mockVideo1: MediaItem = {
        id: 1,
        sourceId: 1,
        directoryPath: '/test',
        filePath: '/test/b.mp4',
        fileName: 'b.mp4',
        title: 'B电影',
        scannedAt: Date.now()
      };

      const mockVideo2: MediaItem = {
        id: 2,
        sourceId: 1,
        directoryPath: '/test',
        filePath: '/test/a.mp4',
        fileName: 'a.mp4',
        title: 'A电影',
        scannedAt: Date.now()
      };

      const mockList: MediaListItem[] = [
        { kind: 'video', video: mockVideo1, sortTs: mockVideo1.scannedAt },
        { kind: 'video', video: mockVideo2, sortTs: mockVideo2.scannedAt }
      ];

      model.recentlyAddedList = mockList;
      model.updateFilter({ sortType: SortType.NAME });

      expect(model.filteredList[0].video?.title).assertEqual('A电影');
      expect(model.filteredList[1].video?.title).assertEqual('B电影');
    });

    it('年份筛选应正确过滤结果', 0, () => {
      const mockVideo2020: MediaItem = {
        id: 1,
        sourceId: 1,
        directoryPath: '/test',
        filePath: '/test/2020.mp4',
        fileName: '2020.mp4',
        title: '2020年电影',
        releaseDate: '2020-01-01',
        scannedAt: Date.now()
      };

      const mockVideo2021: MediaItem = {
        id: 2,
        sourceId: 1,
        directoryPath: '/test',
        filePath: '/test/2021.mp4',
        fileName: '2021.mp4',
        title: '2021年电影',
        releaseDate: '2021-01-01',
        scannedAt: Date.now()
      };

      const mockList: MediaListItem[] = [
        { kind: 'video', video: mockVideo2020, sortTs: mockVideo2020.scannedAt },
        { kind: 'video', video: mockVideo2021, sortTs: mockVideo2021.scannedAt }
      ];

      model.recentlyAddedList = mockList;
      model.updateFilter({ year: '2020' });

      expect(model.filteredList.length).assertEqual(1);
      expect(model.filteredList[0].video?.releaseDate).assertContain('2020');
    });
  });
}
