import { SMBSourceConfig } from '../db/models/FileSourceEntity'
import * as VidAllCorePlayerNapiModule from 'libvidall_core_player_napi.so';

// ─────────────────────────────────────────────────────────────────────────────
// NAPI 桥接接口（当前通过 vidall_core_player_napi.cpp / libvidall_core_player_napi.so 接入）
// 如后续拆分为独立 smb_napi.cpp，再将 SMB 相关接口迁移到对应 NAPI 模块
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
  /** Unix epoch 毫秒（ms）。Native 层实现时须保证返回毫秒，勿透传秒级时间戳。 */
  lastModifiedMs: number;
}

export interface SmbListDirectoryResult {
  files: SmbFileInfo[];
  error?: string;
}

export interface SmbShareInfo {
  name: string;
  remark: string;
  /** 原始 type 位字段，0=磁盘, 1=打印, 2=设备, 3=IPC */
  type: number;
}

export interface SmbListSharesResult {
  shares: SmbShareInfo[];
  error?: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// NAPI default export 兼容层
// ─────────────────────────────────────────────────────────────────────────────

interface SmbNapiBridge {
  smbTestConnection: (host: string, port: number, username: string, password: string, domain: string, shareName: string, timeoutMs: number) => Promise<Record<string, Object>>;
  smbListDirectory: (host: string, port: number, username: string, password: string, domain: string, shareName: string, path: string, timeoutMs: number) => Promise<Record<string, Object>>;
  smbListShares: (host: string, port: number, username: string, password: string, domain: string, timeoutMs: number) => Promise<Record<string, Object>>;
}

interface SmbNapiBridgeModule {
  default?: SmbNapiBridge;
}

function getModule(): SmbNapiBridge {
  const bridgeModule = VidAllCorePlayerNapiModule as SmbNapiBridgeModule | SmbNapiBridge | undefined;
  if (bridgeModule === undefined) {
    throw new Error('libvidall_core_player_napi.so 未加载');
  }
  const defaultBridge = (bridgeModule as SmbNapiBridgeModule).default;
  if (defaultBridge !== undefined) {
    return defaultBridge as SmbNapiBridge;
  }
  return bridgeModule as SmbNapiBridge;
}

// ─────────────────────────────────────────────────────────────────────────────
// SMB 客户端配置
// ─────────────────────────────────────────────────────────────────────────────

export interface SMBClientConfig {
  host: string;
  port: number;
  username: string;
  password: string;
  /** 共享名，如 "nas-share"。为空时 testConnection 连接 IPC$（纯认证检验） */
  shareName?: string;
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
    this.shareName = config.shareName ?? '';
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
      shareName: config.shareName ?? '',
      domain: config.domain,
      workgroup: config.workgroup
    }
    return new SMBClient(clientConfig)
  }

  /**
   * 获取 SMB URL（smb://host/share 格式）
   */
  getSmbUrl(path?: string): string {
    const base: string = `smb://${this.host}/${this.shareName}`;
    if (path === undefined) {
      return base;
    }
    const raw: string = path.trim();
    if (raw.length === 0 || raw === '/') {
      return base;
    }
    // 将反斜杠统一替换为正斜杠
    let normalized: string = raw.split('\\').join('/');
    // 确保以 / 开头
    if (!normalized.startsWith('/')) {
      normalized = '/' + normalized;
    }
    // 收敛连续多重斜杠
    while (normalized.indexOf('//') !== -1) {
      normalized = normalized.split('//').join('/');
    }
    return `${base}${normalized}`;
  }

  /**
   * 测试 SMB 连接
   * 调用 Native NAPI smbTestConnection，当前返回 success:false+"libsmb2 not compiled" 是预期行为
   */
  async testConnection(): Promise<SmbTestConnectionResult> {
    console.info(`[SMBClient] testConnection: ${this.host}/${this.shareName}`);
    try {
      const raw = await getModule().smbTestConnection(
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
      const err = e as import('@kit.BasicServicesKit').BusinessError;
      const result: SmbTestConnectionResult = {
        success: false,
        error: err.message ?? '调用失败'
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
      const raw = await getModule().smbListDirectory(
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
          // Native 层须返回毫秒（ms）；Phase 2 实现时注意单位
          lastModifiedMs: fm['lastModified'] as number
        };
        return fileInfo;
      });

      const result: SmbListDirectoryResult = { files };
      if (raw['error']) {
        result.error = raw['error'] as string;
      }
      return result;
    } catch (e) {
      const err = e as import('@kit.BasicServicesKit').BusinessError;
      const result: SmbListDirectoryResult = {
        files: [],
        error: err.message ?? '调用失败'
      };
      return result;
    }
  }

  /**
   * 枚举服务器上的 SMB 共享列表（连接到 IPC$，无需提前知道共享名）
   */
  async listShares(): Promise<SmbListSharesResult> {
    console.info(`[SMBClient] listShares: ${this.host}`);
    try {
      const raw = await getModule().smbListShares(
        this.host,
        this.port,
        this.username,
        this.password,
        this.domain,
        this.timeoutMs
      ) as Record<string, Object>;

      const sharesRaw = raw['shares'] as Object[];
      const shares: SmbShareInfo[] = sharesRaw.map((s) => {
        const sm = s as Record<string, Object>;
        const shareInfo: SmbShareInfo = {
          name: sm['name'] as string,
          remark: sm['remark'] as string,
          type: sm['type'] as number
        };
        return shareInfo;
      });

      const result: SmbListSharesResult = { shares };
      if (raw['error']) {
        result.error = raw['error'] as string;
      }
      return result;
    } catch (e) {
      const err = e as import('@kit.BasicServicesKit').BusinessError;
      const result: SmbListSharesResult = {
        shares: [],
        error: err.message ?? '调用失败'
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
  getAuthInfo(): SmbAuthInfo {
    const info: SmbAuthInfo = {
      username: this.username,
      domain: this.domain
    };
    return info;
  }
}

export interface SmbAuthInfo {
  username: string;
  domain: string;
}
