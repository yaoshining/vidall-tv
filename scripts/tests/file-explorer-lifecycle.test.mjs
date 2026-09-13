import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import assert from 'node:assert/strict';
import test from 'node:test';
const root = new URL('../../entry/src/main/ets/components/core/file/', import.meta.url);
const leaseCode = stripTypeScriptTypes(readFileSync(new URL('FileThumbnailLease.ets', root), 'utf8').replace(/^export /gm, ''));
const { FileThumbnailLease: Lease, FileThumbnailSession: Session, FileThumbnailSlots: Slots } = new Function(leaseCode + '\nreturn { FileThumbnailLease, FileThumbnailSession, FileThumbnailSlots };')();
test('独占 lease 只释放一次，不影响相同文件名的其他 lease', () => {
  let first = 0, second = 0;
  const a = new Lease('file:///temp/thumb-a', () => first++);
  const b = new Lease('file:///temp/thumb-b', () => second++);
  a.release(); a.release(); assert.equal(first, 1); assert.equal(second, 0);
  b.release(); assert.equal(second, 1);
});
test('离屏、再入和迟到成功：旧请求释放，当前图片保留', () => {
  const s = new Session(); const released = [];
  const old = s.reset(); s.reset(); const current = s.reset();
  assert.equal(s.accept(current, new Lease('new', () => released.push('new'))), true);
  assert.equal(s.accept(old, new Lease('old', () => released.push('old'))), false);
  assert.deepEqual(released, ['old']); s.reset(); s.reset();
  assert.deepEqual(released, ['old', 'new']);
});
test('切目录/参数变化及卸载使所有旧请求失效', () => {
  const s = new Session(); let released = 0;
  const requests = Array.from({ length: 100 }, () => s.reset()); s.reset();
  for (const id of requests.reverse()) assert.equal(s.accept(id, new Lease('late', () => released++)), false);
  assert.equal(released, 100);
});
test('并发严格限制四个，迟到请求结算前不能重新占用，没有队列', () => {
  for (let i = 0; i < 4; i++) assert.equal(Slots.acquire(), true);
  for (let i = 0; i < 10000; i++) assert.equal(Slots.acquire(), false);
  Slots.release(); assert.equal(Slots.acquire(), true);
  for (let i = 0; i < 4; i++) Slots.release();
});
// 执行真实组件业务方法；只移除 ArkUI build/@Builder 和装饰器，UI、时钟为受控替身。
let component = readFileSync(new URL('FileExplorer.ets', root), 'utf8');
component = component.slice(0, component.indexOf('  @Builder\n  ToolbarButton')) + '\n}';
component = component.replace(/^import .*\n/gm, '').replace('@ComponentV2\nexport struct FileExplorer', 'class FileExplorer')
 .replace(/@Monitor\([^\n]*\)\n/g, '').replace(/@(Param|Require|Event|Local|BuilderParam)\s*/g, '');
const KeyCode = { KEYCODE_DPAD_DOWN: 2013, KEYCODE_DPAD_UP: 2012 };
function harness(n = 100) {
 const timers = new Map(); let seq = 0; const scrolled = [], focused = [];
 class Scroller { scrollToIndex(index) { scrolled.push(index); } }
 const C = new Function('util','Scroller','FileExplorerToastState','FileThumbnailLease','KeyCode','KeyType','ScrollAlign','setTimeout','clearTimeout',
 stripTypeScriptTypes(component) + '\nreturn FileExplorer;')({ generateRandomUUID: () => 'test' },Scroller, class {}, Lease, KeyCode, { Down: 0 }, { AUTO: 0 }, fn => { timers.set(++seq, fn); return seq; }, id => timers.delete(id));
 const c = new C(); c.getUIContext = () => ({ getFocusController: () => ({ requestFocus: key => { focused.push(key); return true; } }) });
 c.controller = { currentPath: '/', sortedResources: Array.from({length:n}, (_,i) => ({key:`k${i}`,path:`/f${i}`,name:`f${i}`})) };
 c.aboutToAppear(); c.focusedKey = 'k0'; c.anchorKey = 'k0';
 return { c, scrolled, focused, timers, flush: () => { for (const [id, fn] of timers) { timers.delete(id); fn(); } } };
}
test('100/1000/10000 项长按只保留一个焦点任务，末尾不越界', () => {
 for (const count of [100,1000,10000]) {
  const h = harness(count);
  for (let i = 1; i < count; i++) h.c.navigate({type:0,keyCode:2013});
  assert.equal(h.timers.size,1); assert.equal(h.c.pendingKey,`k${count-1}`);
  assert.equal(h.c.navigate({type:0,keyCode:2013}),true); h.flush();
  assert.equal(h.focused.at(-1),`explorer-row:test:k${count-1}`);
 }
});
test('排序按 key 恢复；删除焦点项选择邻近项；隐藏过滤跳过禁用项', () => {
 const h = harness(); h.c.focusedKey='k50'; h.c.anchorKey='k50'; h.c.anchorIndex=50;
 h.c.controller.sortedResources.reverse(); h.c.reconcileFocus(); assert.equal(h.c.anchorIndex,49); h.flush();
 h.c.controller.sortedResources=h.c.controller.sortedResources.filter(r=>r.key!=='k50');
 h.c.reconcileFocus(); assert.equal(h.c.anchorKey,'k49'); h.flush();
 h.c.disableResourceClick=r=>r.key==='k48'; h.c.focusedKey='k49';
 h.c.navigate({type:0,keyCode:2013}); assert.equal(h.c.pendingKey,'k47');
});
test('进入和返回目录定位刚离开的子目录；空目录回到返回按钮', () => {
 const h = harness(); h.c.controller.currentPath='/f20'; h.c.controller.sortedResources=[{key:'child',path:'/f20/a'}];
 h.c.reconcileFocus(); h.flush(); assert.equal(h.focused.at(-1),'explorer-row:test:child');
 h.c.controller.currentPath='/'; h.c.controller.sortedResources=[{key:'other',path:'/other'},{key:'parent',path:'/f20'}];
 h.c.reconcileFocus(); h.flush(); assert.equal(h.focused.at(-1),'explorer-row:test:parent');
 h.c.focusedKey='parent'; h.c.controller.sortedResources=[]; h.c.reconcileFocus();
 assert.equal(h.focused.at(-1),'explorer-test:back');
});
test('方向键清除悬停，离开组件取消未完成焦点任务', () => {
 const h=harness(); h.c.hoveredKey='k88'; h.c.navigate({type:0,keyCode:2013});
 assert.equal(h.c.hoveredKey,''); h.c.aboutToDisappear(); assert.equal(h.timers.size,0);
});

