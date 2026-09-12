// 主机 SQLite 适配器：执行真实 DAO/解析器和生产建表 SQL，不模拟查询结果。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const { DatabaseSync } = require('node:sqlite');
const ts = require(process.env.TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../main/ets');
const baseline = 'b57ad6d7fbc588d38229fb5f9d48250a88170755';
function source(file, old = false) {
  return old ? execFileSync('git', ['show', `${baseline}:entry/src/main/ets/${file}`], { encoding: 'utf8' })
    : fs.readFileSync(path.join(root, file), 'utf8');
}
function load(file, old = false, cache = new Map()) {
  if (cache.has(file)) return cache.get(file);
  const exports = {};
  cache.set(file, exports);
  const code = ts.transpileModule(source(file, old), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
  } }).outputText;
  vm.runInNewContext(code, { exports, console: { info() {}, error() {}, warn() {} }, require(name) {
    if (name === '@ohos.data.relationalStore') return {};
    if (name === '@kit.PerformanceAnalysisKit') return { hilog: { error() {} } };
    if (name.endsWith('/PinyinUtil')) return {
      normalizeSearchText: s => s.toLowerCase(), toPinyinFull: s => s, toPinyinInitials: s => s
    };
    if (name.startsWith('.')) return load(path.posix.join(path.posix.dirname(file), name) + '.ets', old, cache);
    throw new Error(`未适配依赖 ${name}`);
  } }, { filename: file });
  return exports;
}
class Rows {
  constructor(rows) { this.rows = rows; this.index = -1; this.columns = Object.keys(rows[0] || {}); }
  goToNextRow() { return ++this.index < this.rows.length; }
  goToFirstRow() { this.index = 0; return this.rows.length > 0; }
  getColumnIndex(name) { return this.columns.indexOf(name); }
  value(col) { return this.rows[this.index][this.columns[col]]; }
  isColumnNull(col) { return this.value(col) == null; }
  getLong(col) { return Number(this.value(col)); }
  getDouble(col) { return Number(this.value(col)); }
  getString(col) { return String(this.value(col) ?? ''); }
  close() { this.closed = true; }
}
function fixture(count = 0) {
  const db = new DatabaseSync(':memory:');
  db.exec('PRAGMA foreign_keys=OFF');
  const constants = load('db/files/DbConstants.ets');
  for (const match of source('db/files/FileSourceDbCore.ets').split('  private async createVideoServerTable')[0].matchAll(/CREATE TABLE IF NOT EXISTS \$\{(TABLE_\w+)\} \([\s\S]*?\n\s*\)/g)) {
    if (match[0].includes('`')) continue;
    db.exec(match[0].replace(/\$\{(TABLE_\w+)\}/g, (_, key) => constants[key]));
  }
  // 已有 v9 索引，生产索引而非为基准临时添加。
  db.exec('CREATE INDEX IF NOT EXISTS idx_scrape_info_tvs_ep ON scrape_info(tv_series_id, episode_id)');
  const insert = (table, row) => db.prepare(`INSERT INTO ${table} (${Object.keys(row)}) VALUES (${Object.keys(row).map(() => '?')})`).run(...Object.values(row));
  const ratings = [null, 4.999, 5, 5.999, 6, 6.999, 7, 7.999, 8, 8.999, 9, 9.999, 10];
  function movie(id, rating = ratings[id % ratings.length], movieId = id) {
    const title = `电影${String(movieId).padStart(6, '0')}`;
    if (!db.prepare('SELECT id FROM movies WHERE id=?').get(movieId)) insert('movies', {
      id: movieId, provider: 'tmdb', provider_id: String(movieId), title, title_normalized: title,
      rating, release_date: `${1950 + id % 77}-01-01`, scraped_at: id * 7
    });
    video(id);
    insert('scrape_info', { video_id: id, provider: 'tmdb', provider_id: String(movieId),
      media_type: 'movie', movie_id: movieId, title, scraped_at: id * 7 });
  }
  function video(id) { insert('videos', { id, source_id: 1, directory_path: '/库', file_path: `/库/${id}.mkv`,
    file_name: `${id}.mkv`, scanned_at: id * 3, file_size: 1000000, duration_ms: 1000000 }); }
  function episode(id, seriesId, season, episodeNumber, rating = 8.5) {
    const title = `剧集${seriesId}`;
    if (!db.prepare('SELECT id FROM tv_series WHERE id=?').get(seriesId)) insert('tv_series', {
      id: seriesId, provider: 'tmdb', provider_id: String(seriesId), title, title_normalized: title,
      rating, first_air_date: '2020-01-01', scraped_at: id * 7
    });
    if (!db.prepare('SELECT id FROM tv_seasons WHERE series_id=? AND season_number=?').get(seriesId, season)) insert('tv_seasons', {
      series_id: seriesId, season_number: season, provider: 'tmdb', provider_id: `${seriesId}_${season}`, scraped_at: id * 7
    });
    insert('tv_episodes', { id, series_id: seriesId, provider: 'tmdb', provider_id: String(id),
      season_number: season, episode_number: episodeNumber, title: `第${episodeNumber}集`, scraped_at: id * 7 });
    video(id);
    insert('scrape_info', { video_id: id, provider: 'tmdb', provider_id: String(id), media_type: 'episode',
      tv_series_id: seriesId, episode_id: id, season_number: season, episode_number: episodeNumber, title, scraped_at: id * 7 });
  }
  db.exec('BEGIN');
  for (let id = 1; id <= count; id++) {
    if (id % 10 === 0) video(id);
    else if (id % 10 < 5) movie(id);
    else {
      const n = Math.floor(id / 10) * 5 + id % 10 - 5;
      episode(id, 100000 + Math.floor(n / 20), 1 + Math.floor(n % 20 / 10), 1 + n % 10);
    }
  }
  db.exec('COMMIT');
  const metrics = [];
  const results = [];
  const core = { isReady: () => true, getStore: () => ({ querySql: async (sql, args = []) => {
    const start = performance.now();
    const rows = db.prepare(sql).all(...args);
    metrics.push({ ms: performance.now() - start, rows: rows.length,
      directMediaItems: sql.includes('v.id AS vid') ? rows.length : 0,
      seriesGroups: sql.includes('AS series_id') || sql.includes('AS season_num') ? rows.length : 0 });
    const rs = new Rows(rows); results.push(rs); return rs;
  } }) };
  const VideoDao = load('db/files/VideoDao.ets').VideoDao;
  const Dao = load('db/files/MediaQueryDao.ets').MediaQueryDao;
  const OldDao = load('db/files/MediaQueryDao.ets', true).MediaQueryDao;
  return { db, core, videoDao: new VideoDao(core), dao: new Dao(core), old: new OldDao(core), metrics, results, insert, movie, episode, video };
}
const plain = value => JSON.parse(JSON.stringify(value));
module.exports = { fixture, plain, load, baseline };
