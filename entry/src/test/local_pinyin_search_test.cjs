// Executes production ArkTS query/write/migration code against real SQLite (Node >= 22.13).
// TYPESCRIPT_PATH may point to DevEco's installed TypeScript module.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const { DatabaseSync } = require('node:sqlite');
const root = path.resolve(__dirname, '../../..');
const ts = require(process.env.TYPESCRIPT_PATH || 'typescript');
require.extensions['.ets'] = (module, filename) => module._compile(ts.transpileModule(
  fs.readFileSync(filename, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2021 } }).outputText, filename);
class Predicates {
  constructor(table) { this.table = table; }
  equalTo(column, value) { this.column = column; this.value = value; return this; }
}
const originalLoad = Module._load;
Module._load = function(request, parent, main) {
  if (request === 'pinyin-pro') return originalLoad.call(this, path.join(root, 'oh_modules/pinyin-pro/dist/index.js'), parent, main);
  if (request === '@ohos.data.relationalStore') return { default: { RdbPredicates: Predicates } };
  if (request === '@kit.BasicServicesKit') return { emitter: { emit() {} } };
  if (request === '@kit.PerformanceAnalysisKit') return { hilog: { error() {} } };
  return originalLoad.call(this, request, parent, main);
};
const source = name => require(path.join(root, 'entry/src/main/ets', name));
const { toPinyinFull, toPinyinInitials, toPinyinSegments, normalizeSearchText } = source('utils/PinyinUtil.ets');
const { FileSourceDbCore } = source('db/files/FileSourceDbCore.ets');
const { MediaContentDao } = source('db/files/MediaContentDao.ets');
const { MediaQueryDao } = source('db/files/MediaQueryDao.ets');

class Store {
  constructor() { this.db = new DatabaseSync(':memory:'); this.calls = []; this.openCursors = 0; }
  async executeSql(sql, params = []) { this.calls.push(sql); this.db.prepare(sql).run(...params); }
  async querySql(sql, params = []) {
    this.calls.push(sql);
    const stmt = this.db.prepare(sql);
    const columns = stmt.columns().map(c => c.name);
    const rows = stmt.all(...params);
    let index = -1;
    this.openCursors++;
    const value = col => rows[index][columns[col]];
    return { rowCount: rows.length, goToNextRow: () => ++index < rows.length,
      goToFirstRow: () => { index = 0; return rows.length > 0; },
      getColumnIndex: name => columns.indexOf(name), isColumnNull: col => value(col) == null,
      getString: col => value(col), getLong: col => value(col), getDouble: col => value(col),
      close: () => { this.openCursors--; } };
  }
  async insert(table, bucket) {
    const columns = Object.keys(bucket);
    return Number(this.db.prepare(`INSERT INTO ${table} (${columns}) VALUES (${columns.map(() => '?')})`)
      .run(...Object.values(bucket)).lastInsertRowid);
  }
  async update(bucket, pred) {
    return Number(this.db.prepare(`UPDATE ${pred.table} SET ${Object.keys(bucket).map(c => `${c} = ?`)} WHERE ${pred.column} = ?`)
      .run(...Object.values(bucket), pred.value).changes);
  }
}

