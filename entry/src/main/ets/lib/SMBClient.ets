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

export interface SmbDiscoverHostsResult {
  hosts: string[];
  error?: string;
}

/** parsePath 返回结果 */
interface ParsedSmbPath {
  shareName: string;
  subPath: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// NAPI default export 兼容层
// ─────────────────────────────────────────────────────────────────────────────

interface SmbNapiBridge {
  smbTestConnection: (host: string, port: number, username: string, password: string, domain: string, shareName: string, timeoutMs: number) => Promise<Record<string, Object>>;
  smbListDirectory: (host: string, port: number, username: string, password: string, domain: string, shareName: string, path: string, timeoutMs: number) => Promise<Record<string, Object>>;
  smbListShares: (host: string, port: number, username: string, password: string, domain: string, timeoutMs: number) => Promise<Record<string, Object>>;
  smbDiscoverHosts: (subnetPrefix: string, startOctet: number, endOctet: number, port: number, timeoutMs: number) => Promise<Record<string, Object>>;
  smbReadTextFile: (url: string, maxSizeBytes: number, timeoutSeconds?: number) => Promise<string>;
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
   * 路径规范化：将反斜杠转为正斜杠，合并重复斜杠（Fix 4）。
   * 不处理前导 "/"，调用方按需补充。
   */
  private normalizePath(rawPath: string): string {
    // 将反斜杠统一替换为正斜杠
    let path: string = rawPath.split('\\').join('/');
    // 收敛连续多重斜杠
    while (path.indexOf('//') !== -1) {
      path = path.split('//').join('/');
    }
    return path;
  }

