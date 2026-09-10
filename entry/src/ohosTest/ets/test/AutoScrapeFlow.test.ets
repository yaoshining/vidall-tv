/** 隔离 RDB + 真实保存/扫描编排/队列；网络枚举与刮削执行使用确定性夹具。 */
import { describe, it, expect, beforeAll, beforeEach, afterAll } from '@ohos/hypium';
import { TestContext } from './TestContext';
import { common } from '@kit.AbilityKit';
import { FileSourceDatabase } from '../../../main/ets/db/files/FileSourceDatabase';
import { FileSourceModel } from '../../../main/ets/stores/files/FileSourceModel';
import { FileSource, FileSourceType, FileSourceDirectory } from '../../../main/ets/db/models/FileSourceEntity';
import { VideoEntity, VideoUpsertResult } from '../../../main/ets/db/models/MediaEntity';
import { AutoScrapeTrigger } from '../../../main/ets/services/scrape/AutoScrapeTrigger';
import { AutoScrapeRetryExecutor } from '../../../main/ets/services/scrape/AutoScrapeRetryExecutor';
import { ScrapeTaskQueue } from '../../../main/ets/services/scrape/ScrapeTaskQueue';
import { ScrapeTaskStore } from '../../../main/ets/services/scrape/ScrapeTaskStore';
import { ScopedScrapeExecutor, ScrapeProgressCallback } from '../../../main/ets/services/scrape/ScopedScrapeService';
import { ScopedScrapeRequest, ScrapeExecutionOutcome, ScrapeProgress, ScrapeTaskSnapshot } from '../../../main/ets/services/scrape/ScopedScrapeTypes';
import { VideoScannerUtil, DirectedUpsertStrategy, ScanDirectoriesDeps, DirectedAdapterBundle } from '../../../main/ets/utils/VideoScannerUtil';
import { VideoUpsertWithResultProvider, ISourceAdapter, VideoFileInfo, ScanOptions } from '../../../main/ets/utils/VideoScannerTypes';
import { getTestParameter, readTestParameter } from './TestParameters';

class FixtureProvider implements VideoUpsertWithResultProvider {
  failPath: string = '';
  private db: FileSourceDatabase;
  constructor(db: FileSourceDatabase) { this.db = db; }
  async upsertVideoWithResult(entity: VideoEntity): Promise<VideoUpsertResult> {
    if (entity.filePath === this.failPath) { throw new Error('夹具入库失败'); }
    return this.db.upsertVideoWithResult(entity);
  }
}

class FixtureAdapter implements ISourceAdapter {
  private deps: FixtureScanDeps;
  private strategy: DirectedUpsertStrategy;
  private sourceId: number;
  constructor(deps: FixtureScanDeps, strategy: DirectedUpsertStrategy, sourceId: number) {
    this.deps = deps; this.strategy = strategy; this.sourceId = sourceId;
  }
  async scan(path: string, options: ScanOptions): Promise<VideoFileInfo[]> {
    this.deps.scannedPaths.push(path);
    if (this.deps.failedPaths.includes(path)) { throw new Error('夹具目录不可达'); }
    for (const file of this.deps.files.get(path) ?? []) {
      const entity: VideoEntity = {
        sourceId: this.sourceId, directoryPath: path, filePath: file, fileName: file.split('/').pop() ?? 'video.mkv', scannedAt: Date.now()
      };
      try { await this.strategy.upsert(entity); } catch { /* 与生产适配器相同，由 strategy 汇总 DB 错误。 */ }
    }
    return [];
  }
}

class FixtureScanDeps implements ScanDirectoriesDeps {
  files: Map<string, string[]> = new Map();
  failedPaths: string[] = [];
  scannedPaths: string[] = [];
  provider: FixtureProvider;
  private db: FileSourceDatabase;
  constructor(db: FileSourceDatabase) { this.db = db; this.provider = new FixtureProvider(db); }
  async init(): Promise<void> { await this.db.init(); }
  async getFileSourceById(id: number): Promise<FileSource | null> { return this.db.getFileSourceById(id); }
  createDirectedAdapter(source: FileSource): DirectedAdapterBundle {
    const strategy = new DirectedUpsertStrategy(this.provider);
    return { strategy: strategy, adapter: new FixtureAdapter(this, strategy, source.id ?? 0) };
  }
}

class FixtureScraper implements ScopedScrapeExecutor {
  ids: number[] = [];
  phases: string[] = [];
  async execute(request: ScopedScrapeRequest, onProgress: ScrapeProgressCallback): Promise<ScrapeExecutionOutcome> {
    const ids = request.videoIds ?? [];
    this.ids.push(...ids);
    const progress: ScrapeProgress = { total: ids.length, completed: 0, succeeded: 0, failed: 0, cancelled: 0 };
    this.phases.push('preparing'); onProgress(progress, 'preparing');
    this.phases.push('scraping'); onProgress(progress, 'scraping');
    return { kind: 'completed', result: { total: ids.length, succeeded: ids.length, failed: 0, cancelled: 0,
      succeededVideoIds: ids.slice(), failedVideoIds: [], failedItems: [] } };
  }
}

