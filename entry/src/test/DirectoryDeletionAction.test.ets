import { describe, it, expect } from '@ohos/hypium';
import {
  deleteDirectoryOnly,
  DirectoryDeletionModel,
  DirectoryDeletionTarget
} from '../main/ets/stores/files/DirectoryDeletionAction';

class RecordingDirectoryDeletionModel implements DirectoryDeletionModel {
  clearCalls: number = 0;
  deleteSourceCalls: number = 0;
  dirId: number = 0;
  sourceId: number = 0;
  directoryPath: string = '';

  async clearMissingDirectory(dirId: number, sourceId: number, directoryPath: string): Promise<void> {
    this.clearCalls += 1;
    this.dirId = dirId;
    this.sourceId = sourceId;
    this.directoryPath = directoryPath;
  }

  async deleteFileSource(): Promise<void> {
    this.deleteSourceCalls += 1;
  }
}

export default function directoryDeletionActionTest(): void {
  describe('DirectoryDeletionAction', (): void => {
    it('should_delete_only_selected_directory', 0, async (): Promise<void> => {
      const model = new RecordingDirectoryDeletionModel();
      const target: DirectoryDeletionTarget = {
        dirId: 21,
        sourceId: 8,
        directoryPath: '/电影'
      };

      await deleteDirectoryOnly(model, target);

      expect(model.clearCalls).assertEqual(1);
      expect(model.deleteSourceCalls).assertEqual(0);
      expect(model.dirId).assertEqual(21);
      expect(model.sourceId).assertEqual(8);
      expect(model.directoryPath).assertEqual('/电影');
    });
  });
}