function thumbnailHarness() {
 let src = readFileSync(new URL('FileThumbnail.ets', root), 'utf8');
 src = src.slice(0, src.indexOf('  build() {')) + '\n}';
 src = src.replace(/^import .*\n/gm, '').replace('@ComponentV2\nexport struct FileThumbnail','class FileThumbnail')
   .replace(/@Monitor\([^\n]*\)\n/g,'').replace(/@(Param|Require|Local)\s*/g,'');
 const timers=new Map(); let seq=0;
 const T=new Function('FileThumbnailLease','FileThumbnailSession','FileThumbnailSlots','setTimeout','clearTimeout',
   stripTypeScriptTypes(src)+'\nreturn FileThumbnail;')(Lease,Session,Slots,fn=>{timers.set(++seq,fn);return seq},id=>timers.delete(id));
 const c=new T(); c.resource={key:'a',size:1024}; c.aboutToAppear(); c.visible=true;
 return {c,timers};
}
test('真实缩略图组件：旧失败不擦除新成功，旧成功释放，离屏重入重新加载', async () => {
 const {c}=thumbnailHarness(); const requests=[]; const released=[];
 c.loader=()=>new Promise((resolve,reject)=>requests.push({resolve,reject}));
 c.load(); c.reset(); c.load();
 requests[1].resolve(new Lease('new',()=>released.push('new'))); await Promise.resolve();
 requests[0].reject(new Error('late failure')); await Promise.resolve();
 assert.equal(c.source,'new');
 c.reset(); c.load(); c.reset(); c.load();
 requests[2].resolve(new Lease('late',()=>released.push('late')));
 requests[3].resolve(new Lease('current',()=>released.push('current'))); await Promise.resolve();
 assert.equal(c.source,'current'); assert.deepEqual(released,['new','late']);
 c.aboutToDisappear(); assert.deepEqual(released,['new','late','current']);
 c.aboutToAppear(); c.visible=true; c.load(); assert.equal(requests.length,5);
 requests[4].resolve(new Lease('return',()=>released.push('return'))); await Promise.resolve();
 assert.equal(c.source,'return'); c.aboutToDisappear(); assert.equal(released.at(-1),'return');
});
test('真实缩略图组件：同步异常归还槽位；离屏取消唯一的重试定时器', async () => {
 const {c,timers}=thumbnailHarness(); c.loader=()=>{throw new Error('sync')};
 c.load(); await Promise.resolve();
 for(let i=0;i<4;i++) assert.equal(Slots.acquire(),true);
 c.reset(); c.load(); c.load(); assert.equal(timers.size,1);
 c.aboutToDisappear(); assert.equal(timers.size,0);
 for(let i=0;i<4;i++) Slots.release();
});

test('较慢布局不丢弃唯一目标，后续滚动布局事件可恢复焦点', () => {
 const h=harness(); let available=false;
 h.c.getUIContext=()=>({getFocusController:()=>({requestFocus:key=>{
   if(!available) throw new Error('not on tree'); h.focused.push(key);
 }})});
 h.c.requestRow(20); h.flush(); assert.equal(h.timers.size,0); assert.equal(h.c.pendingKey,'k20');
 available=true; h.c.finishFocus(); h.flush(); assert.equal(h.focused.at(-1),'explorer-row:test:k20');
});
for (const page of ['index.ets', 'SmbFileExplorerPage.ets']) {
  test(`${page} 实际 loader：失败清理部分文件，成功移交唯一文件所有权`, async () => {
    const source = readFileSync(new URL('../../entry/src/main/ets/pages/files/' + page, import.meta.url), 'utf8');
    const start = source.indexOf('  private async loadThumbnail(');
    const method = source.slice(start, source.indexOf('\n  }', start) + 4);
    const unlinked = []; let fail = true; let target;
    const P = new Function('fileIo','util','FileThumbnailLease', stripTypeScriptTypes('class Page {\n' + method + '\n}') + '\nreturn Page;')(
      { unlink: async path => { unlinked.push(path); } }, { generateRandomUUID: () => 'unique' }, Lease);
    const p = new P(); p.getUIContext = () => ({ getHostContext: () => ({ tempDir: '/private-temp' }) });
    const download = async (path, dest) => { target = dest; if (fail) throw new Error('partial download'); return dest; };
    p.client = { downloadFileStream: download, downloadFileToLocal: download };
    await assert.rejects(p.loadThumbnail({ path: '/remote/a.png' }), /partial download/);
    assert.deepEqual(unlinked, [target]); unlinked.length = 0; fail = false;
    const lease = await p.loadThumbnail({ path: '/remote/a.png' });
    assert.equal(lease.source, 'file://' + target); assert.deepEqual(unlinked, []);
    lease.release(); lease.release(); assert.deepEqual(unlinked, [target]);
  });
}
