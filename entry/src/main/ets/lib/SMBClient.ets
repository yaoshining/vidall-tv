import { SMBSourceConfig } from '../db/models/FileSourceEntity'

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
   * 阶段一：Native 层未就绪时返回占位结果
   */
  async testConnection(): Promise<SmbTestConnectionResult> {
    // TODO: 待 Native smb_napi.cpp 实现后，替换为真实 NAPI 调用
    // return await libvidall_core_player_napi.smbTestConnection(
    //   this.host, this.port, this.username, this.password,
    //   this.domain, this.shareName, this.timeoutMs
    // )

    console.info(`[SMBClient] testConnection called: ${this.host}/${this.shareName} (Native 层未就绪)`);
    const result: SmbTestConnectionResult = {
      success: false,
      error: 'SMB Native 层开发中，暂不支持连接测试'
    };
    return result;
  }

  /**
   * 列举指定路径下的文件和目录
   * 阶段一：Native 层未就绪时返回空列表
   */
  async listDirectory(path: string): Promise<SmbListDirectoryResult> {
    // TODO: 待 Native smb_napi.cpp 实现后，替换为真实 NAPI 调用
    // return await libvidall_core_player_napi.smbListDirectory(
    //   this.host, this.port, this.username, this.password,
    //   this.domain, this.shareName, path, this.timeoutMs
    // )

    console.info(`[SMBClient] listDirectory called: ${this.getSmbUrl(path)} (Native 层未就绪)`);
    const result: SmbListDirectoryResult = {
      files: [],
      error: 'SMB Native 层开发中，暂不支持目录列举'
    };
    return result;
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