async function main() {
  assert.equal(toPinyinInitials('重庆森林'), 'cqsl');
  assert.equal(toPinyinInitials('长安三万里'), 'caswl');
  assert.equal(toPinyinInitials('音乐之声'), 'yyzs');
  assert.equal(toPinyinInitials('阿Q正传'), 'aqzz');
  assert.equal(toPinyinFull('重庆森林'), 'chongqingsenlin');
  assert.equal(toPinyinFull('长津湖'), 'changjinhu');
  assert.equal(toPinyinFull('音乐之声'), 'yinyuezhisheng');
  assert.equal(normalizeSearchText(' ＣＨÓＮＧ-QING '), 'chongqing');
  for (const input of ['lǜ', 'lü', 'lu:', 'ｌｖ']) assert.equal(normalizeSearchText(input), 'lv');
  assert.equal(toPinyinFull('绿皮书'), 'lvpishu');
  assert.equal(toPinyinFull('lu:皮书'), 'lvpishu');
  assert.ok(toPinyinSegments('重庆森林').includes('|senlin|'));
  assert.ok(!toPinyinSegments('重庆森林').includes('|ong'));
  assert.ok(toPinyinSegments('人'.repeat(1000)).length <= 64 * 257 + 1);
  const store = new Store();
  const core = new FileSourceDbCore();
  core.rdbStore = store;
  await core.onCreate(store);
  await store.executeSql("INSERT INTO file_sources (id, name, type, config_json, created_at) VALUES (1, 'Local', 'webdav', '{}', 1)");
  const content = new MediaContentDao(core);
  const query = new MediaQueryDao(core);
  let nextId = 0;
  async function add(title, type = 'movie', rating = 5, originalTitle) {
    const id = ++nextId;
    const entity = { provider: 'tmdb', providerId: String(id), title, rating, originalTitle,
      scrapedAt: 1, genresJson: '["剧情"]', releaseDate: '2020-01-01', firstAirDate: '2020-01-01' };
    const mediaId = type === 'movie' ? await content.upsertMovie(entity) : await content.upsertTvSeries(entity);
    await store.executeSql('INSERT INTO videos (id, source_id, directory_path, file_path, file_name, scanned_at) VALUES (?, 1, ?, ?, ?, 1)',
      [id, '/', `/${id}.mkv`, `${title}.mkv`]);
    await store.executeSql(`INSERT INTO scrape_info (video_id, provider, provider_id, title, scraped_at, media_type, ${type === 'movie' ? 'movie_id' : 'tv_series_id'}) VALUES (?, 'tmdb', ?, ?, 1, ?, ?)`,
      [id, String(id), title, type, mediaId]);
    return { mediaId, entity };
  }
  const fixtures = ['重庆森林', '长安三万里', '长津湖', '音乐之声', '绿皮书', '少年派的奇幻漂流',
    '阿Q正传', '重启之极海听雷', '楚乔传', '重庆', '森林', '挪威的森林', '虫情森林',
    '爱', '爱在黎明破晓前', '100% Love', '1000 Love', 'A_B', 'AXB', 'Back\\Slash', "O'Connor"];
  for (const title of fixtures) await add(title);
  await add('庆余年', 'tv');
  await add('庆余年第二季', 'tv');
  await add('千与千寻', 'movie', 9, 'Spirited Away');
  const titles = async (kw, options) => (await query.searchMediaItems(kw, options, true)).map(i => i.title);
  const includes = async (kw, wanted) => assert.ok((await titles(kw)).includes(wanted), `${kw} should match ${wanted}`);
  const excludes = async (kw, unwanted) => assert.ok(!(await titles(kw)).includes(unwanted), `${kw} must not match ${unwanted}`);
  for (const [kw, title] of [
    ['重 庆', '重庆森林'], ['长安·三万里', '长安三万里'], ['重庆', '重庆森林'], ['chongqing', '重庆森林'], ['ＣＨÓＮＧ ＱＩＮＧ', '重庆森林'],
    ['cqsl', '重庆森林'], ['cq', '重庆森林'], ['senlin', '重庆森林'],
    ['changjinhu', '长津湖'], ['cjh', '长津湖'], ['caswl', '长安三万里'],
    ['yinyue', '音乐之声'], ['yyzs', '音乐之声'], ['lǜ pi shu', '绿皮书'], ['lu: pi shu', '绿皮书'],
    ['奇幻piaoliu', '少年派的奇幻漂流'], ['重庆senlin', '重庆森林'], ['chongqing森林', '重庆森林'],
    ['重庆sl', '重庆森林'], ['aqzz', '阿Q正传'], ['qyn', '庆余年'], ['Spirited', '千与千寻'],
    ['Ｓｐｉｒｉｔｅｄ', '千与千寻'], ['100%', '100% Love'], ['A_B', 'A_B'], ['Back\\', 'Back\\Slash'], ["O'Connor", "O'Connor"]
  ]) await includes(kw, title);
  for (const [kw, title] of [['c', '重庆森林'], ['qsl', '重庆森林'], ['ongqing', '重庆森林'],
    ['重庆', '虫情森林'], ['重庆senlin', '虫情森林'], ['100%', '1000 Love'],
    ['A_B', 'AXB'], ["' OR 1=1 --", '重庆森林'], ['\\', '重庆森林']]) await excludes(kw, title);
  assert.deepEqual((await titles('森林')).slice(0, 1), ['森林']);
  assert.equal((await titles('重庆'))[0], '重庆');
  assert.deepEqual(await titles('qyn', { mediaType: 'tv' }), ['庆余年', '庆余年第二季']);
  assert.deepEqual(await titles('qyn', { mediaType: 'movie' }), []);
  assert.equal((await titles('cq', { limit: 1 })).length, 1);
  assert.equal((await titles('senlin'))[0], '森林');
  assert.deepEqual((await titles('cqsl')).slice(0, 2), ['虫情森林', '重庆森林']);
  assert.ok((await titles('cqsl', { sortBy: 'title' })).includes('重庆森林'));
  assert.ok((await titles('cqsl', { sortBy: 'year' })).includes('重庆森林'));
  assert.deepEqual(await titles('cqsl'), await titles('cqsl'));

  assert.deepEqual(await titles('cq', { minRating: 10 }), []);
  // All four production insertion/update paths keep search indexes in sync.
  for (const type of ['movie', 'tv']) {
    const { mediaId, entity } = await add('旧片名', type);
    entity.title = '重庆森林新篇';
    if (type === 'movie') await content.upsertMovie(entity); else await content.upsertTvSeries(entity);
    const row = store.db.prepare(`SELECT * FROM ${type === 'movie' ? 'movies' : 'tv_series'} WHERE id = ?`).get(mediaId);
    assert.equal(row.title_initials, 'cqslxp');
    assert.ok(row.title_pinyin_segments.includes('|senlinxinpian|'));
  }
  assert.equal(store.openCursors, 0);
  // Upgrade a v12 database, backfill > one batch, and prove restart does no writes.
  const legacy = new Store();
  legacy.db.exec('CREATE TABLE movies (id INTEGER PRIMARY KEY, title TEXT, title_pinyin TEXT, title_initials TEXT); CREATE TABLE tv_series (id INTEGER PRIMARY KEY, title TEXT, title_pinyin TEXT, title_initials TEXT)');
  for (let id = 1; id <= 205; id++) legacy.db.prepare('INSERT INTO movies VALUES (?, ?, ?, ?)').run(id, '重庆森林', 'chongqingsenlin', 'chqsl');
  legacy.db.exec("INSERT INTO tv_series VALUES (1, '长安三万里', '', '')");
  await core.onUpgrade(legacy, 12, 13);
  await core.backfillPinyinFields(legacy);
  assert.equal(legacy.db.prepare("SELECT COUNT(*) n FROM movies WHERE title_initials = 'cqsl' AND title_pinyin_segments IS NOT NULL").get().n, 205);
  assert.equal(legacy.db.prepare('SELECT title_initials FROM tv_series').get().title_initials, 'caswl');
  legacy.calls = [];
  await core.backfillPinyinFields(legacy);
  assert.equal(legacy.calls.filter(sql => sql.startsWith('UPDATE')).length, 0);
  assert.equal(legacy.openCursors, 0);
  await core.onUpgrade(legacy, 12, 13); // Idempotent schema recovery after interruption.
  // Failed backfill is surfaced, retains NULL on unfinished rows, and resumes next time.
  await legacy.executeSql('UPDATE movies SET title_pinyin_segments = NULL');
  const execute = legacy.executeSql.bind(legacy);
  let writes = 0;
  legacy.executeSql = async (sql, params) => {
    if (sql.startsWith('UPDATE') && ++writes === 102) throw new Error('simulated interruption');
    return execute(sql, params);
  };
  await assert.rejects(core.backfillPinyinFields(legacy), /simulated interruption/);
  assert.equal(legacy.openCursors, 0);
  legacy.executeSql = execute;
  await core.backfillPinyinFields(legacy);
  assert.equal(legacy.db.prepare('SELECT COUNT(*) n FROM movies WHERE title_pinyin_segments IS NULL').get().n, 0);
  const missing = new Store();
  await core.onUpgrade(missing, 12, 13);
  assert.ok(missing.db.prepare('PRAGMA table_info(movies)').all().some(c => c.name === 'title_pinyin_segments'));
  if (process.argv.includes('--benchmark')) {
    const oldLog = console.info;
    console.info = () => {};
    store.db.exec('BEGIN');
    const start = performance.now();
    for (let i = 0; i < 10000; i++) await add(`测试电影${i}重庆森林`);
    store.db.exec('COMMIT');
    const indexingMs = performance.now() - start;
    const timings = [];
    for (const kw of ['重庆', 'chongqing', 'cqsl', 'ceshi', '森林', 'missing']) {
      const before = performance.now();
      await titles(kw);
      timings.push({ keyword: kw, ms: Math.round(performance.now() - before) });
    }
    console.info = oldLog;
    console.log(JSON.stringify({ syntheticRows: 10000, indexingMs: Math.round(indexingMs), timings }));
  }
  console.log('Local pinyin: utility, real SQLite search/ranking, insert/update, v12 migration and restart checks passed.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
