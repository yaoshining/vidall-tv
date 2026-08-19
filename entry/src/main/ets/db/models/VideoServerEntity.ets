/**
 * 影视服务器类型枚举
 */
export enum VideoServerType {
  JELLYFIN = 'jellyfin',
  EMBY = 'emby',
  PLEX = 'plex'
}

/**
 * Jellyfin / Emby 服务器配置
 */
export interface JellyfinServerConfig {
  /** 服务器地址（IP 或主机名，如 "192.168.1.100" 或 "nas.local"） */
  url: string;
  /** 端口号，Jellyfin 默认 8096，Emby 默认 8096 */
  port: number;
  /** 协议 */
  protocol: 'http' | 'https';
  /** 可选基础路径（反代子路径场景），以 / 开头 */
  basePath?: string;
  /** 认证方式 */
  authMethod: 'apikey' | 'password';
  /** API Key（authMethod=apikey 时使用） */
  apiKey?: string;
  /** 用户名（authMethod=password 时使用） */
  username?: string;
  /** 密码（authMethod=password 时使用） */
  password?: string;
}

/**
 * Emby 服务器配置（与 Jellyfin 同构）
 */
export type EmbyServerConfig = JellyfinServerConfig;

/**
 * Plex 服务器配置
 */
export interface PlexServerConfig {
  /** 服务器地址（IP 或主机名） */
  url: string;
  /** 端口号，默认 32400 */
  port: number;
  /** 协议 */
  protocol: 'http' | 'https';
  /** X-Plex-Token */
  token: string;
}

/**
 * 影视服务器实体
 */
export interface VideoServer {
  id?: number;
  name: string;
  type: VideoServerType;
  configJson: string;
  createdAt: number;
}

/**
 * 影视服务器类型标签映射
 */
export class VideoServerTypeLabels {
  static getLabel(type: VideoServerType): string {
    switch (type) {
      case VideoServerType.JELLYFIN:
        return 'Jellyfin';
      case VideoServerType.EMBY:
        return 'Emby';
      case VideoServerType.PLEX:
        return 'Plex';
      default:
        return '未知';
    }
  }
}
