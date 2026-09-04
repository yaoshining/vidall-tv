import { FileSourceDatabase } from '../../db/files/FileSourceDatabase';
import { VideoEntity } from '../../db/models/MediaEntity';
import { FolderScrapeScope, ScrapeScope, normalizeScrapeDirectoryPath } from './ScopedScrapeTypes';

export { normalizeScrapeDirectoryPath };

export interface ScrapeScopeVideoSource {
  getVideoById(videoId: number): Promise<VideoEntity | null>;
  getVideosByMovieId(movieId: number): Promise<VideoEntity[]>;
  getVideosByTvSeriesId(tvSeriesId: number): Promise<VideoEntity[]>;
  getVideosBySeason(tvSeriesId: number, seasonNumber: number): Promise<VideoEntity[]>;
  getVideosByDirectoryTree(sourceId: number, directoryPath: string): Promise<VideoEntity[]>;
  getVideosBySourceId(sourceId: number): Promise<VideoEntity[]>;
  getAllVideos(): Promise<VideoEntity[]>;
}

export class ScrapeScopeResolver {
  private source: ScrapeScopeVideoSource;

  constructor(source?: ScrapeScopeVideoSource) {
    this.source = source ?? FileSourceDatabase.getInstance();
  }

  async resolve(scope: ScrapeScope): Promise<VideoEntity[]> {
    let videos: VideoEntity[] = [];
    if (scope.kind === 'movie') {
      videos = await this.source.getVideosByMovieId(scope.movieId);
    } else if (scope.kind === 'series') {
      videos = await this.source.getVideosByTvSeriesId(scope.tvSeriesId);
    } else if (scope.kind === 'season') {
      videos = await this.source.getVideosBySeason(scope.tvSeriesId, scope.seasonNumber);
    } else if (scope.kind === 'episode') {
      const video = await this.source.getVideoById(scope.videoId);
      videos = video === null ? [] : [video];
    } else if (scope.kind === 'folder') {
      videos = await this.resolveFolderScope(scope);
    } else {
      videos = await this.source.getAllVideos();
    }
    return this.stableUnique(videos);
  }

  /**
   * 解析目录范围：自动任务携带 directoryPaths 权威多目录列表（目录名可含逗号，不做字符串拆分），
   * 多目录时合并各目录树结果（重叠父子目录由 stableUnique 去重）；
   * 手动任务 directoryPath 为单一路径语义，不按逗号拆分。
   */
  private async resolveFolderScope(scope: FolderScrapeScope): Promise<VideoEntity[]> {
    if (scope.directoryPaths !== undefined) {
      const merged: VideoEntity[] = [];
      for (const path of scope.directoryPaths) {
        const normalizedPath = normalizeScrapeDirectoryPath(path);
        const branchVideos = normalizedPath === '/'
          ? await this.source.getVideosBySourceId(scope.sourceId)
          : await this.source.getVideosByDirectoryTree(scope.sourceId, normalizedPath);
        for (const video of branchVideos) {
          merged.push(video);
        }
      }
      return merged;
    }
    const normalizedPath = normalizeScrapeDirectoryPath(scope.directoryPath);
    return normalizedPath === '/'
      ? await this.source.getVideosBySourceId(scope.sourceId)
      : await this.source.getVideosByDirectoryTree(scope.sourceId, normalizedPath);
  }

  private stableUnique(videos: VideoEntity[]): VideoEntity[] {
    const byKey = new Map<string, VideoEntity>();
    for (const video of videos) {
      const key = video.id !== undefined ? `id:${video.id}` : `path:${video.sourceId}:${video.filePath}`;
      if (!byKey.has(key)) {
        byKey.set(key, video);
      }
    }
    const unique = Array.from(byKey.values());
    unique.sort((left: VideoEntity, right: VideoEntity): number => {
      const leftId = left.id ?? Number.MAX_SAFE_INTEGER;
      const rightId = right.id ?? Number.MAX_SAFE_INTEGER;
      if (leftId !== rightId) {
        return leftId - rightId;
      }
      return left.filePath.localeCompare(right.filePath);
    });
    return unique;
  }
}
