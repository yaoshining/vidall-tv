import { SMBSourceConfig } from '../db/models/FileSourceEntity'
import * as VidAllCorePlayerNapiModule from 'libvidall_core_player_napi.so';

// ─────────────────────────────────────────────────────────────────────────────
// NAPI 桥接接口（占位 - 待 Native C++ smb_napi.cpp 实现后真实接入）
// ─────────────────────────────────────────────────────────────────────────────

export interface SmbTestConnectionResult {
  /** 是否连接成功 */
  success: boolean;
  /** 错误信息（失败时） */
  error?: string;
  /** 服务器返回的信息（成功时） */
  serverInfo?: string;
}

export interface SmbFileInfo {
  name: string;
  path: string;
  isDirectory: boolean;
  size: number;
  lastModified: number;
}

export interface SmbListDirectoryResult {
  files: SmbFileInfo[];
  error?: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// SMB 客户端配置
// ─────────────────────────────────────────────────────────────────────────────

export interface SMBClientConfig {
  host: string;
  port: number;
  username: string;
  password: string;
  shareName: string;
  domain?: string;
  workgroup?: string;
  timeoutMs?: number;
}

// ─────────────────────────────────────────────────────────────────────────────
// SMBClient - SMB 协议高层客户端
// ─────────────────────────────────────────────────────────────────────────────

export class SMBClient {
  private readonly host: string;
  private readonly port: number;
  private readonly username: string;
  private readonly password: string;
  private readonly shareName: string;
  private readonly domain: string;
  private readonly workgroup: string;
  private readonly timeoutMs: number;

  constructor(config: SMBClientConfig) {
    this.host = config.host;
    this.port = config.port ?? 445;
    this.username = config.username;
    this.password = config.password;
    this.shareName = config.shareName;
    this.domain = config.domain ?? '';
    this.workgroup = config.workgroup ?? 'WORKGROUP';
    this.timeoutMs = config.timeoutMs ?? 30000;
  }

  /**
   * 从 SMBSourceConfig 创建客户端实例
   */
  static fromSourceConfig(config: SMBSourceConfig): SMBClient {
    const clientConfig: SMBClientConfig = {
      host: config.host,
      port: config.port ?? 445,
      username: config.username,
      password: config.password,
      shareName: config.shareName,
      domain: config.domain,
      workgroup: config.workgroup
    }
    return new SMBClient(clientConfig)
  }

  /**
   * 获取 SMB URL（smb://host/share 格式）
   */
  getSmbUrl(path?: string): string {
    const base = `smb://${this.host}/${this.shareName}`;
    if (!path || path === '/') {
      return base;
    }
    const normalizedPath = path.startsWith('/') ? path : `/${path}`;
    return `${base}${normalizedPath}`;
  }

  /**
   * 测试 SMB 连接
   * 调用 Native NAPI smbTestConnection，当前返回 success:false+"libsmb2 not compiled" 是预期行为
   */
  async testConnection(): Promise<SmbTestConnectionResult> {
    console.info(`[SMBClient] testConnection: ${this.host}/${this.shareName}`);
    try {
      const raw = await VidAllCorePlayerNapiModule.smbTestConnection(
        this.host,
        this.port,
        this.username,
        this.password,
        this.domain,
        this.shareName,
        this.timeoutMs
      ) as Record<string, Object>;

      const result: SmbTestConnectionResult = {
        success: raw['success'] as boolean
      };
      if (raw['error']) {
        result.error = raw['error'] as string;
      }
      if (raw['serverInfo']) {
        result.serverInfo = raw['serverInfo'] as string;
      }
      return result;
    } catch (e) {
      const result: SmbTestConnectionResult = {
        success: false,
        error: `调用失败: ${JSON.stringify(e)}`
      };
      return result;
    }
  }

  /**
   * 列举指定路径下的文件和目录
   * 调用 Native NAPI smbListDirectory
   */
  async listDirectory(path: string): Promise<SmbListDirectoryResult> {
    console.info(`[SMBClient] listDirectory: ${this.getSmbUrl(path)}`);
    try {
      const raw = await VidAllCorePlayerNapiModule.smbListDirectory(
        this.host,
        this.port,
        this.username,
        this.password,
        this.domain,
        this.shareName,
        path,
        this.timeoutMs
      ) as Record<string, Object>;

      const filesRaw = raw['files'] as Object[];
      const files: SmbFileInfo[] = filesRaw.map((f) => {
        const fm = f as Record<string, Object>;
        const fileInfo: SmbFileInfo = {
          name: fm['name'] as string,
          path: fm['path'] as string,
          isDirectory: fm['isDirectory'] as boolean,
          size: fm['size'] as number,
          lastModified: fm['lastModified'] as number
        };
        return fileInfo;
      });

      const result: SmbListDirectoryResult = { files };
      if (raw['error']) {
        result.error = raw['error'] as string;
      }
      return result;
    } catch (e) {
      const result: SmbListDirectoryResult = {
        files: [],
        error: `调用失败: ${JSON.stringify(e)}`
      };
      return result;
    }
  }

  /**
   * 获取完整的 SMB URL（用于播放器直接使用）
   */
  getFullUrl(path: string): string {
    return this.getSmbUrl(path);
  }

  /**
   * 获取认证头信息（预留接口，SMB 认证通过 NTLM 在 Native 层处理）
   */
  getAuthInfo(): { username: string; domain: string } {
    return {
      username: this.username,
      domain: this.domain
    };
  }
}
