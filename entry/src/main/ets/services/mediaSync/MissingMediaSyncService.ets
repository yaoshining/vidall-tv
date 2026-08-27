import { FileSourceDatabase } from '../../db/files/FileSourceDatabase';
import { FileSource } from '../../db/models/FileSourceEntity';
import { VideoEntity } from '../../db/models/MediaEntity';
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
}

export const defaultMissingMediaSyncService = new MissingMediaSyncService();
