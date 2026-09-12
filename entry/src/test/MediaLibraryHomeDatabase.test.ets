import { describe, it, expect } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import relationalStore from '@ohos.data.relationalStore';
import { Context } from '@ohos.abilityAccessCtrl';
import { FileSourceDbCore } from '../main/ets/db/files/FileSourceDbCore';
import { MediaQueryDao } from '../main/ets/db/files/MediaQueryDao';

/** 只替换连接来源；查询和ResultSet解析均为真实平台实现，不改全局数据库名/单例。 */
class HomeQueryTestCore extends FileSourceDbCore {
  private testStore: relationalStore.RdbStore;

  constructor(store: relationalStore.RdbStore) {
    super();
    this.testStore = store;
  }

  isReady(): boolean { return true; }
  getStore(): relationalStore.RdbStore { return this.testStore; }
}

let databaseSequence: number = 0;

async function withHomeDatabase(
  verify: (dao: MediaQueryDao, store: relationalStore.RdbStore) => Promise<void>
): Promise<void> {
  const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
  const name = `VIDALL_HOME_QUERY_SMOKE_${Date.now()}_${++databaseSequence}.db`;
  const config: relationalStore.StoreConfig = { name, securityLevel: relationalStore.SecurityLevel.S1 };
  const store = await relationalStore.getRdbStore(context, config);
  try {
    // 测试专用最小schema，列与生产查询一致；不连接FILE_SOURCES_DB，不复用门面单例。
    const metadataColumns = `id INTEGER PRIMARY KEY, title TEXT, original_title TEXT, overview TEXT,
      rating REAL, genres_json TEXT, poster_url TEXT, backdrop_url TEXT,
      poster_local_path TEXT, backdrop_local_path TEXT`;
    const schema: string[] = [
      `CREATE TABLE videos (id INTEGER PRIMARY KEY, source_id INTEGER, directory_path TEXT,
        file_path TEXT, file_name TEXT, file_size INTEGER, duration_ms INTEGER, width INTEGER,
        height INTEGER, video_codec TEXT, audio_tracks_json TEXT, scanned_at INTEGER)`,
      `CREATE TABLE movies (${metadataColumns}, release_date TEXT)`,
      `CREATE TABLE tv_series (${metadataColumns}, provider_id TEXT, first_air_date TEXT)`,
      `CREATE TABLE tv_episodes (id INTEGER PRIMARY KEY, overview TEXT)`,
      `CREATE TABLE tv_seasons (series_id INTEGER, season_number INTEGER, poster_url TEXT)`,
      `CREATE TABLE scrape_info (video_id INTEGER UNIQUE, provider TEXT, provider_id TEXT,
        media_type TEXT, title TEXT, movie_id INTEGER, tv_series_id INTEGER, episode_id INTEGER,
        season_number INTEGER, episode_number INTEGER, scraped_at INTEGER)`,
      `CREATE TABLE media_progress (media_key TEXT PRIMARY KEY, position_ms INTEGER,
        duration_ms INTEGER, is_watched INTEGER, last_played_at INTEGER)`
    ];
    for (const sql of schema) { await store.executeSql(sql); }
    await verify(new MediaQueryDao(new HomeQueryTestCore(store)), store);
  } finally {
    try { await store.close(); } finally {
      // name仅来自上面的专用前缀，绝不删除生产库。
      await relationalStore.deleteRdbStore(context, name);
    }
  }
}

