import buffer from '@ohos.buffer';
import { WebDAVConfig } from './WebDavTypes';
import { normalizeTlsCertPolicy } from './WebDavUtils';

/**
 * WebDAV 连接配置值对象：承载从 WebDAVConfig 解析出的连接状态，
 * 以及 URL 构建、认证头与路径编码等与连接相关的逻辑。
 * 拆分自 WebDAVClient.ets。
 */
export class WebDavConnection {
  readonly baseUrl: string;
  readonly host: string;
  readonly port: number;
  readonly isHttps: boolean;
  readonly username: string;
  readonly password: string;
  readonly timeout: number;
  readonly tlsCertPolicy: string;

  private constructor(config: WebDAVConfig) {
    this.baseUrl = config.baseUrl.replace(/\/$/, '');
    this.username = config.username || '';
    this.password = config.password || '';
    this.timeout = config.timeout || 30000;
    // 默认放开 TLS 验证以兼容家庭网络（代理、自签名证书）；仅显式传 'strict' 时才严格校验。
    this.tlsCertPolicy = normalizeTlsCertPolicy(config.tlsCertPolicy);

    const urlPattern = /^(https?):\/\/([^:\/]+)(?::(\d+))?(\/.*)?$/;
    const match = this.baseUrl.match(urlPattern);

    if (match) {
      this.isHttps = match[1] === 'https';
      this.host = match[2];
      this.port = match[3] ? parseInt(match[3]) : (this.isHttps ? 443 : 80);
    } else {
      throw new Error('Invalid URL format');
    }

    console.info(`WebDAV: host=${this.host}, port=${this.port}, https=${this.isHttps}`);
  }

  static fromConfig(config: WebDAVConfig): WebDavConnection {
    return new WebDavConnection(config);
  }

  /**
   * 获取 Auth Header（用于外部调用与下载/目录请求）
   */
  getAuthHeader(): string {
    if (!this.username) {
      return '';
    }

    try {
      const credentials = `${this.username}:${this.password}`;
      const buf = buffer.from(credentials, 'utf-8');
      const base64 = buf.toString('base64');
      return `Basic ${base64}`;
    } catch (error) {
      console.error('Auth header error:', JSON.stringify(error));
      return `Basic ${this.base64Encode(`${this.username}:${this.password}`)}`;
    }
  }

  /**
   * 获取完整的 WebDAV URL（用于流式播放）
   */
  getFullUrl(path: string): string {
    return `${this.isHttps ? 'https' : 'http'}://${this.host}:${this.port}${this.buildEncodedPath(path)}`;
  }

  /**
   * 合并服务根路径和资源路径，确保所有请求使用相同的路径规范化规则。
   */
  buildEncodedPath(remotePath: string): string {
    const basePath = this.getBasePath();
    // 文件浏览器会把选中目录拼入 baseUrl，仅规整路径段，避免产生重复斜杠。
    const fullPath = `${basePath}/${remotePath}`.replace(/\/{2,}/g, '/');
    return this.encodeURIPath(fullPath);
  }

  /**
   * 提取服务根路径（去掉协议与 host:port），供目录列表与连接测试复用。
   */
  getBasePath(): string {
    let basePath = this.baseUrl.replace(/^https?:\/\/[^:\/]+(?::\d+)?/, '');
    if (!basePath) {
      basePath = '/';
    }
    return basePath;
  }

  private base64Encode(str: string): string {
    const base64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let result = '';
    let i = 0;

    while (i < str.length) {
      const a = str.charCodeAt(i++);
      const b = i < str.length ? str.charCodeAt(i++) : 0;
      const c = i < str.length ? str.charCodeAt(i++) : 0;

      const bitmap = (a << 16) | (b << 8) | c;

      result += base64Chars.charAt((bitmap >> 18) & 63);
      result += base64Chars.charAt((bitmap >> 12) & 63);
      result += i - 1 < str.length ? base64Chars.charAt((bitmap >> 6) & 63) : '=';
      result += i < str.length ? base64Chars.charAt(bitmap & 63) : '=';
    }

    return result;
  }

  /**
   * 编码 URI 路径（保留斜杠）
   * 注意：智能处理已编码和未编码的路径段
   */
  encodeURIPath(path: string): string {
    // 分割路径，对每个部分单独检查和编码
    const parts = path.split('/');
    const encodedParts: string[] = [];

    for (let i = 0; i < parts.length; i++) {
      if (parts[i]) {
        const part = parts[i];

        // 检查这个路径段是否已经被完全编码
        // 如果解码后再编码能得到相同的结果，说明已编码
        try {
          const decoded = decodeURIComponent(part);
          const reencoded = encodeURIComponent(decoded);

          if (reencoded === part) {
            // 已经正确编码，直接使用
            encodedParts.push(part);
          } else {
            // 未正确编码或部分编码，重新编码
            // 但首先尝试解码，如果包含已编码的内容（如%20），需要先解码
            const hasEncodedChars = /%[0-9A-F]{2}/i.test(part);
            if (hasEncodedChars) {
              // 包含编码字符，先解码再重新编码
              encodedParts.push(encodeURIComponent(decoded));
            } else {
              // 不包含编码字符，直接编码
              encodedParts.push(encodeURIComponent(part));
            }
          }
        } catch (e) {
          // 解码失败，说明包含无效的编码序列，直接编码原始字符串
          encodedParts.push(encodeURIComponent(part));
        }
      } else {
        encodedParts.push('');
      }
    }

    const result = encodedParts.join('/');
    console.info(`Path encoding: "${path}" -> "${result}"`);
    return result;
  }
}
