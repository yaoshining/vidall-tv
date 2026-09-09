// Run with TYPESCRIPT_PATH pointing to the DevEco bundled TypeScript package.
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH || 'typescript');
const tests = [];
const cache = new Map();
const hypium = {
  describe: (_, fn) => fn(), it: (name, _, fn) => tests.push({name, fn}),
  beforeAll() {}, beforeEach() {}, afterEach() {}, afterAll() {},
  expect: value => ({
    assertEqual: expected => assert.equal(value, expected),
    assertTrue: () => assert.equal(value, true), assertFalse: () => assert.equal(value, false),
    assertUndefined: () => assert.equal(value, undefined), assertLarger: expected => assert.ok(value > expected)
  })
};
function load(file) {
  file = path.resolve(file);
  if (cache.has(file)) return cache.get(file);
  const exports = {};
  cache.set(file, exports);
  const source = fs.readFileSync(file, 'utf8');
  const js = ts.transpileModule(source, {compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  }}).outputText;
  const req = name => {
    if (name === '@ohos/hypium') return hypium;
    if (name.endsWith('AppPreferences')) return {AppPreferences: {getNumber: async () => 2}, PrefKey: {}};
    if (name.startsWith('@') || name.includes('/db/')) return {};
    return load(path.resolve(path.dirname(file), name + '.ets'));
  };
  vm.runInNewContext(js, {exports, require: req, setTimeout, clearTimeout, Promise,
    console: {info() {}, warn() {}, error() {}, log() {}}}, {filename: file});
  return exports;
}
load('entry/src/test/ScrapeClient.test.ets').default();
load('entry/src/test/MediaTypeClassifierContract.test.ets').default();
(async () => {
  let failed = 0;
  for (const test of tests) {
    try { await test.fn(); }
    catch (error) { failed++; console.error('FAIL:', test.name, error); }
  }
  console.log(`${tests.length - failed}/${tests.length} scrape regression tests passed`);
  process.exitCode = failed ? 1 : 0;
})();
