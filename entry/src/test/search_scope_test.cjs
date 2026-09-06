// 仓库 Hypium 运行器的主机适配层，无需设备或数据库。
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const root = path.resolve(__dirname, '../../..');
// 默认解析项目 TypeScript；允许通过绝对路径使用已有 SDK 中的模块。
const typescriptPath = process.env.TYPESCRIPT_PATH;
if (typescriptPath !== undefined && !path.isAbsolute(typescriptPath)) {
  throw new Error('TYPESCRIPT_PATH 必须为已安装的 TypeScript 模块绝对路径');
}
const ts = require(typescriptPath === undefined ? 'typescript' : typescriptPath);
const hypium = fs.realpathSync(path.join(root, 'oh_modules/@ohos/hypium/src/main'));
const originalJs = require.extensions['.js'];
function compile(module, filename) {
  module._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021,
      experimentalDecorators: true }
  }).outputText, filename);
}
require.extensions['.ets'] = compile;
require.extensions['.js'] = (module, filename) => {
  if (filename.startsWith(hypium)) compile(module, filename);
  else originalJs(module, filename);
};
global.ObservedV2 = (target) => target;
global.Trace = () => {};
const load = Module._load;
Module._load = function (request, parent, main) {
  if (request === '@ohos/hypium') return require(path.join(hypium, 'interface.js'));
  if (request === '@ohos.app.ability.abilityDelegatorRegistry') {
    return { default: { getAbilityDelegator: () => ({ getAppContext: () => ({}) }) } };
  }
  if (request === '@ohos.data.preferences') return {};
  if (request === '@ohos.net.http') return {}; // Search tests stub only the native transport boundary.
  // 仅替换网络与主机数据库边界，执行真实 VideoServerModel 删除、通知与缓存逻辑。
  if (request === '../../db/files/FileSourceDatabase' && parent &&
    parent.filename.endsWith('/stores/servers/VideoServerModel.ets')) {
    return { FileSourceDatabase: { getInstance: () => ({ deleteVideoServer: async () => {}, updateVideoServer: async () => {} }) } };
  }
  return load.call(this, request, parent, main);
};

function extractMethodBody(source, signature) {
  const start = source.indexOf(signature);
  if (start === -1) {
    throw new Error(`未找到方法: ${signature}`);
  }
  const bodyStart = source.indexOf('{', start);
  if (bodyStart === -1) {
    throw new Error(`未找到方法体: ${signature}`);
  }
  let depth = 1;
  let index = bodyStart + 1;
  while (index < source.length && depth > 0) {
    const char = source[index];
    if (char === '{') {
      depth++;
    } else if (char === '}') {
      depth--;
    }
    index++;
  }
  if (depth !== 0) {
    throw new Error(`方法体未闭合: ${signature}`);
  }
  return source.slice(bodyStart + 1, index - 1);
}

function loadMethod(source, signature, params, dependencies, isAsync = false) {
  const body = extractMethodBody(source, signature);
  const factorySource = `${isAsync ? 'async ' : ''}function extracted(${params.join(', ')}) {${body}}`;
  const compiled = ts.transpileModule(factorySource, {
    compilerOptions: { target: ts.ScriptTarget.ES2021 }
  }).outputText;
  return new Function(...Object.keys(dependencies), `${compiled}; return extracted;`)(...Object.values(dependencies));
}

function createDeferred() {
  let resolveValue = () => {};
  let rejectValue = () => {};
  const promise = new Promise((resolve, reject) => {
    resolveValue = resolve;
    rejectValue = reject;
  });
  return { promise, resolve: resolveValue, reject: rejectValue };
}

async function flushMicrotasks() {
  await Promise.resolve();
  await new Promise((resolve) => setImmediate(resolve));
}

function installFakeTimers() {
  const originalSetTimeout = global.setTimeout;
  const originalClearTimeout = global.clearTimeout;
  let nextId = 1;
  const tasks = new Map();
  global.setTimeout = (callback, _delay) => {
    const id = nextId++;
    tasks.set(id, callback);
    return id;
  };
  global.clearTimeout = (id) => {
    tasks.delete(id);
  };
  return {
    pendingCount() { return tasks.size; },
    runNext() {
      const next = tasks.entries().next();
      if (next.done) {
        throw new Error('没有待执行的定时器');
      }
      const [id, callback] = next.value;
      tasks.delete(id);
      callback();
    },
    restore() {
      global.setTimeout = originalSetTimeout;
      global.clearTimeout = originalClearTimeout;
    }
  };
}

