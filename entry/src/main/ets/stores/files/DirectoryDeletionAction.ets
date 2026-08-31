export interface DirectoryDeletionTarget {
  dirId: number;
  sourceId: number;
  directoryPath: string;
}

export interface DirectoryDeletionModel {
  clearMissingDirectory(dirId: number, sourceId: number, directoryPath: string): Promise<void>;
}

export async function deleteDirectoryOnly(
  model: DirectoryDeletionModel,
  target: DirectoryDeletionTarget
): Promise<void> {
  await model.clearMissingDirectory(target.dirId, target.sourceId, target.directoryPath);
}