async function seedHomeDatabase(store: relationalStore.RdbStore): Promise<void> {
  await store.executeSql(`INSERT INTO movies (id, title, rating, release_date)
    VALUES (1, '电影一', 5.0, '1999-01-01'), (2, '电影二', 10.0, '2024-01-01')`);
  await store.executeSql(`INSERT INTO tv_series (id, title, provider_id, rating, first_air_date)
    VALUES (10, '两季剧', '100', 8.0, '2020-01-01')`);
  await store.executeSql(`INSERT INTO tv_episodes (id, overview) VALUES (4, '第一季'), (5, '第二季')`);
  for (let id = 1; id <= 5; id++) {
    await store.executeSql(`INSERT INTO videos
      (id, source_id, directory_path, file_path, file_name, scanned_at)
      VALUES (?, 1, '/test', ?, ?, ?)`, [id, `/test/${id}.mkv`, `${id}.mkv`, id * 10]);
  }
  // 同电影两个文件、10分电影、同剧两季；用于验证聚合与去重口径不同。
  await store.executeSql(`INSERT INTO scrape_info
    (video_id, provider, provider_id, media_type, title, movie_id, scraped_at)
    VALUES (1, 'tmdb', '1', 'movie', '电影一', 1, 10),
      (2, 'tmdb', '1', 'movie', '电影一', 1, 20),
      (3, 'tmdb', '2', 'movie', '电影二', 2, 30)`);
  await store.executeSql(`INSERT INTO scrape_info
    (video_id, provider, provider_id, media_type, title, tv_series_id, episode_id,
      season_number, episode_number, scraped_at)
    VALUES (4, 'tmdb', '4', 'episode', '两季剧', 10, 4, 1, 1, 40),
      (5, 'tmdb', '5', 'episode', '两季剧', 10, 5, 2, 1, 50)`);
}

export default function mediaLibraryHomeDatabaseTest(): void {
  describe('MediaLibraryHome_relationalStore_smoke', () => {
    it('empty_database_executes_all_home_queries', 0, async () => {
      await withHomeDatabase(async (dao: MediaQueryDao, _store: relationalStore.RdbStore): Promise<void> => {
        expect((await dao.getHomeMovies()).length).assertEqual(0);
        const counts = await dao.getHomeMediaCounts();
        expect(counts.movieCount).assertEqual(0);
        expect(counts.ratingCounts.join(',')).assertEqual('0,0,0,0,0');
        expect((await dao.getHomeUnwatched()).length).assertEqual(0);
        expect(await dao.getContinueWatchingMedia('missing')).assertUndefined();
      });
    });

    it('mixed_movies_seasons_counts_and_window_query_match_contract', 0, async () => {
      await withHomeDatabase(async (dao: MediaQueryDao, store: relationalStore.RdbStore): Promise<void> => {
        await seedHomeDatabase(store);
        const movies = await dao.getHomeMovies();
        expect(movies.map(item => item.id).join(',')).assertEqual('3,2,1');
        const counts = await dao.getHomeMediaCounts();
        expect(counts.movieCount).assertEqual(3);
        expect(counts.ratingCounts.join(',')).assertEqual('2,0,0,2,0');
        expect((await dao.getMediaStats(true)).movies).assertEqual(2);
        const unseen = await dao.getHomeUnwatched();
        expect(unseen.map(item => item.id).join(',')).assertEqual('3,4,1');
        expect((await dao.getDistinctTvSeriesGroups(30, true))[0].episodeCount).assertEqual(2);
        const recent = await dao.getRecentlyAddedList(20, true);
        expect(recent.length).assertEqual(5);
        expect(recent[0].series?.seasonNumber).assertEqual(2);
        expect(recent[1].series?.seasonNumber).assertEqual(1);
        expect((await dao.getContinueWatchingMedia('1'))?.id).assertEqual(1);
        expect((await dao.getContinueWatchingMedia('', 10, 2, 1))?.id).assertEqual(5);
      });
    });

    it('progress_filters_movies_and_whole_series_but_keeps_zero_position', 0, async () => {
      await withHomeDatabase(async (dao: MediaQueryDao, store: relationalStore.RdbStore): Promise<void> => {
        await seedHomeDatabase(store);
        await store.executeSql(`INSERT INTO media_progress VALUES
          ('media_progress_movie_1', 0, 1000000, 1, 1),
          ('media_progress_episode_tmdb_100_s2_e1', 0, 1000000, 0, 2)`);
        expect((await dao.getHomeUnwatched()).map(item => item.id).join(',')).assertEqual('3,4');
        await store.executeSql(`UPDATE media_progress SET position_ms = 1
          WHERE media_key = 'media_progress_episode_tmdb_100_s2_e1'`);
        expect((await dao.getHomeUnwatched()).map(item => item.id).join(',')).assertEqual('3');
        // 继续观看元数据查询不被首页未观看过滤，仍可找回全库指定集。
        expect((await dao.getContinueWatchingMedia('', 10, 2, 1))?.id).assertEqual(5);
      });
    });
  });
}
