// 执行真实模型，只替换设备数据库边界及 ArkUI 装饰器；不复制会话实现。
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.TYPESCRIPT_PATH || 'typescript');
const filename = path.resolve(__dirname, '../main/ets/stores/media/MediaLibraryModel.ets');
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function fixture() {
  const errors = [];
  const env = { db: null };
  const exports = {};
  const code = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021,
      experimentalDecorators: true }
  }).outputText;
  vm.runInNewContext(code, { exports, ObservedV2: x => x, Trace: () => {},
    console: { info() {}, warn: (...x) => errors.push(x), error: (...x) => errors.push(x) },
    require(name) {
      if (name.endsWith('/FileSourceDatabase')) return { FileSourceDatabase: { getInstance: () => env.db } };
      if (name.endsWith('/MediaProgressStore')) return { MediaProgressStore: {
        isNearEnd: (position, duration) => duration - position < 60000 || position / duration >= 0.95
      } };
      if (name.endsWith('/TimeUtil')) return { millisecondsToTime: String };
      throw new Error(`未声明的依赖 ${name}`);
    }
  }, { filename });
  return { env, errors, model: new exports.MediaLibraryModel() };
}
const queries = ['getAllMediaItems', 'getMediaItemsByType', 'getMediaItemsByRating',
  'getDistinctReleaseYears', 'getMediaStats', 'getDistinctTvSeriesGroups',
  'getLatestScanTime', 'getRecentlyAddedList', 'searchMediaItems'];