  /**
   * 获取 SMB URL（smb://host/share 格式）。
   * shareName 为空时 base 为 "smb://host"（无尾部斜杠），避免与 normalized 拼接产生双斜杠。
   */
  getSmbUrl(path?: string): string {
    const base: string = this.shareName.length > 0
      ? `smb://${this.host}/${this.shareName}`
      : `smb://${this.host}`;
    if (path === undefined) {
      return base;
    }
    const raw: string = path.trim();
    if (raw.length === 0 || raw === '/') {
      return base;
    }
    // 统一规范化路径（Fix 4：与 buildSmbUrl 共用同一逻辑）
    let normalized: string = this.normalizePath(raw);
    // 确保以 / 开头
    if (!normalized.startsWith('/')) {
      normalized = '/' + normalized;
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
   * 解析全路径 "/shareName/sub/path" → { shareName, subPath }
   * 根目录 "/" 或 "" → { shareName: '', subPath: '/' }
   */
  private parsePath(fullPath: string): ParsedSmbPath {
    let clean = fullPath;
    while (clean.startsWith('/')) {
      clean = clean.substring(1);
    }
    while (clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }
    if (clean.length === 0) {
      const r: ParsedSmbPath = { shareName: '', subPath: '/' };
      return r;
    }
    const slashIdx = clean.indexOf('/');
    if (slashIdx === -1) {
      const r: ParsedSmbPath = { shareName: clean, subPath: '/' };
      return r;
    }
    const r: ParsedSmbPath = {
      shareName: clean.substring(0, slashIdx),
      subPath: '/' + clean.substring(slashIdx + 1)
    };
    return r;
  }

  /**
   * 在指定 shareName 下列举 subPath 目录内容。
   * 返回的每个文件 path 格式为 "/<shareName>/<sub/path>/<name>"。
   */
  private async listDirectoryInShare(shareName: string, subPath: string): Promise<SmbListDirectoryResult> {
    try {
      // smb2_opendir 在连接 share 后期望路径不含前导 "/"（如 "Movies" 而非 "/Movies"）
      // 空字符串由 native 层自动处理为 share 根目录
      const nativePath = subPath.startsWith('/') ? subPath.substring(1) : subPath;
      console.info('[SMBClient] listDirectoryInShare shareName=' + shareName + ' subPath=' + subPath + ' nativePath=' + nativePath);
      const raw = await getModule().smbListDirectory(
        this.host,
        this.port,
        this.username,
        this.password,
        this.domain,
        shareName,
        nativePath,
        this.timeoutMs
      ) as Record<string, Object>;

      const filesRaw = raw['files'] as Object[];
      if (raw['error']) {
        console.error('[SMBClient] native error shareName=' + shareName + ' nativePath=' + nativePath + ' err=' + (raw['error'] as string));
      } else {
        console.info('[SMBClient] native ok shareName=' + shareName + ' nativePath=' + nativePath + ' count=' + filesRaw.length.toString());
      }
      // 构造全路径：/<shareName>/<subPath去尾斜杠>/<name>
      let cleanSub = subPath;
      while (cleanSub.endsWith('/')) {
        cleanSub = cleanSub.substring(0, cleanSub.length - 1);
      }
      const files: SmbFileInfo[] = filesRaw.map((f) => {
        const fm = f as Record<string, Object>;
        const name = fm['name'] as string;
        const fileInfo: SmbFileInfo = {
          name: name,
          path: '/' + shareName + cleanSub + '/' + name,
          isDirectory: fm['isDirectory'] as boolean,
          size: fm['size'] as number,
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
      return { files: [], error: err.message ?? '调用失败' };
    }
  }

  /**
   * 列举指定路径下的文件和目录。
   *
   * 路径规则：
   *   - "" 或 "/"：列举服务器上所有磁盘共享，以目录形式返回（无需预知共享名）
   *   - "/<share>"：列举 share 的根目录
   *   - "/<share>/sub/path"：列举 share 内部的子路径
   */
  async listDirectory(path: string): Promise<SmbListDirectoryResult> {
    console.info(`[SMBClient] listDirectory: ${this.host}${path}`);
    const parsed = this.parsePath(path);

    if (parsed.shareName.length === 0) {
      // 根目录：枚举共享，每个磁盘共享作为一个目录项
      const sharesResult = await this.listShares();
      const files: SmbFileInfo[] = [];
      for (const s of sharesResult.shares) {
        if ((s.type & 3) === 0) {
          const fileInfo: SmbFileInfo = {
            name: s.name,
            path: '/' + s.name,
            isDirectory: true,
            size: 0,
            lastModifiedMs: 0
          };
          files.push(fileInfo);
        }
      }
      return { files, error: sharesResult.error };
    }

    return this.listDirectoryInShare(parsed.shareName, parsed.subPath);
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
   * 构建带凭据的完整 SMB URL，用于直接传递给 Native NAPI。
   * 格式：smb://[user[:pass]@]host[:port]/share/filePath
   * 凭据经过 percent-encode，与 Native ParseSmbUrl() 的解码逻辑对应。
   */
  private buildSmbUrl(filePath: string): string {
    let auth: string = '';
    if (this.username.length > 0) {
      auth = encodeURIComponent(this.username);
      if (this.password.length > 0) {
        auth += ':' + encodeURIComponent(this.password);
      }
      auth += '@';
    }
    const portPart: string = this.port !== 445 ? `:${this.port.toString()}` : '';
    const sharePart: string = this.shareName.length > 0 ? '/' + this.shareName : '';
    // Fix 4：规范化路径（反斜杠转正斜杠、合并重复斜杠），与 getSmbUrl 保持一致
    let normalized: string = this.normalizePath(filePath.trim());
    if (normalized.length > 0 && !normalized.startsWith('/')) {
      normalized = '/' + normalized;
    }
    return 'smb://' + auth + this.host + portPart + sharePart + normalized;
  }

  /**
   * 通过 SMB 协议读取小文件（如字幕 .srt/.ass）的 UTF-8 文本内容。
   *
   * @param filePath  相对于配置根 shareName 的文件路径，如 "/Videos/subtitle.srt"
   * @param maxSizeBytes  最大读取字节数，超过则 reject；默认 5MB
   * @returns  文件全文 UTF-8 字符串
   */
  async readTextFile(filePath: string, maxSizeBytes: number = 5 * 1024 * 1024): Promise<string> {
    // 脱敏日志：只打印 host + shareName + filePath，不打印凭据
    console.info(`[SMBClient] readTextFile: ${this.host}/${this.shareName}${filePath}`);
    const url: string = this.buildSmbUrl(filePath);
    try {
      // Fix C: 传入 timeoutSeconds=5，替代 Native 侧原硬编码 30s
      const content: string = await getModule().smbReadTextFile(url, maxSizeBytes, 5);
      return content;
    } catch (e) {
      const err = e as import('@kit.BasicServicesKit').BusinessError;
      throw new Error(err.message ?? '读取文件失败');
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

  /**
   * 并发扫描子网内开放指定端口的主机（通常 port=445 用于 SMB 发现）。
   * subnetPrefix 如 "192.168.3."，startOctet/endOctet 如 1/254，timeoutMs 扫描超时。
   */
  static async discoverHosts(
    subnetPrefix: string,
    startOctet: number,
    endOctet: number,
    port: number,
    timeoutMs: number
  ): Promise<SmbDiscoverHostsResult> {
    try {
      const raw = await getModule().smbDiscoverHosts(
        subnetPrefix,
        startOctet,
        endOctet,
        port,
        timeoutMs
      ) as Record<string, Object>;

      const hostsRaw = raw['hosts'] as Object[];
      const hosts: string[] = hostsRaw.map((h) => h as string);
      const result: SmbDiscoverHostsResult = { hosts };
      if (raw['error']) {
        result.error = raw['error'] as string;
      }
      return result;
    } catch (e) {
      const err = e as import('@kit.BasicServicesKit').BusinessError;
      return { hosts: [], error: err.message ?? '调用失败' };
    }
  }
}

export interface SmbAuthInfo {
  username: string;
  domain: string;
}
