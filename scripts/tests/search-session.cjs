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
const { MediaQueryDao, MediaSearchError, MediaSearchErrorCode } = compile('entry/src/main/ets/db/files/MediaQueryDao.ets', () => ({}));
tests.push({ name: '数据库传播 Error 子类、稳定兜底码和底层 code，消息不含私密信息', fn: async () => {
  const cases = [
    { ready: false, expectedCode: MediaSearchErrorCode.DatabaseNotReady, message: '搜索数据库尚未就绪' },
    { ready: true, expectedCode: MediaSearchErrorCode.QueryFailed, message: '搜索数据库查询失败' },
    { ready: true, code: 14800014, expectedCode: 14800014, message: '搜索数据库查询失败' }
  ];
  assert.notEqual(MediaSearchErrorCode.DatabaseNotReady, MediaSearchErrorCode.QueryFailed);
  for (const scenario of cases) {
    let storeAccesses = 0;
    const dao = new MediaQueryDao({
      isReady: () => scenario.ready,
      getStore: () => {
        storeAccesses++;
        return { querySql: async () => {
          const error = new Error('private-url');
          if (scenario.code !== undefined) { error.code = scenario.code; }
          throw error;
        } };
      }
    });
    assert.equal((await dao.searchMediaItems('test')).length, 0);
    assert.equal((await dao.searchMediaItems('test', undefined, false)).length, 0);
    await assert.rejects(() => dao.searchMediaItems('test', undefined, true), error => {
      assert.ok(error instanceof Error);
      assert.ok(error instanceof MediaSearchError);
      assert.equal(error.code, scenario.expectedCode);
      assert.equal(error.message, scenario.message);
      assert.equal(error.message.includes('private-url'), false);
      return true;
    });
    if (!scenario.ready) { assert.equal(storeAccesses, 0); }
  }
} });
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
