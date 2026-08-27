import { VideoEntity } from '../../db/models/MediaEntity';
import { MissingMediaDirectoryGroup, MissingMediaVideoRef } from './MissingMediaSyncTypes';

export function normalizeMissingMediaPath(path: string): string {
  let normalized = path.replace(/\\/g, '/').replace(/\/+/g, '/');
  try {
    normalized = decodeURI(normalized);
  } catch {
    // Keep malformed encoded paths unchanged so they can only match exactly.
  }
  if (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  if (normalized.length === 0) {
    return '/';
  }
  return normalized.startsWith('/') ? normalized : `/${normalized}`;
}

export function getMissingMediaParentPath(filePath: string): string {
  const normalized = normalizeMissingMediaPath(filePath);
  const separatorIndex = normalized.lastIndexOf('/');
  if (separatorIndex <= 0) {
    return '/';
  }
  return normalized.substring(0, separatorIndex);
}

export function isExactMissingMediaPathMatch(expectedPath: string, actualPath: string): boolean {
  return normalizeMissingMediaPath(expectedPath) === normalizeMissingMediaPath(actualPath);
}

export function groupMissingMediaVideos(videos: VideoEntity[]): MissingMediaDirectoryGroup[] {
  const groups: Map<string, MissingMediaDirectoryGroup> = new Map();
  for (const video of videos) {
    if (video.id === undefined) {
      continue;
    }
    const directoryPath = normalizeMissingMediaPath(
      video.directoryPath.length > 0 ? video.directoryPath : getMissingMediaParentPath(video.filePath)
    );
    const key = `${video.sourceId}:${directoryPath}`;
    let group = groups.get(key);
    if (group === undefined) {
      const newGroup: MissingMediaDirectoryGroup = {
        key,
        sourceId: video.sourceId,
        directoryPath,
        videos: []
      };
      groups.set(key, newGroup);
      group = newGroup;
    }
    const videoRef: MissingMediaVideoRef = {
      videoId: video.id,
      sourceId: video.sourceId,
      directoryPath,
      filePath: normalizeMissingMediaPath(video.filePath)
    };
    group.videos.push(videoRef);
  }
  return Array.from(groups.values());
}
