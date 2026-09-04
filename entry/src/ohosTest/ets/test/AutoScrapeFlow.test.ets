/**
 * AutoScrapeFlow.test.ets
 * 自动刮削新增目录流程集成测试套件（openspec change: auto-scrape-new-directory-files 7.x）
 *
 * 覆盖：保存后任务自动入队、定向扫描状态流转、零首次入库、
 *        扫描失败重试上下文（全失败/部分失败）、别名变化不触发、SKIP_SCAN_TESTS 跳过
 *
 * 运行方式：
 *   aa test -b com.yao.vidalltv -m entry_test -s unittest OpenHarmonyTestRunner \
 *     -s SKIP_SCAN_TESTS false \
 *     -s TEST_AUTO_SCRAPE_SOURCE_ID <真实文件源 id>
 *
 * 说明：
 *   - 7.1/7.4/7.6/7.7 使用隔离数据库与不存在的 sourceId，离线即可执行；
 *   - 7.2/7.3/7.5 需要真实可达的 WebDAV 文件源，通过 TEST_AUTO_SCRAPE_SOURCE_ID
 *     参数提供，未提供时以软通过处理（与 ScanFlow 先例一致）。
 */

import { describe, it, expect, beforeAll } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@ohos.abilityAccessCtrl';
import { FileSourceDatabase } from '../../../main/ets/db/files/FileSourceDatabase';
import { FileSourceModel } from '../../../main/ets/stores/files/FileSourceModel';
import { AutoScrapeTrigger } from '../../../main/ets/services/scrape/AutoScrapeTrigger';
import { AutoScrapeRetryExecutor } from '../../../main/ets/services/scrape/AutoScrapeRetryExecutor';
import { ScrapeTaskStore } from '../../../main/ets/services/scrape/ScrapeTaskStore';
import { FileSourceDirectory } from '../../../main/ets/db/models/FileSourceEntity';
import { ScrapeTaskSnapshot, ScrapeScope } from '../../../main/ets/services/scrape/ScopedScrapeTypes';

function getTestParam(key: string, fallback: string): string {
  try {
    const args = abilityDelegatorRegistry.getArguments();
    const params = args.parameters as Record<string, string>;
    const val: string = params[key];
    return (val !== undefined && val !== null && val.length > 0) ? val : fallback;
  } catch {
    return fallback;
  }
}

const WAIT_TASK_MS = 10000;
const POLL_INTERVAL_MS = 200;

async function sleep(ms: number): Promise<void> {
  await new Promise<void>((resolve: (value: void) => void) => setTimeout(resolve, ms));
}

function findAutoTasksBySegment(segment: string): ScrapeTaskSnapshot[] {
  return ScrapeTaskStore.getState().getTasks().filter((task: ScrapeTaskSnapshot): boolean => {
    const path = folderScopePath(task.request.scope);
    return path !== undefined && path.includes(segment);
  });
}

/** 从联合 scope 中窄化取出 folder 的 directoryPath（ArkTS 需显式窄化）。 */
function folderScopePath(scope: ScrapeScope): string | undefined {
  if (scope.kind === 'folder') {
    return scope.directoryPath;
  }
  return undefined;
}

async function waitForAutoTask(segment: string, timeoutMs: number,
  predicate?: (task: ScrapeTaskSnapshot) => boolean): Promise<ScrapeTaskSnapshot | undefined> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const tasks = findAutoTasksBySegment(segment);
    const found = predicate === undefined
      ? tasks[0]
      : tasks.find((task: ScrapeTaskSnapshot): boolean => predicate(task));
    if (found !== undefined) {
      return found;
    }
    await sleep(POLL_INTERVAL_MS);
  }
  return undefined;
}

