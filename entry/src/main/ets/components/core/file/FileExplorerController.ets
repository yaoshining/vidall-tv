import { WebDAVResource } from "../../../lib/WebDAVClient";

export interface FileExplorerControllerParam {
  resources: WebDAVResource[];
  currentPath: string;
  onFolderChange?: (path: string) => void
  onBack?: () => boolean
}

/**
 * 路径导航项
 */
interface PathItem {
  name: string;
  path: string;
}

@ObservedV2
export class FileExplorerController {
  @Trace resources: WebDAVResource[] = [];
  @Trace currentPath: string = '/';

  @Trace sortField: 'name' | 'size' | 'date' = 'name';
  @Trace sortAscending: boolean = true;
  onFolderChange: (path: string) => void = () => {}
  /**
   * 当文件夹回退到根目录时触发
   */
  private onBack: () => boolean = () => true

  constructor(params: FileExplorerControllerParam) {
    this.resources = params.resources
    this.currentPath = params.currentPath
    this.onFolderChange = params.onFolderChange || this.onFolderChange
    this.onBack = params.onBack || this.onBack
  }

  /**
   * 获取路径导航项
   */
  @Computed
  get pathItems(): PathItem[] {
    const items: PathItem[] = [];

    items.push({
      name: '根目录',
      path: '/'
    });

    if (this.currentPath === '/') {
      return items;
    }

    const parts = this.currentPath.split('/').filter(p => p.length > 0);
    let accumulatedPath = '';

    for (let i = 0; i < parts.length; i++) {
      accumulatedPath += '/' + parts[i];
      items.push({
        name: decodeURIComponent(parts[i]),
        path: accumulatedPath
      });
    }

    return items;
  }

  /**
   * 获取排序后的资源列表
   */
  @Computed
  get sortedResources(): WebDAVResource[] {
    const sorted = this.resources.slice();

    sorted.sort((a, b) => {
      if (a.isCollection && !b.isCollection) return -1;
      if (!a.isCollection && b.isCollection) return 1;

      let compareResult = 0;

      if (this.sortField === 'name') {
        compareResult = a.displayName.localeCompare(b.displayName);
      } else if (this.sortField === 'size') {
        const sizeA = a.size || 0;
        const sizeB = b.size || 0;
        compareResult = sizeA - sizeB;
      } else if (this.sortField === 'date') {
        const dateA = a.lastModified || '';
        const dateB = b.lastModified || '';
        compareResult = dateA.localeCompare(dateB);
      }

      return this.sortAscending ? compareResult : -compareResult;
    });

    return sorted;
  }

  @Computed
  get parentPath() {
    const lastSlashIndex = this.currentPath.lastIndexOf('/');
    const parentPath = lastSlashIndex > 0
      ? this.currentPath.substring(0, lastSlashIndex)
      : '/';
    return parentPath
  }

  handleBack(): void {
    console.log('current path: ' + this.currentPath)
    if (this.currentPath === '/') {
      const handled = this.onBack();
      if (!handled) {
        console.info('Already at root directory');
      }
      return;
    }

    const parentPath = this.parentPath
    this.onFolderChange(parentPath);
  }
}