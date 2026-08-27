export type MissingMediaTargetType = 'movie' | 'series';

export enum MissingMediaVerificationStatus {
  EXISTS = 'exists',
  MISSING = 'missing',
  UNCONFIRMED = 'unconfirmed'
}

export interface MissingMediaSyncTarget {
  type: MissingMediaTargetType;
  mediaId: number;
}

export interface MissingMediaSyncProgress {
  checked: number;
  total: number;
}

export interface MissingMediaVideoRef {
  videoId: number;
  sourceId: number;
  directoryPath: string;
  filePath: string;
}

export interface MissingMediaDirectoryGroup {
  key: string;
  sourceId: number;
  directoryPath: string;
  videos: MissingMediaVideoRef[];
}

export interface MissingMediaVerificationResult {
  videoId: number;
  status: MissingMediaVerificationStatus;
}

export interface MissingMediaSyncResult {
  totalCount: number;
  checkedCount: number;
  existingCount: number;
  removedCount: number;
  unconfirmedCount: number;
  targetRemoved: boolean;
}

export type MissingMediaProgressCallback = (progress: MissingMediaSyncProgress) => void;
