// 仓库 Hypium 运行器的主机适配层，无需设备或数据库。
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const root = path.resolve(__dirname, '../../..');
const ts = require(process.env.TYPESCRIPT_PATH ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
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
if (process.argv.includes('--integration')) {
  // 静态接入检查补充纯模型用例，不执行 ArkUI。
  const assert = require('node:assert/strict');
  function checkGuard(file, method, capability) {
    const source = fs.readFileSync(path.join(root, file), 'utf8');
    const start = source.indexOf(method);
    assert.notEqual(start, -1, method);
    const body = source.slice(source.indexOf('{', start) + 1).trimStart();
    assert.ok(body.startsWith(`if (!getSearchCapabilities(this.scope).${capability}`), method);
  }
  const workspace = 'entry/src/main/ets/pages/search/SearchWorkspacePage.ets';
  const results = 'entry/src/main/ets/pages/search/MediaResultPage.ets';
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
  const page = fs.readFileSync(path.join(root, workspace), 'utf8');
  assert.ok(page.includes('TextInput({ text: this.searchText'));
  assert.ok(page.includes('subscribeSearchSource(() => this.refreshSource())'));
  assert.ok(page.includes('subscribeSearchConfiguration(() => this.refreshSource())'));
  assert.ok(page.includes('.onWillHide(() => { this.leaveSearch(); })'));
  const preview = page.slice(page.indexOf('  buildServerResults()'), page.indexOf('  build() {\n    NavDestination()'));
  assert.ok(!preview.includes('onClick') && !preview.includes('navigateToDetail'));
  assert.ok(preview.includes('.focusable(false)'));
  const resultSource = fs.readFileSync(path.join(root, results), 'utf8');
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
  console.log('静态路由/副作用/输入/生命周期守卫、观察字段与 2 项真实重置方法回归：通过');
}
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
