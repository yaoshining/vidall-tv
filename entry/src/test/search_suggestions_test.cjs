// Node >= 22.13; runs production ArkTS storage against real SQLite.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { DatabaseSync } = require('node:sqlite');
const ts = require(process.env.TYPESCRIPT_PATH || 'typescript');
const base = 'entry/src/main/ets/';
function compile(source, deps = {}, globals = {}) {
  const exports = {};
  const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021,
    module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInNewContext(js, { exports, require: name => deps[name] || {}, console, setTimeout, clearTimeout, ...globals });
  return exports;
}
const read = path => fs.readFileSync(base + path, 'utf8');
const constants = compile(read('db/files/DbConstants.ets'));
const { SearchHistoryDao } = compile(read('db/files/SearchHistoryDao.ets'), {
  './DbConstants': constants, '../models/MediaEntity': { SearchHistoryEntry: class {} }
});
const { FileSourceDbCore } = compile(read('db/files/FileSourceDbCore.ets'), { './DbConstants': constants });
const { titleSuggestions, searchInputExample } = compile(read('services/search/SearchSuggestions.ets'));
const { getSearchCapabilities } = compile(read('models/search/SearchScope.ets'));
const local = { kind: 'localFiles', key: 'local-files' };
const jelly = { kind: 'videoServer', key: 'video-server:jellyfin:1' };
const plex = { kind: 'videoServer', key: 'video-server:plex:2' };
const db = new DatabaseSync(':memory:');
let cursors = 0;
const store = {
  executeSql: async (sql, args = []) => db.prepare(sql).run(...args),
  querySql: async (sql, args = []) => {
    const stmt = db.prepare(sql), columns = stmt.columns().map(c => c.name), rows = stmt.all(...args);
    let index = -1; cursors++;
    return { goToNextRow: () => ++index < rows.length, getColumnIndex: name => columns.indexOf(name),
      getString: col => rows[index][columns[col]], getLong: col => rows[index][columns[col]], close: () => cursors-- };
  }
};
async function main() {
  db.exec("CREATE TABLE search_history (keyword TEXT UNIQUE, searched_at INTEGER); INSERT INTO search_history VALUES ('legacy', 1)");
  await FileSourceDbCore.prototype.ensureScopedSearchHistory(store);
  await FileSourceDbCore.prototype.ensureScopedSearchHistory(store);
  const dao = new SearchHistoryDao({ isReady: () => true, getStore: () => store });
  assert.equal((await dao.getSearchHistory(local.key)).length, 0);
  for (const scope of [local, jelly, plex]) await dao.upsertSearchHistory(scope.key, 'Dune');
  for (let i = 0; i < 20; i++) await dao.upsertSearchHistory(local.key, `Local ${i}`);
  assert.equal((await dao.getSearchHistory(local.key)).length, 15);
  for (const scope of [jelly, plex]) assert.equal((await dao.getSearchHistory(scope.key))[0].keyword, 'Dune');
  await dao.upsertSearchHistory(jelly.key, 'Dune');
  assert.equal((await dao.getSearchHistory(jelly.key)).length, 1);
  await dao.deleteSearchHistory(jelly.key, 'Dune');
  assert.equal((await dao.getSearchHistory(jelly.key)).length, 0);
  assert.equal((await dao.getSearchHistory(plex.key)).length, 1);
  await dao.clearSearchHistory(local.key);
  assert.equal((await dao.getSearchHistory(local.key)).length, 0);
  assert.equal((await dao.getSearchHistory(plex.key)).length, 1);
  assert.equal(db.prepare('SELECT keyword FROM search_history').get().keyword, 'legacy');
  await dao.upsertSearchHistory(plex.key, "O'Brien ? %");
  assert.equal((await dao.getSearchHistory(plex.key)).length, 2);
  assert.equal(cursors, 0);
  console.log('PASS schema upgrade, legacy exclusion, scope isolation, per-scope pruning/upsert/delete/clear, bound SQL');
  const items = [{ title: 'Dune' }, { title: 'dune' }, { title: '' }, { title: '流浪地球' }];
  assert.equal(titleSuggestions(local, items).join(','), 'Dune,流浪地球');
  assert.equal(titleSuggestions(local, Array.from({length: 20}, (_, i) => ({title: `title${i}`}))).length, 6);
  for (const scope of [jelly, plex, {kind: 'unavailable'}]) assert.equal(titleSuggestions(scope, items).length, 0);
  assert.ok(searchInputExample(jelly).includes('不代表已收录'));
  assert.ok(searchInputExample(local).includes('lldq'));
  assert.equal(searchInputExample({kind: 'unavailable'}), '');
  console.log('PASS source-specific title completion, stable ranking, deduplication and honest input examples');

  // Execute the real page's non-render methods; native UI/IO are substituted.
  const pageSource = read('pages/search/SearchWorkspacePage.ets');
  const start = pageSource.indexOf('struct SearchWorkspacePage {');
  const end = pageSource.indexOf('  @Builder', start);
  const body = pageSource.slice(start, end).replace('struct SearchWorkspacePage', 'export class Page')
    .replace(/@Consumer\([^)]*\)\s*/g, '').replace(/@Local\s*/g, '') + '}';
  class Empty {}
  const { Page } = compile(body, {}, { NavPathStack: Empty, SearchSession: Empty,
    SearchResultSource: Empty, Scroller: Empty, SearchWorkspaceSession: Empty, TextInputController: Empty,
    createUnavailableSearchScope: () => ({kind:'unavailable'}), getSearchCapabilities });
  const page = new Page();
  page.pageActive = true; page.scope = local;
  let finish;
  page.db = { getSearchHistory: () => new Promise(resolve => { finish = resolve; }) };
  page.loadHistory();
  page.invalidateHistorySource(); page.scope = jelly;
  finish([{keyword:'local secret'}]); await Promise.resolve();
  assert.equal(page.historyList.length, 0);
  const writes = [], searches = [];
  page.db = { upsertSearchHistory: async (...args) => writes.push(args), getSearchHistory: async () => [] };
  page.invalidateSearch = () => {};
  page.executeSearch = () => searches.push('local');
  page.executeServerSearch = () => searches.push('server');
  for (const scope of [local, jelly, plex]) {
    page.scope = scope; page.searchText = 'Dune'; page.executeSearchWithHistory();
  }
  assert.equal(writes.map(w => w[0]).join(','), [local,jelly,plex].map(s => s.key).join(','));
  assert.equal(searches.join(','), 'local,server,server');
  console.log('PASS late history suppression and suggestion submission stays in current source');
}
main().catch(e => { console.error(e); process.exitCode = 1; });