async function waitForTerminal(beforeIds: string[]): Promise<ScrapeTaskSnapshot> {
  for (let i = 0; i < 100; i++) {
    const found = ScrapeTaskStore.getState().getTasks().find((task: ScrapeTaskSnapshot): boolean =>
      !beforeIds.includes(task.id) && ['completed', 'failed', 'partial-failure'].includes(task.status));
    if (found !== undefined) { return found; }
    await new Promise<void>((resolve: () => void) => setTimeout(resolve, 20));
  }
  throw new Error('自动任务没有进入终态');
}

export default function autoScrapeFlowTest() {
  // 在注册阶段跳过，不能用 expect(true) 冒充业务通过。
  if (getTestParameter('SKIP_SCAN_TESTS', 'false') === 'true') {
    console.info('[AutoScrapeFlow] SKIP_SCAN_TESTS=true：未注册集成用例');
    return;
  }
  describe('自动刮削新增目录流程集成测试', () => {
    let db: FileSourceDatabase;
    let model: FileSourceModel;
    let deps: FixtureScanDeps;
    let scraper: FixtureScraper;
    let queue: ScrapeTaskQueue;
    let sourceId: number = 0;
    let context: common.Context;
    let previousTasks: ScrapeTaskSnapshot[] = [];

    beforeAll(async () => {
      context = TestContext.require();
      previousTasks = ScrapeTaskStore.getState().getTasks();
      FileSourceDatabase.setDatabaseNameForTesting(`AUTO_SCRAPE_FLOW_${Date.now()}`);
      db = FileSourceDatabase.getInstance(context);
      await db.init();
      AutoScrapeTrigger.getInstance().setContext(context);
    });
    beforeEach(async () => {
      sourceId = await db.insertFileSource({ name: '自动刮削测试源', type: FileSourceType.WEBDAV,
        configJson: '{}', createdAt: Date.now() });
      model = new FileSourceModel();
      await model.loadFileSources(true);
      deps = new FixtureScanDeps(db);
      scraper = new FixtureScraper();
      queue = new ScrapeTaskQueue(scraper, 1);
      ScrapeTaskStore.getState().update([]);
      AutoScrapeTrigger.getInstance().setTestDependencies(queue,
        (_context: common.Context, id: number, paths: string[], options?: Partial<ScanOptions>) =>
          VideoScannerUtil.scanDirectoriesWithDeps(deps, id, paths, options));
    });
    afterAll(async () => {
      AutoScrapeTrigger.getInstance().setTestDependencies();
      ScrapeTaskStore.getState().update(previousTasks);
      FileSourceDatabase.setDatabaseNameForTesting(null);
      await FileSourceDatabase.getInstance(context).init();
    });

    const save = async (paths: string[]): Promise<ScrapeTaskSnapshot> => {
      const before = ScrapeTaskStore.getState().getTasks().map((t: ScrapeTaskSnapshot): string => t.id);
      const dirs: FileSourceDirectory[] = paths.map((path: string): FileSourceDirectory => ({ sourceId: sourceId, directoryPath: path }));
      const event = await model.saveDirectoriesWithCleanup(sourceId, dirs);
      expect(event !== null).assertTrue();
      return waitForTerminal(before);
    }

    it('新增目录保存后自动入队并完成首次入库刮削', 0, async () => {
      deps.files.set('/new', ['/new/a.mkv']);
      const task = await save(['/new']);
      expect(task.status).assertEqual('completed');
      expect(task.request.videoIds?.length).assertEqual(1);
      expect(scraper.ids.length).assertEqual(1);
      expect(scraper.phases.join(',')).assertEqual('preparing,scraping');
      expect(deps.scannedPaths.join(',')).assertEqual('/new');
      expect(task.request.candidateStrategy).assertEqual('automatic');
    });

    it('已有父目录视频新增子目录时零目标完成', 0, async () => {
      await db.insertDirectories(sourceId, [{ sourceId: sourceId, directoryPath: '/parent' }]);
      await db.upsertVideo({ sourceId: sourceId, directoryPath: '/parent', filePath: '/parent/sub/a.mkv',
        fileName: 'a.mkv', scannedAt: Date.now() });
      deps.files.set('/parent/sub', ['/parent/sub/a.mkv']);
      const task = await save(['/parent', '/parent/sub']);
      expect(task.status).assertEqual('completed');
      expect(task.result?.total).assertEqual(0);
      expect(deps.scannedPaths.join(',')).assertEqual('/parent/sub');
      if (task.request.scope.kind === 'folder') {
        expect(task.request.scope.directoryPaths?.join(',')).assertEqual('/parent/sub');
      } else { expect(false).assertTrue(); }
    });

    it('全部失败保留错误原因且重试原始范围', 0, async () => {
      deps.failedPaths = ['/a', '/b'];
      const task = await save(['/a', '/b']);
      expect(task.status).assertEqual('failed');
      expect(task.result?.directedScanContext?.failures?.length).assertEqual(2);
      expect(task.result?.directedScanContext?.failures?.[0].message).assertEqual('夹具目录不可达');
      deps.failedPaths = [];
      deps.scannedPaths = [];
      expect(await AutoScrapeRetryExecutor.getInstance().retry(task.id)).assertTrue();
      const retried = await waitForTerminal([task.id]);
      expect(retried.status).assertEqual('completed');
      expect(deps.scannedPaths.join(',')).assertEqual('/a,/b');
    });

    it('部分失败只重扫失败目录且成功视频仅处理一次', 0, async () => {
      deps.files.set('/ok', ['/ok/a.mkv']);
      deps.files.set('/bad', ['/bad/b.mkv']);
      deps.failedPaths = ['/bad'];
      const task = await save(['/ok', '/bad']);
      expect(task.status).assertEqual('partial-failure');
      expect(task.result?.succeeded).assertEqual(1);
      deps.failedPaths = [];
      deps.scannedPaths = [];
      expect(await AutoScrapeRetryExecutor.getInstance().retry(task.id)).assertTrue();
      const retried = await waitForTerminal([task.id]);
      expect(retried.status).assertEqual('completed');
      expect(deps.scannedPaths.join(',')).assertEqual('/bad');
      expect(scraper.ids.length).assertEqual(2);
      expect(new Set<number>(scraper.ids).size).assertEqual(2);
    });

    it('同目录部分入库失败时成功ID不丢失且重试不重复刮削', 0, async () => {
      deps.files.set('/mixed', ['/mixed/a.mkv', '/mixed/b.mkv']);
      deps.provider.failPath = '/mixed/b.mkv';
      const task = await save(['/mixed']);
      expect(task.status).assertEqual('partial-failure');
      expect(task.result?.succeeded).assertEqual(1);
      deps.provider.failPath = '';
      expect(await AutoScrapeRetryExecutor.getInstance().retry(task.id)).assertTrue();
      const retried = await waitForTerminal([task.id]);
      expect(retried.status).assertEqual('completed');
      expect(scraper.ids.length).assertEqual(2);
      expect(new Set<number>(scraper.ids).size).assertEqual(2);
    });

    it('零目标部分扫描失败不能显示完成', 0, async () => {
      deps.failedPaths = ['/bad'];
      const task = await save(['/empty', '/bad']);
      expect(task.status).assertEqual('partial-failure');
      expect(task.result?.total).assertEqual(0);
    });

    it('仅修改别名不发事件不新增任务', 0, async () => {
      await save(['/alias']);
      const count = ScrapeTaskStore.getState().getTasks().length;
      const event = await model.saveDirectoriesWithCleanup(sourceId,
        [{ sourceId: sourceId, directoryPath: '/alias', customName: '新别名' }]);
      expect(event === null).assertTrue();
      expect(ScrapeTaskStore.getState().getTasks().length).assertEqual(count);
    });

    it('扫描任务取消后忽略就绪和目标写入', 0, async () => {
      AutoScrapeTrigger.getInstance().setTestDependencies(queue,
        async (_context: common.Context, id: number, paths: string[], options?: Partial<ScanOptions>) => {
          const task = ScrapeTaskStore.getState().getTasks()[0];
          expect(task.phase).assertEqual('scanning');
          expect(queue.cancel(task.id)).assertTrue();
          return { succeededDirectories: paths, failedDirectories: [], newlyInsertedVideoIds: [999], totalFilesScanned: 1 };
        });
      await AutoScrapeTrigger.getInstance().startScanTask(sourceId, ['/cancel'], '取消测试');
      const task = ScrapeTaskStore.getState().getTasks()[0];
      expect(task.status).assertEqual('cancelled');
      expect(task.request.videoIds === undefined).assertTrue();
      expect(scraper.ids.length).assertEqual(0);
    });

    it('测试参数同时读取裸键和 aa 前缀键', 0, () => {
      expect(readTestParameter({ 'SKIP_SCAN_TESTS': 'true' }, 'SKIP_SCAN_TESTS', 'false')).assertEqual('true');
      expect(readTestParameter({ '-s SKIP_SCAN_TESTS': 'true' }, 'SKIP_SCAN_TESTS', 'false')).assertEqual('true');
      expect(readTestParameter({ '-s TEST_AUTO_SCRAPE_SOURCE_ID': '42' }, 'TEST_AUTO_SCRAPE_SOURCE_ID', '0')).assertEqual('42');
      expect(readTestParameter({}, 'missing', 'fallback')).assertEqual('fallback');
    });
  });
}
