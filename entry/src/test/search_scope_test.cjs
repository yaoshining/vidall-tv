// Host adapter for the repository Hypium runner; no device or database required.
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
  // Host-only database boundary; execute the real VideoServerModel deletion/cache logic.
  if (request === '../../db/files/FileSourceDatabase' && parent &&
    parent.filename.endsWith('/stores/servers/VideoServerModel.ets')) {
    return { FileSourceDatabase: { getInstance: () => ({ deleteVideoServer: async () => {} }) } };
  }
  return load.call(this, request, parent, main);
};
if (process.argv.includes('--integration')) {
  // Static integration checks complement pure-model cases; they do not execute ArkUI.
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
  console.log('Static routing/side-effect guards: passed');
}
const Core = require(path.join(hypium, 'core.js')).default;
const core = Core.getInstance();
core.init();
require(path.join(root, 'entry/src/test/SearchScope.test.ets')).default();
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