async function runHostIntegrationChecks() {
  // 静态接入检查补充纯模型与真实页面方法回归，不执行 ArkUI。
  const assert = require('node:assert/strict');
  const workspace = 'entry/src/main/ets/pages/search/SearchWorkspacePage.ets';
  const results = 'entry/src/main/ets/pages/search/MediaResultPage.ets';
  const workspacePath = path.join(root, workspace);
  const resultPath = path.join(root, results);
  const workspaceSource = fs.readFileSync(workspacePath, 'utf8');
  const resultSource = fs.readFileSync(resultPath, 'utf8');
  const { createLocalSearchScope, resolveSearchScope, getSearchCapabilities } =
    require(path.join(root, 'entry/src/main/ets/models/search/SearchScope.ets'));
  const { SearchWorkspaceSession } = require(path.join(root,
    'entry/src/main/ets/services/search/SearchWorkspaceSession.ets'));
  const { VideoServerSearchService } = require(path.join(root,
    'entry/src/main/ets/services/search/VideoServerSearchService.ets'));

  function checkGuard(file, method, capability) {
    const source = fs.readFileSync(path.join(root, file), 'utf8');
    const start = source.indexOf(method);
    assert.notEqual(start, -1, method);
    const body = source.slice(source.indexOf('{', start) + 1).trimStart();
    assert.ok(body.startsWith(`if (!getSearchCapabilities(this.scope).${capability}`), method);
  }

  for (const method of ['private loadHistory()', 'private deleteHistory(', 'private clearAllHistory()',
    'private executeSearchWithHistory()']) checkGuard(workspace, method, 'localHistory');
  checkGuard(workspace, 'private async executeSearch()', 'localSearch');
  checkGuard(workspace, 'private navigateToDetail(', 'localDetail');
  checkGuard(results, 'private async doSearch()', 'localSearch');
  checkGuard(results, 'private async loadGenreOptions()', 'localSearch');
  checkGuard(results, 'private navigateToDetail()', 'localDetail');
  for (const file of [workspace, results]) {
    const source = fs.readFileSync(path.join(root, file), 'utf8');
    assert.ok(source.includes('resolveSearchRoute(param, SourceSwitchModel.getState().getSearchScope(servers), servers)'));
    assert.ok(source.includes('searchScope: this.scope'));
  }
  assert.ok(workspaceSource.includes('private historyLoadGeneration: number = 0;'));
  assert.ok(workspaceSource.includes('private historySourceGeneration: number = 0;'));
  assert.ok(workspaceSource.includes('private invalidateHistorySource(): void'));
  assert.ok(workspaceSource.includes('TextInput({ text: this.searchText'));
  assert.ok(workspaceSource.includes('subscribeSearchSource(() => this.refreshSource())'));
  assert.ok(workspaceSource.includes('subscribeSearchConfiguration(() => this.refreshSource())'));
  assert.ok(workspaceSource.includes('.onWillHide(() => { this.leaveSearch(); })'));
  const preview = workspaceSource.slice(workspaceSource.indexOf('  buildServerResults()'),
    workspaceSource.indexOf('  build() \n    NavDestination()'));
  assert.ok(!preview.includes('onClick') && !preview.includes('navigateToDetail'));
  assert.ok(preview.includes('.focusable(false)'));
  const resetBody = resultSource.match(/private resetAll\(\): void \{([\s\S]*?)\n  \}/)[1];
  const reset = new Function(ts.transpileModule(`function reset() {${resetBody}}`, {
    compilerOptions: { target: ts.ScriptTarget.ES2021 }
  }).outputText + '; return reset;')();
  for (const [rating, year] of [[8, '1990'], [0, '']]) {
    const state = {
      initialMediaType: 'movie', initialGenre: '剧情', initialPageTitle: '入口',
      initialRating: rating, initialYearLabel: year,
      filterRating: 9, filterYearLabel: '2020',
      doSearch() { this.searched = true; return Promise.resolve(); }
    };
    reset.call(state);
    assert.equal(state.filterRating, rating);
    assert.equal(state.filterYearLabel, year);
    assert.equal(state.filterMediaType, 'movie');
    assert.equal(state.filterGenre, '剧情');
    assert.equal(state.pageTitle, '入口');
    assert.equal(state.searched, true);
  }
  for (const field of ['Rating', 'YearLabel']) {
    assert.ok(resultSource.includes(`this.initial${field} = this.filter${field};`));
  }
  const sourceModel = fs.readFileSync(path.join(root,
    'entry/src/main/ets/stores/media/SourceSwitchModel.ets'), 'utf8');
  assert.match(sourceModel, /@Trace\s+private sourceLoaded: boolean/);

  const localScope = createLocalSearchScope();
  const localDbSlot = { current: null };
  const fileSourceDatabase = { FileSourceDatabase: { getInstance: () => localDbSlot.current } };
  const methodDeps = { getSearchCapabilities, FileSourceDatabase: fileSourceDatabase.FileSourceDatabase };
  const methods = {
    invalidateSearch: loadMethod(workspaceSource, 'private invalidateSearch(): void', [], {}),
    invalidateHistoryRequests: loadMethod(workspaceSource, 'private invalidateHistoryRequests(): void', [], {}),
    invalidateHistorySource: loadMethod(workspaceSource, 'private invalidateHistorySource(): void', [], {}),
    loadHistory: loadMethod(workspaceSource, 'private loadHistory(): void', [], { getSearchCapabilities }),
    scheduleSearch: loadMethod(workspaceSource, 'private scheduleSearch(): void', [], { getSearchCapabilities }),
    executeServerSearch: loadMethod(workspaceSource, 'private executeServerSearch(): void', [], {}),
    appendChar: loadMethod(workspaceSource, 'private appendChar(c: string): void', ['c'], {}),
    clearSearch: loadMethod(workspaceSource, 'private clearSearch(): void', [], {}),
    leaveSearch: loadMethod(workspaceSource, 'private leaveSearch(): void', [], {}),
    refreshSource: loadMethod(workspaceSource, 'private refreshSource(): void', [], methodDeps)
  };

  function createServerContext(id) {
    const server = { id, name: `Server ${id}`, type: 'jellyfin', configJson: '{}', createdAt: 1 };
    return { scope: resolveSearchScope({ kind: 'videoServer', serverId: id }, [server]), server };
  }

  function createPageHarness(scope, db) {
    const page = {
      scope,
      db,
      pageActive: true,
      searchText: '',
      searchResults: [],
      historyList: [],
      isSearching: false,
      serverResult: null,
      searchDebounceTimer: -1,
      searchGeneration: 0,
      historyLoadGeneration: 0,
      historySourceGeneration: 0,
      unsubscribeSource() {},
      unsubscribeConfiguration() {},
      executeSearchCalls: 0,
      executeSearch() { this.executeSearchCalls++; },
      currentContext() { return { scope: this.scope }; },
      serverSession: {
        invalidations: 0,
        disposals: 0,
        searches: [],
        invalidate() { this.invalidations++; },
        dispose() { this.disposals++; },
        search(keyword, current, publish) {
          this.searches.push({ keyword, current, publish });
          return Promise.resolve();
        }
      }
    };
    page.invalidateSearch = methods.invalidateSearch;
    page.invalidateHistoryRequests = methods.invalidateHistoryRequests;
    page.invalidateHistorySource = methods.invalidateHistorySource;
    page.loadHistory = methods.loadHistory;
    page.scheduleSearch = methods.scheduleSearch;
    page.executeServerSearch = methods.executeServerSearch;
    page.appendChar = methods.appendChar;
    page.clearSearch = methods.clearSearch;
    page.leaveSearch = methods.leaveSearch;
    page.refreshSource = methods.refreshSource;
    return page;
  }

  {
    const timers = installFakeTimers();
    try {
      const deferred = createDeferred();
      const page = createPageHarness(localScope, {
        getSearchHistory() { return deferred.promise; }
      });
      page.loadHistory();
      page.appendChar('A');
      deferred.resolve([{ keyword: '已有历史', updatedAt: 1 }]);
      await flushMicrotasks();
      assert.equal(page.historyList.length, 1);
      assert.equal(page.historyList[0].keyword, '已有历史');
      page.clearSearch();
      assert.equal(page.historyList.length, 1);
      assert.equal(page.searchDebounceTimer, -1);
    } finally {
      timers.restore();
    }
  }

  {
    const deferred = createDeferred();
    const page = createPageHarness(localScope, {
      getSearchHistory() { return deferred.promise; }
    });
    page.loadHistory();
    page.leaveSearch();
    deferred.resolve([{ keyword: '过期历史', updatedAt: 1 }]);
    await flushMicrotasks();
    assert.equal(page.historyList.length, 0);
    assert.equal(page.serverSession.disposals, 1);
  }

  {
    const deferred = createDeferred();
    const page = createPageHarness(localScope, {
      getSearchHistory() { return deferred.promise; }
    });
    const serverContext = createServerContext(9);
    page.currentContext = () => serverContext;
    page.loadHistory();
    localDbSlot.current = page.db;
    page.refreshSource();
    deferred.resolve([{ keyword: '旧本地历史', updatedAt: 1 }]);
    await flushMicrotasks();
    assert.equal(page.scope.key, serverContext.scope.key);
    assert.equal(page.historyList.length, 0);
    assert.equal(page.db, null);
  }

  {
    const timers = installFakeTimers();
    try {
      const page = createPageHarness(createServerContext(1).scope, null);
      page.currentContext = () => createServerContext(1);
      page.appendChar('f');
      assert.equal(page.serverSession.invalidations, 1);
      assert.equal(timers.pendingCount(), 1);
      timers.runNext();
      await flushMicrotasks();
      assert.equal(page.serverSession.invalidations, 2);
      assert.equal(page.serverSession.searches.length, 1);
      assert.equal(page.serverSession.searches[0].keyword, 'f');
      page.appendChar('i');
      assert.equal(page.serverSession.invalidations, 3);
      assert.equal(page.serverSession.searches.length, 1);
      assert.equal(timers.pendingCount(), 1);
      page.clearSearch();
      assert.equal(page.serverSession.invalidations, 4);
      assert.equal(page.isSearching, false);
      assert.equal(timers.pendingCount(), 0);
    } finally {
      timers.restore();
    }
  }

  {
    const session = new SearchWorkspaceSession();
    const service = new VideoServerSearchService();
    const current = createServerContext(7);
    const states = [];
    const deferred = createDeferred();
    service.search = () => deferred.promise;
    const task = session.search('film', () => current, (result) => { states.push(result.status); }, service);
    session.invalidate();
    deferred.reject(new Error('network'));
    await task;
    assert.deepEqual(states, ['loading']);
  }

  console.log('静态路由/副作用/输入/生命周期守卫、4 项真实页面回归、1 项真实 reject 隔离与 2 项真实重置方法回归：通过');
}

function registerAndExecuteCore() {
  const Core = require(path.join(hypium, 'core.js')).default;
  const core = Core.getInstance();
  core.init();
  require(path.join(root, 'entry/src/test/SearchScope.test.ets')).default();
  if (process.argv.includes('--server-search')) {
    require(path.join(root, 'entry/src/test/VideoServerSearch.test.ets')).default();
    require(path.join(root, 'entry/src/test/SearchWorkspaceSession.test.ets')).default();
  }
  if (process.argv.includes('--integration')) {
    require(path.join(root, 'entry/src/test/SourceSwitchModel.test.ets')).default();
    require('./search_scope_deletion_test.cjs')();
  }
  core.registerEvent('task', {
    id: 'host-result', taskStart() {},
    taskDone() {
      const summary = core.getDefaultService('suite').getSummary();
      console.log(JSON.stringify(summary));
      process.exitCode = summary.failure || summary.error || summary.total === 0 ? 1 : 0;
    }
  });
  core.execute();
}

if (process.argv.includes('--integration')) {
  runHostIntegrationChecks()
    .then(() => { registerAndExecuteCore(); })
    .catch((error) => {
      console.error(error);
      process.exitCode = 1;
    });
} else {
  registerAndExecuteCore();
}
