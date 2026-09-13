const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../entry/src/test/ci/StructuredReport.js'), 'utf8')
  .replace(/^import .*;\n/gm, '').replaceAll('export ', '') + '\nStructuredReport';
function setup() {
  let output;
  const fileSystem = {
    accessSync: () => true,
    readSync: (_, buffer) => {
      const bytes = Buffer.from(JSON.stringify({ run_id: '1-1', commit_sha: 'abc', started_at: 1 }));
      new Uint8Array(buffer).set(bytes); return bytes.length;
    },
    openSync: () => ({ fd: 1 }), writeSync: (_, text) => { output = JSON.parse(text); },
    fsyncSync() {}, closeSync() {}, OpenMode: { CREATE: 1, READ_WRITE: 2, TRUNC: 4 }
  };
  const context = vm.createContext({ fs: fileSystem, __testMode__: 'unitTest', __savePath__: '/tmp/js_coverage.json' });
  const Report = vm.runInContext(source, context);
  const report = new Report();
  const spec = { getTestTotal: () => 1, currentRunningSpec: null };
  const summary = { total: 1, pass: 1, failure: 0, error: 0, ignore: 0 };
  const suite = { currentRunningSuite: {}, getCurrentRunningSuiteDesc: () => 'suite', getSummary: () => summary };
  const subscriptions = [];
  report.init({ getDefaultService: name => name === 'spec' ? spec : suite, subscribeEvent: name => subscriptions.push(name) });
  report.taskStart();
  return { report, spec, suite, summary, fileSystem, output: () => output, subscriptions };
}
test('逐例状态来自框架，中文和看似时间尾部的名称保持原样', () => {
  for (const [state, status] of [[{}, 'passed'], [{ fail: {} }, 'failed'], [{ error: {} }, 'broken'], [{ isSkip: true }, 'skipped']]) {
    const t = setup();
    assert.deepEqual(t.subscriptions, ['spec', 'suite', 'task']);
    t.spec.currentRunningSpec = { description: '用例20:22.55', ...state };
    t.report.specStart(); t.report.specDone(); t.report.taskDone();
    assert.equal(t.output().cases[0].status, status);
    assert.equal(t.output().cases[0].name, '用例20:22.55');
    assert.equal(t.output().run_id, '1-1');
  }
});
test('缺少、重复或错配完成记录不能落盘', () => {
  for (const scenario of ['missing', 'duplicate-start', 'duplicate-end', 'wrong-end']) {
    const t = setup(); t.spec.currentRunningSpec = { description: 'one' }; t.report.specStart();
    if (scenario === 'missing') assert.throws(() => t.report.taskDone());
    if (scenario === 'duplicate-start') assert.throws(() => t.report.specStart());
    if (scenario === 'duplicate-end') { t.report.specDone(); assert.throws(() => t.report.specDone()); }
    if (scenario === 'wrong-end') { t.spec.currentRunningSpec = { description: 'other' }; assert.throws(() => t.report.specDone()); }
    assert.equal(t.output(), undefined);
  }
});
test('hook 错误保留，文件写入失败不伪造完成', () => {
  const t = setup(); t.suite.currentRunningSuite.hookError = new Error('beforeAll failed');
  t.report.suiteDone(); t.report.taskDone();
  assert.equal(t.output().hook_errors[0], 'beforeAll failed');
  let closed = false;
  t.fileSystem.writeSync = () => { throw new Error('disk full'); };
  t.fileSystem.closeSync = () => { closed = true; };
  assert.throws(() => t.report.taskDone(), /disk full/);
  assert.equal(closed, true);
});
