const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
// Pass TYPESCRIPT_PATH when TypeScript is not installed in the local Node resolution path.
const ts = require(process.env.TYPESCRIPT_PATH || 'typescript');
const tests = [];
function compile(path, req) {
  const source = fs.readFileSync(path, 'utf8').replace(/@ObservedV2\s*/g, '').replace(/@Trace\s*/g, '');
  const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const exports = {};
  vm.runInNewContext(js, { exports, require: req, setTimeout, clearTimeout, Promise, Error });
  return exports;
}
const session = compile('entry/src/main/ets/services/search/SearchSession.ets');
const suite = compile('entry/src/test/SearchSession.test.ets', name => name.includes('SearchSession') ? session : {
  describe: (_, fn) => fn(), it: (name, _, fn) => tests.push({name, fn}),
  expect: value => ({ assertTrue: () => assert.equal(value, true), assertFalse: () => assert.equal(value, false), assertEqual: expected => assert.equal(value, expected) })
});
suite.default();
const { MediaQueryDao } = compile('entry/src/main/ets/db/files/MediaQueryDao.ets', () => ({}));
tests.push({ name: '数据库未就绪和查询失败可进入错误状态，默认调用保持兼容', fn: async () => {
  for (const ready of [false, true]) {
    const dao = new MediaQueryDao({
      isReady: () => ready,
      getStore: () => ({ querySql: async () => { throw new Error('private-url'); } })
    });
    assert.equal((await dao.searchMediaItems('test')).length, 0);
    const state = new session.SearchSession();
    await state.run(() => Promise.resolve(['previous']));
    assert.equal(await state.run(() => dao.searchMediaItems('test', undefined, true)), false);
    assert.equal(state.status, 'error');
    assert.equal(state.results[0], 'previous');
  }
} });
(async () => { for (const t of tests) { await t.fn(); console.log('PASS ' + t.name); } })().catch(e => { console.error(e); process.exitCode = 1; });
