import { FileExplorerAdapter } from './FileExplorerController';
import { FileSourceDatabase } from '../../../db/files/FileSourceDatabase';
import { FileSourceStore } from '../../../stores/files/FileSourceStore';
import { MediaDataVersionStore } from '../../../services/scrape/MediaDataVersionStore';

export function isExplorerMissingError(message: string): boolean {
  return /\b(?:NT_)?STATUS_OBJECT_(?:NAME|PATH)_NOT_FOUND\b|\b0xc000003[4a]\b|no such file or directory|\bHTTP\s+404\b/i.test(message);
}

export function isExplorerPathWithin(path: string, directory: string): boolean {
  const root = directory.length > 1 ? directory.replace(/\/$/, '') : directory;
  return path === root || path.startsWith(root === '/' ? '/' : root + '/');
}

export type ExplorerConfirm = (message: string, confirm: () => void, cancel: () => void) => void;

/** 核验与清理分开；任何超时、认证错误都不能作为缺失证据。 */
export class FileExplorerRecovery {
  private prompting: boolean = false;

  async isMissing(adapter: FileExplorerAdapter, path: string, directory: boolean): Promise<boolean> {
    const parent = path.substring(0, path.lastIndexOf('/')) || '/';
    const result = await adapter.list(directory ? path : parent);
    if (result.errorMessage) { return isExplorerMissingError(result.errorMessage); }
    return !directory && !result.resources.some(resource => resource.path === path);
  }

  prompt(adapter: FileExplorerAdapter, path: string, directory: boolean, sourceId: number,
    databasePath: string, confirm: ExplorerConfirm, notify: (message: string) => void,
    onCleared: () => void): void {
    if (this.prompting) { return; }
    this.prompting = true;
    confirm(`${directory ? '此目录' : '此文件'}在服务器上已不存在，是否清除本地列表及关联媒体记录？不会删除服务器上的文件。`, () => {
      this.clean(adapter, path, directory, sourceId, databasePath).then((cleared: boolean) => {
        this.prompting = false;
        if (cleared) { onCleared(); }
        else { notify('路径已恢复或暂时无法确认，未清除任何记录'); }
      }).catch(() => {
        this.prompting = false;
        notify('清理未完成，请重试');
      });
    }, () => { this.prompting = false; });
  }

  private async clean(adapter: FileExplorerAdapter, path: string, directory: boolean,
    sourceId: number, databasePath: string): Promise<boolean> {
    if (!await this.isMissing(adapter, path, directory)) { return false; }
    if (sourceId > 0 && databasePath.startsWith('/')) {
      const database = FileSourceDatabase.getInstance();
      const videos = await database.getVideosBySourceId(sourceId);
      const ids: number[] = [];
      for (const video of videos) {
        if (video.id !== undefined && (directory ? isExplorerPathWithin(video.filePath, databasePath) : video.filePath === databasePath)) {
          ids.push(video.id);
        }
      }
      if (ids.length > 0) { await database.deleteVideosWithScrapeInfo(ids); }
      if (directory) {
        const directories = await database.getDirectoriesBySourceId(sourceId);
        for (const dir of directories) {
          if (dir.id !== undefined && isExplorerPathWithin(dir.directoryPath, databasePath)) {
            await FileSourceStore.getState().clearMissingDirectory(dir.id, sourceId, dir.directoryPath);
          }
        }
      }
      MediaDataVersionStore.getState().publish({ kind: 'folder', sourceId, directoryPath: databasePath, displayName: '' });
      await FileSourceStore.getState().loadFileSources(true);
    }
    return true;
  }
}
