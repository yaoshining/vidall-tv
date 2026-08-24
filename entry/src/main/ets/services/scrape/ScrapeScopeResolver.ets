import { FileSourceDatabase } from '../../db/files/FileSourceDatabase';
import { VideoEntity } from '../../db/models/MediaEntity';
import { ScrapeScope } from './ScopedScrapeTypes';

export interface ScrapeScopeVideoSource {
  getVideoById(videoId: number): Promise<VideoEntity | null>;
  getVideosByMovieId(movieId: number): Promise<VideoEntity[]>;
  getVideosByTvSeriesId(tvSeriesId: number): Promise<VideoEntity[]>;
  getVideosBySeason(tvSeriesId: number, seasonNumber: number): Promise<VideoEntity[]>;
  getVideosByDirectoryTree(sourceId: number, directoryPath: string): Promise<VideoEntity[]>;
  getVideosBySourceId(sourceId: number): Promise<VideoEntity[]>;
  getAllVideos(): Promise<VideoEntity[]>;
}

export function normalizeScrapeDirectoryPath(path: string): string {
  const slashPath = path.trim().replace(/\\/g, '/').replace(/\/{2,}/g, '/');
  if (slashPath.length === 0 || slashPath === '/') {
    return '/';
  }
  const withLeadingSlash = slashPath.startsWith('/') ? slashPath : `/${slashPath}`;
  return withLeadingSlash.replace(/\/+$/g, '');
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
      const normalizedPath = normalizeScrapeDirectoryPath(scope.directoryPath);
      videos = normalizedPath === '/'
        ? await this.source.getVideosBySourceId(scope.sourceId)
        : await this.source.getVideosByDirectoryTree(scope.sourceId, normalizedPath);
    } else {
      videos = await this.source.getAllVideos();
    }
    return this.stableUnique(videos);
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
