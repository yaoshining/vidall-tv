import { describe, it, expect } from '@ohos/hypium';
import { VideoEntity, VideoUpsertResult } from '../main/ets/db/models/MediaEntity';
import { VideoUpsertWithResultProvider, VideoUpsertStrategy, ISourceAdapter, VideoFileInfo, ScanOptions, ErrorInfo, DirectedScanResult } from '../main/ets/utils/VideoScannerTypes';
import { DirectedUpsertStrategy, VideoScannerUtil, ScanDirectoriesDeps, DirectedAdapterBundle } from '../main/ets/utils/VideoScannerUtil';
import { FileSourceType, FileSource } from '../main/ets/db/models/FileSourceEntity';

class InMemoryUpsertProvider implements VideoUpsertWithResultProvider {
  private videos: Map<string, VideoEntity> = new Map<string, VideoEntity>();
  private nextId: number = 1;
  public callCount: number = 0;

  async upsertVideoWithResult(entity: VideoEntity): Promise<VideoUpsertResult> {
    this.callCount++;
    const existing: VideoEntity | undefined = this.videos.get(entity.filePath);
    if (existing !== undefined && existing.id !== undefined) {
      const updated: VideoEntity = {
        id: existing.id,
        sourceId: entity.sourceId,
        directoryPath: entity.directoryPath,
        filePath: entity.filePath,
        fileName: entity.fileName,
        fileSize: entity.fileSize,
        lastModified: entity.lastModified,
        contentType: entity.contentType,
        durationMs: entity.durationMs,
        width: entity.width,
        height: entity.height,
        frameRate: entity.frameRate,
        videoCodec: entity.videoCodec,
        audioTracksJson: entity.audioTracksJson,
        subtitleTracksJson: entity.subtitleTracksJson,
        updatedInLastScan: 1,
        scannedAt: entity.scannedAt
      };
      this.videos.set(entity.filePath, updated);
      const result: VideoUpsertResult = { id: existing.id, wasNewlyInserted: false };
      return result;
    }
    const id: number = this.nextId++;
    const stored: VideoEntity = {
      id: id,
      sourceId: entity.sourceId,
      directoryPath: entity.directoryPath,
      filePath: entity.filePath,
      fileName: entity.fileName,
      fileSize: entity.fileSize,
      lastModified: entity.lastModified,
      contentType: entity.contentType,
      durationMs: entity.durationMs,
      width: entity.width,
      height: entity.height,
      frameRate: entity.frameRate,
      videoCodec: entity.videoCodec,
      audioTracksJson: entity.audioTracksJson,
      subtitleTracksJson: entity.subtitleTracksJson,
      updatedInLastScan: 1,
      scannedAt: entity.scannedAt
    };
    this.videos.set(entity.filePath, stored);
    const result: VideoUpsertResult = { id: id, wasNewlyInserted: true };
    return result;
  }
}

class FailingUpsertProvider implements VideoUpsertWithResultProvider {
  public callCount: number = 0;

  async upsertVideoWithResult(_entity: VideoEntity): Promise<VideoUpsertResult> {
    this.callCount++;
    throw new Error('DB write failed');
  }
}

class PartialFailingUpsertProvider implements VideoUpsertWithResultProvider {
  private failPaths: Set<string> = new Set<string>();
  private videos: Map<string, VideoEntity> = new Map<string, VideoEntity>();
  private nextId: number = 1;
  public callCount: number = 0;

  constructor(failPaths: string[]) {
    for (const p of failPaths) {
      this.failPaths.add(p);
    }
  }

  async upsertVideoWithResult(entity: VideoEntity): Promise<VideoUpsertResult> {
    this.callCount++;
    if (this.failPaths.has(entity.filePath)) {
      throw new Error('DB write failed for ' + entity.filePath);
    }
    const existing: VideoEntity | undefined = this.videos.get(entity.filePath);
    if (existing !== undefined && existing.id !== undefined) {
      const result: VideoUpsertResult = { id: existing.id, wasNewlyInserted: false };
      return result;
    }
    const id: number = this.nextId++;
    this.videos.set(entity.filePath, {
      id: id,
      sourceId: entity.sourceId,
      directoryPath: entity.directoryPath,
      filePath: entity.filePath,
      fileName: entity.fileName,
      fileSize: entity.fileSize,
      lastModified: entity.lastModified,
      contentType: entity.contentType,
      durationMs: entity.durationMs,
      width: entity.width,
      height: entity.height,
      frameRate: entity.frameRate,
      videoCodec: entity.videoCodec,
      audioTracksJson: entity.audioTracksJson,
      subtitleTracksJson: entity.subtitleTracksJson,
      updatedInLastScan: 1,
      scannedAt: entity.scannedAt
    });
    const result: VideoUpsertResult = { id: id, wasNewlyInserted: true };
    return result;
  }
}

