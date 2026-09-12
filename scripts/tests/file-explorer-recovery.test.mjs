// 使用 Node 的 TypeScript 擦除执行真实恢复逻辑，平台数据库用受控替身隔离。
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import assert from 'node:assert/strict';
import test from 'node:test';
const source = readFileSync(new URL('../../entry/src/main/ets/components/core/file/FileExplorerRecovery.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
function harness() {
  const removed = [], clearedDirs = [];
  const db = {
    getVideosBySourceId: async id => {
      assert.equal(id, 7);
      return [{ id: 1, filePath: '/show/a.mkv' }, { id: 2, filePath: '/show/sub/b.mkv' }, { id: 3, filePath: '/show-other/a.mkv' }];
    },
    deleteVideosWithScrapeInfo: async ids => removed.push(...ids),
    getDirectoriesBySourceId: async () => [{ id: 5, directoryPath: '/show' }, { id: 6, directoryPath: '/show-other' }]
  };
  const store = { clearMissingDirectory: async id => clearedDirs.push(id), loadFileSources: async () => {} };
  const api = new Function('FileSourceDatabase', 'FileSourceStore', 'MediaDataVersionStore',
    stripTypeScriptTypes(source) + '\nreturn { FileExplorerRecovery, isExplorerMissingError, isExplorerPathWithin };')(
      { getInstance: () => db }, { getState: () => store }, { getState: () => ({ publish: () => {} }) });
  return { ...api, removed, clearedDirs };
}
const api = harness();
for (const message of ['STATUS_OBJECT_NAME_NOT_FOUND', 'NT_STATUS_OBJECT_PATH_NOT_FOUND', 'OpEN (0xc0000034)', 'HTTP 404', 'no such file or directory']) {
  test(`识别明确缺失：${message}`, () => assert.equal(api.isExplorerMissingError(message), true));
}
for (const message of ['HTTP 401', 'HTTP 403', 'HTTP 500', 'timeout', 'STATUS_ACCESS_DENIED', 'host not found', 'port 4040 unavailable']) {
  test(`不误清理：${message}`, () => assert.equal(api.isExplorerMissingError(message), false));
}
test('目录边界不匹配同名前缀', () => {
  assert.equal(api.isExplorerPathWithin('/show/a', '/show'), true);
  assert.equal(api.isExplorerPathWithin('/show-other/a', '/show'), false);
});
test('文件缺失通过父目录列表核验，网络错误不算缺失', async () => {
  const recovery = new api.FileExplorerRecovery();
  assert.equal(await recovery.isMissing({ list: async () => ({ resources: [] }) }, '/show/a', false), true);
  assert.equal(await recovery.isMissing({ list: async () => ({ resources: [{ path: '/show/a' }] }) }, '/show/a', false), false);
  assert.equal(await recovery.isMissing({ list: async () => ({ resources: [], errorMessage: 'timeout' }) }, '/show/a', false), false);
});
test('取消不写数据库', () => {
  const h = harness();
  new h.FileExplorerRecovery().prompt({}, '/show', true, 7, '/show', (_m, _ok, cancel) => cancel(), () => {}, () => {});
  assert.deepEqual(h.removed, []);
});
test('确认后再次核验，路径恢复时不删除', async () => {
  const h = harness();
  await new Promise(resolve => new h.FileExplorerRecovery().prompt(
    { list: async () => ({ resources: [] }) }, '/show', true, 7, '/show',
    (_m, ok) => ok(), resolve, () => assert.fail('不应清理')));
  assert.deepEqual(h.removed, []);
});
test('清理仅针对目标文件源及目录树', async () => {
  const h = harness();
  await new Promise((resolve, reject) => new h.FileExplorerRecovery().prompt(
    { list: async () => ({ resources: [], errorMessage: 'HTTP 404' }) }, '/show', true, 7, '/show',
    (_m, ok) => ok(), reject, resolve));
  assert.deepEqual(h.removed, [1, 2]);
  assert.deepEqual(h.clearedDirs, [5]);
});
test('单文件清理不影响同目录其他文件或目录配置', async () => {
  const h = harness();
  await new Promise((resolve, reject) => new h.FileExplorerRecovery().prompt(
    { list: async () => ({ resources: [] }) }, '/show/a.mkv', false, 7, '/show/a.mkv',
    (_m, ok) => ok(), reject, resolve));
  assert.deepEqual(h.removed, [1]);
  assert.deepEqual(h.clearedDirs, []);
});
