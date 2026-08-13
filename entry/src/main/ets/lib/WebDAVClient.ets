import http from '@ohos.net.http';
import { WebDavConnection } from './WebDavConnection';
import { WebDavHttp } from './WebDavHttp';
import { WebDavXmlParser } from './WebDavXmlParser';
import { WebDavDownloader } from './WebDavDownloader';
import {
  classifyTlsError, isTlsError, normalizeTlsCertPolicy, sanitizeUrlForAudit, buildWebDavHttpHeader
} from './WebDavUtils';
import { WebDAVConfig, WebDAVResource, StreamDownloadCallback, TestConnectionResult } from './WebDavTypes';

// 保持既有 import 路径与导出符号完全兼容（外部调用方零改动）。
export { classifyTlsError, isTlsError, normalizeTlsCertPolicy, sanitizeUrlForAudit, buildWebDavHttpHeader };
export { WebDAVConfig, WebDAVResource, StreamDownloadCallback, TestConnectionResult };

/**
 * WebDAV 客户端门面。
 *
 * 传输层已拆至 WebDavHttp，连接/URL/认证拆至 WebDavConnection，
 * XML 解析拆至 WebDavXmlParser，下载拆至 WebDavDownloader；
 * 本类保留对外 public API（getAuthHeaderPublic / getFullUrl /
 * listDirectory / downloadFileStream / testConnection），行为不变。
 */
export class WebDAVClient {
  private connection: WebDavConnection;
  private http: WebDavHttp;
  private xmlParser: WebDavXmlParser;
  private downloader: WebDavDownloader;

  constructor(config: WebDAVConfig) {
    this.connection = WebDavConnection.fromConfig(config);
    this.http = new WebDavHttp(this.connection);
    this.xmlParser = new WebDavXmlParser();
    this.downloader = new WebDavDownloader(this.connection, this.http, this.xmlParser);
  }

  /**
   * 获取 Auth Header（用于外部调用）
   */
  public getAuthHeaderPublic(): string {
    return this.connection.getAuthHeader();
  }

  /**
   * 获取完整的 WebDAV URL（用于流式播放）
   */
  public getFullUrl(path: string): string {
    return this.connection.getFullUrl(path);
  }

  /**
   * 流式下载文件（带进度回调）
   */
  async downloadFileStream(
    remotePath: string,
    localFilePath: string,
    callback?: StreamDownloadCallback,
    redirectCount: number = 0
  ): Promise<void> {
    return this.downloader.downloadFileStream(remotePath, localFilePath, callback, redirectCount);
  }

  async listDirectory(path: string = '/'): Promise<WebDAVResource[]> {
    const basePath = this.connection.getBasePath();
    let fullPath = basePath + path;
    // 去除双斜杠（如 basePath='/' + path='/' → '//' → '/'）
    fullPath = fullPath.replace(/\/+/g, '/');

    // 对路径中的空格等特殊字符进行 URL 编码，避免 HTTP 请求行格式错误（400 Bad Request）
    const encodedPath = this.connection.encodeURIPath(fullPath);
    console.info('[WebDAVClient] listDirectory — baseUrl:', this.connection.baseUrl, 'basePath:', basePath, 'path:', path, 'fullPath:', fullPath);

    const propfindBody = `<?xml version="1.0" encoding="utf-8" ?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:displayname/>
    <D:getcontentlength/>
    <D:getlastmodified/>
    <D:getcontenttype/>
    <D:resourcetype/>
  </D:prop>
</D:propfind>`;

    const headers: Record<string, string> = {
      'Content-Type': 'application/xml; charset=utf-8',
      'Depth': '1',
      'User-Agent': 'WebDAV-Client/1.0',
      'Accept': '*/*'
    };

    const authHeader = this.connection.getAuthHeader();
    if (authHeader) {
      headers['Authorization'] = authHeader;
    }

    try {
      const response = await this.http.sendRawHttpRequest('PROPFIND', encodedPath, headers, propfindBody);

      console.info('PROPFIND response:', response.statusCode);

      if (response.statusCode === 207 || response.statusCode === 200) {
        return this.xmlParser.parsePropfindResponse(response.body);
      } else if (response.statusCode === 401) {
        throw new Error('认证失败');
      } else {
        throw new Error(`HTTP ${response.statusCode}: ${response.statusText}`);
      }
    } catch (error) {
      const errMsg = (error as Error).message ?? String(error);
      console.error('List error:', errMsg);
      throw new Error(errMsg);
    }
  }