function makeVideo(filePath: string, fileName: string): VideoEntity {
  const entity: VideoEntity = {
    sourceId: 1,
    directoryPath: '/movies',
    filePath: filePath,
    fileName: fileName,
    scannedAt: Date.now()
  };
  return entity;
}

class TestSourceAdapter implements ISourceAdapter {
  private scanResults: Map<string, VideoFileInfo[]> = new Map<string, VideoFileInfo[]>();
  private failingDirs: Set<string> = new Set<string>();
  private strategy?: VideoUpsertStrategy;

  constructor(
    scanResults: Map<string, VideoFileInfo[]>,
    failingDirs: Set<string>,
    strategy?: VideoUpsertStrategy
  ) {
    this.scanResults = scanResults;
    this.failingDirs = failingDirs;
    this.strategy = strategy;
  }

  async scan(directoryPath: string, _options: ScanOptions): Promise<VideoFileInfo[]> {
    if (this.failingDirs.has(directoryPath)) {
      throw new Error(`Scan failed for ${directoryPath}`);
    }
    const results: VideoFileInfo[] | undefined = this.scanResults.get(directoryPath);
    if (results === undefined) {
      return [];
    }
    if (this.strategy !== undefined) {
      for (const info of results) {
        const entity: VideoEntity = {
          sourceId: info.sourceId,
          directoryPath: info.directoryPath,
          filePath: info.filePath,
          fileName: info.fileName,
          fileSize: info.fileSize,
          lastModified: info.lastModified,
          contentType: info.contentType,
          scannedAt: Date.now()
        };
        try {
          await this.strategy.upsert(entity);
        } catch (e) {
          // upsert 失败由策略内部捕获并统计，不中断整目录扫描
        }
      }
    }
    return results;
  }
}

function makeVideoInfo(filePath: string, fileName: string, dirPath: string): VideoFileInfo {
  const info: VideoFileInfo = {
    sourceId: 1,
    sourceName: 'test',
    sourceType: FileSourceType.WEBDAV,
    directoryPath: dirPath,
    filePath: filePath,
    fileName: fileName
  };
  return info;
}

class TestScanDirectoriesDeps implements ScanDirectoriesDeps {
  private fileSource: FileSource | null = null;
  private bundle: DirectedAdapterBundle | null = null;
  public initShouldFail: boolean = false;

  setFileSource(source: FileSource | null): void {
    this.fileSource = source;
  }

  setBundle(b: DirectedAdapterBundle | null): void {
    this.bundle = b;
  }

  async init(): Promise<void> {
    if (this.initShouldFail) {
      throw new Error('DB init failed');
    }
  }

  async getFileSourceById(_sourceId: number): Promise<FileSource | null> {
    return this.fileSource;
  }

  createDirectedAdapter(_fileSource: FileSource): DirectedAdapterBundle | null {
    return this.bundle;
  }
}

function makeWebdavSource(): FileSource {
  const source: FileSource = {
    id: 1,
    name: 'test-webdav',
    type: FileSourceType.WEBDAV,
    configJson: '{}',
    createdAt: Date.now()
  };
  return source;
}

