import socket from '@ohos.net.socket';
import buffer from '@ohos.buffer';

export interface WebDAVConfig {
  baseUrl: string;
  username?: string;
  password?: string;
  timeout?: number;
}

export interface WebDAVResource {
  href: string;
  displayName: string;
  isCollection: boolean;
  size?: number;
  lastModified?: string;
  contentType?: string;
}

class HttpResponse {
  statusCode: number = 0;
  statusText: string = '';
  headers: Map<string, string> = new Map();
  body: string = '';
}

export class WebDAVClient {
  private baseUrl: string;
  private host: string;
  private port: number;
  private isHttps: boolean;
  private username: string;
  private password: string;
  private timeout: number;

  constructor(config: WebDAVConfig) {
    this.baseUrl = config.baseUrl.replace(/\/$/, '');
    this.username = config.username || '';
    this.password = config.password || '';
    this.timeout = config.timeout || 30000;

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

  private getAuthHeader(): string {
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
   * 使用 Socket 发送请求 - 修复接收问题
   */
  private async sendRawHttpRequest(
    method: string,
    path: string,
    headers: Record<string, string>,
    body?: string
  ): Promise<HttpResponse> {
    return new Promise((resolve, reject) => {
      const tcp = socket.constructTCPSocketInstance();
      let fullResponseData = '';
      let isComplete = false;
      let hasReceivedData = false;

      const address: socket.NetAddress = {
        address: this.host,
        port: this.port,
        family: 1
      };

      console.info(`WebDAV: Connecting to ${this.host}:${this.port}`);

      const timeoutId = setTimeout(() => {
        if (!isComplete) {
          console.error('Request timeout');
          isComplete = true;
          tcp.close();

          if (fullResponseData.length > 0) {
            try {
              const response = this.parseHttpResponse(fullResponseData);
              resolve(response);
            } catch (error) {
              reject(new Error('Timeout and parse failed'));
            }
          } else {
            reject(new Error('Timeout - no data received'));
          }
        }
      }, this.timeout);

      // 修复：监听消息事件
      tcp.on('message', (value: socket.SocketMessageInfo) => {
        if (isComplete) return;

        try {
          console.info('Message event triggered');

          // 检查 message 是否为空
          if (!value.message) {
            console.warn('Received null message');
            return;
          }

          const messageData = value.message as ArrayBuffer;

          // 检查 ArrayBuffer 大小
          if (messageData.byteLength === 0) {
            console.warn('Received empty ArrayBuffer');
            return;
          }

          hasReceivedData = true;

          const receivedBuffer = buffer.from(messageData);
          const chunk = receivedBuffer.toString('utf-8');
          fullResponseData += chunk;

          console.info(`Received ${chunk.length} bytes, total: ${fullResponseData.length}`);

          // 检查是否完整
          if (this.isHttpResponseComplete(fullResponseData)) {
            console.info('Complete response detected');
            isComplete = true;
            clearTimeout(timeoutId);

            try {
              const response = this.parseHttpResponse(fullResponseData);
              tcp.close();
              resolve(response);
            } catch (error) {
              tcp.close();
              reject(error);
            }
          }
        } catch (error) {
          console.error('Message error:', JSON.stringify(error));
        }
      });

      // 监听连接关闭
      tcp.on('close', () => {
        console.info(`Connection closed, received data: ${hasReceivedData}`);

        if (!isComplete) {
          isComplete = true;
          clearTimeout(timeoutId);

          if (fullResponseData.length > 0) {
            try {
              const response = this.parseHttpResponse(fullResponseData);
              resolve(response);
            } catch (error) {
              reject(error);
            }
          } else {
            reject(new Error('Connection closed without receiving data'));
          }
        }
      });

      // 监听错误
      tcp.on('error', (err: Error) => {
        console.error('Socket error:', JSON.stringify(err));

        if (!isComplete) {
          isComplete = true;
          clearTimeout(timeoutId);
          tcp.close();
          reject(err);
        }
      });

      // 连接
      tcp.connect({ address: address, timeout: 10000 })
        .then(() => {
          console.info('Connected, sending request...');

          // 构建请求
          let request = `${method} ${path} HTTP/1.1\r\n`;
          request += `Host: ${this.host}:${this.port}\r\n`;

          const headerKeys = Object.keys(headers);
          for (let i = 0; i < headerKeys.length; i++) {
            const key = headerKeys[i];
            request += `${key}: ${headers[key]}\r\n`;
          }

          if (body) {
            const bodyBytes = buffer.from(body, 'utf-8');
            request += `Content-Length: ${bodyBytes.length}\r\n`;
          } else {
            request += `Content-Length: 0\r\n`;
          }

          request += `Connection: close\r\n`;
          request += `\r\n`;

          if (body) {
            request += body;
          }

          console.info('=== REQUEST ===');
          console.info(request);
          console.info('=== END ===');

          // 发送
          const sendBuffer = buffer.from(request, 'utf-8');

          return tcp.send({ data: sendBuffer.buffer });
        })
        .then(() => {
          console.info('Request sent, waiting for response...');

          // 发送后立即尝试接收（备用方案）
          setTimeout(() => {
            if (!hasReceivedData && !isComplete) {
              console.info('No message event received, trying manual receive...');

              // 尝试手动接收
              tcp.getState().then((state: socket.SocketStateBase) => {
                console.info('Socket state:', JSON.stringify(state));

                if (state.isClose) {
                  console.info('Socket already closed');

                  if (!isComplete) {
                    isComplete = true;
                    clearTimeout(timeoutId);
                    reject(new Error('Socket closed before receiving data'));
                  }
                }
              });
            }
          }, 2000);
        })
        .catch((err: Error) => {
          console.error('Connect/Send error:', JSON.stringify(err));

          if (!isComplete) {
            isComplete = true;
            clearTimeout(timeoutId);
            tcp.close();
            reject(err);
          }
        });
    });
  }

  private isHttpResponseComplete(data: string): boolean {
    const headerEndIndex = data.indexOf('\r\n\r\n');
    if (headerEndIndex === -1) {
      return false;
    }

    const contentLengthMatch = data.match(/Content-Length:\s*(\d+)/i);
    if (contentLengthMatch) {
      const expectedLength = parseInt(contentLengthMatch[1]);
      const bodyStart = headerEndIndex + 4;
      const actualBodyLength = data.length - bodyStart;

      console.info(`Content-Length: ${expectedLength}, Actual: ${actualBodyLength}`);

      return actualBodyLength >= expectedLength;
    }

    if (data.match(/Transfer-Encoding:\s*chunked/i)) {
      return data.endsWith('0\r\n\r\n') || data.endsWith('0\r\n\r\n\r\n');
    }

    return false;
  }

  private parseHttpResponse(responseText: string): HttpResponse {
    const response = new HttpResponse();

    console.info('=== RESPONSE ===');
    console.info(responseText.substring(0, 1000));
    console.info('=== END ===');

    const headerEndIndex = responseText.indexOf('\r\n\r\n');
    if (headerEndIndex === -1) {
      throw new Error('Invalid HTTP response');
    }

    const headerSection = responseText.substring(0, headerEndIndex);
    response.body = responseText.substring(headerEndIndex + 4);

    const lines = headerSection.split('\r\n');

    if (lines.length === 0) {
      throw new Error('No status line');
    }

    const statusLine = lines[0];
    console.info('Status:', statusLine);

    const statusMatch = statusLine.match(/HTTP\/[\d.]+\s+(\d+)\s+(.+)/);
    if (statusMatch) {
      response.statusCode = parseInt(statusMatch[1]);
      response.statusText = statusMatch[2];
    }

    for (let i = 1; i < lines.length; i++) {
      const colonIndex = lines[i].indexOf(':');
      if (colonIndex > 0) {
        const key = lines[i].substring(0, colonIndex).trim().toLowerCase();
        const value = lines[i].substring(colonIndex + 1).trim();
        response.headers.set(key, value);
      }
    }

    console.info(`Status: ${response.statusCode}, Body: ${response.body.length} bytes`);

    return response;
  }

  async listDirectory(path: string = '/'): Promise<WebDAVResource[]> {
    let basePath = this.baseUrl.replace(/^https?:\/\/[^:\/]+(?::\d+)?/, '');
    if (!basePath) {
      basePath = '';
    }

    let fullPath = basePath + path;
    if (!fullPath.startsWith('/')) {
      fullPath = '/' + fullPath;
    }

    console.info('Listing:', fullPath);

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

    const authHeader = this.getAuthHeader();
    if (authHeader) {
      headers['Authorization'] = authHeader;
    }

    try {
      const response = await this.sendRawHttpRequest('PROPFIND', fullPath, headers, propfindBody);

      console.info('PROPFIND response:', response.statusCode);

      if (response.statusCode === 207 || response.statusCode === 200) {
        return this.parsePropfindResponse(response.body);
      } else if (response.statusCode === 401) {
        throw new Error('认证失败');
      } else {
        throw new Error(`HTTP ${response.statusCode}: ${response.statusText}`);
      }
    } catch (error) {
      console.error('List error:', JSON.stringify(error));
      throw new Error(error);
    }
  }

  private parsePropfindResponse(xmlText: string): WebDAVResource[] {
    const resources: WebDAVResource[] = [];

    try {
      if (xmlText.includes('<html') || xmlText.includes('<HTML')) {
        console.error('Received HTML');
        return resources;
      }

      const responsePattern = /<(?:D:)?response[^>]*>([\s\S]*?)<\/(?:D:)?response>/gi;
      const matches = Array.from(xmlText.matchAll(responsePattern));

      console.info(`Found ${matches.length} resources`);

      for (let i = 0; i < matches.length; i++) {
        const match = matches[i];
        const responseXml = match[1];

        const href = this.extractXmlValue(responseXml, 'href');
        const displayName = this.extractXmlValue(responseXml, 'displayname');
        const size = this.extractXmlValue(responseXml, 'getcontentlength');
        const lastModified = this.extractXmlValue(responseXml, 'getlastmodified');
        const contentType = this.extractXmlValue(responseXml, 'getcontenttype');
        const isCollection = responseXml.includes('<collection') || responseXml.includes(':collection');

        if (href) {
          const pathParts = href.split('/');
          const filteredParts: string[] = [];
          for (let j = 0; j < pathParts.length; j++) {
            if (pathParts[j]) {
              filteredParts.push(pathParts[j]);
            }
          }
          const lastPart = filteredParts.length > 0 ? filteredParts[filteredParts.length - 1] : '';

          resources.push({
            href: href,
            displayName: displayName || decodeURIComponent(lastPart),
            isCollection: isCollection,
            size: size ? parseInt(size) : undefined,
            lastModified: lastModified,
            contentType: contentType
          });
        }
      }
    } catch (error) {
      console.error('Parse error:', JSON.stringify(error));
    }

    return resources;
  }

  private extractXmlValue(xml: string, tagName: string): string {
    const patterns = [
      new RegExp(`<D:${tagName}[^>]*>([\\s\\S]*?)<\\/D:${tagName}>`, 'i'),
      new RegExp(`<d:${tagName}[^>]*>([\\s\\S]*?)<\\/d:${tagName}>`, 'i'),
      new RegExp(`<${tagName}[^>]*>([\\s\\S]*?)<\\/${tagName}>`, 'i')
    ];

    for (let i = 0; i < patterns.length; i++) {
      const match = xml.match(patterns[i]);
      if (match) {
        return match[1].trim();
      }
    }

    return '';
  }

  async testConnection(): Promise<boolean> {
    let fullPath = this.baseUrl.replace(/^https?:\/\/[^:\/]+(?::\d+)?/, '');
    if (!fullPath) {
      fullPath = '/';
    }

    const headers: Record<string, string> = {
      'User-Agent': 'WebDAV-Client/1.0'
    };

    const authHeader = this.getAuthHeader();
    if (authHeader) {
      headers['Authorization'] = authHeader;
    }

    try {
      const response = await this.sendRawHttpRequest('OPTIONS', fullPath, headers);
      console.info('OPTIONS:', response.statusCode);
      return response.statusCode >= 200 && response.statusCode < 400;
    } catch (error) {
      console.error('Test error:', JSON.stringify(error));
      return false;
    }
  }
}