function database(id, hold) {
  const item = { id, providerId: String(id), mediaType: 'movie', fileName: `电影${id}`,
    sourceId: 1, filePath: `/${id}`, scannedAt: id, rating: 8.5 };
  const values = [[item], [item], [item], ['2020'], { total: id, movies: id, tv: 0, other: 0 },
    [], id, [{ kind: 'video', video: item, sortTs: id }], [item]];
  const gate = deferred();
  const entered = deferred();
  const calls = [];
  const db = { getAllMediaProgress: async () => [], item, gate, entered, calls };
  queries.forEach((name, index) => {
    db[name] = async () => {
      calls.push(name);
      if (name === hold) { entered.resolve(); await gate.promise; }
      return values[index];
    };
  });
  return db;
}
function start(f, db, method = 'reload') {
  f.env.db = db;
  return f.model[method]();
}
function snapshot(m) {
  return JSON.stringify([m.recentlyAdded, m.movies, m.byRating, m.stats, m.seriesGroups,
    m.latestScanTime, m.unwatched, m.recentlyAddedList, m.unwatchedList,
    m.ratingLabels, m.decadeGroups, m.continueWatchingList, [...m.movieProgressMap]]);
}
function progress(id, ratio = 0.2) {
  return [{ mediaKey: `media_progress_movie_${id}`, positionMs: 1000000 * ratio,
    durationMs: 1000000, isWatched: 0, lastPlayedAt: id }];
}
// 每一个主库 await 都独立制造旧请求晚到，覆盖统计、最近添加和未观看分支。
for (const query of queries) {
  test(`旧请求在 ${query} 晚于新请求完成，不能提交任何字段`, async () => {
    const f = fixture();
    const old = database(1, query);
    const pending = start(f, old);
    await old.entered.promise;
    await start(f, database(2));
    const expected = snapshot(f.model);
    old.gate.resolve();
    await pending;
    assert.equal(snapshot(f.model), expected);
    assert.equal(f.model.stats.total, 2);
    assert.equal(f.model.isLoading, false);
  });
}
test('旧请求失败，新请求成功，不输出过期错误', async () => {
  const f = fixture(), old = database(1, queries[0]);
  const pending = start(f, old);
  await start(f, database(2));
  old.gate.reject(new Error('过期失败'));
  await pending;
  assert.equal(f.errors.length, 0);
  assert.equal(f.model.stats.total, 2);
  assert.equal(f.model.isLoaded, true);
});
for (const fail of [false, true]) {
  test(`旧请求${fail ? '失败' : '结束'}不能提前结束新请求 loading`, async () => {
    const f = fixture(), old = database(1, queries[0]), latest = database(2, queries[0]);
    const first = start(f, old), second = start(f, latest);
    fail ? old.gate.reject(new Error('过期')) : old.gate.resolve();
    await first;
    assert.equal(f.model.isLoading, true);
    assert.equal(f.model.isLoaded, false);
    latest.gate.resolve();
    await second;
    assert.equal(f.model.isLoading, false);
    assert.equal(f.model.stats.total, 2);
  });
}
test('连续多次 load/reload，最后一次需求实际查询且提交', async () => {
  const f = fixture();
  const dbs = [1, 2, 3, 4].map(id => database(id, queries[0]));
  const pending = dbs.map((db, i) => start(f, db, i % 2 ? 'load' : 'reload'));
  for (const db of dbs) assert.equal(db.calls.length, 1);
  dbs[3].gate.resolve();
  await pending[3];
  for (const db of dbs.slice(0, 3)) db.gate.resolve();
  await Promise.all(pending);
  assert.equal(f.model.stats.total, 4);
  assert.equal(dbs[3].calls.length, queries.length);
});
for (const query of queries) {
  test(`${query} 失败保留完整有效数据，允许重试`, async () => {
    const f = fixture();
    await start(f, database(1));
    const previous = snapshot(f.model), broken = database(2, query);
    const pending = start(f, broken);
    await broken.entered.promise;
    assert.equal(snapshot(f.model), previous);
    broken.gate.reject(new Error('当前查询失败'));
    await pending;
    assert.equal(snapshot(f.model), previous);
    assert.equal(f.model.isLoading, false);
    assert.equal(f.model.isLoaded, true);
    assert.equal(f.errors.length, 1);
    await start(f, database(3));
    assert.equal(f.model.stats.total, 3);
  });
}
test('首次加载失败后 loading 结束，后续重试成功', async () => {
  const f = fixture(), db = database(1, queries[0]);
  const pending = start(f, db);
  db.gate.reject(new Error('首次失败'));
  await pending;
  assert.equal(f.model.isLoaded, false);
  assert.equal(f.model.isLoading, false);
  assert.equal(f.model.recentlyAdded.length, 0);
  await start(f, database(2));
  assert.equal(f.model.isLoaded, true);
  assert.equal(f.model.stats.total, 2);
});
test('旧继续观看晚到，不覆盖新主库及其继续观看', async () => {
  const f = fixture();
  await start(f, database(1));
  const gate = deferred();
  f.env.db.getAllMediaProgress = () => gate.promise;
  const old = f.model.loadContinueWatching();
  const latest = database(2);
  latest.getAllMediaProgress = async () => progress(2);
  await start(f, latest);
  gate.resolve(progress(1));
  await old;
  assert.equal(f.model.continueWatchingList[0].videoId, 2);
  assert.equal(f.model.getMovieProgress('2'), 0.2);
  assert.equal(f.model.getMovieProgress('1'), 0);
});
test('主库加载中进度事件使用旧元数据，主库提交后必须重读最新进度', async () => {
  const f = fixture();
  await start(f, database(1));
  const latest = database(2, queries[0]), eventGate = deferred();
  const pending = start(f, latest);
  latest.getAllMediaProgress = () => eventGate.promise;
  const event = f.model.loadContinueWatching();
  latest.getAllMediaProgress = async () => progress(2, 0.4);
  latest.gate.resolve();
  await pending;
  eventGate.resolve(progress(1));
  await event;
  assert.equal(f.model.continueWatchingList[0].videoId, 2);
  assert.equal(f.model.getMovieProgress('2'), 0.4);
});
test('继续观看不阻塞主库 loading；过期失败不清空新列表或记录错误', async () => {
  const f = fixture(), db = database(1), gate = deferred();
  db.getAllMediaProgress = () => gate.promise;
  await start(f, db);
  assert.equal(f.model.isLoading, false);
  db.getAllMediaProgress = async () => progress(1);
  await f.model.loadContinueWatching();
  gate.reject(new Error('旧进度失败'));
  // 明确排空 fire-and-forget 的 catch 微任务。
  await Promise.resolve(); await Promise.resolve();
  assert.equal(f.model.continueWatchingList[0].videoId, 1);
  assert.equal(f.errors.length, 0);
});
test('继续观看当前失败保留列表与进度映射，后续可重试', async () => {
  const f = fixture(), db = database(1);
  db.getAllMediaProgress = async () => progress(1);
  await start(f, db);
  const previous = snapshot(f.model);
  db.getAllMediaProgress = async () => { throw new Error('进度失败'); };
  await f.model.loadContinueWatching();
  assert.equal(snapshot(f.model), previous);
  assert.equal(f.errors.length, 1);
  db.getAllMediaProgress = async () => progress(1, 0.5);
  await f.model.loadContinueWatching();
  assert.equal(f.model.getMovieProgress('1'), 0.5);
});
for (const kind of ['episode', 'series']) {
  for (const query of ['getTvSeriesByProviderId', 'getTvEpisode']) {
    test(`${kind} 的 ${query} 晚到，列表及电影进度必须一起丢弃`, async () => {
      const f = fixture(), db = database(1), gate = deferred(), entered = deferred();
      await start(f, db);
      f.model.recentlyAdded.push({ ...db.item, id: 10, mediaType: 'episode',
        tvSeriesId: 10, seasonNumber: 1, episodeNumber: 1 });
      db.getAllMediaProgress = async () => [...progress(1, 0.3), {
        ...progress(1)[0], mediaKey: kind === 'episode'
          ? 'media_progress_episode_tmdb_10_s1_e1' : 'media_progress_series_tmdb_10',
        seasonNumber: 1, episodeNumber: 1
      }];
      for (const name of ['getTvSeriesByProviderId', 'getTvEpisode']) {
        db[name] = async () => {
          if (query === name) { entered.resolve(); await gate.promise; }
          return { id: 10, title: '剧集' };
        };
      }
      const old = f.model.loadContinueWatching();
      await entered.promise;
      assert.equal(f.model.getMovieProgress('1'), 0);
      db.getAllMediaProgress = async () => progress(1, 0.6);
      await f.model.loadContinueWatching();
      gate.resolve(); await old;
      assert.equal(f.model.continueWatchingList.length, 1);
      assert.equal(f.model.getMovieProgress('1'), 0.6);
    });
  }
}
