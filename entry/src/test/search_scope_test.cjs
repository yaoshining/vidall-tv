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
  const detailPage = 'entry/src/main/ets/pages/detail/ServerMediaDetailPage.ets';
  const workspacePath = path.join(root, workspace);
  const resultPath = path.join(root, results);
  const workspaceSource = fs.readFileSync(workspacePath, 'utf8');
  const resultSource = fs.readFileSync(resultPath, 'utf8');
  const detailPageSource = fs.readFileSync(path.join(root, detailPage), 'utf8');
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
  assert.ok(preview.includes('ServerSearchResultCard'));
  assert.ok(preview.includes('this.openServerResultDetail(item);'));
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
    invalidateSearch: loadMethod(workspaceSource, 'private invalidateSearch(): void', [], {}),
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
      buildServerEpisodePlaybackContext: async () => null,
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
      detailLoadGeneration: 0,
      detailRequestActive: false,
      playOperationGeneration: 0,
      playOperationActive: false,
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
    page.invalidateSearch = methods.invalidateSearch;
    page.invalidateHistoryRequests = methods.invalidateHistoryRequests;
    page.invalidateHistorySource = methods.invalidateHistorySource;
    page.loadHistory = methods.loadHistory;
    page.scheduleSearch = methods.scheduleSearch;
    page.executeServerSearch = methods.executeServerSearch;
    page.openServerResultDetail = methods.openServerResultDetail;
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
    const timers = installFakeTimers();
    try {
      const page = createPageHarness(createServerContext(3).scope, null);
      page.currentContext = () => createServerContext(3);
      page.searchText = 'return-search';
      page.refreshSource();
      assert.equal(page.scope.key, 'video-server:jellyfin:3');
      assert.equal(page.searchResults.length, 0);
      assert.equal(page.db, null);
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

  console.log('静态路由/副作用/输入/生命周期守卫、真实页面方法与详情页身份/错误态回归、reject/resetAll 回归：通过');
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