  /**
   * 测试 WebDAV 连接
   * @returns 测试结果
   */
  async testConnection(): Promise<TestConnectionResult> {
    try {
      console.info('Testing WebDAV connection...');
      console.info('BaseUrl:', this.connection.baseUrl);

      const basePath = this.connection.getBasePath();
      console.info('Testing path:', basePath);
      const encodedBasePath = this.connection.encodeURIPath(basePath);

      // HTTP/HTTPS 统一走 PROPFIND（内部已是 native libcurl 优先 + fallback）
      const propfindBody = `<?xml version="1.0" encoding="utf-8" ?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:resourcetype/>
  </D:prop>
</D:propfind>`;

      const propfindHeaders: Record<string, string> = {
        'Content-Type': 'application/xml; charset=utf-8',
        'Depth': '0',
        'User-Agent': 'WebDAV-Client/1.0',
        'Accept': '*/*'
      };

      const authHeader = this.connection.getAuthHeader();
      if (authHeader) {
        propfindHeaders['Authorization'] = authHeader;
      }

      try {
        const response = await this.http.sendRawHttpRequest('PROPFIND', encodedBasePath, propfindHeaders, propfindBody);
        console.info('PROPFIND response status:', response.statusCode);

        if (response.statusCode === 401) {
          return { success: false, message: '认证失败，请检查用户名和密码' };
        }
        if (response.statusCode === 404) {
          return { success: false, message: '路径不存在或无权限访问' };
        }
        if (response.statusCode === 405) {
          return { success: false, message: '服务器不支持 WebDAV 协议或 PROPFIND 方法被禁用' };
        }
        if (response.statusCode !== 207 && response.statusCode !== 200) {
          return { success: false, message: `服务器返回错误：HTTP ${response.statusCode}` };
        }
        // HTTP 200 不一定是 WebDAV 响应，可能是普通 web 页面；需要验证内容
        if (response.statusCode === 200) {
          const bodyStr: string = response.body;
          if (bodyStr.includes('<html') || bodyStr.includes('<HTML')) {
            return { success: false, message: '服务器返回了网页而非 WebDAV 响应，请检查端口和根路径(rootPath)配置是否正确' };
          }
        }
        console.info('WebDAV connection test successful');
        return { success: true, message: '连接成功' };
      } catch (error) {
        const errMsg = (error as Error).message ?? '';
        console.error('Connection test failed:', JSON.stringify(error));

        // TLS 错误直接返回结构化提示，审计日志已在 sendViaNative 中记录
        if (isTlsError(errMsg)) {
          return { success: false, message: errMsg };
        }

        // HTTPS 在 PROPFIND 探测失败时，再回退 OPTIONS 判断是否是网络/证书层问题
        if (this.connection.isHttps) {
          return await this.testConnectionHttps(encodedBasePath);
        }

        return { success: false, message: '无法连接到服务器，请检查服务器地址和网络连接' };
      }
    } catch (error) {
      console.error('Test connection error:', JSON.stringify(error));
      return { success: false, message: '测试连接时发生未知错误：' + JSON.stringify(error) };
    }
  }

  /**
   * HTTPS 回退连通性测试：当 PROPFIND 探测失败时，用 OPTIONS 判断基础网络/鉴权状态
   */
  private async testConnectionHttps(encodedBasePath: string): Promise<TestConnectionResult> {
    const isStandardPort = this.connection.port === 443;
    const portStr = isStandardPort ? '' : `:${this.connection.port}`;
    const url = `https://${this.connection.host}${portStr}${encodedBasePath}`;

    const authHeader = this.connection.getAuthHeader();
    const requestHeaders: Record<string, string> = {
      'User-Agent': 'WebDAV-Client/1.0',
      'Accept': '*/*'
    };
    if (authHeader) {
      requestHeaders['Authorization'] = authHeader;
    }

    return new Promise((resolve) => {
      const httpRequest = http.createHttp();
      console.info(`WebDAV HTTPS testConnection OPTIONS: ${url}`);

      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.OPTIONS,
        header: requestHeaders,
        connectTimeout: this.connection.timeout,
        readTimeout: this.connection.timeout,
        expectDataType: http.HttpDataType.STRING
      };

      httpRequest.request(url, options, (err, data) => {
        httpRequest.destroy();
        if (err) {
          console.error(`WebDAV HTTPS OPTIONS error: ${JSON.stringify(err)}`);
          resolve({ success: false, message: `无法连接到服务器：${err.message || JSON.stringify(err)}` });
          return;
        }
        const statusCode = data.responseCode as number;
        console.info(`WebDAV HTTPS OPTIONS response: ${statusCode}`);

        if (statusCode === 401) {
          resolve({ success: false, message: '认证失败，请检查用户名和密码' });
          return;
        }
        if (statusCode === 403) {
          resolve({ success: false, message: '无权限访问，请检查账户权限' });
          return;
        }
        // OPTIONS 仅验证服务器网络可达性，无法确认是否为 WebDAV 服务
        // PROPFIND 已失败（可能非 WebDAV 端口或路径），不能仅凭 OPTIONS 成功就判定连接成功
        if (statusCode === 200 || statusCode === 207) {
          // OPTIONS 返回 200/207 只说明 HTTP 服务器可达，不一定是 WebDAV
          // 需检查 DAV header 确认 WebDAV 支持
          let hasDavHeader = false;
          const headerObj = data.header;
          if (headerObj !== null && headerObj !== undefined) {
            const headerRecord = headerObj as Record<string, string>;
            const davVal = headerRecord['DAV'] ?? headerRecord['dav'] ?? '';
            if (davVal.length > 0) {
              hasDavHeader = true;
            }
          }
          if (hasDavHeader) {
            console.info('WebDAV HTTPS connection test successful (DAV header confirmed)');
            resolve({ success: true, message: '连接成功' });
            return;
          }
          console.warn('WebDAV HTTPS OPTIONS OK but no DAV header, server may not be WebDAV');
          resolve({ success: false, message: '服务器可达但未检测到 WebDAV 服务，请检查端口和根路径(rootPath)配置' });
          return;
        }
        if (statusCode === 405) {
          // 405 = 不支持 OPTIONS 但服务器存在，无法确认是 WebDAV
          resolve({ success: false, message: '服务器可达但不支持 WebDAV 协议，请检查端口和根路径(rootPath)配置' });
          return;
        }
        if (statusCode >= 100 && statusCode < 500) {
          resolve({ success: false, message: `服务器返回 HTTP ${statusCode}，未确认是 WebDAV 服务，请检查端口和根路径配置` });
          return;
        }
        resolve({ success: false, message: `服务器返回错误：HTTP ${statusCode}` });
      });
    });
  }
}
