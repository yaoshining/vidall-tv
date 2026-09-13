const { test } = require('node:test');
const assert = require('node:assert/strict');
const { fixture, plain } = require('./media_library_sql_fixture.cjs');

async function visible(dao, old) {
  const all = old ? await dao.getAllMediaItems() : undefined;
  const movies = old ? await dao.getMediaItemsByType('movie') : await dao.getHomeMovies();
  let counts;
  if (old) {
    const rated = await dao.getMediaItemsByRating();
    counts = { movieCount: movies.length,
      ratingCounts: [5,6,7,8,9].map(floor => rated.filter(x => x.rating >= floor && x.rating < floor + 1).length) };
  } else counts = await dao.getHomeMediaCounts();
  const years = await dao.getDistinctReleaseYears(true);
  const stats = await dao.getMediaStats(true);
  const series = await dao.getDistinctTvSeriesGroups(30, true);
  const recent = await dao.getRecentlyAddedList(20, true);
  const unwatched = old ? await dao.searchMediaItems('', { watchProgress: 'unseen', limit: 20 }, true)
    : await dao.getHomeUnwatched();
  return plain({ movies: movies.slice(0, 30), counts, years, stats, series, recent,
    unwatched: unwatched.sort((a, b) => b.scannedAt - a.scannedAt) });
}
for (const count of [0, 13, 1000, 10000]) {
  test(`${count} 条混合库：首页项、顺序、季分组、评分、年代与全库统计一致`, async () => {
    const f = fixture(count);
    try {
      assert.deepEqual(await visible(f.dao, false), await visible(f.old, true));
      assert.ok(f.results.every(rs => rs.closed));
    } finally { f.db.close(); }
  });
}
test('评分边界包括空评分、低于5、每档端点、9.999及10；同一剧每集分别计数', async () => {
  const f = fixture();
  try {
    [null, 4.999, 5, 5.999, 6, 6.999, 7, 7.999, 8, 8.999, 9, 9.999, 10].forEach((r, i) => f.movie(i + 1, r));
    f.episode(100, 1, 1, 1, 8); f.episode(101, 1, 2, 1, 8);
    f.movie(200, 5, 3); // 同电影两文件：电影栏与顶部统计有意不同
    const result = plain(await f.dao.getHomeMediaCounts());
    assert.deepEqual(result, { movieCount: 14, ratingCounts: [3, 2, 2, 4, 2] });
    assert.equal((await f.dao.getMediaStats()).movies, 13);
  } finally { f.db.close(); }
});
test('首页窗口外的完整列表、定向搜索、年份筛选、电影/剧集详情和继续观看仍可访问', async () => {
  const f = fixture(1000);
  try {
    const home = await visible(f.dao, false);
    assert.equal((await f.dao.getAllMediaItems()).length, 1000);
    assert.equal((await f.dao.getMediaItemsByType('movie')).length, 400);
    assert.ok(!home.movies.some(x => x.id === 1));
    assert.equal((await f.dao.searchMediaItems('电影000001', { limit: 200 }, true))[0].id, 1);
    assert.ok((await f.dao.getMediaItemsByYear('1951')).some(x => x.id === 1));
    assert.equal((await f.dao.getMediaItemByVideoId(1)).id, 1);
    assert.equal((await f.dao.getContinueWatchingMedia('1')).id, 1);
    assert.equal((await f.dao.getContinueWatchingMedia('', 100000, 1, 1)).id, 5);
    assert.equal((await f.dao.getMediaItemsByTvSeriesId(100000)).length, 20);
    assert.deepEqual(plain(await f.dao.searchMediaItems('', { limit: 200 }, true)),
      plain(await f.old.searchMediaItems('', { limit: 200 }, true)));
  } finally { f.db.close(); }
});
test('未观看保留观看标记、0%下一集、旧剧级key及provider前缀匹配规则', async () => {
  const f = fixture();
  try {
    for (let id = 1; id <= 8; id++) f.movie(id, 8);
    for (let id = 1; id <= 4; id++) f.episode(100 + id, id === 4 ? 13990 : id === 3 ? 1399 : id, 1, 1);
    const progress = (key, position, watched = 0) => f.insert('media_progress', {
      media_key: key, position_ms: position, duration_ms: 1000000, is_watched: watched, last_played_at: 1
    });
    progress('media_progress_movie_1', 1); progress('media_progress_movie_2', 0, 1);
    progress('media_progress_movie_3', 0);
    progress('media_progress_episode_tmdb_1_s1_e1', 0);
    progress('media_progress_series_tmdb_2', 10);
    progress('media_progress_episode_tmdb_13990_s1_e1', 10);
    assert.deepEqual(await visible(f.dao, false), await visible(f.old, true));
    const items = await f.dao.getHomeUnwatched();
    assert.ok(!items.some(x => x.id === 1 || x.id === 2 || x.id === 104));
    for (const id of [3, 101, 102, 103]) assert.ok(items.some(x => x.id === id));
  } finally { f.db.close(); }
});
test('继续观看重复文件保留原Map覆盖规则，选择最早扫描文件', async () => {
  const f = fixture();
  try {
    f.movie(1, 8); f.movie(100, 8, 1);
    const oldMap = new Map((await f.old.getAllMediaItems()).map(x => [x.providerId, x]));
    assert.deepEqual(plain(await f.dao.getContinueWatchingMedia('1')), plain(oldMap.get('1')));
    f.db.exec('UPDATE videos SET scanned_at=1');
    const tiedMap = new Map((await f.old.getAllMediaItems()).map(x => [x.providerId, x]));
    assert.deepEqual(plain(await f.dao.getContinueWatchingMedia('1')), plain(tiedMap.get('1')));
  } finally { f.db.close(); }
});
for (const method of ['getHomeMovies', 'getHomeMediaCounts', 'getHomeUnwatched',
  'getDistinctReleaseYears', 'getMediaStats', 'getDistinctTvSeriesGroups', 'getRecentlyAddedList']) {
  test(`${method}: DAO真实查询失败向首页传播；默认共享语义不变`, async () => {
    const f = fixture();
    const args = method === 'getDistinctTvSeriesGroups' ? [30, true]
      : method === 'getRecentlyAddedList' ? [20, true] : [true];
    try {
      f.core.getStore = () => ({ querySql: async () => { throw new Error('注入数据库失败'); } });
      await assert.rejects(f.dao[method](...args), /注入数据库失败/);
      if (!method.startsWith('getHome')) await f.dao[method]();
      f.core.isReady = () => false;
      await assert.rejects(f.dao[method](...args), /尚未就绪/);
    } finally { f.db.close(); }
  });
}
module.exports = { visible };