export default function directedScanStrategyTest(): void {
  describe('DirectedUpsertStrategy', () => {
    it('首次插入 wasNewlyInserted=true 立即收集 ID', 0, async () => {
      const provider: InMemoryUpsertProvider = new InMemoryUpsertProvider();
      const strategy: DirectedUpsertStrategy = new DirectedUpsertStrategy(provider);
      strategy.beginDirectory();
      const entity: VideoEntity = makeVideo('/movies/a.mkv', 'a.mkv');
      const id: number = await strategy.upsert(entity);
      expect(id > 0).assertTrue();
      const ids: number[] = strategy.getNewlyInsertedVideoIds();
      expect(ids.length).assertEqual(1);
      expect(ids[0]).assertEqual(id);
    });

    it('已有记录 wasNewlyInserted=false 不收集 ID', 0, async () => {
      const provider: InMemoryUpsertProvider = new InMemoryUpsertProvider();
      const strategy: DirectedUpsertStrategy = new DirectedUpsertStrategy(provider);
      strategy.beginDirectory();
      const entity: VideoEntity = makeVideo('/movies/a.mkv', 'a.mkv');
      await strategy.upsert(entity);

      strategy.beginDirectory();
      const again: VideoEntity = makeVideo('/movies/a.mkv', 'a.mkv');
      const id2: number = await strategy.upsert(again);

      expect(id2 > 0).assertTrue();
      const ids: number[] = strategy.getNewlyInsertedVideoIds();
      expect(ids.length).assertEqual(1);
    });

    it('跨目录去重：同 filePath 仅首次 upsert 且 callCount=1', 0, async () => {
      const provider: InMemoryUpsertProvider = new InMemoryUpsertProvider();
      const strategy: DirectedUpsertStrategy = new DirectedUpsertStrategy(provider);

      strategy.beginDirectory();
      const entity1: VideoEntity = makeVideo('/media/a.mkv', 'a.mkv');
      const id1: number = await strategy.upsert(entity1);

      strategy.beginDirectory();
      const entity2: VideoEntity = makeVideo('/media/a.mkv', 'a.mkv');
      const id2: number = await strategy.upsert(entity2);

      expect(id1).assertEqual(id2);
      const ids: number[] = strategy.getNewlyInsertedVideoIds();
      expect(ids.length).assertEqual(1);
      expect(provider.callCount).assertEqual(1);
    });

    it('DB 失败时 hasDirectoryUpsertError=true 且 ErrorInfo 有内容', 0, async () => {
      const provider: FailingUpsertProvider = new FailingUpsertProvider();
      const strategy: DirectedUpsertStrategy = new DirectedUpsertStrategy(provider);
      strategy.beginDirectory();
      const entity: VideoEntity = makeVideo('/movies/a.mkv', 'a.mkv');
      try {
        await strategy.upsert(entity);
      } catch (e) {
        // expected
      }
      expect(strategy.hasDirectoryUpsertError()).assertTrue();
      const error: ErrorInfo = strategy.getDirectoryFirstError();
      expect(error.message.length > 0).assertTrue();
    });

    it('部分 upsert 失败：成功 ID 立即收集不丢失', 0, async () => {
      const provider: PartialFailingUpsertProvider = new PartialFailingUpsertProvider(['/movies/b.mkv']);
      const strategy: DirectedUpsertStrategy = new DirectedUpsertStrategy(provider);
      strategy.beginDirectory();
      const entityA: VideoEntity = makeVideo('/movies/a.mkv', 'a.mkv');
      const idA: number = await strategy.upsert(entityA);
      const entityB: VideoEntity = makeVideo('/movies/b.mkv', 'b.mkv');
      try {
        await strategy.upsert(entityB);
      } catch (e) {
        // expected failure
      }
      expect(idA > 0).assertTrue();
      expect(strategy.hasDirectoryUpsertError()).assertTrue();
      const ids: number[] = strategy.getNewlyInsertedVideoIds();
      expect(ids.length).assertEqual(1);
      expect(ids[0]).assertEqual(idA);
    });
  });

  describe('scanDirectoriesWithDeps 集成', () => {
    it('2 成功 1 失败：succeeded=2 failed=1 IDs 正确', 0, async () => {
      const provider: InMemoryUpsertProvider = new InMemoryUpsertProvider();
      const strategy: DirectedUpsertStrategy = new DirectedUpsertStrategy(provider);

      const scanResults: Map<string, VideoFileInfo[]> = new Map<string, VideoFileInfo[]>();
      scanResults.set('/dir1', [makeVideoInfo('/dir1/a.mkv', 'a.mkv', '/dir1')]);
      scanResults.set('/dir2', [makeVideoInfo('/dir2/b.mkv', 'b.mkv', '/dir2')]);

      const failingDirs: Set<string> = new Set<string>();
      failingDirs.add('/dir3');

      const adapter: TestSourceAdapter = new TestSourceAdapter(scanResults, failingDirs, strategy);
      const bundle: DirectedAdapterBundle = { adapter: adapter, strategy: strategy };

      const deps: TestScanDirectoriesDeps = new TestScanDirectoriesDeps();
      deps.setFileSource(makeWebdavSource());
      deps.setBundle(bundle);

      const result: DirectedScanResult = await VideoScannerUtil.scanDirectoriesWithDeps(
        deps, 1, ['/dir1', '/dir2', '/dir3']
      );

      expect(result.succeededDirectories.length).assertEqual(2);
      expect(result.failedDirectories.length).assertEqual(1);
      expect(result.failedDirectories[0].directoryPath).assertEqual('/dir3');
      expect(result.failedDirectories[0].error.message.length > 0).assertTrue();
      expect(result.newlyInsertedVideoIds.length).assertEqual(2);
      expect(result.totalFilesScanned).assertEqual(2);
    });

    it('同目录 1 成功 1 失败：目录整体标记 failed 但成功 ID 已收集', 0, async () => {
      const provider: PartialFailingUpsertProvider = new PartialFailingUpsertProvider(['/dir1/b.mkv']);
      const strategy: DirectedUpsertStrategy = new DirectedUpsertStrategy(provider);

      const scanResults: Map<string, VideoFileInfo[]> = new Map<string, VideoFileInfo[]>();
      scanResults.set('/dir1', [
        makeVideoInfo('/dir1/a.mkv', 'a.mkv', '/dir1'),
        makeVideoInfo('/dir1/b.mkv', 'b.mkv', '/dir1')
      ]);

      const failingDirs: Set<string> = new Set<string>();
      const adapter: TestSourceAdapter = new TestSourceAdapter(scanResults, failingDirs, strategy);
      const bundle: DirectedAdapterBundle = { adapter: adapter, strategy: strategy };

      const deps: TestScanDirectoriesDeps = new TestScanDirectoriesDeps();
      deps.setFileSource(makeWebdavSource());
      deps.setBundle(bundle);

      const result: DirectedScanResult = await VideoScannerUtil.scanDirectoriesWithDeps(
        deps, 1, ['/dir1']
      );

      expect(result.succeededDirectories.length).assertEqual(0);
      expect(result.failedDirectories.length).assertEqual(1);
      expect(result.failedDirectories[0].directoryPath).assertEqual('/dir1');
      expect(result.failedDirectories[0].error.message.length > 0).assertTrue();
      expect(result.newlyInsertedVideoIds.length).assertEqual(1);
      expect(result.totalFilesScanned).assertEqual(2);
    });

    it('db.init 失败：全部目录标记 failed', 0, async () => {
      const deps: TestScanDirectoriesDeps = new TestScanDirectoriesDeps();
      deps.initShouldFail = true;
      deps.setFileSource(makeWebdavSource());

      const result: DirectedScanResult = await VideoScannerUtil.scanDirectoriesWithDeps(
        deps, 1, ['/dir1', '/dir2']
      );

      expect(result.succeededDirectories.length).assertEqual(0);
      expect(result.failedDirectories.length).assertEqual(2);
      expect(result.newlyInsertedVideoIds.length).assertEqual(0);
      expect(result.failedDirectories[0].error.message.length > 0).assertTrue();
      expect(result.failedDirectories[1].error.message.length > 0).assertTrue();
    });

    it('不支持的源类型：createDirectedAdapter 返回 null 全部失败', 0, async () => {
      const deps: TestScanDirectoriesDeps = new TestScanDirectoriesDeps();
      const unsupportedSource: FileSource = {
        id: 2,
        name: 'test-aliyun',
        type: FileSourceType.ALIYUN,
        configJson: '{}',
        createdAt: Date.now()
      };
      deps.setFileSource(unsupportedSource);
      deps.setBundle(null);

      const result: DirectedScanResult = await VideoScannerUtil.scanDirectoriesWithDeps(
        deps, 2, ['/dir1']
      );

      expect(result.succeededDirectories.length).assertEqual(0);
      expect(result.failedDirectories.length).assertEqual(1);
      expect(result.newlyInsertedVideoIds.length).assertEqual(0);
    });

    it('FileSource 不存在：全部目录标记 failed', 0, async () => {
      const deps: TestScanDirectoriesDeps = new TestScanDirectoriesDeps();
      deps.setFileSource(null);

      const result: DirectedScanResult = await VideoScannerUtil.scanDirectoriesWithDeps(
        deps, 999, ['/dir1']
      );

      expect(result.succeededDirectories.length).assertEqual(0);
      expect(result.failedDirectories.length).assertEqual(1);
      expect(result.failedDirectories[0].error.message.length > 0).assertTrue();
    });
  });
}
