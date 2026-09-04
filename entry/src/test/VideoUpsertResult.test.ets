import { describe, it, expect } from '@ohos/hypium'
import { VideoDao, VideoPersistencePort } from '../main/ets/db/files/VideoDao'
import { VideoEntity } from '../main/ets/db/models/MediaEntity'
import { FileSourceDbCore } from '../main/ets/db/files/FileSourceDbCore'

class InMemoryVideoPersistencePort implements VideoPersistencePort {
  private videos: Map<string, VideoEntity> = new Map();
  private nextId: number = 1;

  async findByPath(filePath: string): Promise<VideoEntity | null> {
    const entity = this.videos.get(filePath);
    return entity ?? null;
  }

  async insertVideo(entity: VideoEntity): Promise<number> {
    const existing = this.videos.get(entity.filePath);
    if (existing) {
      return -1;
    }
    const id = this.nextId++;
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
    return id;
  }

  async updateVideo(existingId: number, entity: VideoEntity): Promise<void> {
    const stored = this.videos.get(entity.filePath);
    if (stored !== undefined) {
      const updated: VideoEntity = {
        id: existingId,
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
    }
  }

  async findIdByPath(filePath: string): Promise<number> {
    const entity = this.videos.get(filePath);
    return entity?.id ?? 0;
  }
}

function makeVideo(overrides?: Partial<VideoEntity>): VideoEntity {
  const base: VideoEntity = {
    sourceId: 1,
    directoryPath: '/movies',
    filePath: '/movies/test.mkv',
    fileName: 'test.mkv',
    scannedAt: Date.now()
  };
  if (overrides === undefined) {
    return base;
  }
  const result: VideoEntity = {
    sourceId: overrides.sourceId ?? base.sourceId,
    directoryPath: overrides.directoryPath ?? base.directoryPath,
    filePath: overrides.filePath ?? base.filePath,
    fileName: overrides.fileName ?? base.fileName,
    scannedAt: overrides.scannedAt ?? base.scannedAt,
    fileSize: overrides.fileSize,
    lastModified: overrides.lastModified,
    contentType: overrides.contentType,
    durationMs: overrides.durationMs,
    width: overrides.width,
    height: overrides.height,
    frameRate: overrides.frameRate,
    videoCodec: overrides.videoCodec,
    audioTracksJson: overrides.audioTracksJson,
    subtitleTracksJson: overrides.subtitleTracksJson
  };
  return result;
}

export default function videoUpsertResultTest() {
  describe('upsertVideoWithResult', () => {
    it('首次插入返回 wasNewlyInserted=true', 0, async () => {
      const port = new InMemoryVideoPersistencePort();
      const core = new FileSourceDbCore();
      const dao = new VideoDao(core, port);
      const entity = makeVideo();
      const result = await dao.upsertVideoWithResult(entity);
      expect(result.wasNewlyInserted).assertTrue();
      expect(result.id > 0).assertTrue();
    });

    it('同路径再次调用返回 wasNewlyInserted=false', 0, async () => {
      const port = new InMemoryVideoPersistencePort();
      const core = new FileSourceDbCore();
      const dao = new VideoDao(core, port);
      const entity = makeVideo();
      await dao.upsertVideoWithResult(entity);
      const result = await dao.upsertVideoWithResult(entity);
      expect(result.wasNewlyInserted).assertFalse();
    });

    it('UPDATE 后 ID 不变', 0, async () => {
      const port = new InMemoryVideoPersistencePort();
      const core = new FileSourceDbCore();
      const dao = new VideoDao(core, port);
      const entity = makeVideo();
      const first = await dao.upsertVideoWithResult(entity);
      const second = await dao.upsertVideoWithResult(entity);
      expect(second.id).assertEqual(first.id);
      expect(second.wasNewlyInserted).assertFalse();
    });

    it('不同路径的首次插入各自独立', 0, async () => {
      const port = new InMemoryVideoPersistencePort();
      const core = new FileSourceDbCore();
      const dao = new VideoDao(core, port);
      const entityA = makeVideo({ filePath: '/movies/a.mkv', fileName: 'a.mkv' });
      const entityB = makeVideo({ filePath: '/movies/b.mkv', fileName: 'b.mkv' });
      const resultA = await dao.upsertVideoWithResult(entityA);
      const resultB = await dao.upsertVideoWithResult(entityB);
      expect(resultA.wasNewlyInserted).assertTrue();
      expect(resultB.wasNewlyInserted).assertTrue();
      expect(resultA.id !== resultB.id).assertTrue();
    });
  });
}
