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
const detailRegistryDatabase = {
  whenReady: async () => {},
  update: async () => {},
  delete: async () => {},
  getAll: async () => []
};
const load = Module._load;
Module._load = function (request, parent, main) {
  if (request === '@ohos/hypium') {
    // 补齐真实 Hypium 的边界替身导出，避免加载依赖设备运行时的包入口。
    return { ...require(path.join(hypium, 'interface.js')),
      ...require(path.join(hypium, 'module/mock/MockKit.js')),
      ArgumentMatchers: require(path.join(hypium, 'module/mock/ArgumentMatchers.js')).default };
  }
  if (request === '@ohos.app.ability.abilityDelegatorRegistry') {
    return { default: { getAbilityDelegator: () => ({ getAppContext: () => ({}) }) } };
  }
  if (request === '@ohos.data.preferences') return {};
  if (request === '@ohos.net.http') return {}; // Search tests stub only the native transport boundary.
  // 仅替换网络与主机数据库边界，执行真实 VideoServerModel 删除、通知与缓存逻辑。
  if (request === '../../db/files/FileSourceDatabase' && parent &&
    parent.filename.endsWith('/stores/servers/VideoServerModel.ets')) {
    return { FileSourceDatabase: {
      whenDatabaseReady: () => detailRegistryDatabase.whenReady(),
      getInstance: () => ({
        deleteVideoServer: () => detailRegistryDatabase.delete(),
        updateVideoServer: () => detailRegistryDatabase.update(),
        getAllVideoServers: () => detailRegistryDatabase.getAll()
      })
    } };
  }
  return load.call(this, request, parent, main);
};

