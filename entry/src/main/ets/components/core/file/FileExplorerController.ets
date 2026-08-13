import { WebDAVResource } from "../../../lib/WebDAVClient";
import { SmbFileInfo } from "../../../lib/SMBClient";

export type FileExplorerSortField = 'name' | 'size' | 'date'

export interface FileExplorerResource {
  key: string;
  name: string;
  path: string;
  isDirectory: boolean;
  size?: number;
  lastModifiedMs?: number;
  isHidden: boolean;
  sourceType: 'webdav' | 'smb';
}

export interface FileExplorerLoadResult {
  resources: FileExplorerResource[];
  errorMessage?: string;
}

export interface FileExplorerAdapter {
  list(path: string): Promise<FileExplorerLoadResult>;
}

function getChineseDigitValue(char: string): number {
  switch (char) {
    case '零':
      return 0;
    case '一':
      return 1;
    case '二':
      return 2;
    case '两':
      return 2;
    case '三':
      return 3;
    case '四':
      return 4;
    case '五':
      return 5;
    case '六':
      return 6;
    case '七':
      return 7;
    case '八':
      return 8;
    case '九':
      return 9;
    default:
      return -1;
  }
}

function getChineseUnitValue(char: string): number {
  switch (char) {
    case '十':
      return 10;
    case '百':
      return 100;
    case '千':
      return 1000;
    case '万':
      return 10000;
    default:
      return 0;
  }
}

function parseChineseOrdinalNumber(rawValue: string): number | undefined {
  if (/^\d+$/.test(rawValue)) {
    return parseInt(rawValue, 10);
  }

  let total = 0;
  let current = 0;
  let hasValue = false;
  for (let i = 0; i < rawValue.length; i++) {
    const char = rawValue[i];
    const digitValue = getChineseDigitValue(char);
    if (digitValue >= 0) {
      current = digitValue;
      hasValue = true;
      continue;
    }

    const unitValue = getChineseUnitValue(char);
    if (unitValue > 0) {
      const baseValue = current === 0 ? 1 : current;
      total += baseValue * unitValue;
      current = 0;
      hasValue = true;
      continue;
    }

    return undefined;
  }

  if (!hasValue) {
    return undefined;
  }

  return total + current;
}

function padNaturalNumber(value: number): string {
  return value.toString().padStart(8, '0');
}

function normalizeChineseOrdinalName(name: string): string {
  return name.replace(/第([零一二两三四五六七八九十百千万\d]+)(季|集|章|部|卷|话|回)/g, (_match: string, rawValue: string, suffix: string): string => {
    const parsed = parseChineseOrdinalNumber(rawValue);
    if (parsed === undefined) {
      return `第${rawValue}${suffix}`;
    }
    return `第${padNaturalNumber(parsed)}${suffix}`;
  });
}

function normalizeArabicNumberName(name: string): string {
  return name.replace(/\d+/g, (rawValue: string): string => {
    return padNaturalNumber(parseInt(rawValue, 10));
  });
}

function normalizeFileExplorerSortName(name: string): string {
  const normalizedChinese = normalizeChineseOrdinalName(name);
  return normalizeArabicNumberName(normalizedChinese);
}

export function compareFileExplorerNames(a: string, b: string): number {
  const normalizedA = normalizeFileExplorerSortName(a);
  const normalizedB = normalizeFileExplorerSortName(b);
  return normalizedA.localeCompare(normalizedB);
}

function joinFileExplorerPath(parentPath: string, childName: string): string {
  if (parentPath === '/') {
    return '/' + childName;
  }
  return parentPath.endsWith('/') ? parentPath + childName : parentPath + '/' + childName;
}

function isFileExplorerPathInRoot(currentPath: string, rootPath: string): boolean {
  if (rootPath === '/') {
    return currentPath.startsWith('/');
  }
  return currentPath === rootPath || currentPath.startsWith(rootPath + '/');
}

function getFileExplorerPathLeafName(path: string): string {
  const normalizedPath = path.endsWith('/') && path.length > 1
    ? path.substring(0, path.length - 1)
    : path;
  const lastSlashIndex = normalizedPath.lastIndexOf('/');
  if (lastSlashIndex < 0) {
    return normalizedPath;
  }
  return normalizedPath.substring(lastSlashIndex + 1);
}

function normalizeWebDavLastModified(lastModified?: string): number | undefined {
  if (lastModified === undefined || lastModified.length === 0) {
    return undefined;
  }
  const timestamp = Date.parse(lastModified);
  if (Number.isNaN(timestamp)) {
    return undefined;
  }
  return timestamp;
}

