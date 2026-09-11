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
async function verifyHistoryCreationFailures(ensure = FileSourceDbCore.prototype.ensureScopedSearchHistory) {
  const migrationDb = new DatabaseSync(':memory:');
  const legacyRows = () => migrationDb.prepare('SELECT keyword, searched_at FROM search_history ORDER BY keyword').all();
  const scopedExists = () => migrationDb.prepare("SELECT COUNT(*) AS count FROM sqlite_master WHERE type = 'table' AND name = ?")
    .get(constants.TABLE_SCOPED_SEARCH_HISTORY).count;
  let failAfterWrite = false;
  let attempts = 0;
  const migrationStore = {
    executeSql: async (sql, args = []) => {
      attempts++;
      const result = migrationDb.prepare(sql).run(...args);
      if (failAfterWrite) throw new Error('injected acknowledgement failure');
      return result;
    }
  };
  try {
    migrationDb.exec("CREATE TABLE search_history (keyword TEXT UNIQUE, searched_at INTEGER); " +
      "INSERT INTO search_history VALUES ('legacy', 1), ('旧历史', 42), ('same keyword', 99)");
    const original = legacyRows();
    // SQLite itself rejects the DDL; the test does not add a transaction absent in production.
    migrationDb.exec('PRAGMA query_only = ON');
    await assert.rejects(() => ensure(migrationStore), /readonly/i);
    assert.equal(attempts, 1);
    assert.equal(scopedExists(), 0, 'failed DDL must not leave a partial source table');
    assert.deepEqual(legacyRows(), original, 'failed DDL must preserve every legacy row');
    migrationDb.exec('PRAGMA query_only = OFF');
    failAfterWrite = true;
    await assert.rejects(() => ensure(migrationStore), /injected acknowledgement failure/);
    assert.equal(scopedExists(), 1, 'DDL completed before its acknowledgement failed');
    assert.deepEqual(legacyRows(), original);
    assert.equal(migrationDb.prepare(`SELECT COUNT(*) AS count FROM ${constants.TABLE_SCOPED_SEARCH_HISTORY}`).get().count, 0,
      'unattributed legacy history must not enter source history');
    migrationDb.prepare(`INSERT INTO ${constants.TABLE_SCOPED_SEARCH_HISTORY} (scope_key, keyword, searched_at) VALUES (?, ?, ?)`)
      .run(local.key, 'retry sentinel', 123);
    failAfterWrite = false;
    await ensure(migrationStore);
    await ensure(migrationStore);
    assert.equal(attempts, 4, 'both recovery attempts must execute the production DDL');
    assert.deepEqual(legacyRows(), original, 'retries must preserve legacy timestamps and keywords');
    const scoped = migrationDb.prepare(`SELECT scope_key, keyword, searched_at FROM ${constants.TABLE_SCOPED_SEARCH_HISTORY}`).all();
    assert.deepEqual(scoped.map(row => [row.scope_key, row.keyword, row.searched_at]), [[local.key, 'retry sentinel', 123]],
      'retries must neither duplicate nor remove existing source history');
    assert.throws(() => migrationDb.prepare(`INSERT INTO ${constants.TABLE_SCOPED_SEARCH_HISTORY} (scope_key, keyword, searched_at) VALUES (?, ?, ?)`)
      .run(local.key, 'retry sentinel', 456), /UNIQUE constraint failed/);
  } finally {
    migrationDb.close();
  }
}
async function main() {
  await verifyHistoryCreationFailures();
  // Negative control: swallowing migration failures must fail the same assertions.
  await assert.rejects(() => verifyHistoryCreationFailures(async store => {
    try { await FileSourceDbCore.prototype.ensureScopedSearchHistory(store); } catch {}
  }), /Missing expected rejection/);
  console.log('通过: 真实 SQLite DDL 失败、写入后应答失败、旧历史保留及幂等重试；吞错负例被拒绝');
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
  console.log('通过: 数据库升级、排除旧历史、来源隔离、按来源裁剪/插入更新/删除/清空及 SQL 参数绑定');
  const items = [{ title: 'Dune' }, { title: 'dune' }, { title: '' }, { title: '流浪地球' }];
  assert.equal(titleSuggestions(local, items).join(','), 'Dune,流浪地球');
  assert.equal(titleSuggestions(local, Array.from({length: 20}, (_, i) => ({title: `title${i}`}))).length, 20);
  for (const scope of [jelly, plex, {kind: 'unavailable'}]) assert.equal(titleSuggestions(scope, items).length, 0);
  assert.ok(searchInputExample(jelly).includes('不代表已收录'));
  assert.ok(searchInputExample(local).includes('lldq'));
  assert.equal(searchInputExample({kind: 'unavailable'}), '');
  console.log('通过: 当前来源片名补全、稳定排序、去重及准确的输入示例');

  // Execute the real page's non-render methods; native UI/IO are substituted.
  const pageSource = read('pages/search/SearchWorkspacePage.ets');
  const start = pageSource.indexOf('struct SearchWorkspacePage {');
  const end = pageSource.indexOf('  @Builder', start);
  const body = pageSource.slice(start, end).replace('struct SearchWorkspacePage', 'export class Page')
    .replace(/@Consumer\([^)]*\)\s*/g, '').replace(/@Local\s*/g, '') +
    pageSource.slice(pageSource.indexOf('  private focusResults()'),
      pageSource.indexOf('  @Builder', pageSource.indexOf('  private focusResults()'))) + '}';
  class Empty {}
  const { SearchSession } = compile(read('services/search/SearchSession.ets').replace(/@ObservedV2\s*/g, '').replace(/@Trace\s*/g, ''));
  const { Page } = compile(body, {}, { NavPathStack: Empty, SearchSession, titleSuggestions,
    KeyType: { Down: 0, Up: 1 }, KeyCode: { KEYCODE_DPAD_UP: 19, KEYCODE_DPAD_DOWN: 20 },
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
  assert.equal(writes.map(w => w[0]).join(','), [jelly,plex].map(s => s.key).join(','));
  assert.equal(searches.join(','), 'local,server,server');
  console.log('通过: 忽略迟到的历史响应，建议词提交保持在当前来源');

  const preview = new Page();
  preview.pageActive = true; preview.scope = local; preview.searchText = 'H';
  preview.serverSession = { invalidate() {} };
  let displayed = [];
  preview.resultSource = { replace(items) { displayed = items; } };
  const calls = [], history = [];
  const first = { id: 1, movieId: 1, title: '花开锦绣' };
  const second = { id: 2, movieId: 2, title: '花儿与少年' };
  preview.db = {
    searchMediaItems: async kw => { calls.push(kw); return kw === 'H' ? [first, second] : kw === first.title ? [first] : [second]; },
    upsertSearchHistory: async (...args) => history.push(args), getSearchHistory: async () => []
  };
  preview.updateResultSource = () => preview.resultSource.replace(preview.session.results);
  await preview.executeSearch();
  assert.equal(calls.join(','), `H,${first.title}`);
  assert.equal(preview.searchText, 'H');
  assert.equal(preview.suggestions.join(','), `${first.title},${second.title}`);
  assert.equal(preview.selectedSuggestion, first.title);
  assert.equal(preview.session.results[0].title, first.title);
  assert.equal(history.length, 1, 'automatic first suggestion must write history');
  assert.equal(history[0].join(','), `${local.key},${first.title}`);
  const settle = async () => { for (let i = 0; i < 15; i++) await Promise.resolve(); };
  preview.selectSuggestion(second.title); await settle();
  assert.equal(preview.searchText, 'H');
  assert.equal(preview.suggestions.length, 2);
  assert.equal(preview.session.results[0].title, second.title);
  assert.equal(history[1].join(','), `${local.key},${second.title}`);
  preview.executeSearchWithHistory(); await settle();
  assert.equal(history[2][1], second.title, 'submit confirms selected title, not initials');
  // Submit before debounce resolves: write only the accepted title, never raw initials.
  preview.selectedSuggestion = ''; preview.suggestions = []; preview.searchText = 'HKJX';
  const beforeImmediate = history.length;
  preview.db.searchMediaItems = async () => [first];
  preview.scheduleSearch(); preview.executeSearchWithHistory(); await settle();
  assert.equal(history.length, beforeImmediate + 1);
  assert.equal(history.at(-1)[1], first.title);
  assert.ok(!history.some(row => row[1] === 'HKJX'));
  preview.searchText = 'ZZZ'; preview.selectedSuggestion = ''; preview.suggestions = [];
  preview.db.searchMediaItems = async () => [];
  preview.executeSearchWithHistory(); await settle();
  assert.equal(history.length, beforeImmediate + 1, 'no candidates must not save raw input');
  preview.searchText = 'H'; preview.db.searchMediaItems = async () => [second];
  await preview.executeSearch();
  // A result request must become stale immediately, including inside debounce.
  let resolveOld;
  preview.suggestions = [first.title, second.title];
  preview.db.searchMediaItems = () => new Promise(resolve => { resolveOld = resolve; });
  preview.selectSuggestion(first.title);
  preview.searchText = 'HX'; preview.scheduleSearch();
  assert.equal(preview.suggestions.length, 0);
  assert.equal(preview.selectedSuggestion, '');
  assert.equal(preview.session.status, 'refreshing');
  assert.equal(displayed[0].title, second.title, 'keep the last displayed grid during debounce');
  resolveOld([first]); await settle();
  assert.equal(preview.session.results[0].title, second.title, 'stale response cannot replace retained results');
  assert.equal(displayed[0].title, second.title);
  preview.searchText = ''; preview.scheduleSearch();
  assert.equal(displayed.length, 0, 'empty input clears the grid');
  assert.equal(preview.session.results.length, 0);
  preview.searchText = 'HX';
  // Candidate completion after clear must not launch a second query.
  const writesBeforeStale = history.length;
  const pending = preview.executeSearch();
  preview.searchText = ''; preview.invalidateSearch(true);
  resolveOld([first, second]); await pending;
  assert.equal(preview.suggestions.length, 0);
  assert.equal(preview.selectedSuggestion, '');
  assert.equal(history.length, writesBeforeStale, 'stale candidates must not write history');
  // Empty, errors, and retries are distinct and retain the selected query.
  preview.searchText = 'H'; preview.db.searchMediaItems = async () => [];
  await preview.executeSearch();
  assert.equal(preview.session.status, 'empty');
  assert.equal(preview.suggestions.length, 0);
  preview.suggestions = [first.title]; preview.selectedSuggestion = first.title;
  preview.db.searchMediaItems = async () => { throw new Error('failure'); };
  await preview.executeSearch(first.title, false);
  assert.equal(preview.session.status, 'error');
  preview.db.searchMediaItems = async kw => { assert.equal(kw, first.title); return [first]; };
  preview.retrySearch(); await settle();
  assert.equal(preview.session.status, 'results');
  assert.equal(preview.suggestions[0], first.title);
  // Leaving / switching source invalidates both stages, even for A -> B -> A.
  preview.db.searchMediaItems = () => new Promise(resolve => { resolveOld = resolve; });
  const stale = preview.executeSearch();
  preview.invalidateSearch(true); preview.scope = jelly; preview.scope = local;
  resolveOld([first]); await stale;
  assert.equal(preview.suggestions.length, 0);
  assert.equal(preview.session.results.length, 0);
  console.log('通过: 首项自动预览、保留输入与候选、主动选择历史、清空及换源乱序、错误重试');

  // Execute actual navigation methods, not a duplicate focus model.
  const nav = new Page(); nav.pageActive = true; nav.scope = local;
  const focus = [], suggestionScroll = [], historyScroll = [];
  nav.getUIContext = () => ({ getFocusController: () => ({ requestFocus: id => focus.push(id) }) });
  nav.inputController = { stopEditing() {} };
  nav.suggestionScroller = { scrollToIndex: index => suggestionScroll.push(index) };
  nav.historyScroller = { scrollToIndex: index => historyScroll.push(index) };
  nav.resultScroller = { scrollToIndex() {} };
  let resultCount = 6;
  nav.resultSource = { totalCount: () => resultCount };
  nav.suggestions = Array.from({length: 20}, (_, i) => `候选${i}`);
  nav.selectedSuggestion = '候选19';
  let stopped = 0;
  const key = (code, type = 0) => ({ keyCode: code, type, stopPropagation() { stopped++; } });
  for (const id of ['Z', 'X', 'C', 'V', 'B', 'N', 'M', '9', '0', 'backspace']) {
    nav.rememberKeyboardKey(`search-key-${id}`);
    nav.handleKeyboardNavigation(key(20));
    assert.equal(focus.at(-1), 'search-suggestion-19');
    assert.equal(suggestionScroll.at(-1), 19);
    nav.handleWordNavigation(key(19));
    assert.equal(focus.at(-1), `search-key-${id}`);
  }
  const focusCount = focus.length;
  nav.rememberKeyboardKey('search-key-Q'); nav.handleKeyboardNavigation(key(20));
  nav.rememberKeyboardKey('search-key-Z'); nav.handleKeyboardNavigation(key(20, 1));
  assert.equal(focus.length, focusCount, 'upper rows and key-up keep native keyboard navigation');
  nav.handleWordNavigation(key(20));
  assert.equal(focus.at(-1), 'search-workspace-result-0');
  nav.focusWordRow(); assert.equal(focus.at(-1), 'search-suggestion-19');
  nav.suggestions = []; nav.searchText = 'NO MATCH'; nav.historyList = [{keyword:'旧词'}];
  assert.equal(nav.historyVisible(), false);
  nav.focusWordRow(true); assert.equal(focus.at(-1), 'search-workspace-result-0');
  resultCount = 0;
  nav.focusWordRow(true); assert.equal(focus.at(-1), 'search-workspace-input');
  nav.searchText = ''; nav.historyList = Array.from({length:15}, (_, i) => ({keyword:`历史${i}`}));
  nav.focusedHistoryIndex = 0; nav.focusWordRow(true);
  assert.equal(focus.at(-1), 'search-history-clear');
  nav.focusedHistoryIndex = 15; nav.historyList = [{keyword:'剩余词'}]; nav.focusWordRow(true);
  assert.equal(focus.at(-1), 'search-history-0', 'deleted history clamps focus to existing item');
  assert.equal(historyScroll.at(-1), 1);
  nav.scope = jelly; nav.searchText = 'server text'; nav.suggestions = ['stale local'];
  assert.equal(nav.historyVisible(), true);
  nav.focusWordRow(); assert.equal(focus.at(-1), 'search-history-0', 'server never focuses local candidates');
  nav.handleWordNavigation(key(19)); assert.equal(focus.at(-1), 'search-workspace-input');
  nav.invalidateHistorySource(); nav.focusWordRow();
  assert.equal(focus.at(-1), 'search-workspace-input');
  assert.equal(nav.focusedHistoryIndex, 0);
  for (const [width, height] of [[912, 234], [1232, 432], [1872, 720]]) {
    nav.resultViewportWidth = width; nav.resultViewportHeight = height;
    const cardWidth = nav.posterWidth();
    assert.ok(cardWidth * 6 + 96 <= width + 0.001, 'six columns fit available width');
    assert.ok(cardWidth * 1.5 + 76 <= height + 0.001, 'poster, caption, metadata and padding fit first viewport');
  }
  console.log('通过: 键盘底行到候选、20项横向焦点、15条历史和删除回退、服务器隔离及首排几何边界');
}
main().catch(e => { console.error(e); process.exitCode = 1; });
