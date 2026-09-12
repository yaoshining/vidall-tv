// node --expose-gc entry/src/test/media_library_home_benchmark.cjs
// 仅主机 SQLite/DAO 测量，不代表 HarmonyOS 真机或端到端渲染。
const os = require('node:os');
const { fixture, baseline, plain } = require('./media_library_sql_fixture.cjs');
const assert = require('node:assert/strict');
async function loadHome(f, old) {
  const dao = old ? f.old : f.dao;
  const all = old ? await dao.getAllMediaItems() : [];
  const movies = old ? await dao.getMediaItemsByType('movie') : await dao.getHomeMovies();
  const rated = old ? await dao.getMediaItemsByRating() : [];
  const counts = old ? { movieCount: movies.length,
    ratingCounts: [5, 6, 7, 8, 9].map(n => rated.filter(x => x.rating >= n && x.rating < n + 1).length) }
    : await dao.getHomeMediaCounts();
  const years = await dao.getDistinctReleaseYears(true);
  const stats = await dao.getMediaStats(true);
  const series = await dao.getDistinctTvSeriesGroups(30, true);
  const latest = await f.videoDao.getLatestScanTime(true);
  const recent = await dao.getRecentlyAddedList(20, true);
  const unwatched = old ? await dao.searchMediaItems('', { watchProgress: 'unseen', limit: 20 }, true)
    : await dao.getHomeUnwatched();
  unwatched.sort((a, b) => b.scannedAt - a.scannedAt);
  // 正常加载路径的主库查询与评分分档。输出裁剪只用于比较旧版最终显示结果。
  return { movies: movies.slice(0, 30), counts, years, stats, series, latest, recent, unwatched };
}
const median = values => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
async function measure(f, old) {
  global.gc?.();
  f.metrics.length = 0; f.results.length = 0;
  let parsed = 0;
  const dao = old ? f.old : f.dao, parse = dao.parseMediaItem;
  dao.parseMediaItem = function(rs) { parsed++; return parse.call(this, rs); };
  const start = performance.now();
  const value = await loadHome(f, old);
  const elapsedMs = performance.now() - start;
  dao.parseMediaItem = parse;
  return { value, elapsedMs, queryMs: f.metrics.reduce((n, x) => n + x.ms, 0),
    queryCount: f.metrics.length, returnedRows: f.metrics.reduce((n, x) => n + x.rows, 0),
    // 最近添加的电影/剧季与剧集栏直接构造对象，未调用 parseMediaItem；分别统计。
    mediaItemObjects: parsed + f.metrics.reduce((n, x) => n + x.directMediaItems, 0),
    seriesGroupObjects: f.metrics.reduce((n, x) => n + x.seriesGroups, 0) };
}
(async () => {
  const report = { baseline, measuredAt: new Date().toISOString(), environment: {
    os: `${os.type()} ${os.release()}`, arch: os.arch(), cpu: os.cpus()[0].model,
    node: process.version, database: 'SQLite :memory:', logging: 'console disabled for both; diagnostic queries retained in baseline',
    warmupPairs: 2, measuredPairs: 7, gcBeforeSample: !!global.gc
  }, datasets: [] };
  for (const count of [1000, 10000]) {
    const f = fixture(count);
    report.environment.sqlite = f.db.prepare('SELECT sqlite_version() AS version').get().version;
    for (let i = 0; i < 2; i++) { await measure(f, true); await measure(f, false); }
    const before = [], after = [];
    for (let i = 0; i < 7; i++) {
      const pair = i % 2 ? [await measure(f, false), await measure(f, true)].reverse()
        : [await measure(f, true), await measure(f, false)];
      assert.deepEqual(plain(pair[0].value), plain(pair[1].value));
      before.push(pair[0]); after.push(pair[1]);
    }
    const summarize = runs => ({ elapsedMedianMs: median(runs.map(x => x.elapsedMs)),
      queryMedianMs: median(runs.map(x => x.queryMs)), queryCount: runs[0].queryCount,
      returnedRows: runs[0].returnedRows, mediaItemObjects: runs[0].mediaItemObjects,
      seriesGroupObjects: runs[0].seriesGroupObjects,
      elapsedSamplesMs: runs.map(x => x.elapsedMs), querySamplesMs: runs.map(x => x.queryMs) });
    report.datasets.push({ videos: count, movies: count * 0.4, episodes: count * 0.5, unscraped: count * 0.1,
      episodesPerSeries: 20, seasonsPerSeries: 2, progressRows: 0, before: summarize(before), after: summarize(after),
      visibleResultsEqual: true });
    f.db.close();
  }
  process.stdout.write(JSON.stringify(report, null, 2) + '\n');
})().catch(e => { console.error(e); process.exitCode = 1; });