const { SearchSession } = require(path.join(root, 'entry/src/main/ets/services/search/SearchSession.ets'));
const { SearchResultSource } = require(path.join(root, 'entry/src/main/ets/pages/search/SearchResultSource.ets'));
function attachLocalSession(page) {
  page.session = new SearchSession();
  page.resultSource = new SearchResultSource();
  page.suggestions = [];
  page.selectedSuggestion = '';
  page.focusedResult = 0;
  page.restoreResult = false;
  page.resultScroller = { scrollToIndex() {} };
  Object.defineProperty(page, 'searchResults', { get: () => page.session.results });
  Object.defineProperty(page, 'localStatus', {
    get: () => page.session.status === 'results' ? 'success' : page.session.status
  });
}

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
    tasks.set(id, { callback, delay: _delay });
    return id;
  };
  global.clearTimeout = (id) => {
    tasks.delete(id);
  };
  return {
    pendingCount() { return [...tasks.values()].filter(task => (task.delay === 800 || task.delay === 250)).length; },
    runNext() {
      const next = tasks.entries().next();
      if (next.done) {
        throw new Error('没有待执行的定时器');
      }
      const [id, task] = next.value;
      tasks.delete(id);
      task.callback();
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
  const detailPage = 'entry/src/main/ets/pages/detail/ServerMediaDetailPage.ets';
  const workspacePath = path.join(root, workspace);
  const resultPath = path.join(root, results);
  const workspaceSource = fs.readFileSync(workspacePath, 'utf8');
  const resultSource = fs.readFileSync(resultPath, 'utf8');
  // 结果区不再添加多余的焦点跳转按钮，保留首行向上返回输入的路径。
  assert.doesNotMatch(workspaceSource, /Button\('(浏览结果|返回输入)'\)/);
  assert.match(workspaceSource, /KEYCODE_DPAD_UP && index < 6\) \{\s*this\.focusWordRow\(\)/);
  const detailPageSource = fs.readFileSync(path.join(root, detailPage), 'utf8');
  const adapterSource = fs.readFileSync(path.join(root,
    'entry/src/main/ets/pages/search/SearchResultSource.ets'), 'utf8');
  // 主机不运行 ArkUI，静态护栏确保首次挂载条件具有可观察的数量依赖。
  assert.match(adapterSource, /@ObservedV2\s+export class SearchResultSource/);
  assert.match(adapterSource, /@Trace private count: number/);
  assert.match(adapterSource, /totalCount\(\): number \{ return this\.count; \}/);
  const adapter = new SearchResultSource();
  assert.equal(adapter.totalCount(), 0);
  adapter.replace([{ id: 'local' }]);
  assert.equal(adapter.totalCount(), 1);
  let reloads = 0;
  const listener = { onDataReloaded() {
    reloads += 1;
    assert.equal(adapter.totalCount(), expectedCount);
  } };
  let expectedCount = 1;
  adapter.registerDataChangeListener(listener);
  adapter.replace([{ id: 'server' }]);
  assert.equal(adapter.getData(0).id, 'server');
  expectedCount = 0;
  adapter.replace([]);
  assert.equal(adapter.totalCount(), 0);
  assert.equal(reloads, 2);
  adapter.unregisterDataChangeListener(listener);
  adapter.replace([{ id: 'retry' }]);
  assert.equal(adapter.totalCount(), 1);
  assert.equal(reloads, 2);

  const { createLocalSearchScope, resolveSearchScope, getSearchCapabilities } =
    require(path.join(root, 'entry/src/main/ets/models/search/SearchScope.ets'));
  const { VideoServerType } = require(path.join(root, 'entry/src/main/ets/db/models/VideoServerEntity.ets'));
  const { SearchWorkspaceSession } = require(path.join(root,
    'entry/src/main/ets/services/search/SearchWorkspaceSession.ets'));
  const { VideoServerSearchService, VideoServerSearchSourceSnapshot } = require(path.join(root,
    'entry/src/main/ets/services/search/VideoServerSearchService.ets'));

  function checkGuard(file, method, capability) {
    const source = fs.readFileSync(path.join(root, file), 'utf8');
    const start = source.indexOf(method);
    assert.notEqual(start, -1, method);
    const body = source.slice(source.indexOf('{', start) + 1).trimStart();
    assert.ok(body.startsWith(`if (!getSearchCapabilities(this.scope).${capability}`), method);
  }

  function checkHistoryGuard(source, method, operation) {
    const body = extractMethodBody(source, method).trimStart();
    assert.match(body, /^if \(this\.scope\.kind === 'unavailable'(?: \|\| this\.db === null| \|\| !this\.pageActive)?\) \{ return; \}/, method);
    assert.ok(body.includes(`this.db.${operation}(this.scope.key${operation === 'clearSearchHistory' ? ')' : ','}`), `${method}: current scope history`);
  }
  for (const [method, operation] of [
    ['private loadHistory()', 'getSearchHistory'],
    ['private deleteHistory(', 'deleteSearchHistory'],
    ['private clearAllHistory()', 'clearSearchHistory'],
    ['private saveSearchHistory(', 'upsertSearchHistory']
  ]) {
    checkHistoryGuard(workspaceSource, method, operation);
    for (const key of ["'local-files'", "'video-server:jellyfin:999'"]) {
      const mutant = workspaceSource.replace(`this.db.${operation}(this.scope.key`, `this.db.${operation}(${key}`);
      assert.notEqual(mutant, workspaceSource);
      assert.throws(() => checkHistoryGuard(mutant, method, operation), assert.AssertionError);
    }
    const body = extractMethodBody(workspaceSource, method);
    const mutant = workspaceSource.replace(body, body.replace("this.scope.kind === 'unavailable'", 'false'));
    assert.throws(() => checkHistoryGuard(mutant, method, operation), assert.AssertionError);
  }
  checkGuard(workspace, 'private async executeSearch(', 'localSearch');
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
  const preview = workspaceSource.slice(workspaceSource.indexOf('  buildResultList()'),
    workspaceSource.indexOf('  build() \n    NavDestination()'));
  assert.ok(preview.includes('WorkspacePosterCard'));
  assert.ok(preview.includes('this.openResult(item);'));
  assert.ok(!preview.includes('focusable(false)'));
  assert.ok(!preview.includes('暂不支持打开详情'));
  assert.ok(workspaceSource.includes('mediaId: item.selection.mediaId'));
  assert.ok(workspaceSource.includes('mediaType: item.selection.mediaType'));
  assert.ok(workspaceSource.includes('itemId: item.selection.detailItemId'));
  assert.ok(workspaceSource.includes('item.sourceSnapshot.matches(context.scope, context.server)'));
  assert.ok(detailPageSource.includes("Text('重试')"));
  assert.ok(detailPageSource.includes('.defaultFocus(true)'));
  assert.ok(detailPageSource.includes('.focusable(true)'));
  assert.ok(detailPageSource.includes('.onClick(() => { this.retryDetail() })'));
  assert.ok(detailPageSource.includes('private detailRequestActive: boolean = false'));
  assert.ok(detailPageSource.includes('private playOperationGeneration: number = 0'));
  assert.ok(detailPageSource.includes('private playOperationActive: boolean = false'));
  assert.ok(detailPageSource.includes('subscribeSearchConfiguration(() => this.handleDetailConfigurationChange())'));
  assert.ok(detailPageSource.includes('subscribeSearchSource(() => this.handleDetailSourceChange())'));
  assert.ok(detailPageSource.includes('private unsubscribeDetailGuards(): void'));
  assert.ok(detailPageSource.includes('this.leaveDetailPage()'));
  assert.ok(detailPageSource.includes('aboutToAppear(): void'));
  assert.ok(detailPageSource.includes('aboutToDisappear(): void'));
  assert.ok(detailPageSource.includes("this.invalidateDetailState('', false)"));
  assert.ok(detailPageSource.includes('.onHidden(() => { this.handleDetailHidden() })'));
  assert.ok(detailPageSource.includes('.onShown(() => { this.handleDetailShown() })'));
  const playBody = extractMethodBody(detailPageSource, 'private async play(): Promise<void>');
  assert.ok(playBody.indexOf('const server = this.resolvePlayableServer()') <
    playBody.indexOf('const target = this.playTarget()'));
  assert.ok(playBody.includes('const playGeneration = this.beginPlayOperation()'));
  assert.ok(playBody.includes('if (!this.isActivePlayOperation(playGeneration, identity)) {'));
  assert.ok(playBody.includes('this.finishPlayOperation(playGeneration, identity)'));
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
    invalidateSearch: loadMethod(workspaceSource, 'private invalidateSearch(', ['clear = false'], {}),
    invalidateHistoryRequests: loadMethod(workspaceSource, 'private invalidateHistoryRequests(): void', [], {}),
    invalidateHistorySource: loadMethod(workspaceSource, 'private invalidateHistorySource(): void', [], {}),
    loadHistory: loadMethod(workspaceSource, 'private loadHistory(): void', [], { getSearchCapabilities }),
    scheduleSearch: loadMethod(workspaceSource, 'private scheduleSearch(): void', [], { getSearchCapabilities }),
    executeServerSearch: loadMethod(workspaceSource, 'private executeServerSearch(): void', [], {}),
    openServerResultDetail: loadMethod(workspaceSource, 'private openServerResultDetail(item: VideoServerSearchItem): void',
      ['item'], { ServerMediaDetailPage: { PAGE_NAME: 'serverMediaDetail' } }),
    appendChar: loadMethod(workspaceSource, 'private appendChar(c: string): void', ['c'], {}),
    clearSearch: loadMethod(workspaceSource, 'private clearSearch(): void', [], {}),
    leaveSearch: loadMethod(workspaceSource, 'private leaveSearch(): void', [], {}),
    refreshSource: loadMethod(workspaceSource, 'private refreshSource(): void', [], methodDeps)
  };
  const detailClientState = {
    buildContext: async () => null,
    jellyfinClient: null,
    plexClient: null
  };
  const detailSourceModel = {
    activeSource: { kind: 'fileSource' },
    listeners: new Set(),
    subscribeSearchSource(listener) {
      this.listeners.add(listener);
      return () => { this.listeners.delete(listener); };
    },
    emitChange() {
      this.listeners.forEach((listener) => listener());
    }
  };
  const rawDetailMethods = {
    clearLoadedDetail: loadMethod(detailPageSource, 'private clearLoadedDetail(): void', [], {}),
    captureServerIdentity: loadMethod(detailPageSource,
      'private captureServerIdentity(server: VideoServer): ServerMediaDetailServerIdentity',
      ['server'], {}),
    matchesServerIdentity: loadMethod(detailPageSource,
      'private matchesServerIdentity(identity: ServerMediaDetailServerIdentity): boolean',
      ['identity'], {}),
    shouldTrackSearchSource: loadMethod(detailPageSource, 'private shouldTrackSearchSource(): boolean', [], {}),
    matchesCurrentSearchSource: loadMethod(detailPageSource, 'private matchesCurrentSearchSource(): boolean', [], {
      SourceSwitchModel: { getState: () => detailSourceModel }
    }),
    detailInvalidationMessage: loadMethod(detailPageSource,
      'private detailInvalidationMessage(identity: ServerMediaDetailServerIdentity | null = null): string',
      ['identity'], {
        SourceSwitchModel: { getState: () => detailSourceModel }
      }),
    beginDetailRequest: loadMethod(detailPageSource, 'private beginDetailRequest(silent: boolean): number',
      ['silent'], {}),
    isActiveDetailRequest: loadMethod(detailPageSource,
      'private isActiveDetailRequest(generation: number, identity: ServerMediaDetailServerIdentity | null = null): boolean',
      ['generation', 'identity'], {}),
    bindPendingDetailIdentity: loadMethod(detailPageSource,
      'private bindPendingDetailIdentity(generation: number, server: VideoServer): ServerMediaDetailServerIdentity | null',
      ['generation', 'server'], {}),
    applyLoadedDetail: loadMethod(detailPageSource,
      'private applyLoadedDetail(generation: number, identity: ServerMediaDetailServerIdentity,\n    payload: ServerMediaDetailLoadPayload): void',
      ['generation', 'identity', 'payload'], {}),
    applyDetailFailure: loadMethod(detailPageSource,
      'private applyDetailFailure(generation: number, message: string,\n    identity: ServerMediaDetailServerIdentity | null = null): void',
      ['generation', 'message', 'identity'], {}),
    finishDetailRequest: loadMethod(detailPageSource,
      'private finishDetailRequest(generation: number, identity: ServerMediaDetailServerIdentity | null = null): void',
      ['generation', 'identity'], {}),
    invalidateDetailState: loadMethod(detailPageSource,
      'private invalidateDetailState(message: string, clearState: boolean = true): void',
      ['message', 'clearState'], {}),
    handleDetailSourceChange: loadMethod(detailPageSource, 'private handleDetailSourceChange(): void', [], {}),
    handleDetailConfigurationChange: loadMethod(detailPageSource, 'private handleDetailConfigurationChange(): void', [], {}),
    subscribeDetailGuards: loadMethod(detailPageSource, 'private subscribeDetailGuards(): void', [], {
      SourceSwitchModel: { getState: () => detailSourceModel }
    }),
    unsubscribeDetailGuards: loadMethod(detailPageSource, 'private unsubscribeDetailGuards(): void', [], {}),
    leaveDetailPage: loadMethod(detailPageSource, 'private leaveDetailPage(): void', [], {}),
    resolvePlayableServer: loadMethod(detailPageSource, 'private resolvePlayableServer(): VideoServer | null', [], {}),
    beginPlayOperation: loadMethod(detailPageSource, 'private beginPlayOperation(): number', [], {}),
    isActivePlayOperation: loadMethod(detailPageSource,
      'private isActivePlayOperation(generation: number, identity: ServerMediaDetailServerIdentity): boolean',
      ['generation', 'identity'], {}),
    finishPlayOperation: loadMethod(detailPageSource,
      'private finishPlayOperation(generation: number, identity: ServerMediaDetailServerIdentity): void',
      ['generation', 'identity'], {}),
    retryDetail: loadMethod(detailPageSource, 'private retryDetail(): void', [], {}),
    isSeries: loadMethod(detailPageSource, 'private isSeries(): boolean', [], {}),
    playTarget: loadMethod(detailPageSource, 'private playTarget(): VideoServerMediaItem | null', [], {}),
    getTitle: loadMethod(detailPageSource, 'private getTitle(): string', [], {}),
    aboutToAppear: loadMethod(detailPageSource, 'aboutToAppear(): void', [], {}),
    handleDetailHidden: loadMethod(detailPageSource, 'private handleDetailHidden(): void', [], {}),
    handleDetailShown: loadMethod(detailPageSource, 'private handleDetailShown(): void', [], {}),
    getSeasonLabel: loadMethod(detailPageSource, 'private getSeasonLabel(s: VideoServerSeason): string', ['s'], {}),
    openSeason: loadMethod(detailPageSource, 'private openSeason(s: VideoServerSeason): void', ['s'], {
      ServerSeasonDetailPage: { PAGE_NAME: 'season' }
    }),
    openPerson: loadMethod(detailPageSource, 'private openPerson(c: DetailCastMember): void', ['c'], {
      ServerPersonDetailPage: { PAGE_NAME: 'person' }
    }),
    aboutToDisappear: loadMethod(detailPageSource, 'aboutToDisappear(): void', [], {}),
    loadDetail: loadMethod(detailPageSource, 'private async loadDetail(silent: boolean = false): Promise<void>',
      ['silent'], {
        VideoServerType,
        JellyfinClient: { fromConfigJson: () => detailClientState.jellyfinClient },
        PlexClient: { fromConfigJson: () => detailClientState.plexClient }
      }, true),
    play: loadMethod(detailPageSource, 'private async play(): Promise<void>', [], {
      VideoServerType,
      PlayerPage: { PAGE_NAME: 'player' },
      reportServerPlaybackStarted: () => Promise.resolve(),
      buildServerEpisodePlaybackContext: (...args) => detailClientState.buildContext(...args),
      JellyfinClient: { fromConfigJson: () => detailClientState.jellyfinClient },
      PlexClient: { fromConfigJson: () => detailClientState.plexClient }
    }, true)
  };
  const detailMethods = {
    ...rawDetailMethods,
    detailInvalidationMessage(identity) {
      return rawDetailMethods.detailInvalidationMessage.call(this, identity ?? null);
    },
    isActiveDetailRequest(generation, identity) {
      return rawDetailMethods.isActiveDetailRequest.call(this, generation, identity ?? null);
    },
    applyDetailFailure(generation, message, identity) {
      return rawDetailMethods.applyDetailFailure.call(this, generation, message, identity ?? null);
    },
    finishDetailRequest(generation, identity) {
      return rawDetailMethods.finishDetailRequest.call(this, generation, identity ?? null);
    },
    invalidateDetailState(message, clearState) {
      return rawDetailMethods.invalidateDetailState.call(this, message, clearState ?? true);
    }
  };

  function createDetailMedia(type) {
    return {
      id: `${type}-1`,
      title: `${type} title`,
      type,
      backdropUrl: '',
      posterUrl: '',
      progress: 0,
      positionMs: 0,
      durationMs: 0,
      subtitle: '',
      seriesId: type === 'episode' ? 'series-1' : '',
      seasonNumber: 0,
      episodeNumber: 0,
      lastPlayedDate: 0
    };
  }

  function createDetailPayload(type) {
    return {
      media: createDetailMedia(type),
      overview: `${type} overview`,
      rating: 0,
      year: 2024,
      people: []
    };
  }

  function createSeason(id) {
    return { id, title: id, posterUrl: '', indexNumber: 1, episodeCount: 1 };
  }

  function createDetailPageHarness(server, expectedServerType = server?.type ?? '') {
    detailSourceModel.activeSource = {
      kind: 'videoServer',
      serverId: server?.id,
      serverType: server?.type,
      name: server?.name
    };
    detailSourceModel.listeners = new Set();
    const page = {
      serverId: server?.id ?? 0,
      itemId: 'series-1',
      fallbackTitle: 'fallback',
      sourceMediaId: '',
      sourceMediaType: '',
      expectedServerType,
      videoServerModel: {
        server,
        listeners: new Set(),
        loadCalls: 0,
        async loadVideoServers() { this.loadCalls++; },
        searchConfigurationRevision: 0,
        subscribeSearchConfigurationRevision() { return () => {}; },
        subscribeSearchConfiguration(listener) {
          this.listeners.add(listener);
          return () => { this.listeners.delete(listener); };
        },
        emitChange() {
          this.listeners.forEach((listener) => listener());
        },
        getVideoServerById(id) {
          if (this.server !== undefined && this.server !== null && this.server.id === id) {
            return this.server;
          }
          return null;
        }
      },
      detail: createDetailPayload('series'),
      seasons: [createSeason('stale-season')],
      nextUp: createDetailMedia('episode'),
      error: 'stale error',
      isLoading: false,
      unsubscribeRequestConfiguration: () => {},
      unsubscribeLifecycleRevision: () => {},
      detailRequestRevision: 0,
      detailLoadGeneration: 0,
      detailRequestActive: false,
      playOperationGeneration: 0,
      playOperationActive: false,
      initialLoadDone: false,
      detailTargetIdentity: null,
      pendingDetailIdentity: null,
      loadedDetailIdentity: null,
      unsubscribeSource() {},
      unsubscribeConfiguration() {},
      pageStack: {
        pushed: [],
        pushPathByName(name, param) {
          this.pushed.push({ name, param });
        }
      },
      toastMessages: [],
      showToastSafe(message) { this.toastMessages.push(message); },
      isPlaying: false
    };
    page.clearLoadedDetail = detailMethods.clearLoadedDetail;
    page.captureServerIdentity = detailMethods.captureServerIdentity;
    page.matchesServerIdentity = detailMethods.matchesServerIdentity;
    page.shouldTrackSearchSource = detailMethods.shouldTrackSearchSource;
    page.matchesCurrentSearchSource = detailMethods.matchesCurrentSearchSource;
    page.detailInvalidationMessage = detailMethods.detailInvalidationMessage;
    page.beginDetailRequest = detailMethods.beginDetailRequest;
    page.isActiveDetailRequest = detailMethods.isActiveDetailRequest;
    page.bindPendingDetailIdentity = detailMethods.bindPendingDetailIdentity;
    page.applyLoadedDetail = detailMethods.applyLoadedDetail;
    page.applyDetailFailure = detailMethods.applyDetailFailure;
    page.finishDetailRequest = detailMethods.finishDetailRequest;
    page.invalidateDetailState = detailMethods.invalidateDetailState;
    page.handleDetailSourceChange = detailMethods.handleDetailSourceChange;
    page.handleDetailConfigurationChange = detailMethods.handleDetailConfigurationChange;
    page.subscribeDetailGuards = detailMethods.subscribeDetailGuards;
    page.unsubscribeDetailGuards = detailMethods.unsubscribeDetailGuards;
    page.leaveDetailPage = detailMethods.leaveDetailPage;
    page.resolvePlayableServer = detailMethods.resolvePlayableServer;
    page.beginPlayOperation = detailMethods.beginPlayOperation;
    page.isActivePlayOperation = detailMethods.isActivePlayOperation;
    page.finishPlayOperation = detailMethods.finishPlayOperation;
    page.retryDetail = detailMethods.retryDetail;
    page.isSeries = detailMethods.isSeries;
    page.playTarget = detailMethods.playTarget;
    page.getTitle = detailMethods.getTitle;
    page.aboutToAppear = detailMethods.aboutToAppear;
    page.aboutToDisappear = detailMethods.aboutToDisappear;
    page.handleDetailHidden = detailMethods.handleDetailHidden;
    page.handleDetailShown = detailMethods.handleDetailShown;
    page.openSeason = detailMethods.openSeason;
    page.openPerson = detailMethods.openPerson;
    page.getSeasonLabel = detailMethods.getSeasonLabel;
    page.loadDetail = detailMethods.loadDetail;
    page.play = detailMethods.play;
    return page;
  }

  function installDetailClient(type, behavior) {
    const client = {
      getItemDetail: behavior.getItemDetail,
      getSeasons: behavior.getSeasons ?? (async () => []),
      getNextUp: behavior.getNextUp ?? (async () => null),
      getStreamUrl: behavior.getStreamUrl ?? (async (id) => `https://stream/${type}/${id}`),
      getStreamHeader: behavior.getStreamHeader ?? (() => ({ Authorization: `Bearer ${type}` }))
    };
    detailClientState.jellyfinClient = client;
    detailClientState.plexClient = client;
  }

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
      refreshSourceCalls: 0,
      toastMessages: [],
      unsubscribeSource() {},
      unsubscribeConfiguration() {},
      showToastSafe(message) { this.toastMessages.push(message); },
      pageStack: {
        pushed: [],
        pushPathByName(name, param) { this.pushed.push({ name, param }); }
      },
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
    attachLocalSession(page);
    page.updateResultSource = () => {};
    page.invalidateSearch = methods.invalidateSearch;
    page.invalidateHistoryRequests = methods.invalidateHistoryRequests;
    page.invalidateHistorySource = methods.invalidateHistorySource;
    page.loadHistory = methods.loadHistory;
    page.scheduleSearch = methods.scheduleSearch;
    page.executeServerSearch = methods.executeServerSearch;
    page.openServerResultDetail = methods.openServerResultDetail;
    page.appendChar = methods.appendChar;
    page.inputController = { stopEditing() {} };
    page.getUIContext = () => ({ getFocusController: () => ({ requestFocus() {} }) });
    page.focusInput = loadMethod(workspaceSource, 'private focusInput()', [], {});
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
        getSearchHistory(scopeKey, limit) {
          assert.equal(scopeKey, localScope.key);
          assert.equal(limit, 20);
          return deferred.promise;
        }
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
      getSearchHistory(scopeKey, limit) {
        assert.equal(scopeKey, localScope.key);
        assert.equal(limit, 20);
        return deferred.promise;
      }
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
    const historyScopes = [];
    const page = createPageHarness(localScope, {
      getSearchHistory(scopeKey, limit) {
        historyScopes.push(scopeKey);
        assert.equal(limit, 20);
        return scopeKey === localScope.key ? deferred.promise : Promise.resolve([]);
      }
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
    assert.equal(page.db, localDbSlot.current);
    assert.deepEqual(historyScopes, [localScope.key, serverContext.scope.key]);
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
    const timers = installFakeTimers();
    try {
      const page = createPageHarness(createServerContext(3).scope, null);
      page.currentContext = () => createServerContext(3);
      page.searchText = 'return-search';
      page.refreshSource();
      assert.equal(page.scope.key, 'video-server:jellyfin:3');
      assert.equal(page.searchResults.length, 0);
      assert.equal(page.db, localDbSlot.current);
      assert.equal(timers.pendingCount(), 1);
    } finally {
      timers.restore();
    }
  }

  {
    const server = { id: 5, name: 'Server 5', type: 'jellyfin', configJson: '{}', createdAt: 1 };
    const scope = resolveSearchScope({ kind: 'videoServer', serverId: 5 }, [server]);
    const page = createPageHarness(scope, null);
    page.currentContext = () => ({ scope, server });
    const item = {
      key: 'video-server:jellyfin:5:episode-5',
      scopeKey: scope.key,
      serverId: 5,
      serverType: 'jellyfin',
      media: {
        id: 'episode-5',
        title: 'Episode 5',
        type: 'episode',
        backdropUrl: '',
        posterUrl: '',
        progress: 0,
        positionMs: 0,
        durationMs: 0,
        subtitle: '',
        seriesId: 'series-5',
        seasonNumber: 1,
        episodeNumber: 5,
        lastPlayedDate: 0
      },
      selection: {
        serverId: 5,
        serverType: 'jellyfin',
        mediaId: 'episode-5',
        mediaType: 'episode',
        detailItemId: 'series-5'
      },
      sourceSnapshot: new VideoServerSearchSourceSnapshot(scope.key, server)
    };
    page.openServerResultDetail(item);
    assert.equal(page.toastMessages.length, 0);
    assert.equal(page.pageStack.pushed.length, 1);
    assert.deepEqual(page.pageStack.pushed[0], {
      name: 'serverMediaDetail',
      param: {
        serverId: 5,
        serverType: 'jellyfin',
        mediaId: 'episode-5',
        mediaType: 'episode',
        itemId: 'series-5',
        title: 'Episode 5'
      }
    });
  }

  {
    const originalServer = { id: 6, name: 'Server 6', type: 'jellyfin', configJson: '{}', createdAt: 1 };
    const scope = resolveSearchScope({ kind: 'videoServer', serverId: 6 }, [originalServer]);
    const page = createPageHarness(scope, null);
    page.currentContext = () => ({
      scope,
      server: { id: 6, name: 'Server 6', type: 'jellyfin', configJson: '{"changed":true}', createdAt: 1 }
    });
    const item = {
      key: 'video-server:jellyfin:6:movie-6',
      scopeKey: scope.key,
      serverId: 6,
      serverType: 'jellyfin',
      media: {
        id: 'movie-6',
        title: 'Movie 6',
        type: 'movie',
        backdropUrl: '',
        posterUrl: '',
        progress: 0,
        positionMs: 0,
        durationMs: 0,
        subtitle: '',
        seriesId: '',
        seasonNumber: 0,
        episodeNumber: 0,
        lastPlayedDate: 0
      },
      selection: {
        serverId: 6,
        serverType: 'jellyfin',
        mediaId: 'movie-6',
        mediaType: 'movie',
        detailItemId: 'movie-6'
      },
      sourceSnapshot: new VideoServerSearchSourceSnapshot(scope.key, originalServer)
    };
    page.refreshSource = function () { this.refreshSourceCalls++; };
    page.openServerResultDetail(item);
    assert.deepEqual(page.toastMessages, ['当前服务器配置已变更，请重新搜索']);
    assert.equal(page.refreshSourceCalls, 1);
    assert.equal(page.pageStack.pushed.length, 0);
  }

  {
    const originalServer = { id: 7, name: 'Server 7', type: 'jellyfin', configJson: '{}', createdAt: 1 };
    const scope = resolveSearchScope({ kind: 'videoServer', serverId: 7 }, [originalServer]);
    const page = createPageHarness(scope, null);
    page.currentContext = () => ({ scope: createLocalSearchScope(), server: undefined });
    const item = {
      key: 'video-server:jellyfin:7:movie-7',
      scopeKey: scope.key,
      serverId: 7,
      serverType: 'jellyfin',
      media: {
        id: 'movie-7',
        title: 'Movie 7',
        type: 'movie',
        backdropUrl: '',
        posterUrl: '',
        progress: 0,
        positionMs: 0,
        durationMs: 0,
        subtitle: '',
        seriesId: '',
        seasonNumber: 0,
        episodeNumber: 0,
        lastPlayedDate: 0
      },
      selection: {
        serverId: 7,
        serverType: 'jellyfin',
        mediaId: 'movie-7',
        mediaType: 'movie',
        detailItemId: 'movie-7'
      },
      sourceSnapshot: new VideoServerSearchSourceSnapshot(scope.key, originalServer)
    };
    page.refreshSource = function () { this.refreshSourceCalls++; };
    page.openServerResultDetail(item);
    assert.deepEqual(page.toastMessages, ['当前来源已变化，请返回重新选择来源']);
    assert.equal(page.refreshSourceCalls, 1);
    assert.equal(page.pageStack.pushed.length, 0);
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

  {
    const page = createDetailPageHarness(null, 'jellyfin');
    installDetailClient('jellyfin', {
      getItemDetail: async () => { throw new Error('不应访问客户端'); }
    });
    await page.loadDetail(false);
    assert.equal(page.error, '服务器不存在');
    assert.equal(page.detail, null);
    assert.deepEqual(page.seasons, []);
    assert.equal(page.nextUp, null);
    assert.equal(page.isLoading, false);
  }

  {
    const page = createDetailPageHarness(null, 'jellyfin');
    page.error = '';
    await page.loadDetail(true);
    assert.equal(page.error, '服务器不存在');
    assert.equal(page.detail, null);
    assert.deepEqual(page.seasons, []);
    assert.equal(page.nextUp, null);
    assert.equal(page.isLoading, false);
  }

  {
    const server = { id: 11, type: 'plex', name: 'Server 11', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    installDetailClient('plex', {
      getItemDetail: async () => { throw new Error('不应访问客户端'); }
    });
    await page.loadDetail(false);
    assert.equal(page.error, '服务器配置已变更，请返回重试');
    assert.equal(page.detail, null);
    assert.deepEqual(page.seasons, []);
    assert.equal(page.nextUp, null);
  }

  {
    const server = { id: 12, type: 'plex', name: 'Server 12', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    page.error = '';
    await page.loadDetail(true);
    assert.equal(page.error, '服务器配置已变更，请返回重试');
    assert.equal(page.detail, null);
    assert.deepEqual(page.seasons, []);
    assert.equal(page.nextUp, null);
  }

  for (const mode of [
    { silent: false, label: 'initial' },
    { silent: true, label: 'silent' }
  ]) {
    for (const failure of [
      { label: '401', message: '鉴权失败，请检查凭据' },
      { label: '403', message: '鉴权失败，请检查凭据' },
      { label: 'timeout', message: '获取详情失败 timeout' }
    ]) {
      const server = { id: 20, type: 'jellyfin', name: 'Server 20', configJson: '{"token":"a"}', createdAt: 1 };
      const page = createDetailPageHarness(server, 'jellyfin');
      page.error = '';
      installDetailClient('jellyfin', {
        getItemDetail: async () => { throw new Error(failure.message); }
      });
      await page.loadDetail(mode.silent);
      assert.equal(page.error, failure.message, `${mode.label}-${failure.label}`);
      assert.equal(page.detail, null, `${mode.label}-${failure.label}`);
      assert.deepEqual(page.seasons, [], `${mode.label}-${failure.label}`);
      assert.equal(page.nextUp, null, `${mode.label}-${failure.label}`);
      assert.equal(page.isLoading, false, `${mode.label}-${failure.label}`);
    }
  }

  {
    const server = { id: 30, type: 'jellyfin', name: 'Server 30', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    installDetailClient('jellyfin', {
      getItemDetail: async () => createDetailPayload('movie')
    });
    await page.loadDetail(true);
    assert.equal(page.error, '');
    assert.equal(page.detail.media.type, 'movie');
    assert.deepEqual(page.seasons, []);
    assert.equal(page.nextUp, null);
  }

  {
    const first = createDeferred();
    const server = { id: 31, type: 'jellyfin', name: 'Server 31', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    let callCount = 0;
    installDetailClient('jellyfin', {
      getItemDetail: async () => {
        callCount++;
        if (callCount === 1) {
          return first.promise;
        }
        throw new Error('鉴权失败，请检查凭据');
      }
    });
    const staleRequest = page.loadDetail(false);
    await flushMicrotasks();
    await page.loadDetail(true);
    first.resolve(createDetailPayload('movie'));
    await staleRequest;
    assert.equal(page.error, '鉴权失败，请检查凭据');
    assert.equal(page.detail, null);
    assert.deepEqual(page.seasons, []);
    assert.equal(page.nextUp, null);
  }

  {
    const first = createDeferred();
    const server = { id: 36, type: 'jellyfin', name: 'Server 36', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    page.sourceMediaId = 'episode-36';
    page.sourceMediaType = 'episode';
    page.aboutToAppear();
    let callCount = 0;
    installDetailClient('jellyfin', {
      getItemDetail: async () => {
        callCount++;
        if (callCount === 1) {
          return first.promise;
        }
        return createDetailPayload('movie');
      }
    });
    const staleRequest = page.loadDetail(false);
    await flushMicrotasks();
    detailSourceModel.activeSource = { kind: 'fileSource' };
    detailSourceModel.emitChange();
    detailSourceModel.activeSource = {
      kind: 'videoServer',
      serverId: server.id,
      serverType: server.type,
      name: server.name
    };
    detailSourceModel.emitChange();
    await page.loadDetail(false);
    first.resolve(createDetailPayload('series'));
    await staleRequest;
    assert.equal(page.error, '');
    assert.equal(page.detail.media.type, 'movie');
    assert.deepEqual(page.seasons, []);
    assert.equal(page.nextUp, null);
    page.aboutToDisappear();
  }

  {
    const first = createDeferred();
    const server = { id: 37, type: 'jellyfin', name: 'Server 37', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    let callCount = 0;
    installDetailClient('jellyfin', {
      getItemDetail: async () => {
        callCount++;
        if (callCount === 1) {
          return first.promise;
        }
        return createDetailPayload('movie');
      }
    });
    const staleRequest = page.loadDetail(false);
    await flushMicrotasks();
    await page.loadDetail(false);
    first.resolve(createDetailPayload('series'));
    await staleRequest;
    assert.equal(page.error, '');
    assert.equal(page.detail.media.type, 'movie');
    assert.deepEqual(page.seasons, []);
    assert.equal(page.nextUp, null);
    assert.equal(page.isLoading, false);
  }

  {
    const first = createDeferred();
    const server = { id: 38, type: 'jellyfin', name: 'Server 38', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    let callCount = 0;
    installDetailClient('jellyfin', {
      getItemDetail: async () => {
        callCount++;
        if (callCount === 1) {
          return first.promise;
        }
        return createDetailPayload('movie');
      }
    });
    const staleRequest = page.loadDetail(false);
    await flushMicrotasks();
    await page.loadDetail(false);
    first.reject(new Error('鉴权失败，请检查凭据'));
    await staleRequest;
    assert.equal(page.error, '');
    assert.equal(page.detail.media.type, 'movie');
    assert.deepEqual(page.seasons, []);
    assert.equal(page.nextUp, null);
    assert.equal(page.isLoading, false);
  }

  for (const scenario of ['leave', 'source-switch', 'same-id-config-change', 'delete']) {
    const first = createDeferred();
    const server = { id: 34, type: 'jellyfin', name: 'Server 34', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    page.sourceMediaId = 'episode-34';
    page.sourceMediaType = 'episode';
    page.subscribeDetailGuards();
    installDetailClient('jellyfin', {
      getItemDetail: async () => first.promise
    });
    const request = page.loadDetail(false);
    await flushMicrotasks();
    if (scenario === 'leave') {
      page.leaveDetailPage();
    } else if (scenario === 'source-switch') {
      detailSourceModel.activeSource = { kind: 'fileSource' };
      detailSourceModel.emitChange();
    } else if (scenario === 'same-id-config-change') {
      page.videoServerModel.server = { ...server, configJson: '{"changed":true}' };
      page.videoServerModel.emitChange();
    } else {
      page.videoServerModel.server = null;
      page.videoServerModel.emitChange();
    }
    first.resolve(createDetailPayload('movie'));
    await request;
    assert.equal(page.detail, null, scenario);
    assert.deepEqual(page.seasons, [], scenario);
    assert.equal(page.nextUp, null, scenario);
    assert.equal(page.isLoading, false, scenario);
    if (scenario === 'leave') {
      assert.equal(page.error, '', scenario);
    } else if (scenario === 'source-switch') {
      assert.equal(page.error, '当前来源已变化，请返回重新选择来源', scenario);
    } else if (scenario === 'delete') {
      assert.equal(page.error, '服务器不存在', scenario);
    } else {
      assert.equal(page.error, '服务器配置已变更，请返回重试', scenario);
    }
  }

  for (const scenario of ['leave', 'source-switch', 'same-id-config-change', 'delete']) {
    const first = createDeferred();
    const server = { id: 35, type: 'jellyfin', name: 'Server 35', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    page.sourceMediaId = 'episode-35';
    page.sourceMediaType = 'episode';
    page.subscribeDetailGuards();
    installDetailClient('jellyfin', {
      getItemDetail: async () => first.promise
    });
    const request = page.loadDetail(false);
    await flushMicrotasks();
    if (scenario === 'leave') {
      page.leaveDetailPage();
    } else if (scenario === 'source-switch') {
      detailSourceModel.activeSource = { kind: 'fileSource' };
      detailSourceModel.emitChange();
    } else if (scenario === 'same-id-config-change') {
      page.videoServerModel.server = { ...server, configJson: '{"changed":true}' };
      page.videoServerModel.emitChange();
    } else {
      page.videoServerModel.server = null;
      page.videoServerModel.emitChange();
    }
    first.reject(new Error('鉴权失败，请检查凭据'));
    await request;
    assert.equal(page.detail, null, `${scenario}-reject`);
    assert.deepEqual(page.seasons, [], `${scenario}-reject`);
    assert.equal(page.nextUp, null, `${scenario}-reject`);
    assert.equal(page.isLoading, false, `${scenario}-reject`);
    if (scenario === 'leave') {
      assert.equal(page.error, '', `${scenario}-reject`);
    } else if (scenario === 'source-switch') {
      assert.equal(page.error, '当前来源已变化，请返回重新选择来源', `${scenario}-reject`);
    } else if (scenario === 'delete') {
      assert.equal(page.error, '服务器不存在', `${scenario}-reject`);
    } else {
      assert.equal(page.error, '服务器配置已变更，请返回重试', `${scenario}-reject`);
    }
  }

  {
    const server = { id: 32, type: 'jellyfin', name: 'Server 32', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    installDetailClient('jellyfin', {
      getItemDetail: async () => { throw new Error('获取详情失败 timeout'); }
    });
    await page.loadDetail(false);
    assert.equal(page.error, '获取详情失败 timeout');
    installDetailClient('jellyfin', {
      getItemDetail: async () => createDetailPayload('movie')
    });
    page.retryDetail();
    await flushMicrotasks();
    assert.equal(page.error, '');
    assert.equal(page.detail.media.type, 'movie');
    assert.deepEqual(page.seasons, []);
    assert.equal(page.nextUp, null);
    assert.equal(page.isLoading, false);
  }

  {
    const first = createDeferred();
    const server = { id: 33, type: 'jellyfin', name: 'Server 33', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    let callCount = 0;
    installDetailClient('jellyfin', {
      getItemDetail: async () => {
        callCount++;
        return first.promise;
      }
    });
    page.error = '鉴权失败，请检查凭据';
    page.retryDetail();
    page.retryDetail();
    await flushMicrotasks();
    assert.equal(callCount, 1);
    assert.equal(page.isLoading, true);
    first.resolve(createDetailPayload('movie'));
    await flushMicrotasks();
    assert.equal(page.error, '');
    assert.equal(page.detail.media.type, 'movie');
    assert.equal(page.isLoading, false);
  }

  {
    const server = { id: 40, type: 'jellyfin', name: 'Server 40', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    page.detail = createDetailPayload('movie');
    page.loadedDetailIdentity = page.captureServerIdentity(server);
    page.videoServerModel.server = { ...server, configJson: '{"changed":true}' };
    const playable = page.resolvePlayableServer();
    assert.equal(playable, null);
    assert.equal(page.error, '服务器配置已变更，请返回重试');
    assert.equal(page.detail, null);
    assert.deepEqual(page.seasons, []);
    assert.equal(page.nextUp, null);
    assert.deepEqual(page.toastMessages, ['服务器配置已变更，请返回重试']);
  }

  {
    const server = { id: 41, type: 'jellyfin', name: 'Server 41', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    page.detail = createDetailPayload('movie');
    page.loadedDetailIdentity = page.captureServerIdentity(server);
    const playable = page.resolvePlayableServer();
    assert.equal(playable.id, 41);
    assert.equal(page.error, 'stale error');
    assert.equal(page.detail.media.type, 'movie');
  }

  {
    const server = { id: 42, type: 'jellyfin', name: 'Server 42', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    page.detail = createDetailPayload('movie');
    page.loadedDetailIdentity = page.captureServerIdentity(server);
    page.aboutToAppear();
    let streamCalls = 0;
    installDetailClient('jellyfin', {
      getItemDetail: async () => createDetailPayload('movie'),
      getStreamUrl: async (id) => {
        streamCalls++;
        return `https://stream/jellyfin/${id}`;
      }
    });
    page.videoServerModel.server = { ...server, configJson: '{"changed":true}' };
    page.videoServerModel.emitChange();
    await page.play();
    assert.equal(streamCalls, 0);
    assert.equal(page.pageStack.pushed.length, 0);
    assert.equal(page.error, '服务器配置已变更，请返回重试');
    assert.equal(page.detail, null);
    assert.deepEqual(page.toastMessages, []);
    page.aboutToDisappear();
  }

  {
    const first = createDeferred();
    const second = createDeferred();
    const server = { id: 44, type: 'jellyfin', name: 'Server 44', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    page.detail = createDetailPayload('movie');
    page.loadedDetailIdentity = page.captureServerIdentity(server);
    page.aboutToAppear();
    let streamCalls = 0;
    installDetailClient('jellyfin', {
      getStreamUrl: async (id) => {
        streamCalls++;
        if (streamCalls === 1) {
          return first.promise;
        }
        return second.promise;
      }
    });
    const stalePlaying = page.play();
    await flushMicrotasks();
    page.videoServerModel.server = { ...server, configJson: '{"changed":true}' };
    page.videoServerModel.emitChange();
    assert.equal(page.isPlaying, false);
    page.videoServerModel.server = { ...server };
    page.detail = createDetailPayload('movie');
    page.loadedDetailIdentity = page.captureServerIdentity(page.videoServerModel.server);
    page.error = '';
    const activePlaying = page.play();
    await flushMicrotasks();
    assert.equal(page.isPlaying, true);
    first.resolve('https://stream/jellyfin/stale');
    await stalePlaying;
    assert.equal(page.pageStack.pushed.length, 0);
    assert.equal(page.isPlaying, true);
    second.resolve('https://stream/jellyfin/fresh');
    await activePlaying;
    assert.equal(page.pageStack.pushed.length, 1);
    assert.equal(page.pageStack.pushed[0].param.url, 'https://stream/jellyfin/fresh');
    assert.equal(page.isPlaying, false);
    page.aboutToDisappear();
  }

  {
    const pending = createDeferred();
    const server = { id: 45, type: 'jellyfin', name: 'Server 45', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    page.detail = createDetailPayload('movie');
    page.loadedDetailIdentity = page.captureServerIdentity(server);
    page.aboutToAppear();
    installDetailClient('jellyfin', {
      getStreamUrl: async () => pending.promise
    });
    const playing = page.play();
    await flushMicrotasks();
    page.aboutToDisappear();
    assert.equal(page.isPlaying, false);
    pending.resolve('https://stream/jellyfin/disappear');
    await playing;
    assert.equal(page.pageStack.pushed.length, 0);
    assert.equal(page.detail.media.type, 'movie');
    assert.equal(page.error, '');
  }

  {
    const pending = createDeferred();
    const server = { id: 46, type: 'jellyfin', name: 'Server 46', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    page.detail = createDetailPayload('movie');
    page.loadedDetailIdentity = page.captureServerIdentity(server);
    page.aboutToAppear();
    installDetailClient('jellyfin', {
      getItemDetail: async () => pending.promise
    });
    page.retryDetail();
    await flushMicrotasks();
    page.aboutToDisappear();
    assert.equal(page.videoServerModel.listeners.size, 0);
    assert.equal(page.isLoading, false);
    pending.resolve(createDetailPayload('series'));
    await flushMicrotasks();
    assert.equal(page.detail.media.type, 'movie');
    assert.equal(page.loadedDetailIdentity, null);
    assert.equal(page.error, '');
  }

  {
    const server = { id: 43, type: 'jellyfin', name: 'Server 43', configJson: '{"token":"a"}', createdAt: 1 };
    const page = createDetailPageHarness(server, 'jellyfin');
    page.sourceMediaId = 'episode-43';
    page.sourceMediaType = 'episode';
    page.aboutToAppear();
    page.aboutToDisappear();
    detailSourceModel.activeSource = { kind: 'fileSource' };
    detailSourceModel.emitChange();
    assert.equal(page.error, '');
    page.aboutToAppear();
    detailSourceModel.emitChange();
    assert.equal(page.error, '当前来源已变化，请返回重新选择来源');
  }

  {
    const server = { id: 59, type: 'jellyfin', name: 'Server', configJson: 'original', createdAt: 1 };
    const page = createDetailPageHarness(server);
    const pending = createDeferred();
    let calls = 0;
    installDetailClient('jellyfin', { getItemDetail: async () => {
      calls++;
      return createDetailPayload('movie');
    } });
    page.videoServerModel.loadVideoServers = () => pending.promise;
    const initial = page.loadDetail(false);
    // Hide before the first onShown: returning must restart the cancelled initial load.
    page.handleDetailHidden();
    pending.resolve();
    await initial;
    assert.equal(calls, 0);
    page.handleDetailShown();
    await flushMicrotasks();
    assert.equal(calls, 1);
    assert.equal(page.isLoading, false);
    page.handleDetailHidden();
    page.videoServerModel.server = { ...server, configJson: 'replacement' };
    page.videoServerModel.emitChange();
    page.handleDetailShown();
    await flushMicrotasks();
    assert.equal(calls, 1, 'show must not reclaim a hidden replacement configuration');
    assert.equal(page.error, '服务器配置已变更，请返回重试');
    page.aboutToDisappear();
  }

  // 在注册表刷新与保留页面边界执行真实生产方法。
  for (const retry of [false, true]) {
    for (const reject of [false, true]) {
      const server = { id: 60, type: 'jellyfin', name: 'Server', configJson: 'original', createdAt: 1 };
      const page = createDetailPageHarness(server);
      page.clearLoadedDetail();
      page.subscribeDetailGuards();
      let mediaCalls = 0;
      installDetailClient('jellyfin', {
        getItemDetail: async () => { mediaCalls++; throw new Error('initial failure'); }
      });
      if (retry) {
        await page.loadDetail(false);
        assert.equal(page.error, 'initial failure');
        assert.equal(page.loadedDetailIdentity, null);
      }
      const pending = createDeferred();
      page.videoServerModel.loadVideoServers = () => pending.promise;
      const request = retry ? (page.retryDetail(), null) : page.loadDetail(false);
      assert.equal(page.pendingDetailIdentity.configuration, 'original');
      page.videoServerModel.server = { ...server, configJson: 'replacement' };
      page.videoServerModel.emitChange();
      assert.equal(page.isLoading, false);
      if (reject) pending.reject(new Error('late registry error'));
      else pending.resolve();
      if (request) await request;
      await flushMicrotasks();
      assert.equal(mediaCalls, retry ? 1 : 0);
      assert.equal(page.error, '服务器配置已变更，请返回重试');
      page.retryDetail();
      await flushMicrotasks();
      assert.equal(mediaCalls, retry ? 1 : 0, '重试不得重新绑定替换后的配置');
      page.aboutToDisappear();
    }
  }

  {
    const page = createDetailPageHarness(null);
    const pending = createDeferred();
    page.videoServerModel.loadVideoServers = () => pending.promise;
    let calls = 0;
    installDetailClient('jellyfin', { getItemDetail: async () => {
      calls++; return createDetailPayload('movie');
    } });
    const request = page.loadDetail(false);
    page.videoServerModel.server = { id: 0, type: 'jellyfin', name: 'warm', configJson: 'warm', createdAt: 1 };
    pending.resolve();
    await request;
    assert.equal(calls, 0);
    assert.equal(page.error, '服务器配置已变更，请返回重试');
    assert.equal(page.detailTargetIdentity, null, '未发布的注册表值不得建立身份');
    assert.equal(page.isLoading, false);
  }

  // 执行真实注册表加载、赋值与通知，仅替换数据库和传输边界。
  const { VideoServerModel } = require(path.join(root,
    'entry/src/main/ets/stores/servers/VideoServerModel.ets'));
  for (const type of ['jellyfin', 'emby', 'plex']) {
    for (const replacement of ['none', 'notified', 'unnotified', 'aba']) {
      const server = { id: 81, type, name: 'cold', configJson: 'cold-original', createdAt: 1 };
      const page = createDetailPageHarness(null, type);
      page.serverId = server.id;
      page.clearLoadedDetail();
      const model = new VideoServerModel();
      page.videoServerModel = model;
      detailRegistryDatabase.getAll = async () => [server];
      let calls = 0;
      installDetailClient(type, { getItemDetail: async () => {
        calls++; return createDetailPayload('movie');
      } });
      page.subscribeDetailGuards();
      const request = page.loadDetail(false);
      page.handleDetailShown();
      // 在冷启动观察者之后注册，在加载完成前的首次发布中修改配置。
      let published = false;
      const unsubscribe = model.subscribeSearchConfiguration(() => {
        if (published) return;
        published = true;
        assert.equal(page.detailTargetIdentity.configuration, 'cold-original');
        if (replacement === 'unnotified') server.configJson = 'replacement';
        else if (replacement !== 'none') {
          model.videoServers = [{ ...server, configJson: 'replacement' }];
          if (replacement === 'aba') model.videoServers = [server];
        }
      });
      await request;
      unsubscribe();
      assert.equal(calls, replacement === 'none' ? 1 : 0);
      assert.equal(page.isLoading, false);
      if (replacement === 'none') {
        assert.ok(page.detail);
        assert.equal(page.error, '');
        page.handleDetailHidden();
        page.handleDetailShown();
        await flushMicrotasks();
        assert.equal(calls, 2, '正常返回保留页面时自动重新加载');
        assert.equal(page.error, '');
      } else {
        assert.equal(page.detail, null);
        assert.equal(page.error, '服务器配置已变更，请返回重试');
        if (replacement !== 'aba') {
          page.retryDetail();
          await flushMicrotasks();
          assert.equal(calls, 0, '重试不得采用替换后的配置');
        }
        const fresh = createDetailPageHarness(model.getVideoServerById(server.id), type);
        fresh.videoServerModel = model;
        detailRegistryDatabase.getAll = async () => model.videoServers;
        await fresh.loadDetail(false);
        assert.equal(calls, 1, '新的合法入口可绑定当前配置');
        assert.equal(fresh.error, '');
        fresh.aboutToDisappear();
      }
      page.aboutToDisappear();
      assert.equal(model.revisionListeners.size, 0);
      assert.equal(model.searchListeners.size, 0, '冷启动观察者也必须释放');
      console.log(`冷入口真实模型/页面方法 ${type}/${replacement}：通过`);
    }
  }
  for (const boundary of ['hidden', 'source']) {
    const server = { id: 90, type: 'jellyfin', name: 'fixture', configJson: 'original', createdAt: 1 };
    const page = createDetailPageHarness(server);
    const model = new VideoServerModel(); page.videoServerModel = model;
    page.sourceMediaId = 'movie'; page.clearLoadedDetail();
    const read = createDeferred(); detailRegistryDatabase.getAll = () => read.promise;
    let calls = 0;
    installDetailClient('jellyfin', { getItemDetail: async () => {
      calls++; return createDetailPayload('movie');
    } });
    page.subscribeDetailGuards();
    const request = page.loadDetail(false);
    await flushMicrotasks();
    if (boundary === 'hidden') page.handleDetailHidden();
    else {
      detailSourceModel.activeSource = { kind: 'fileSource' };
      detailSourceModel.emitChange();
    }
    read.resolve([server]); await request;
    assert.equal(calls, 0); assert.equal(page.detail, null);
    if (boundary === 'hidden') {
      page.handleDetailShown(); await flushMicrotasks();
      assert.equal(calls, 1); assert.equal(page.error, '');
    }
    page.aboutToDisappear();
    assert.equal(model.searchListeners.size, 0);
    assert.equal(model.revisionListeners.size, 0);
    console.log(`真实冷加载 ${boundary} 与清理：通过`);
  }
  for (const settlement of ['read-first', 'write-first']) {
  for (const operation of ['update', 'delete']) {
    for (const fail of [false, true]) {
      const server = { id: 91, type: 'jellyfin', name: 'fixture', configJson: 'original', createdAt: 1 };
      const page = createDetailPageHarness(null, 'jellyfin');
      page.serverId = 91; page.clearLoadedDetail();
      const model = new VideoServerModel(); page.videoServerModel = model;
      const read = createDeferred(), write = createDeferred();
      detailRegistryDatabase.getAll = () => read.promise;
      detailRegistryDatabase[operation] = () => write.promise;
      let calls = 0;
      installDetailClient('jellyfin', { getItemDetail: async () => {
        calls++; return createDetailPayload('movie');
      } });
      page.subscribeDetailGuards();
      const request = page.loadDetail(false);
      await flushMicrotasks();
      const before = model.searchConfigurationRevision;
      const mutation = operation === 'update' ?
        model.updateVideoServer({ ...server, configJson: 'replacement' }) : model.deleteVideoServer(91);
      const settled = mutation.catch(() => {});
      assert.ok(model.searchConfigurationRevision > before, '数据库完成前写入意图已可见');
      assert.equal(page.isLoading, false);
      if (settlement === 'write-first') {
        if (fail) write.reject(new Error('fixture write failure')); else write.resolve();
        await settled;
      }
      read.resolve([server]); await request;
      assert.equal(calls, 0);
      assert.equal(model.videoServers.length, 0, '迟到的初始快照不得恢复目标');
      if (settlement === 'read-first') {
        if (fail) write.reject(new Error('fixture write failure')); else write.resolve();
        await settled;
      }
      assert.equal(model.isLoaded, false);
      detailRegistryDatabase[operation] = async () => {};
      detailRegistryDatabase.getAll = async () => fail ? [server] :
        operation === 'update' ? [{ ...server, configJson: 'replacement' }] : [];
      page.retryDetail(); await flushMicrotasks();
      assert.equal(calls, fail || operation === 'update' ? 1 : 0);
      if (fail) assert.equal(page.error, '', '写入失败允许显式重新重试');
      page.aboutToDisappear();
      assert.equal(model.revisionListeners.size, 0);
      assert.equal(model.searchListeners.size, 0);
      console.log(`真实 pending ${operation}/failure=${fail}/${settlement} 与恢复：通过`);
    }
  }
  }
  // 已加载页面的写操作使用真实模型方法，数据库和传输的完成时机由测试控制。
  for (const operation of ['update', 'delete']) {
    for (const fail of [false, true]) {
      for (const rejectOld of [false, true]) {
        const server = { id: 992, type: 'jellyfin', name: 'fixture', configJson: 'original', createdAt: 1 };
        const model = new VideoServerModel();
        const page = createDetailPageHarness(server);
        page.videoServerModel = model;
        detailRegistryDatabase.getAll = async () => [server];
        const oldStream = createDeferred(), write = createDeferred(), freshStream = createDeferred();
        detailRegistryDatabase[operation] = () => write.promise;
        let streamCalls = 0;
        installDetailClient('jellyfin', {
          getItemDetail: async () => createDetailPayload('movie'),
          getStreamUrl: () => { streamCalls++; return oldStream.promise; }
        });
        page.subscribeDetailGuards();
        await page.loadDetail(false);
        assert.equal(model.revisionListeners.size, 1, '加载完成清理后可见性守卫仍有效');
        const oldPlay = page.play();
        await flushMicrotasks();
        await page.play();
        assert.equal(streamCalls, 1, '重复点击不得启动第二个待完成流请求');
        const mutation = operation === 'update' ?
          model.updateVideoServer({ ...server, configJson: 'replacement' }) : model.deleteVideoServer(server.id);
        const settled = mutation.catch(() => {});
        assert.equal(page.detail, null, '写入意图在数据库完成前清除已加载媒体');
        assert.equal(page.isPlaying, false);
        assert.equal(page.error, '服务器配置已变更，请返回重试');
        page.retryDetail(); await flushMicrotasks();
        assert.equal(page.detail, null, '写入未完成时重试不得加载');
        assert.equal(page.isLoading, false);
        if (fail) write.reject(new Error('fixture write failure')); else write.resolve();
        await settled;
        const current = fail ? server : operation === 'update' ? { ...server, configJson: 'replacement' } : null;
        detailRegistryDatabase.getAll = async () => current ? [current] : [];
        // 写入失败允许当前页面重试；成功替换配置则要求重新进入页面。
        const recovery = fail ? page : createDetailPageHarness(current, 'jellyfin');
        recovery.serverId = server.id;
        recovery.videoServerModel = model;
        recovery.subscribeDetailGuards();
        installDetailClient('jellyfin', {
          getItemDetail: async () => { throw new Error('new revision detail failure'); }
        });
        await recovery.loadDetail(false);
        assert.equal(recovery.isLoading, false);
        assert.equal(recovery.error, current ? 'new revision detail failure' : '服务器不存在');
        if (!fail) {
          await page.loadDetail(false);
          assert.equal(page.detail, null, '旧入口不得采用替换后的媒体');
        }
        const newDetail = createDeferred();
        installDetailClient('jellyfin', {
          getItemDetail: () => newDetail.promise,
          getStreamUrl: () => { streamCalls++; return freshStream.promise; }
        });
        recovery.retryDetail(); await flushMicrotasks();
        let newPlay = null;
        if (current && rejectOld) {
          newDetail.resolve(createDetailPayload('movie')); await flushMicrotasks();
          newPlay = recovery.play(); await flushMicrotasks();
          assert.equal(recovery.isPlaying, true);
        }
        if (rejectOld) oldStream.reject(new Error('old revision stream failure'));
        else oldStream.resolve('https://fixture.invalid/old-stream');
        await oldPlay;
        assert.equal(page.pageStack.pushed.length, 0, '旧结果不得打开播放器');
        assert.deepEqual(page.toastMessages, [], '旧异常处理不得向新版本报告错误');
        if (current) {
          if (rejectOld) {
            assert.equal(recovery.isPlaying, true, '旧异常处理与清理不得解除新播放锁');
          } else {
            assert.equal(recovery.isLoading, true, '旧完成回调不得解除新加载锁');
            newDetail.resolve(createDetailPayload('movie')); await flushMicrotasks();
            newPlay = recovery.play(); await flushMicrotasks();
          }
          assert.equal(recovery.error, '');
          assert.equal(recovery.isPlaying, true);
          await recovery.play();
          assert.equal(streamCalls, 2, '恢复后的待完成播放仍拒绝重复点击');
          freshStream.resolve('https://fixture.invalid/new-stream'); await newPlay;
          assert.equal(recovery.pageStack.pushed.length, 1);
          recovery.handleDetailHidden();
          if (recovery !== page) page.handleDetailHidden();
          assert.equal(model.revisionListeners.size, 0);
          assert.equal(model.searchListeners.size, 0);
          recovery.handleDetailShown(); await flushMicrotasks();
          assert.equal(recovery.error, '', '正常从播放器返回时重新加载');
          assert.equal(model.revisionListeners.size, 1);
        }
        page.aboutToDisappear(); recovery.aboutToDisappear();
        assert.equal(model.revisionListeners.size, 0);
        assert.equal(model.searchListeners.size, 0);
        console.log(`已加载版本真实操作 ${operation}/失败=${fail}/旧请求拒绝=${rejectOld}：通过`);
      }
    }
  }
  detailRegistryDatabase.getAll = async () => [];
  detailRegistryDatabase.update = async () => {};
  detailRegistryDatabase.delete = async () => {};

  for (const boundary of ['stream', 'directory']) {
    for (const navigation of ['hidden', 'season', 'person']) {
      for (const reject of [false, true]) {
        const server = { id: 61, type: 'jellyfin', name: 'Server', configJson: 'original', createdAt: 1 };
        const page = createDetailPageHarness(server);
        const series = boundary === 'directory';
        const stale = createDeferred();
        const fresh = createDeferred();
        let calls = 0;
        page.detail = createDetailPayload(series ? 'series' : 'movie');
        page.loadedDetailIdentity = page.captureServerIdentity(server);
        page.initialLoadDone = true;
        page.subscribeDetailGuards();
        detailClientState.buildContext = series ? () => (++calls === 1 ? stale.promise : fresh.promise) : async () => null;
        installDetailClient('jellyfin', {
          getItemDetail: async () => createDetailPayload(series ? 'series' : 'movie'),
          getSeasons: async () => [],
          getNextUp: async () => createDetailMedia('episode'),
          getStreamUrl: async () => series ? 'https://stream/episode' : (++calls === 1 ? stale.promise : fresh.promise)
        });
        const oldPlay = page.play();
        await flushMicrotasks();
        assert.equal(calls, 1);
        if (navigation === 'season') page.openSeason({ id: 's1', seasonNumber: 1, name: 'Season', posterUrl: '' });
        else if (navigation === 'person') page.openPerson({ personId: 'p1', name: 'Person', role: '', imageUrl: '' });
        else page.handleDetailHidden();
        const pushed = page.pageStack.pushed.length;
        assert.equal(pushed, navigation === 'hidden' ? 0 : 1);
        assert.equal(page.isPlaying, false);
        assert.equal(page.videoServerModel.listeners.size, 0);
        // 实际 onHidden 可能在路由跳转后触发，重复隐藏仍应安全。
        page.handleDetailHidden();
        page.handleDetailShown();
        await flushMicrotasks();
        assert.equal(page.videoServerModel.listeners.size, 1);
        assert.equal(page.error, '');
        const newPlay = page.play();
        await flushMicrotasks();
        assert.equal(page.isPlaying, true);
        if (reject) stale.reject(new Error('late playback failure'));
        else stale.resolve(series ? null : 'https://stream/stale');
        await oldPlay;
        assert.equal(page.pageStack.pushed.length, pushed);
        assert.equal(page.isPlaying, true, '旧清理回调不得释放新播放锁');
        assert.deepEqual(page.toastMessages, []);
        fresh.resolve(series ? null : 'https://stream/fresh');
        await newPlay;
        assert.equal(page.pageStack.pushed.length, pushed + 1);
        assert.equal(page.pageStack.pushed[pushed].name, 'player');
        assert.equal(page.isPlaying, false);
        page.handleDetailHidden();
        page.handleDetailShown();
        await flushMicrotasks();
        assert.equal(page.error, '');
        assert.ok(page.loadedDetailIdentity);
        page.aboutToDisappear();
      }
    }
  }
  detailClientState.buildContext = async () => null;

  for (const reject of [false, true]) {
    const server = { id: 62, type: 'jellyfin', name: 'Server', configJson: 'original', createdAt: 1 };
    const page = createDetailPageHarness(server);
    const stale = createDeferred();
    const fresh = createDeferred();
    let calls = 0;
    installDetailClient('jellyfin', { getItemDetail: () => ++calls === 1 ? stale.promise : fresh.promise });
    page.initialLoadDone = true;
    const oldLoad = page.loadDetail(false);
    await flushMicrotasks();
    page.handleDetailHidden();
    page.handleDetailShown();
    page.retryDetail();
    await flushMicrotasks();
    assert.equal(page.isLoading, true);
    if (reject) stale.reject(new Error('late detail failure'));
    else stale.resolve(createDetailPayload('series'));
    await oldLoad;
    assert.equal(page.isLoading, true, '旧详情清理回调不得释放新加载锁');
    assert.equal(page.error, '');
    fresh.resolve(createDetailPayload('movie'));
    await flushMicrotasks();
    assert.equal(page.isLoading, false);
    assert.equal(page.detail.media.type, 'movie');
    page.aboutToDisappear();
  }

  console.log('静态路由/副作用/输入/生命周期守卫、真实页面方法与详情页身份/错误态回归、reject/resetAll 回归：通过');
}

async function runSearchChainChecks() {
  const assert = require('node:assert/strict');
  const { VideoServerModel } = require('../main/ets/stores/servers/VideoServerModel.ets');
  const { SourceSwitchModel } = require('../main/ets/stores/media/SourceSwitchModel.ets');
  const { AppPreferences } = require('../main/ets/utils/AppPreferences.ets');
  const { SearchWorkspaceSession } = require('../main/ets/services/search/SearchWorkspaceSession.ets');
  const { JsonHttpClient } = require('../main/ets/lib/JsonHttpClient.ets');
  const scopes = require('../main/ets/models/search/SearchScope.ets');
  const sourceText = fs.readFileSync(path.join(root,
    'entry/src/main/ets/pages/search/SearchWorkspacePage.ets'), 'utf8');
  const failures = [];
  const checkSharedBuilders = source => assert.match(
    extractMethodBody(source.slice(source.lastIndexOf('  build() {')), '  build() {'),
    /this\.buildKeyboard\(\)\s*}\s*this\.buildHistory\(\)\s*this\.buildSuggestions\(\)\s*this\.buildSearchResults\(\)/,
    'history, suggestions and results stay shared outside the local keyboard branch');
  checkSharedBuilders(sourceText);
  for (const name of ['buildHistory', 'buildSuggestions', 'buildSearchResults']) {
    const mutant = sourceText.replace(`this.${name}()`, '');
    assert.notEqual(mutant, sourceText);
    assert.throws(() => checkSharedBuilders(mutant), assert.AssertionError);
  }

  async function runCase(name, scenario, allowLocal = false) {
    console.log(`[search-chain] ${name}: START`);
    let assertions = 0;
    const check = (label, actual, expected) => {
      assert.deepEqual(actual, expected, `${name}: ${label}`);
      assertions++;
      console.log(`[search-chain] ${name}: PASS ${label}`);
    };
    const timers = installFakeTimers();
    const originalGet = JsonHttpClient.get;
    const originalPost = JsonHttpClient.post;
    const originalDelete = detailRegistryDatabase.delete;
    const source = SourceSwitchModel.getState();
    const model = new VideoServerModel();
    const requests = [], searches = [], responses = [], pushes = [], toasts = [], localCalls = [];
    const localResponses = [];
    const historyCalls = [], databaseScopes = [], historyByScope = new Map(), accessViolations = [];
    let deletes = 0;
    let page;
    try {
      const preferences = new Map();
      AppPreferences.resetForTesting();
      AppPreferences.setStoreLoaderForTesting(async () => ({
        get: async (key, fallback) => preferences.has(key) ? preferences.get(key) : fallback,
        put: async (key, value) => { preferences.set(key, value); },
        flush: async () => {}
      }));
      await AppPreferences.init({});
      const servers = [1, 2].map(id => ({
        id, name: `Chain ${id}`, type: 'jellyfin', createdAt: 1,
        configJson: JSON.stringify({ protocol: 'https', url: `chain-${id}.invalid`, port: 443,
          authMethod: 'apikey', apiKey: 'host-test-only' })
      }));
      model.videoServers = servers;
      await source.setVideoServer(servers[0]);
      detailRegistryDatabase.delete = async () => { deletes++; };
      // Keep real client protocol adaptation; replace only JSON HTTP IO.
      JsonHttpClient.get = async (url) => {
        const parsed = new URL(url);
        requests.push({ host: parsed.hostname, path: parsed.pathname });
        assert.ok(['chain-1.invalid', 'chain-2.invalid'].includes(parsed.hostname), 'unexpected host');
        if (parsed.pathname === '/Users') {
          return { statusCode: 200, body: JSON.stringify([{ Id: 'host-user' }]) };
        }
        assert.equal(parsed.pathname, '/Users/host-user/Items', 'unexpected HTTP path');
        assert.equal(parsed.searchParams.get('Limit'), '100');
        searches.push({ host: parsed.hostname, keyword: parsed.searchParams.get('SearchTerm') });
        assert.ok(responses.length > 0, 'unexpected extra search request');
        return await responses.shift()();
      };
      JsonHttpClient.post = async () => { throw new Error('unexpected HTTP POST'); };
      const localDb = {
        searchMediaItems: async (keyword) => {
          if (page.scope.kind !== 'localFiles') accessViolations.push('nonlocal media query');
          assert.equal(page.scope.kind, 'localFiles', 'server/unavailable must not query local media or pinyin');
          localCalls.push(`search:${keyword}`);
          if (localResponses.length > 0) return await localResponses.shift()();
          return [{ id: 317, title: '本地片名', movieId: 317 }];
        },
        getSearchHistory: async (scopeKey, limit) => {
          recordHistory('read', scopeKey);
          if (limit !== 20) accessViolations.push('unexpected history limit');
          assert.equal(limit, 20);
          return (historyByScope.get(scopeKey) || []).map(entry => ({ ...entry }));
        },
        upsertSearchHistory: async (scopeKey, keyword) => {
          recordHistory('write', scopeKey, keyword);
          historyByScope.set(scopeKey, [{ keyword, updatedAt: 1 },
            ...(historyByScope.get(scopeKey) || []).filter(entry => entry.keyword !== keyword)]);
        },
        deleteSearchHistory: async (scopeKey, keyword) => {
          recordHistory('delete', scopeKey, keyword);
          historyByScope.set(scopeKey, (historyByScope.get(scopeKey) || []).filter(entry => entry.keyword !== keyword));
        },
        clearSearchHistory: async scopeKey => {
          recordHistory('clear', scopeKey);
          historyByScope.set(scopeKey, []);
        }
      };
      // Production catches DB rejections; retain violations for the scenario-level assertion.
      function recordHistory(operation, scopeKey, keyword) {
        if (page.scope.kind === 'unavailable' || scopeKey !== page.scope.key) {
          accessViolations.push({ operation, scopeKey, currentScope: page.scope.key });
        }
        assert.notEqual(page.scope.kind, 'unavailable', 'unavailable must not access history');
        assert.equal(scopeKey, page.scope.key, 'history must use the exact current scope');
        historyCalls.push({ operation, scopeKey, ...(keyword === undefined ? {} : { keyword }) });
      }
      const dependencies = {
        ...scopes, SourceSwitchModel,
        titleSuggestions: require(path.join(root, 'entry/src/main/ets/services/search/SearchSuggestions.ets')).titleSuggestions,
        posterSrc: loadMethod(sourceText, 'function posterSrc(', ['item'], {}),
        // Host accessor exposes the real model without the ArkUI StateStore runtime.
        VideoServerStore: { getState: () => model },
        FileSourceDatabase: { getInstance: () => {
          if (page.scope.kind === 'unavailable') accessViolations.push('unavailable database access');
          assert.notEqual(page.scope.kind, 'unavailable', 'unavailable must not open database');
          databaseScopes.push(page.scope.key);
          return localDb;
        } },
        ServerMediaDetailPage: { PAGE_NAME: 'serverMediaDetail' }
      };
      page = {
        scope: scopes.createUnavailableSearchScope(), searchText: 'film', searchResults: [],
        historyList: [], isSearching: false, serverResult: null,
        serverSession: new SearchWorkspaceSession(), pageActive: false, sourceBound: false, db: null,
        isEditing: false, resultsFocused: false, stoppedEditing: 0, focusRequests: [],
        inputController: { stopEditing: () => { page.stoppedEditing++; } },
        searchDebounceTimer: -1, searchGeneration: 0, historyLoadGeneration: 0,
        historySourceGeneration: 0, unsubscribeSource: () => {}, unsubscribeConfiguration: () => {},
        popCount: 0,
        pageStack: { pushPathByName: (route, param) => pushes.push({ route, param }),
          pop: () => { page.popCount++; } },
        getUIContext: () => ({ getPromptAction: () => ({ showToast: value => toasts.push(value.message) }),
          getFocusController: () => ({ requestFocus: id => { page.focusRequests.push(id); return true; } }) })
      };
      attachLocalSession(page);
      for (const method of ['currentContext', 'resumeSearch', 'refreshSource', 'invalidateSearch',
        'leaveSearch', 'invalidateHistoryRequests', 'invalidateHistorySource', 'loadHistory',
        'scheduleSearch', 'executeServerSearch', 'serverErrorText', 'clearSearch',
        'executeSearchWithHistory', 'clearAllHistory', 'resultStatus', 'resultErrorText', 'retrySearch',
        'focusInput', 'handleBack', 'resultItems', 'updateResultSource', 'focusResults']) {
        page[method] = loadMethod(sourceText, `private ${method}(`, method === 'invalidateSearch' ? ['clear = false'] : [], dependencies);
      }
      // Execute the real builder's conditions/Text/ActionKey callbacks; only ArkUI layout is stubbed.
      const rendered = [], retryActions = [];
      const textStyle = { fontSize() { return this; }, fontColor() { return this; } };
      const renderBody = extractMethodBody(sourceText, '  buildSearchResults()')
        .replace(/Column\(\{ space: \d+ \}\) \{/, '{').replace('Row() {', '{')
        .replace('}.width(180)', '}')
        .replace(".width('100%')", '').replace('.layoutWeight(1)', '').replace('.alignItems(HorizontalAlign.Start)', '');
      const renderSource = ts.transpileModule(`function render() {${renderBody}}`, {
        compilerOptions: { target: ts.ScriptTarget.ES2021 }
      }).outputText;
      page.renderResults = new Function('Text', 'ActionKey', 'getSearchCapabilities',
        'C_TEXT_BODY', 'C_SECONDARY', `${renderSource}; return render;`)(
        text => { rendered.push(text); return textStyle; },
        options => { rendered.push(options.label); retryActions.push(options.onPress); },
        scopes.getSearchCapabilities, '', '');
      page.buildResultList = () => rendered.push('shared-cards');
      const render = () => {
        rendered.length = 0;
        retryActions.length = 0;
        page.renderResults();
        return rendered.slice();
      };
      const retry = () => {
        render();
        assert.equal(retryActions.length, 1, 'error builder exposes exactly one retry');
        return retryActions[0];
      };
      page.submitInput = loadMethod(sourceText, '.onSubmit(() =>', [], dependencies);
      page.backButton = loadMethod(sourceText.slice(sourceText.indexOf('  buildBackRow()')),
        '.onClick(() =>', [], dependencies);
      page.backPressed = loadMethod(sourceText, '.onBackPressed(() =>', [], dependencies);
      page.shown = loadMethod(sourceText, '.onShown(() =>', [], dependencies);
      page.willHide = loadMethod(sourceText, '.onWillHide(() =>', [], dependencies);
      page.initializeRoute = loadMethod(sourceText, 'private initializeRoute(', ['param'], dependencies);
      page.executeSearch = loadMethod(sourceText, 'private async executeSearch(', ['keyword = this.searchText.trim()', 'suggest = true'], dependencies, true);
      page.saveSearchHistory = loadMethod(sourceText, 'private saveSearchHistory(', ['kw'], dependencies);
      page.selectSuggestion = loadMethod(sourceText, 'private selectSuggestion(', ['title'], dependencies);
      page.deleteHistory = loadMethod(sourceText, 'private deleteHistory(', ['keyword'], dependencies);
      page.showToastSafe = loadMethod(sourceText, 'private showToastSafe(', ['message'], dependencies);
      page.openResult = loadMethod(sourceText, 'private openResult(', ['item'], dependencies);
      page.openServerResultDetail = loadMethod(sourceText, 'private openServerResultDetail(', ['item'], dependencies);
      const response = title => ({ statusCode: 200, body: JSON.stringify({
        Items: [{ Id: 'shared-media', Name: title, Type: 'Movie' }]
      }) });
      const enqueue = title => responses.push(async () => response(title));
      const tick = async () => {
        check('exactly one scheduled search', timers.pendingCount(), 1);
        timers.runNext();
        await flushMicrotasks();
        check('timer callback executed and drained', timers.pendingCount(), 0);
      };
      const success = (title, id = 1) => {
        check('page publishes nonempty success', page.serverResult?.status, 'success');
        check('one result from expected instance', page.serverResult.items.map(item => ({
          id: item.serverId, title: item.media.title, mediaId: item.selection.mediaId
        })), [{ id, title, mediaId: 'shared-media' }]);
        check('page loading released', page.isSearching, false);
        return page.serverResult.items[0];
      };
      // Lower only ArkUI layout syntax; retain real capability branches and input callbacks.
      const inputNodes = [], inputBranches = [];
      const style = new Proxy({}, { get: () => () => style });
      const node = (type, options) => {
        const entry = { type, options, attributes: {} };
        inputNodes.push(entry);
        const attributes = new Proxy({}, { get: (_, name) => (...args) => {
          entry.attributes[name] = args;
          return attributes;
        } });
        return attributes;
      };
      const inputDependencies = { ...dependencies, style,
        Text: () => style, TextInput: options => node('input', options),
        ActionKey: options => node('action', options),
        Color: { Transparent: '' }, ItemAlign: {}, HorizontalAlign: {}, VerticalAlign: {},
        FlexAlign: {}, ScrollDirection: {}, Alignment: {}, BorderStyle: {}, Curve: {}, TextOverflow: {},
        EnterKeyType: { Search: 'Search' },
        KeyType: { Down: 0, Up: 1 }, KeyCode: { KEYCODE_DPAD_CENTER: 23, KEYCODE_ENTER: 66 } };
      for (const match of sourceText.matchAll(/const (C_\w+|TRANSPARENT): string = '([^']*)';/g)) {
        inputDependencies[match[1]] = match[2];
      }
      const loadBuilder = signature => {
        const body = extractMethodBody(signature === '  build() {'
          ? sourceText.slice(sourceText.lastIndexOf(signature)) : sourceText, signature)
          .replace(/\b(?:NavDestination|Scroll|Column|Row)\((?:\{[^{}]*\})?\)\s*\{/g, '{')
          .replace(/}\s*(?=\.)/g, '}\nstyle');
        const compiled = ts.transpileModule(`function render() {${body}}`, {
          compilerOptions: { target: ts.ScriptTarget.ES2021 }
        }).outputText;
        return new Function(...Object.keys(inputDependencies), `${compiled}; return render;`)(
          ...Object.values(inputDependencies));
      };
      const inputPage = Object.create(page);
      inputPage.buildSearchBar = loadBuilder('  buildSearchBar()');
      const renderWorkspace = loadBuilder('  build() {');
      for (const name of ['buildBackRow', 'buildKeyboard', 'buildHistory', 'buildSuggestions', 'buildSearchResults']) {
        inputPage[name] = () => inputBranches.push(name);
      }
      const renderInput = () => {
        inputNodes.length = 0;
        inputBranches.length = 0;
        // Bind to the actual page so callbacks mutate the same state as the session.
        for (const name of ['buildSearchBar', 'buildBackRow', 'buildKeyboard', 'buildHistory', 'buildSuggestions', 'buildSearchResults']) {
          page[name] = inputPage[name];
        }
        renderWorkspace.call(page);
        return { nodes: inputNodes.slice(), branches: inputBranches.slice() };
      };
      await scenario({ check, timers, source, model, servers, requests, searches, responses,
        pushes, toasts, page, response, enqueue, tick, success, localCalls, localResponses,
        historyCalls, historyByScope, databaseScopes, localDb, scopes, render, retry, renderInput,
        deleteCount: () => deletes });
      if (!allowLocal) check('no local media or pinyin/index queries', localCalls, []);
      check('no swallowed scope/media access violations', accessViolations, []);
      check('all queued transport responses consumed', responses.length, 0);
      page.leaveSearch();
      await source.setVideoServer(servers[1]);
      model.videoServers = [];
      check('leave unsubscribes source/configuration listeners', timers.pendingCount(), 0);
      console.log(`[search-chain] ${name}: PASS (${assertions} assertions)`);
    } catch (error) {
      failures.push(error);
      console.error(`[search-chain] ${name}: FAIL after ${assertions} assertions`, error);
    } finally {
      if (page) page.leaveSearch();
      JsonHttpClient.get = originalGet;
      JsonHttpClient.post = originalPost;
      detailRegistryDatabase.delete = originalDelete;
      await source.setFileSource();
      AppPreferences.setStoreLoaderForTesting(null);
      AppPreferences.resetForTesting();
      timers.restore();
    }
  }

  await runCase('三来源历史读写删清隔离及不可用负例', async h => {
    h.page.searchText = '';
    h.page.resumeSearch();
    const select = async server => {
      if (server) await h.source.setVideoServer(server);
      else await h.source.setFileSource();
      await flushMicrotasks();
    };
    const scopeKeys = [];
    for (const server of [null, ...h.servers]) {
      await select(server);
      const scopeKey = h.page.scope.key;
      scopeKeys.push(scopeKey);
      h.check('new scope cannot see another source history', h.page.historyList, []);
      h.page.searchText = 'shared-keyword';
      if (server) h.enqueue('history submission');
      h.page.executeSearchWithHistory();
      await flushMicrotasks();
      h.check('submission writes exact scope and keyword', h.historyCalls.filter(c => c.operation === 'write').at(-1),
        { operation: 'write', scopeKey, keyword: server ? 'shared-keyword' : '本地片名' });
      h.check('submission reloads only its own history', h.page.historyList,
        server ? [{ keyword: 'shared-keyword', updatedAt: 1 }] :
          [{ keyword: '本地片名', updatedAt: 1 }, { keyword: 'shared-keyword', updatedAt: 1 }]);
      h.page.clearSearch();
    }
    h.check('three independent history partitions', [...h.historyByScope.keys()], scopeKeys);
    await select(h.servers[0]);
    h.page.deleteHistory('shared-keyword');
    await flushMicrotasks();
    h.check('delete reloads current scope only', h.page.historyList, []);
    h.check('delete preserves local and server B rows', scopeKeys.map(key => h.historyByScope.get(key).length), [2, 0, 1]);
    await select(h.servers[1]);
    h.check('server B history survives server A deletion', h.page.historyList,
      [{ keyword: 'shared-keyword', updatedAt: 1 }]);
    h.page.clearAllHistory();
    await flushMicrotasks();
    h.check('clear affects only server B', scopeKeys.map(key => h.historyByScope.get(key).length), [2, 0, 0]);
    h.check('clear resets displayed history', h.page.historyList, []);
    await select(null);
    h.check('local history survives both server mutations', h.page.historyList,
      [{ keyword: '本地片名', updatedAt: 1 }, { keyword: 'shared-keyword', updatedAt: 1 }]);
    await select(h.servers[0]);
    h.model.videoServers = [];
    await flushMicrotasks();
    h.check('deleted source remains unavailable with no database',
      [h.page.scope.kind, h.page.db, h.page.historyList], ['unavailable', null, []]);
    const before = [h.historyCalls.slice(), h.databaseScopes.slice(), h.localCalls.slice(), h.searches.slice()];
    // Retain a DB reference to prove the unavailable guard, not db === null, blocks access.
    h.page.db = h.localDb;
    h.page.searchText = 'blocked';
    h.page.loadHistory();
    h.page.deleteHistory('shared-keyword');
    h.page.clearAllHistory();
    h.page.executeSearchWithHistory();
    await h.page.executeSearch();
    await flushMicrotasks();
    h.check('unavailable blocks every history operation and both search paths',
      [h.historyCalls, h.databaseScopes, h.localCalls, h.searches], before);
    h.check('unavailable does not schedule work', h.timers.pendingCount(), 0);
  }, true);

  for (const delayed of [false, true]) {
    await runCase(`返回焦点编辑回调-${delayed ? '异步' : '同步'}`, async h => {
      h.page.searchText = '';
      h.page.resumeSearch();
      const input = h.renderInput().nodes.find(n => n.type === 'input');
      const events = input.attributes;
      const pending = [];
      const emit = editing => {
        const callback = () => events.onEditChange[0](editing);
        if (delayed) pending.push(callback); else callback();
      };
      const drain = () => { while (pending.length) pending.shift()(); };
      h.page.inputController.stopEditing = () => {
        h.page.stoppedEditing++;
        events.onBlur[0]();
        emit(false);
      };
      h.page.getUIContext = () => ({ getFocusController: () => ({ requestFocus: id => {
        h.page.focusRequests.push(id);
        if (id === 'search-workspace-input') {
          events.onFocus[0]();
          // enableKeyboardOnFocus(false) still permits caret editing / IME attachment.
          emit(true);
        }
        return true;
      } }) });
      h.check('被动获焦不主动弹键盘', events.enableKeyboardOnFocus, [false]);
      h.page.focusInput();
      drain();
      h.check('首次程序聚焦不新增编辑返回层', h.page.isEditing, false);
      h.page.backPressed();
      h.check('首次输入焦点返回直接退出', h.page.popCount, 1);
      drain();
      h.page.shown();
      drain();
      h.page.resultsFocused = true;
      h.page.backPressed();
      drain();
      h.check('结果返回输入且不退出', [h.page.resultsFocused, h.page.isEditing, h.page.popCount],
        [false, false, 1]);
      h.page.backPressed();
      h.check('结果回输入后再次返回退出', h.page.popCount, 2);
      drain();
      for (const activate of [
        () => events.onClick[0](),
        () => events.onKeyEvent[0]({ type: 0, keyCode: 23 }),
        () => events.onKeyEvent[0]({ type: 0, keyCode: 66 }),
        () => events.onChange[0]('typed')
      ]) {
        h.page.shown();
        drain();
        activate();
        emit(true);
        drain();
        const pops = h.page.popCount;
        const requests = h.page.focusRequests.length;
        const stops = h.page.stoppedEditing;
        h.page.backPressed();
        // A late positive callback after stopEditing must not re-arm Back consumption.
        emit(true);
        drain();
        h.check('主动编辑返回仅停止编辑、不重复聚焦',
          [h.page.isEditing, h.page.popCount, h.page.focusRequests.length, h.page.stoppedEditing],
          [false, pops, requests, stops + 1]);
        h.page.backPressed();
        h.check('编辑退出后再次返回离页', h.page.popCount, pops + 1);
        drain();
        h.page.searchText = '';
      }
      h.page.shown();
      drain();
      events.onClick[0]();
      emit(false);
      drain();
      h.page.backPressed();
      h.check('系统已结束编辑时不额外消费返回', h.page.pageActive, false);
      h.page.shown();
      // Back before queued focus callbacks arrive must also leave immediately.
      const pops = h.page.popCount;
      h.page.backPressed();
      drain();
      h.check('快速返回及离页后迟到回调不恢复编辑',
        [h.page.popCount, h.page.pageActive, h.page.isEditing], [pops + 1, false, false]);
    });
  }

  await runCase('输入能力真实切换与按钮IME连续链', async h => {
    h.page.searchText = '';
    await h.source.setFileSource();
    h.page.resumeSearch();
    const local = h.renderInput();
    h.check('local exposes real input modes', h.scopes.getSearchCapabilities(h.page.scope).inputModes,
      ['initials', 'pinyin', 'chinese']);
    h.check('local renders keyboard and history', local.branches,
      ['buildBackRow', 'buildKeyboard', 'buildHistory', 'buildSuggestions', 'buildSearchResults']);
    h.check('local shares TextInput and submit/clear actions', local.nodes.map(n => n.type),
      ['input', 'action', 'action']);
    const localInput = local.nodes[0];
    localInput.attributes.onChange[0]('本地');
    localInput.attributes.onSubmit[0]();
    await flushMicrotasks();
    h.check('local IME searches candidates then first title', h.localCalls, ['search:本地', 'search:本地片名']);
    h.check('local IME writes current scope history once',
      h.historyCalls.filter(c => c.operation === 'write'),
      [{ operation: 'write', scopeKey: h.page.scope.key, keyword: '本地' },
       { operation: 'write', scopeKey: h.page.scope.key, keyword: '本地片名' }]);
    h.check('local submit drains debounce', h.timers.pendingCount(), 0);
    h.page.clearSearch();

    for (const type of ['jellyfin', 'emby', 'plex']) {
      h.model.videoServers = [{ ...h.servers[0], type }];
      await h.source.setVideoServer(h.model.videoServers[0]);
      h.check(`${type}: real text capability`, h.scopes.getSearchCapabilities(h.page.scope).inputModes, ['text']);
      const ui = h.renderInput();
      h.check(`${type}: shared history/suggestions/results without custom keyboard`, ui.branches,
        ['buildBackRow', 'buildHistory', 'buildSuggestions', 'buildSearchResults']);
      h.check(`${type}: input and two actions`, ui.nodes.map(n => n.type), ['input', 'action', 'action']);
      h.check(`${type}: stable focus ids`, ui.nodes.map(n => n.attributes.id[0]),
        ['search-workspace-input', 'search-workspace-submit', 'search-workspace-clear']);
      h.check(`${type}: no focus-triggered IME and Search enter key`,
        [ui.nodes[0].attributes.enableKeyboardOnFocus[0], ui.nodes[0].attributes.enterKeyType[0]], [false, 'Search']);
      h.check(`${type}: actions labelled`, ui.nodes.slice(1).map(n => n.options.label), ['搜索', '清空']);
    }
    h.model.videoServers = h.servers;
    await h.source.setVideoServer(h.servers[0]);
    const ui = h.renderInput();
    const input = ui.nodes[0];
    const submit = ui.nodes[1].options.onPress;
    const clear = ui.nodes[2].options.onPress;
    for (const [label, callback] of [['button', submit], ['IME', input.attributes.onSubmit[0]]]) {
      input.attributes.onChange[0](`film-${label}`);
      h.check(`${label}: change schedules debounce`, h.timers.pendingCount(), 1);
      const pending = createDeferred();
      h.responses.push(() => pending.promise);
      const before = h.searches.length;
      callback();
      await flushMicrotasks();
      h.check(`${label}: one immediate request`, h.searches.length, before + 1);
      h.check(`${label}: submit cancels debounce`, h.timers.pendingCount(), 0);
      clear();
      input.attributes.onChange[0]('');
      input.attributes.onSubmit[0]();
      clear();
      pending.resolve(h.response('late cleared result'));
      await flushMicrotasks();
      h.check(`${label}: clear/empty IME leaves no extra request`, h.searches.length, before + 1);
      h.check(`${label}: clear leaves no text, result or timer`,
        [h.page.searchText, h.page.serverResult, h.page.searchResults, h.page.isSearching, h.timers.pendingCount()],
        ['', null, [], false, 0]);
      h.check(`${label}: shared results restored to idle`, h.render(), ['输入片名搜索当前服务器']);
    }
    input.attributes.onChange[0]('pending');
    h.model.videoServers = [];
    h.check('deleted source has no input modes', h.scopes.getSearchCapabilities(h.page.scope).inputModes, []);
    h.check('unavailable renders no input or results', h.renderInput(),
      { nodes: [], branches: ['buildBackRow'] });
    h.check('unavailable cancels pending timer', h.timers.pendingCount(), 0);
    await h.source.setFileSource();
    h.check('return to local restores keyboard', h.renderInput().branches,
      ['buildBackRow', 'buildKeyboard', 'buildHistory', 'buildSuggestions', 'buildSearchResults']);
    h.page.clearSearch();
  }, true);

  await runCase('本地真实拒绝必须呈现错误而非空白', async h => {
    await h.source.setFileSource();
    const pending = createDeferred();
    h.localResponses.push(() => pending.promise);
    h.page.resumeSearch();
    await h.tick();
    h.check('real local method awaits DB', h.page.session.status, 'loading');
    pending.reject(new Error('synthetic-private-db-path-and-token'));
    await flushMicrotasks();
    console.log(`[search-state] rejected DB observations: ${JSON.stringify({
      isSearching: h.page.isSearching, results: h.page.searchResults,
      localStatus: h.page.localStatus, serverResult: h.page.serverResult })}`);
    h.check('DB rejection is error, not silent empty results', h.page.localStatus, 'error');
  }, true);

  await runCase('本地状态渲染重试清空换源离页连续链', async h => {
    await h.source.setFileSource();
    h.page.searchText = '   ';
    h.page.resumeSearch();
    h.check('blank initial query renders idle', h.render(), ['输入片名搜索本地媒体库']);
    h.check('idle does not schedule search', h.timers.pendingCount(), 0);
    h.page.searchText = 'film';
    const failed = createDeferred();
    h.localResponses.push(() => failed.promise);
    h.page.scheduleSearch();
    h.check('debounce renders loading', h.render(), ['正在搜索…']);
    await h.tick();
    h.check('pending database renders loading', h.render(), ['正在搜索…']);
    failed.reject(new Error('synthetic-private-db-path-and-token'));
    await flushMicrotasks();
    h.check('rejection renders sanitized error and retry', h.render(), ['本地搜索失败，请重试', '重试']);
    const retry = h.retry();
    const empty = createDeferred();
    h.localResponses.push(() => empty.promise);
    retry();
    retry();
    h.check('double retry runs exactly one new search', h.localCalls.filter(c => c.startsWith('search:')).length, 2);
    h.check('retry has no debounce remainder', h.timers.pendingCount(), 0);
    h.check('retry renders loading', h.render(), ['正在搜索…']);
    empty.resolve([]);
    await flushMicrotasks();
    h.check('valid zero matches renders empty, not idle', h.render(), ['本地媒体库未找到匹配内容']);
    retry();
    h.check('stale retry action on empty is inert', h.localCalls.filter(c => c.startsWith('search:')).length, 2);
    h.page.scheduleSearch();
    await h.tick();
    h.check('success renders local cards only', h.render(), ['shared-cards']);
    h.check('success state comes from real database method', h.page.localStatus, 'success');
    h.page.clearSearch();
    h.check('clear removes success and restores idle', [h.page.searchResults, h.render()], [[], ['输入片名搜索本地媒体库']]);

    for (const boundary of ['clear', 'source', 'leave', 'input']) {
      for (const rejection of [false, true]) {
        h.page.searchText = 'film';
        const late = createDeferred();
        h.localResponses.push(() => late.promise);
        h.page.scheduleSearch();
        await h.tick();
        if (boundary === 'clear') h.page.clearSearch();
        if (boundary === 'source') await h.source.setVideoServer(h.servers[0]);
        if (boundary === 'leave') h.page.willHide();
        if (boundary === 'input') { h.page.searchText = 'new'; h.page.scheduleSearch(); }
        const before = [h.page.localStatus, h.page.isSearching, h.render()];
        if (rejection) late.reject(new Error('synthetic-sensitive-late-error'));
        else late.resolve([{ id: 999, title: 'stale' }]);
        await flushMicrotasks();
        h.check(`${boundary}/${rejection}: old completion cannot publish state`,
          [h.page.localStatus, h.page.isSearching, h.render()], before);
        h.check(`${boundary}/${rejection}: stale cards absent`, h.page.searchResults, []);
        h.page.clearSearch();
        if (boundary === 'source') await h.source.setFileSource();
        if (boundary === 'leave') h.page.shown();
      }
    }
    h.check('only accepted first suggestion writes history', h.historyCalls.filter(c => c.operation === 'write'),
      [{ operation: 'write', scopeKey: h.page.scope.key, keyword: '本地片名' }]);
    h.check('local chains never reach HTTP', h.requests, []);
    h.page.searchText = 'film';
    h.page.scheduleSearch();
    await h.tick();
    h.page.willHide();
    h.check('leaving after success clears cards and state',
      [h.page.searchResults, h.page.localStatus, h.page.isSearching], [[], 'idle', false]);
    const before = h.localCalls.length;
    await h.page.executeSearch();
    retry();
    h.check('hidden page cannot restart local query', h.localCalls.length, before);
  }, true);

  await runCase('服务器共享状态容器保留重试语义', async h => {
    h.page.searchText = '';
    h.page.resumeSearch();
    h.check('server idle render', h.render(), ['输入片名搜索当前服务器']);
    h.page.searchText = 'film';
    h.page.scheduleSearch();
    h.check('server debounce loading render', h.render(), ['正在搜索…']);
    h.responses.push(async () => { throw new Error('synthetic-sensitive-network-error'); });
    await h.tick();
    h.check('server error keeps sanitized explanation', h.render(), ['无法连接服务器，请检查网络后重试', '重试']);
    const retry = h.retry();
    h.responses.push(async () => ({ statusCode: 200, body: JSON.stringify({ Items: [] }) }));
    retry();
    retry();
    await flushMicrotasks();
    h.check('server retry renders empty', h.render(), ['当前服务器未找到匹配内容']);
    h.check('server retry is single request without timer', [h.searches.length, h.timers.pendingCount()], [2, 0]);
    h.enqueue('server recovered');
    h.page.scheduleSearch();
    await h.tick();
    h.check('server success uses existing cards', h.render(), ['shared-cards']);
    h.page.clearSearch();
    h.check('server clear restores idle', h.render(), ['输入片名搜索当前服务器']);
  });

  await runCase('本地服务器往返按真实能力分流且失效不回退', async h => {
    await h.source.setFileSource();
    h.page.searchText = 'bdpm';
    h.page.resumeSearch();
    h.check('local input capabilities', h.scopes.getSearchCapabilities(h.page.scope).inputModes,
      ['initials', 'pinyin', 'chinese']);
    await h.tick();
    h.check('local query reaches database with pinyin text', h.localCalls,
      ['search:bdpm', 'search:本地片名']);
    h.check('local opens history database for exact scope', h.databaseScopes, [h.page.scope.key]);
    h.check('local reads and updates scoped history', h.historyCalls, [
      { operation: 'read', scopeKey: h.page.scope.key },
      { operation: 'write', scopeKey: h.page.scope.key, keyword: '本地片名' },
      { operation: 'read', scopeKey: h.page.scope.key }]);
    h.check('local results published', h.page.searchResults.map(item => item.title), ['本地片名']);
    h.check('local mode makes no HTTP requests', h.requests, []);

    for (const server of h.servers) {
      await h.source.setVideoServer(server);
      h.check('server input is literal text only', h.scopes.getSearchCapabilities(h.page.scope).inputModes,
        ['text']);
      h.check('switch clears local results but retains scoped history database',
        [h.page.searchResults, h.page.db === h.localDb], [[], true]);
      h.check('server reads only selected scope history', h.historyCalls.at(-1),
        { operation: 'read', scopeKey: h.page.scope.key });
      const before = h.localCalls.slice();
      // Even an accidental direct invocation must respect the real capability guard.
      await h.page.executeSearch();
      h.page.searchText = '真实片名';
      h.page.scheduleSearch();
      h.enqueue(`服务器 ${server.id}`);
      await h.tick();
      h.success(`服务器 ${server.id}`, server.id);
      h.check('server has no local media/index entry', h.localCalls, before);
      h.check('literal query reaches selected instance', h.searches.at(-1), {
        host: `chain-${server.id}.invalid`, keyword: '真实片名'
      });
    }

    await h.source.setFileSource();
    h.check('return restores local capabilities', h.scopes.getSearchCapabilities(h.page.scope).inputModes,
      ['initials', 'pinyin', 'chinese']);
    h.check('return clears server result immediately', h.page.serverResult, null);
    h.page.searchText = 'bdpm';
    h.page.scheduleSearch();
    await h.tick();
    h.check('return publishes only local results', h.page.searchResults.map(item => item.title), ['本地片名']);
    h.check('local return does not issue HTTP search', h.searches.length, 2);

    await h.source.setVideoServer(h.servers[0]);
    h.page.searchText = '删除前查询';
    h.page.scheduleSearch();
    h.enqueue('删除前结果');
    await h.tick();
    h.success('删除前结果');
    const before = h.localCalls.slice();
    await h.model.deleteVideoServerWithFallback(h.servers[0].id);
    h.check('deleted source remains unavailable', h.page.scope.kind, 'unavailable');
    h.check('unavailable has no input capability', h.scopes.getSearchCapabilities(h.page.scope).inputModes, []);
    h.check('unavailable clears both result modes', [h.page.searchResults, h.page.serverResult], [[], null]);
    h.page.scheduleSearch();
    await h.page.executeSearch();
    h.check('unavailable does not schedule fallback', h.timers.pendingCount(), 0);
    h.check('unavailable never opens local index path', h.localCalls, before);
  }, true);

  for (const local of [true, false]) {
    await runCase(`${local ? '本地' : '服务器'}提交清空退出重入连续链`, async h => {
      if (local) await h.source.setFileSource();
      h.page.searchText = '连续片名';
      h.page.resumeSearch();
      const searchCount = () => local
        ? h.localCalls.filter(call => call.startsWith('search:')).length : h.searches.length;
      const writeCount = () => h.historyCalls.filter(call => call.operation === 'write').length;
      h.check('before submit timer/search/history writes',
        [h.timers.pendingCount(), searchCount(), writeCount()], [1, 0, 0]);
      if (!local) h.enqueue('提交结果');
      h.page.submitInput();
      await flushMicrotasks();
      const afterSubmit = [h.timers.pendingCount(), searchCount(), writeCount()];
      // Drain any leftover debounce to reproduce duplicate work, rather than infer it from code.
      if (h.timers.pendingCount() > 0) {
        if (!local) h.enqueue('重复结果');
        h.timers.runNext();
        await flushMicrotasks();
      }
      console.log(`[search-chain] submit observations: ${JSON.stringify({ local, afterSubmit,
        afterDrain: [h.timers.pendingCount(), searchCount(), writeCount()] })}`);
      h.check('submit consumes debounce and searches/writes once',
        [afterSubmit, searchCount(), writeCount()], [[0, local ? 2 : 1, local ? 2 : 1], local ? 2 : 1, local ? 2 : 1]);
      h.check('submit releases loading', h.page.isSearching, false);
      h.page.clearSearch();
      h.check('clear resets input and both result modes',
        [h.page.searchText, h.page.searchResults, h.page.serverResult, h.page.isSearching,
          h.timers.pendingCount()], ['', [], null, false, 0]);
      h.page.searchText = '纯防抖';
      h.page.scheduleSearch();
      if (!local) h.enqueue('防抖结果');
      await h.tick();
      h.check('debounce searches once without history submission',
        [searchCount(), writeCount()], [local ? 4 : 2, local ? 3 : 1]);
      h.page.searchText = '取消等待';
      h.page.scheduleSearch();
      h.page.backButton();
      h.page.willHide();
      h.check('back button pops exactly once despite hide callback', h.page.popCount, 1);
      h.check('leaving cancels pending work',
        [h.page.pageActive, h.page.isSearching, h.timers.pendingCount(), searchCount()],
        [false, false, 0, local ? 4 : 2]);
      h.page.shown();
      h.page.shown();
      if (!local) h.enqueue('重入结果');
      await h.tick();
      h.check('reentry preserves text and searches exactly once',
        [h.page.searchText, searchCount(), writeCount()], ['取消等待', local ? 6 : 3, local ? 4 : 1]);
      h.page.searchText = '返回取消';
      h.page.scheduleSearch();
      h.check('hardware back consumes event', h.page.backPressed(), true);
      h.page.willHide();
      h.check('hardware back cancels pending work and pops once',
        [h.page.popCount, h.timers.pendingCount(), searchCount()], [2, 0, local ? 6 : 3]);
      h.page.clearSearch();
      h.page.shown();
      h.check('empty reentry stays idle',
        [h.page.searchText, h.page.searchResults, h.page.serverResult, h.page.isSearching,
          h.timers.pendingCount(), searchCount()], ['', [], null, false, 0, local ? 6 : 3]);
    }, local);
  }

  await runCase('跨来源关键词隔离和统一结果选择焦点', async h => {
    await h.source.setFileSource();
    h.page.searchText = '只用于本地';
    h.page.resumeSearch();
    await h.tick();
    const local = h.page.resultItems()[0];
    h.check('本地统一卡片内容', [local.title, local.label, local.scopeKey], ['本地片名', '电影', 'local-files']);
    const localSelections = [];
    h.page.navigateToDetail = item => localSelections.push(item);
    h.page.openResult(local);
    h.check('统一入口承接本地详情', localSelections, [local.localItem]);
    await h.source.setVideoServer(h.servers[0]);
    h.check('切服务器不自动转发本地关键词', [h.page.searchText, h.timers.pendingCount(), h.searches], ['', 0, []]);
    h.page.openResult(local);
    h.check('旧本地卡片不能进入详情', localSelections.length, 1);
    h.page.searchText = '只用于 A';
    h.page.scheduleSearch();
    const late = createDeferred();
    h.responses.push(() => late.promise);
    await h.tick();
    await h.source.setVideoServer(h.servers[1]);
    h.check('A 到 B 清空待查词', [h.page.searchText, h.timers.pendingCount()], ['', 0]);
    late.resolve(h.response('旧 A'));
    await flushMicrotasks();
    h.check('旧响应不能填回 B', h.page.serverResult, null);
    h.page.searchText = 'B 明确输入';
    h.enqueue('B 结果');
    h.page.executeServerSearch();
    await flushMicrotasks();
    const server = h.page.resultItems()[0];
    h.check('服务器统一卡片内容', [server.title, server.label], ['B 结果', '电影']);
    h.page.openResult(server);
    h.check('统一入口承接服务器详情', h.pushes[0].param.serverId, 2);
    h.page.isEditing = true;
    const stopped = h.page.stoppedEditing;
    h.page.backPressed();
    h.check('编辑中返回结束编辑而不退出', [h.page.isEditing, h.page.popCount, h.page.stoppedEditing], [false, 0, stopped + 1]);
    h.page.resultsFocused = true;
    h.page.backPressed();
    h.check('结果返回输入不退出', [h.page.resultsFocused, h.page.popCount, h.page.focusRequests.at(-1)],
      [false, 0, 'search-workspace-input']);
    h.page.backPressed();
    h.check('输入区再次返回才退出', h.page.popCount, 1);
    h.page.shown();
    // Same-source reentry schedules its current query, then switching local cancels it.
    await h.source.setFileSource();
    h.check('B 到本地也不复用关键词', [h.page.searchText, h.timers.pendingCount()], ['', 0]);
    h.check('只有明确输入的 A/B 词进入传输', h.searches, [
      { host: 'chain-1.invalid', keyword: '只用于 A' },
      { host: 'chain-2.invalid', keyword: 'B 明确输入' }
    ]);
  }, true);

  await runCase('旧显式路由与隐藏期间切源不得转发关键词', async h => {
    await h.source.setVideoServer(h.servers[1]);
    h.page.initializeRoute({ scope: { kind: 'videoServer', serverId: 1, serverType: 'jellyfin' }, keyword: '路由词' });
    h.check('旧来源路由关键词清空', h.page.searchText, '');
    h.check('初始化采用当前 B 而非路由 A', h.page.scope.serverId, 2);
    h.check('不发送旧路由关键词', [h.searches, h.timers.pendingCount()], [[], 0]);
    h.page.searchText = 'B 新输入';
    h.page.scheduleSearch();
    h.enqueue('当前来源 B');
    await h.tick();
    const oldCard = h.success('当前来源 B', 2);
    h.page.leaveSearch();
    await h.source.setVideoServer(h.servers[0]);
    h.page.resumeSearch();
    h.check('隐藏期间切源清空关键词', [h.page.searchText, h.timers.pendingCount()], ['', 0]);
    h.page.openServerResultDetail(oldCard);
    h.check('旧 B 卡片不得打开详情', h.pushes, []);
    h.check('只执行明确输入的 B 查询', h.searches, [{ host: 'chain-2.invalid', keyword: 'B 新输入' }]);
  });

  await runCase('delete-success-return-same-word', async h => {
    h.enqueue('before deletion');
    h.page.resumeSearch();
    await h.tick();
    const oldCard = h.success('before deletion');
    await h.model.deleteVideoServerWithFallback(1);
    h.check('real deletion reaches DB once', h.deleteCount(), 1);
    h.check('deleted instance absent; other retained', h.model.videoServers.map(s => s.id), [2]);
    h.check('active deleted identity preserved', h.source.getActiveServerId(), 1);
    h.check('real configuration notification refreshes to unavailable', h.page.scope.kind, 'unavailable');
    h.check('deletion clears cards', h.page.serverResult, null);
    h.check('deletion clears lazy data source', h.page.resultSource.totalCount(), 0);
    h.page.openServerResultDetail(oldCard);
    h.check('old card cannot push after deletion', h.pushes, []);
    h.check('identity gate reports changed source', h.toasts.length, 1);
    const before = h.requests.length;
    h.page.leaveSearch();
    h.page.resumeSearch();
    h.page.resumeSearch();
    h.page.scheduleSearch();
    await flushMicrotasks();
    h.check('unavailable clears keyword', h.page.searchText, '');
    h.check('unavailable return schedules no timer', h.timers.pendingCount(), 0);
    h.check('no deleted or alternative instance HTTP after return', h.requests.length, before);
    h.check('only original instance searched', h.searches, [{ host: 'chain-1.invalid', keyword: 'film' }]);
    h.check('return has no cards or local results', [h.page.serverResult, h.page.searchResults], [null, []]);
  });

  await runCase('same-instance-reject-recover-stale-response', async h => {
    h.enqueue('initial');
    h.page.resumeSearch();
    await h.tick();
    h.success('initial');
    const stale = createDeferred();
    h.responses.push(() => stale.promise);
    h.page.scheduleSearch();
    await h.tick();
    h.check('pending response has no new cards', [h.page.serverResult.status, h.page.serverResult.items], ['loading', []]);
    h.responses.push(async () => { throw new Error('host transport disconnected'); });
    h.page.scheduleSearch();
    await h.tick();
    h.check('transport reject becomes page network error', [h.page.serverResult.status, h.page.serverResult.errorCode], ['error', 'network']);
    h.check('error response has no new cards', [h.page.serverResult.items, h.page.searchResults], [[], []]);
    h.check('refresh failure retains accepted lazy cards', h.page.resultSource.getData(0).title, 'initial');
    h.check('error releases loading', h.page.isSearching, false);
    h.check('page exposes connection error text', h.page.serverErrorText(), '无法连接服务器，请检查网络后重试');
    const recovery = createDeferred();
    h.responses.push(() => recovery.promise);
    h.page.scheduleSearch();
    await h.tick();
    stale.resolve(h.response('must not return'));
    await flushMicrotasks();
    h.check('deferred old response cannot refill recovering page',
      [h.page.serverResult.status, h.page.serverResult.items, h.page.isSearching], ['loading', [], true]);
    recovery.resolve(h.response('recovered'));
    await flushMicrotasks();
    h.success('recovered');
    h.check('recovery replaces lazy cards', h.page.resultSource.getData(0).title, 'recovered');
    h.check('same-word recovery searches only original instance', h.searches,
      Array.from({ length: 4 }, () => ({ host: 'chain-1.invalid', keyword: 'film' })));
    h.check('all HTTP remains on original instance', h.requests.every(r => r.host === 'chain-1.invalid'), true);
    h.check('error/recovery does not navigate', h.pushes, []);
  });

  await runCase('detail-return-once-same-protocol-media-isolation', async h => {
    h.enqueue('A initial');
    h.page.resumeSearch();
    await h.tick();
    const cardA = h.success('A initial');
    h.page.openServerResultDetail(cardA);
    h.check('successful card pushes exact detail identity', h.pushes, [{ route: 'serverMediaDetail', param: {
      serverId: 1, serverType: 'jellyfin', mediaId: 'shared-media', mediaType: 'movie',
      itemId: 'shared-media', title: 'A initial'
    } }]);
    h.page.leaveSearch();
    h.check('leave clears cards and timer', [h.page.serverResult, h.timers.pendingCount()], [null, 0]);
    h.enqueue('A returned');
    h.page.resumeSearch();
    h.page.resumeSearch();
    await h.tick();
    h.success('A returned');
    h.check('detail return restores card focus', h.page.focusRequests.at(-1), 'search-workspace-result-0');
    h.check('restored card Back returns to input', [h.page.resultsFocused, h.page.handleBack(), h.page.popCount], [true, true, 0]);
    h.check('detail return triggers exactly one same-word re-search', h.searches,
      Array.from({ length: 2 }, () => ({ host: 'chain-1.invalid', keyword: 'film' })));
    const staleA = createDeferred();
    h.responses.push(() => staleA.promise);
    h.page.scheduleSearch();
    await h.tick();
    await h.source.setVideoServer(h.servers[1]);
    h.check('real source notification switches page to B', h.page.scope.serverId, 2);
    h.page.openServerResultDetail(cardA);
    h.check('A card cannot push while B active', h.pushes.length, 1);
    h.page.searchText = 'film';
    h.page.scheduleSearch();
    h.enqueue('B same media');
    await h.tick();
    const cardB = h.success('B same media', 2);
    h.check('same protocol and mediaId fixture', [cardA.serverType, cardA.selection.mediaId],
      [cardB.serverType, cardB.selection.mediaId]);
    h.check('A/B result keys isolated', cardA.key === cardB.key, false);
    const publishedB = h.page.serverResult;
    staleA.resolve(h.response('late A same media'));
    await flushMicrotasks();
    h.check('deferred A cannot replace B result object', h.page.serverResult === publishedB, true);
    h.success('B same media', 2);
    h.page.openServerResultDetail(cardB);
    h.check('B card pushes B identity despite same mediaId', h.pushes[1], { route: 'serverMediaDetail', param: {
      serverId: 2, serverType: 'jellyfin', mediaId: 'shared-media', mediaType: 'movie',
      itemId: 'shared-media', title: 'B same media'
    } });
    h.page.leaveSearch();
    h.enqueue('B returned');
    h.page.resumeSearch();
    h.page.resumeSearch();
    await h.tick();
    h.success('B returned', 2);
    h.check('A/B requests preserve keyword and exact counts', h.searches, [
      ...Array.from({ length: 3 }, () => ({ host: 'chain-1.invalid', keyword: 'film' })),
      ...Array.from({ length: 2 }, () => ({ host: 'chain-2.invalid', keyword: 'film' }))
    ]);
    h.page.openServerResultDetail(cardA);
    h.check('old A remains blocked after B detail return', h.pushes.length, 2);
    h.page.leaveSearch();
  });
  if (failures.length > 0) throw new AggregateError(failures, 'Search chain regressions');
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

function runLibraryImageChecks() {
  const assert = require('node:assert/strict');
  const page = fs.readFileSync(path.join(root,
    'entry/src/main/ets/pages/home/tabs/MediaLibraryTab.ets'), 'utf8');
  const source = page.slice(page.indexOf('struct ServerLibraryCard {'),
    page.indexOf('struct SectionRow {'));
  const card = { library: { imageUrl: '', type: 'movies' }, imageFailed: false };
  for (const name of ['resetImageFailure', 'onImageError', 'shouldLoadThumbnail', 'getPlaceholder']) {
    card[name] = loadMethod(source, `private ${name}(`, [], { $r: (value) => value });
  }
  assert.equal(card.shouldLoadThumbnail(), false);
  assert.equal(card.getPlaceholder(), 'app.media.library_placeholder_movie');
  card.library.imageUrl = 'https://invalid.example/missing.jpg';
  assert.equal(card.shouldLoadThumbnail(), true);
  card.onImageError();
  assert.equal(card.shouldLoadThumbnail(), false);
  assert.equal(card.getPlaceholder(), 'app.media.library_placeholder_movie');
  card.library = { imageUrl: 'https://example.test/new.jpg', type: 'tvshows' };
  card.resetImageFailure();
  assert.equal(card.shouldLoadThumbnail(), true);
  card.onImageError();
  assert.equal(card.getPlaceholder(), 'app.media.library_placeholder_tv');
  assert.equal(card.shouldLoadThumbnail(), false);
  card.resetImageFailure();
  assert.equal(card.imageFailed, false);
  assert.match(source, /@Monitor\('library'\)/);
  assert.match(source, /\.onError\(\(\) => \{ this.onImageError\(\) \}\)/);
  assert.match(source, /\.onComplete\(\(\) => \{ this.resetImageFailure\(\) \}\)/);
  const fallback = source.slice(source.indexOf('} else {'), source.indexOf('private getPlaceholder'));
  assert.match(fallback, /Image\(this.getPlaceholder\(\)\)/);
  assert.doesNotMatch(fallback, /onComplete|onError/);
  console.log('媒体库图片回退: 空地址、非空失效地址错误回调、分类占位、复用恢复及占位图无重试循环检查通过');
}

if (process.argv.includes('--library-images')) {
  runLibraryImageChecks();
} else if (process.argv.includes('--search-chains')) {
  runSearchChainChecks().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
} else if (process.argv.includes('--integration')) {
  runHostIntegrationChecks()
    .then(() => runSearchChainChecks())
    .then(() => { registerAndExecuteCore(); })
    .catch((error) => {
      console.error(error);
      process.exitCode = 1;
    });
} else {
  registerAndExecuteCore();
}
