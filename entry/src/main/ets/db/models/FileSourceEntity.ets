/**
 * 文件源类型枚举
 */
export enum FileSourceType {
  WEBDAV = 'webdav',
  SMB = 'smb',
  ALIYUN = 'aliyun',
  CLOUD_139 = 'cloud139',
  BAIDU = 'baidu',
  CLOUD_123 = 'cloud123',
  CLOUD_115 = 'cloud115',
  OTHER = 'other'
}

/**
 * WebDAV 文件源配置
 */
export interface WebDAVSourceConfig {
  url: string;
  username: string;
  password: string;
  protocol: 'http' | 'https';
  port: number;
  rootPath: string;
}

/**
 * 文件源实体
 */
export interface FileSource {
  id?: number;
  name: string;
  type: FileSourceType;
  configJson: string;
  createdAt: number;
}

/**
 * 文件源目录关联
 */
export interface FileSourceDirectory {
  id?: number;
  sourceId: number;
  directoryPath: string;
  customName?: string;
}

/**
 * 文件源类型标签映射
 */
export class FileSourceTypeLabels {
  static getLabel(type: FileSourceType): string {
    switch (type) {
      case FileSourceType.WEBDAV:
        return 'WebDAV';
      case FileSourceType.SMB:
        return 'SMB';
      case FileSourceType.ALIYUN:
        return '阿里云盘';
      case FileSourceType.CLOUD_139:
        return '139网盘';
      case FileSourceType.BAIDU:
        return '百度网盘';
      case FileSourceType.CLOUD_123:
        return '123网盘';
      case FileSourceType.CLOUD_115:
        return '115网盘';
      case FileSourceType.OTHER:
        return '其他';
      default:
        return '未知';
    }
  }
}