export function createFileExplorerResourceFromWebDav(
  currentPath: string,
  resource: WebDAVResource
): FileExplorerResource {
  const mappedResource: FileExplorerResource = {
    key: resource.href,
    name: resource.displayName,
    path: joinFileExplorerPath(currentPath, resource.displayName),
    isDirectory: resource.isCollection,
    size: resource.size,
    lastModifiedMs: normalizeWebDavLastModified(resource.lastModified),
    isHidden: resource.displayName.startsWith('.'),
    sourceType: 'webdav'
  };
  return mappedResource;
}

export function createFileExplorerResourceFromSmb(file: SmbFileInfo): FileExplorerResource {
  const mappedResource: FileExplorerResource = {
    key: file.path,
    name: file.name,
    path: file.path,
    isDirectory: file.isDirectory,
    size: file.size,
    lastModifiedMs: file.lastModifiedMs > 0 ? file.lastModifiedMs : undefined,
    isHidden: file.name.startsWith('.'),
    sourceType: 'smb'
  };
  return mappedResource;
}

export interface FileExplorerControllerParam {
  resources: FileExplorerResource[];
  currentPath: string;
  rootPath?: string;
  onFolderChange?: (path: string) => void
  onBack?: () => boolean
}

/**
 * 路径导航项
 */
export interface FileExplorerPathItem {
  name: string;
  path: string;
}

function normalizeFileExplorerRootPath(path: string): string {
  if (path.length === 0 || path === '/') {
    return '/';
  }
  if (!path.startsWith('/')) {
    return '/' + path;
  }
  return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
}

@ObservedV2
export class FileExplorerController {
  @Trace resources: FileExplorerResource[] = [];
  @Trace currentPath: string = '/';
  @Trace rootPath: string = '/';

  @Trace sortField: FileExplorerSortField = 'name';
  @Trace sortAscending: boolean = true;
  @Trace showHiddenFiles: boolean = false;
  onFolderChange: (path: string) => void = () => {}
  /**
   * 当文件夹回退到根目录时触发
   */
  private onBack: () => boolean = () => true

  constructor(params: FileExplorerControllerParam) {
    this.resources = params.resources
    this.currentPath = params.currentPath
    this.rootPath = normalizeFileExplorerRootPath(params.rootPath ?? '/')
    this.onFolderChange = params.onFolderChange || this.onFolderChange
    this.onBack = params.onBack || this.onBack
  }

  /**
   * 获取路径导航项
   */
  @Computed
  get pathItems(): FileExplorerPathItem[] {
    const items: FileExplorerPathItem[] = [];
    const pathInRoot = isFileExplorerPathInRoot(this.currentPath, this.rootPath);

    items.push({
      name: '根目录',
      path: this.rootPath
    });

    if (this.currentPath === this.rootPath) {
      return items;
    }

    if (!pathInRoot) {
      items.push({
        name: decodeURIComponent(getFileExplorerPathLeafName(this.currentPath)),
        path: this.currentPath
      });
      return items;
    }

    const relativePath = this.currentPath.substring(this.rootPath.length);
    const parts = relativePath.split('/').filter(p => p.length > 0);
    let accumulatedPath = this.rootPath === '/' ? '' : this.rootPath;

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
  get sortedResources(): FileExplorerResource[] {
    // 先过滤隐藏文件
    let filtered = this.resources;
    if (!this.showHiddenFiles) {
      filtered = this.resources.filter((resource: FileExplorerResource) => !resource.isHidden);
    }

    const sorted = filtered.slice();

    sorted.sort((a: FileExplorerResource, b: FileExplorerResource) => {
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;

      let compareResult = 0;

      if (this.sortField === 'name') {
        compareResult = compareFileExplorerNames(a.name, b.name);
      } else if (this.sortField === 'size') {
        const sizeA = a.size || 0;
        const sizeB = b.size || 0;
        compareResult = sizeA - sizeB;
      } else if (this.sortField === 'date') {
        const dateA = a.lastModifiedMs || 0;
        const dateB = b.lastModifiedMs || 0;
        compareResult = dateA - dateB;
      }

      return this.sortAscending ? compareResult : -compareResult;
    });

    return sorted;
  }

  @Computed
  get parentPath() {
    if (this.currentPath === this.rootPath) {
      return this.rootPath
    }
    const lastSlashIndex = this.currentPath.lastIndexOf('/');
    const parentPath = lastSlashIndex > 0
      ? this.currentPath.substring(0, lastSlashIndex)
      : this.rootPath;
    if (parentPath.length < this.rootPath.length) {
      return this.rootPath
    }
    return isFileExplorerPathInRoot(parentPath, this.rootPath) ? parentPath : this.rootPath
  }

  handleBack(): void {
    if (this.currentPath === this.rootPath) {
      const handled = this.onBack();
      if (!handled) {
        console.info('Already at explorer root directory');
      }
      return;
    }

    const parentPath = this.parentPath
    this.onFolderChange(parentPath);
  }
}