test('超长剧集：去重后截断，修复旧200候选耗尽导致的少项', async () => {
  const f = fixture();
  try {
    for (let i = 1; i <= 250; i++) f.episode(i, 1, 1 + Math.floor((i - 1) / 125), 1 + (i - 1) % 125, 9.9);
    for (let i = 300; i < 340; i++) f.movie(i, 8);
    assert.equal((await f.old.searchMediaItems('', { watchProgress: 'unseen', limit: 20 }, true)).length, 1);
    const items = await f.dao.getHomeUnwatched();
    assert.equal(items.length, 20);
    assert.equal(items.filter(x => x.tvSeriesId === 1).length, 1);
    assert.equal((await f.dao.getRecentlyAddedList()).filter(x => x.kind === 'series').length, 0);
  } finally { f.db.close(); }
});
test('最近添加的同时间剧季优先、剧级与单集共存时排除剧级条目', async () => {
  const f = fixture();
  try {
    f.episode(1, 1, 1, 1); f.episode(2, 1, 2, 1); f.movie(3);
    f.video(4);
    f.insert('scrape_info', { video_id: 4, provider: 'tmdb', provider_id: '1', media_type: 'tv',
      tv_series_id: 1, title: '剧级', scraped_at: 999 });
    f.db.exec('UPDATE scrape_info SET scraped_at=100');
    const items = await f.dao.getRecentlyAddedList();
    assert.deepEqual(plain(items), plain(await f.old.getRecentlyAddedList()));
    assert.deepEqual(items.map(x => x.kind).join(','), 'series,series,video');
    assert.equal(items.filter(x => x.kind === 'series').length, 2);
  } finally { f.db.close(); }
});
test('扫描时间查询失败/未就绪向首页传播，默认调用仍保持旧值语义', async () => {
  const f = fixture();
  try {
    f.core.getStore = () => ({ querySql: async () => { throw new Error('扫描查询失败'); } });
    await assert.rejects(f.videoDao.getLatestScanTime(true), /扫描查询失败/);
    assert.equal(await f.videoDao.getLatestScanTime(), 0);
    f.core.isReady = () => false;
    await assert.rejects(f.videoDao.getLatestScanTime(true), /尚未就绪/);
  } finally { f.db.close(); }
});
