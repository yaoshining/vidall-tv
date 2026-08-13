/**
 * WebDAV 客户端公共类型定义。
 * 拆分自 WebDAVClient.ets，供 connection / http / downloader / xmlParser 共用。
 */

export interface WebDAVConfig {
  baseUrl: string;
  username?: string;
  password?: string;
  timeout?: number;
  /**
   * TLS 证书校验策略，默认 'allow_self_signed'（面向家庭用户优先保证易用性）。
   * - 'allow_self_signed': 默认，跳过 TLS 证书校验，兼容代理、自签名证书等家庭网络场景。
   * - 'strict': 严格校验系统 CA，拒绝过期、域名不匹配和不受信任证书。
   */
  tlsCertPolicy?: 'strict' | 'allow_self_signed';
}

export interface WebDAVResource {
  href: string;
  displayName: string;
  isCollection: boolean;
  size?: number;
  lastModified?: string;
  contentType?: string;
}

// 流式下载进度回调
export interface StreamDownloadCallback {
  onProgress?: (downloaded: number, total: number) => void;
  onComplete?: (filePath: string) => void;
  onError?: (error: Error) => void;
}

export interface TestConnectionResult {
  success: boolean;
  message: string;
}
