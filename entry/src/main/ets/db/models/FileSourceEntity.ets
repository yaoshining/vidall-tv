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
  /**
   * TLS 证书校验策略（持久化字段，默认 'strict'）。
   * 'allow_self_signed' 仅在内网自签名证书场景下受控启用，不得作为生产默认值。
   */
  tlsCertPolicy?: 'strict' | 'allow_self_signed';
}

/**
 * SMB / CIFS 文件源配置
 *
 * 用于连接局域网内的 Windows 共享目录或 NAS 设备，
 * 支持 Workgroup 与 Windows AD 域两种认证模式。
 */
export interface SMBSourceConfig {
  /** 服务器地址，IP 或主机名，如 "192.168.1.100" 或 "nas.local" */
  host: string;
  /** 端口号，默认 445；Samba 旧版可能使用 139 */
  port?: number;
  /** 认证用户名 */
  username: string;
  /** 认证密码 */
  password: string;
  /**
   * Windows 域名（企业 AD 环境使用）。
   * 普通工作组场景可留空，不影响连接。
   */
  domain?: string;
  /** SMB 共享名，如 "nas-share"、"Videos"。为空时可通过 listShares() 枚举后选择 */
  shareName?: string;
  /** 工作组名，默认 "WORKGROUP" */
  workgroup?: string;
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
 * 目录可达性状态
 * - active:      最近一次扫描成功，目录正常可达
 * - missing:     服务器返回 404，目录已不存在
 * - unreachable: 网络超时、401 鉴权失败等暂时不可达
 */
export type DirStatus = 'active' | 'missing' | 'unreachable';

/**
 * 文件源目录关联
 */
export interface FileSourceDirectory {
  id?: number;
  sourceId: number;
  directoryPath: string;
  customName?: string;
  /** 目录可达性状态，默认 'active' */
  dirStatus?: DirStatus;
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