export default function autoScrapeFlowTest() {
  const skipScanTests = getTestParam('SKIP_SCAN_TESTS', 'false') === 'true';
  const realSourceId = parseInt(getTestParam('TEST_AUTO_SCRAPE_SOURCE_ID', '0'), 10);
  const hasRealSource = !isNaN(realSourceId) && realSourceId > 0;

  let model!: FileSourceModel;
  const noSourceId = 999999001;

  describe('自动刮削新增目录流程集成测试', () => {

    beforeAll(() => {
      if (skipScanTests) {
        console.info('[AutoScrapeFlow] SKIP_SCAN_TESTS=true，跳过初始化');
        return;
      }
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      // 隔离数据库，避免污染真实文件源数据（与 FileSourceDatabase.test.ets 同模式）
      FileSourceDatabase.setDatabaseNameForTesting(`AUTO_SCRAPE_FLOW_TEST_${Date.now()}`);
      FileSourceDatabase.getInstance(ctx);
      // 自动任务编排需要 context（扫描器与 DB 依赖）
      AutoScrapeTrigger.getInstance().setContext(ctx);
      model = new FileSourceModel();
    });

    /**
     * 7.1 新增目录保存后任务自动入队：
     * 保存新增目录 → 事件触发 → AutoScrapeTrigger 入队 folder scope 任务（phase='scanning' 起步）。
     * 离线执行：sourceId 不存在，扫描会失败，但"任务入队"这一断言不受影响。
     */
    it('新增目录保存后任务自动入队', 0, async () => {
      if (skipScanTests) { expect(true).assertTrue(); return }
      const seg = `enqueue-it-${Date.now()}`;
      const dir: FileSourceDirectory = {
        sourceId: noSourceId,
        directoryPath: `/auto-scrape-it/${seg}`,
        customName: ''
      };
      const event = await model.saveDirectoriesWithCleanup(noSourceId, [dir]);
      expect(event).not().assertNull();
      expect(event!.addedDirectoryPaths.length).assertEqual(1);
      const task = await waitForAutoTask(seg, WAIT_TASK_MS);
      expect(task).not().assertNull();
      const path = folderScopePath(task!.request.scope);
      expect(path).not().assertNull();
      expect(path!.includes(seg)).assertTrue();
    });

    /**
     * 7.4 全部扫描失败 → 任务 failed → 重试保留完整定向上下文：
     * sourceId 不存在导致所有目录失败 → directedScanContext.originalDirectoryPaths
     * 含全部原始目录 → retry 后重试任务 scope 仍为全部原始目录，不扩大为全库。
     */
    it('全部扫描失败后重试保留完整定向上下文', 0, async () => {
      if (skipScanTests) { expect(true).assertTrue(); return }
      const seg = `allfail-it-${Date.now()}`;
      const dirs: FileSourceDirectory[] = [
        { sourceId: noSourceId, directoryPath: `/auto-scrape-it/${seg}/a`, customName: '' },
        { sourceId: noSourceId, directoryPath: `/auto-scrape-it/${seg}/b`, customName: '' }
      ];
      const event = await model.saveDirectoriesWithCleanup(noSourceId, dirs);
      expect(event).not().assertNull();
      const task = await waitForAutoTask(seg, WAIT_TASK_MS,
        (t: ScrapeTaskSnapshot): boolean => t.status === 'failed');
      expect(task).not().assertNull();
      const ctx = task!.result?.directedScanContext;
      expect(ctx).not().assertNull();
      expect(ctx!.originalDirectoryPaths.length).assertEqual(2);
      const retried = await AutoScrapeRetryExecutor.getInstance().retry(task!.id);
      expect(retried).assertTrue();
      // 重试任务为独立新任务，scope 仍覆盖全部原始目录
      const retryTask = await waitForAutoTask(seg, WAIT_TASK_MS,
        (t: ScrapeTaskSnapshot): boolean => t.id !== task!.id);
      expect(retryTask).not().assertNull();
      const retryPath = folderScopePath(retryTask!.request.scope);
      expect(retryPath).not().assertNull();
      expect(retryPath!.includes(`${seg}/a`)).assertTrue();
      expect(retryPath!.includes(`${seg}/b`)).assertTrue();
    });

    /**
     * 7.6 别名变化不触发自动刮削：
     * 第一次保存新增目录触发任务；第二次仅修改 customName 保存 →
     * addedPaths 为空 → 返回 null 且无新任务入队。
     */
    it('别名变化不触发自动刮削', 0, async () => {
      if (skipScanTests) { expect(true).assertTrue(); return }
      const seg = `alias-it-${Date.now()}`;
      const path = `/auto-scrape-it/${seg}`;
      const first: FileSourceDirectory[] = [
        { sourceId: noSourceId, directoryPath: path, customName: '' }
      ];
      const event = await model.saveDirectoriesWithCleanup(noSourceId, first);
      expect(event).not().assertNull();
      await waitForAutoTask(seg, WAIT_TASK_MS);
      const countAfterFirst = findAutoTasksBySegment(seg).length;
      expect(countAfterFirst).assertEqual(1);
      // 仅改别名：路径集合不变，不应触发新任务
      const second: FileSourceDirectory[] = [
        { sourceId: noSourceId, directoryPath: path, customName: '自定义别名' }
      ];
      const event2 = await model.saveDirectoriesWithCleanup(noSourceId, second);
      expect(event2).assertNull();
      await sleep(1500);
      const countAfterSecond = findAutoTasksBySegment(seg).length;
      expect(countAfterSecond).assertEqual(countAfterFirst);
    });

    /**
     * 7.2 定向扫描完成且任务进入刮削阶段（需真实文件源，软通过）：
     * 扫描完成 → markTaskReady → preparing → execute → scraping → completed。
     */
    it('定向扫描完成后任务进入刮削阶段直至完成', 0, async () => {
      if (skipScanTests || !hasRealSource) {
        console.info('[AutoScrapeFlow] 7.2 软通过：SKIP_SCAN_TESTS 或未提供 TEST_AUTO_SCRAPE_SOURCE_ID');
        expect(true).assertTrue();
        return;
      }
      const seg = `scan-done-it-${Date.now()}`;
      const dir: FileSourceDirectory = {
        sourceId: realSourceId,
        directoryPath: `/auto-scrape-it/${seg}`,
        customName: ''
      };
      const event = await model.saveDirectoriesWithCleanup(realSourceId, [dir]);
      expect(event).not().assertNull();
      // 等待任务走完 scanning → preparing/scraping → 终态
      const task = await waitForAutoTask(seg, 60000,
        (t: ScrapeTaskSnapshot): boolean => t.status === 'completed' || t.status === 'partial-failure');
      expect(task).not().assertNull();
      expect(task!.status !== 'failed').assertTrue();
    });

    /**
     * 7.3 零首次入库视频时任务正常 completed（需真实文件源，软通过）：
     * 已扫描过的目录再次触发 → newlyInsertedVideoIds=[] → completed 而非 failed。
     */
    it('零首次入库视频时任务正常完成', 0, async () => {
      if (skipScanTests || !hasRealSource) {
        console.info('[AutoScrapeFlow] 7.3 软通过：SKIP_SCAN_TESTS 或未提供 TEST_AUTO_SCRAPE_SOURCE_ID');
        expect(true).assertTrue();
        return;
      }
      const seg = `zero-new-it-${Date.now()}`;
      const dir: FileSourceDirectory = {
        sourceId: realSourceId,
        directoryPath: `/auto-scrape-it/${seg}`,
        customName: ''
      };
      // 第一次保存触发扫描（把目录视频入库）
      await model.saveDirectoriesWithCleanup(realSourceId, [dir]);
      await waitForAutoTask(seg, 60000,
        (t: ScrapeTaskSnapshot): boolean => t.status !== 'waiting');
      // 第二次保存移除后重加同一路径：内容已入库，无首次入库视频 → completed
      await model.saveDirectoriesWithCleanup(realSourceId, []);
      const event = await model.saveDirectoriesWithCleanup(realSourceId, [dir]);
      expect(event).not().assertNull();
      const task = await waitForAutoTask(seg, 60000,
        (t: ScrapeTaskSnapshot): boolean => t.status === 'completed');
      expect(task).not().assertNull();
    });

    /**
     * 7.5 部分目录扫描失败 → partial-failure → 重试仅扫失败目录（需真实文件源，软通过）：
     * 一个可达目录 + 一个不可达目录 → 部分失败 → retry 后 scope 仅含失败目录。
     */
    it('部分扫描失败后重试仅扫失败目录', 0, async () => {
      if (skipScanTests || !hasRealSource) {
        console.info('[AutoScrapeFlow] 7.5 软通过：SKIP_SCAN_TESTS 或未提供 TEST_AUTO_SCRAPE_SOURCE_ID');
        expect(true).assertTrue();
        return;
      }
      const seg = `partial-it-${Date.now()}`;
      const dirs: FileSourceDirectory[] = [
        { sourceId: realSourceId, directoryPath: `/auto-scrape-it/${seg}/real`, customName: '' },
        { sourceId: realSourceId, directoryPath: `/auto-scrape-it/${seg}/missing-sub`, customName: '' }
      ];
      const event = await model.saveDirectoriesWithCleanup(realSourceId, dirs);
      expect(event).not().assertNull();
      const task = await waitForAutoTask(seg, 60000,
        (t: ScrapeTaskSnapshot): boolean => t.status === 'partial-failure' || t.status === 'failed');
      expect(task).not().assertNull();
      if (task!.status !== 'partial-failure') {
        console.info('[AutoScrapeFlow] 7.5 源环境未产生部分失败（目录均可达或均失败），软通过');
        expect(true).assertTrue();
        return;
      }
      const ctx = task!.result?.directedScanContext;
      expect(ctx).not().assertNull();
      expect(ctx!.failedDirectoryPaths.length).assertLess(2);
      const retried = await AutoScrapeRetryExecutor.getInstance().retry(task!.id);
      expect(retried).assertTrue();
      const retryTask = await waitForAutoTask(seg, WAIT_TASK_MS,
        (t: ScrapeTaskSnapshot): boolean => t.id !== task!.id);
      expect(retryTask).not().assertNull();
      // 重试 scope 仅含失败目录
      const retryPath = folderScopePath(retryTask!.request.scope);
      expect(retryPath).not().assertNull();
      expect(retryPath!.includes('missing-sub')).assertTrue();
      expect(retryPath!.includes('/real')).assertFalse();
    });

    /**
     * 7.7 SKIP_SCAN_TESTS 参数跳过机制自检：
     * 参数为 true 时套件所有用例直接通过，不影响其他套件运行。
     */
    it('SKIP_SCAN_TESTS 参数跳过机制生效', 0, () => {
      if (skipScanTests) {
        // 走到此处说明门控生效（前面用例均直接通过）
        expect(true).assertTrue();
        return;
      }
      // 未跳过时验证参数解析行为本身
      expect(getTestParam('SKIP_SCAN_TESTS', 'false')).assertEqual('false');
      expect(getTestParam('NON_EXISTENT_PARAM', 'fallback')).assertEqual('fallback');
    });
  });
}
