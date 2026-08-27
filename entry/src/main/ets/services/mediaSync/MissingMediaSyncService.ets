import { FileSourceDatabase } from '../../db/files/FileSourceDatabase';
import { FileSource } from '../../db/models/FileSourceEntity';
import { VideoEntity } from '../../db/models/MediaEntity';
import { MediaDataVersionStore } from '../scrape/MediaDataVersionStore';
import { MovieScrapeScope, SeriesScrapeScope } from '../scrape/ScopedScrapeTypes';
import { groupMissingMediaVideos } from './MissingMediaPathUtils';
import { defaultMissingMediaVerifier, MissingMediaVerifier } from './MissingMediaVerifier';
import {
  MissingMediaDirectoryGroup,
  MissingMediaProgressCallback,
  MissingMediaSyncResult,
  MissingMediaSyncTarget,
  MissingMediaVerificationResult,
  MissingMediaVerificationStatus
} from './MissingMediaSyncTypes';

export class MissingMediaSyncService {
  private readonly database: FileSourceDatabase;
  private readonly verifier: MissingMediaVerifier;

  constructor(
    database: FileSourceDatabase = FileSourceDatabase.getInstance(),
    verifier: MissingMediaVerifier = defaultMissingMediaVerifier
  ) {
    this.database = database;
    this.verifier = verifier;
  }

  async sync(
    target: MissingMediaSyncTarget,
    onProgress?: MissingMediaProgressCallback
  ): Promise<MissingMediaSyncResult> {
    const videos = target.type === 'movie'
      ? await this.database.getVideosByMovieId(target.mediaId)
      : await this.database.getVideosByTvSeriesId(target.mediaId);
    return this.syncVideos(target, videos, onProgress);
  }

  private async syncVideos(
    target: MissingMediaSyncTarget,
    videos: VideoEntity[],
    onProgress?: MissingMediaProgressCallback
  ): Promise<MissingMediaSyncResult> {
    const groups = groupMissingMediaVideos(videos);
    const missingIds: number[] = [];
    let checked = 0;
    let existing = 0;
    let unconfirmed = 0;
    if (onProgress !== undefined) {
      onProgress({ checked: 0, total: videos.length });
    }
    for (const group of groups) {
      const source: FileSource | null = await this.database.getFileSourceById(group.sourceId);
      const groupResults = await this.verifier.verifyGroup(source, group);
      for (const verification of groupResults) {
        if (verification.status === MissingMediaVerificationStatus.MISSING) {
          missingIds.push(verification.videoId);
        } else if (verification.status === MissingMediaVerificationStatus.EXISTS) {
          existing++;
        } else {
          unconfirmed++;
        }
      }
      checked += group.videos.length;
      if (onProgress !== undefined) {
        onProgress({ checked, total: videos.length });
      }
    }
    if (missingIds.length > 0) {
      await this.database.deleteVideosWithScrapeInfo(missingIds);
      // 删除后广播媒体数据版本变化，让首页/详情页通过 @Monitor 重新加载
      // 元数据与「继续观看」列表，避免同步后残留已清理条目（需重启才消失）。
      this.publishMediaChange(target);
    }
    const targetRemoved = target.type === 'movie'
      ? await this.database.getMovieById(target.mediaId) === null
      : await this.database.getTvSeriesById(target.mediaId) === null;
    const result: MissingMediaSyncResult = {
      totalCount: videos.length,
      checkedCount: checked,
      existingCount: existing,
      removedCount: missingIds.length,
      unconfirmedCount: unconfirmed,
      targetRemoved
    };
    return result;
  }

  /**
   * 广播媒体数据版本变化，触发首页「继续观看」与媒体库列表刷新。
   * 详情页与播放页就地同步共用同一服务；删除后必须 publish，
   * 否则首页 MediaLibraryTab 持有的 recentlyAdded 内存数据陈旧，
   * loadContinueWatching 会重建出已删除的条目。
   */
  private publishMediaChange(target: MissingMediaSyncTarget): void {
    if (target.type === 'movie') {
      const scope: MovieScrapeScope = { kind: 'movie', movieId: target.mediaId, displayName: '' };
      MediaDataVersionStore.getState().publish(scope);
    } else {
      const scope: SeriesScrapeScope = { kind: 'series', tvSeriesId: target.mediaId, displayName: '' };
      MediaDataVersionStore.getState().publish(scope);
    }
  }
}

export const defaultMissingMediaSyncService = new MissingMediaSyncService();
