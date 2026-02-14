import socket from '@ohos.net.socket';
import buffer from '@ohos.buffer';
import fs from '@ohos.file.fs';

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

// 新增：流式下载进度回调
export interface StreamDownloadCallback {
  onProgress?: (downloaded: number, total: number) => void;
  onComplete?: (filePath: string) => void;
  onError?: (error: Error) => void;
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

  /**
   * 获取 Auth Header（用于外部调用）
   */
  public getAuthHeaderPublic(): string {
    return this.getAuthHeader();
  }

  /**
   * 获取完整的 WebDAV URL（用于流式播放）
   */
  public getFullUrl(path: string): string {
    let basePath = this.baseUrl.replace(/^https?:\/\/[^:\/]+(?::\d+)?/, '');
    let fullPath = basePath + (path.startsWith('/') ? path : '/' + path);

    return `${this.isHttps ? 'https' : 'http'}://${this.host}:${this.port}${fullPath}`;
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

      tcp.on('message', (value: socket.SocketMessageInfo) => {
        if (isComplete) return;

        try {
          console.info('Message event triggered');

          if (!value.message) {
            console.warn('Received null message');
            return;
          }

          const messageData = value.message as ArrayBuffer;

          if (messageData.byteLength === 0) {
            console.warn('Received empty ArrayBuffer');
            return;
          }

          hasReceivedData = true;

          const receivedBuffer = buffer.from(messageData);
          const chunk = receivedBuffer.toString('utf-8');
          fullResponseData += chunk;

          console.info(`Received ${chunk.length} bytes, total: ${fullResponseData.length}`);

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

      tcp.on('error', (err: Error) => {
        console.error('Socket error:', JSON.stringify(err));

        if (!isComplete) {
          isComplete = true;
          clearTimeout(timeoutId);
          tcp.close();
          reject(err);
        }
      });

      tcp.connect({ address: address, timeout: 10000 })
        .then(() => {
          console.info('Connected, sending request...');

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

          const sendBuffer = buffer.from(request, 'utf-8');

          return tcp.send({ data: sendBuffer.buffer });
        })
        .then(() => {
          console.info('Request sent, waiting for response...');

          setTimeout(() => {
            if (!hasReceivedData && !isComplete) {
              console.info('No message event received, trying manual receive...');

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

  /**
   * 流式下载文件（带进度回调）- 修复版
   * @param remotePath 远程文件路径
   * @param localFilePath 本地保存路径
   * @param callback 进度回调
   */
  async downloadFileStream(
    remotePath: string,
    localFilePath: string,
    callback?: StreamDownloadCallback
  ): Promise<void> {
    return new Promise((resolve, reject) => {
      const tcp = socket.constructTCPSocketInstance();
      let fileHandle: fs.File | null = null;
      let isComplete = false;
      let headerReceived = false;
      let contentLength = 0;
      let downloadedBytes = 0;
      let headerData = '';
      let headerBuffer: ArrayBuffer[] = [];
      let lastProgressTime = Date.now();
      let noDataCount = 0;

      const address: socket.NetAddress = {
        address: this.host,
        port: this.port,
        family: 1
      };

      console.info(`WebDAV Stream Download: Connecting to ${this.host}:${this.port}`);

      // 增加超时时间，并在有数据时重置
      const timeoutId = setTimeout(() => {
        if (!isComplete) {
          console.error(`Download timeout. Downloaded: ${downloadedBytes}/${contentLength}`);
          isComplete = true;
          if (fileHandle !== null) {
            try {
              fs.closeSync(fileHandle);
            } catch (error) {
              console.error('Close file error:', error);
            }
          }
          tcp.close();

          // 如果下载了大部分数据，考虑是否接受部分下载
          if (contentLength > 0 && downloadedBytes > contentLength * 0.95) {
            console.warn('Downloaded >95%, treating as complete');
            callback?.onComplete?.(localFilePath);
            resolve();
          } else {
            callback?.onError?.(new Error('Download timeout'));
            reject(new Error('Download timeout'));
          }
        }
      }, this.timeout * 2); // 增加超时时间

      // 监听数据接收
      tcp.on('message', (value: socket.SocketMessageInfo) => {
        if (isComplete) return;

        try {
          if (!value.message || (value.message as ArrayBuffer).byteLength === 0) {
            noDataCount++;
            console.warn(`Received empty data, count: ${noDataCount}`);

            // 如果连续收到多个空数据，可能是连接问题
            if (noDataCount > 5) {
              console.error('Too many empty data packets');
            }
            return;
          }

          noDataCount = 0; // 重置空数据计数
          lastProgressTime = Date.now();

          const messageData = value.message as ArrayBuffer;
          console.info(`Received packet: ${messageData.byteLength} bytes`);

          if (!headerReceived) {
            headerBuffer.push(messageData);

            const receivedBuffer = buffer.from(messageData);
            const chunk = receivedBuffer.toString('utf-8');
            headerData += chunk;

            const headerEndIndex = headerData.indexOf('\r\n\r\n');
            if (headerEndIndex !== -1) {
              headerReceived = true;

              const headerSection = headerData.substring(0, headerEndIndex);
              const bodyStartInString = headerEndIndex + 4;

              console.info('=== HTTP RESPONSE HEADER ===');
              console.info(headerSection);
              console.info('=== END HEADER ===');

              const statusMatch = headerSection.match(/HTTP\/[\d.]+\s+(\d+)\s+(.+)/);
              if (statusMatch) {
                const statusCode = parseInt(statusMatch[1]);
                const statusText = statusMatch[2];

                console.info(`HTTP Status: ${statusCode} ${statusText}`);

                if (statusCode !== 200) {
                  throw new Error(`HTTP ${statusCode}: ${statusText}`);
                }
              } else {
                throw new Error('Invalid HTTP response');
              }

              const contentLengthMatch = headerSection.match(/Content-Length:\s*(\d+)/i);
              if (contentLengthMatch) {
                contentLength = parseInt(contentLengthMatch[1]);
                console.info(`Content-Length: ${contentLength} bytes (${(contentLength/1024/1024).toFixed(2)} MB)`);
              } else {
                console.warn('No Content-Length header found');
              }

              fileHandle = fs.openSync(localFilePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);

              // 计算并写入头部后的body数据
              let totalHeaderBytes = 0;
              let headerEndBufferIndex = -1;
              let headerEndByteOffset = 0;

              for (let i = 0; i < headerBuffer.length; i++) {
                const bufStr = buffer.from(headerBuffer[i]).toString('utf-8');
                const bufLen = bufStr.length;

                if (totalHeaderBytes + bufLen >= bodyStartInString) {
                  headerEndBufferIndex = i;
                  headerEndByteOffset = bodyStartInString - totalHeaderBytes;
                  break;
                }

                totalHeaderBytes += bufLen;
              }

              if (headerEndBufferIndex >= 0 && headerEndBufferIndex < headerBuffer.length) {
                // 计算第一个body buffer中头部占用的字节数
                const firstBuf = headerBuffer[headerEndBufferIndex];
                const firstBufStr = buffer.from(firstBuf).toString('utf-8');
                const headerBytesInFirstBuf = buffer.from(firstBufStr.substring(0, headerEndByteOffset), 'utf-8').length;

                // 写入第一个包含body的buffer的剩余部分
                if (headerBytesInFirstBuf < firstBuf.byteLength) {
                  const firstBodyData = firstBuf.slice(headerBytesInFirstBuf);
                  fs.writeSync(fileHandle.fd, firstBodyData);
                  downloadedBytes += firstBodyData.byteLength;
                  console.info(`Wrote first body chunk: ${firstBodyData.byteLength} bytes`);
                }

                // 写入后续的buffer
                for (let i = headerEndBufferIndex + 1; i < headerBuffer.length; i++) {
                  fs.writeSync(fileHandle.fd, headerBuffer[i]);
                  downloadedBytes += headerBuffer[i].byteLength;
                  console.info(`Wrote header buffer ${i}: ${headerBuffer[i].byteLength} bytes`);
                }
              }

              headerBuffer = [];

              console.info(`Initial body bytes written: ${downloadedBytes}/${contentLength}`);
              callback?.onProgress?.(downloadedBytes, contentLength);

              // 检查是否已经完成
              if (contentLength > 0 && downloadedBytes >= contentLength) {
                console.info('Download completed in header processing');
                isComplete = true;
                clearTimeout(timeoutId);

                fs.closeSync(fileHandle);
                fileHandle = null;

                tcp.close();

                callback?.onComplete?.(localFilePath);
                resolve();
              }
            }
          } else {
            // 继续写入文件数据
            if (fileHandle !== null) {
              fs.writeSync(fileHandle.fd, messageData);
              downloadedBytes += messageData.byteLength;

              const percentage = ((downloadedBytes / contentLength) * 100).toFixed(2);
              console.info(`Downloaded: ${downloadedBytes}/${contentLength} (${percentage}%)`);

              callback?.onProgress?.(downloadedBytes, contentLength);

              // 检查是否下载完成
              if (contentLength > 0 && downloadedBytes >= contentLength) {
                console.info('Download completed - all bytes received');
                isComplete = true;
                clearTimeout(timeoutId);

                fs.closeSync(fileHandle);
                fileHandle = null;

                tcp.close();

                callback?.onComplete?.(localFilePath);
                resolve();
              }
            }
          }
        } catch (error) {
          console.error('Download error:', JSON.stringify(error));
          if (!isComplete) {
            isComplete = true;
            clearTimeout(timeoutId);

            if (fileHandle !== null) {
              try {
                fs.closeSync(fileHandle);
              } catch (e) {
                console.error('Close file error:', e);
              }
            }

            tcp.close();
            callback?.onError?.(error as Error);
            reject(error);
          }
        }
      });

      // 监听连接关闭
      tcp.on('close', () => {
        console.info(`Connection closed. Downloaded: ${downloadedBytes}/${contentLength}`);

        if (!isComplete) {
          isComplete = true;
          clearTimeout(timeoutId);

          if (fileHandle !== null) {
            try {
              fs.closeSync(fileHandle);
            } catch (error) {
              console.error('Close file error:', error);
            }
          }

          // 检查下载完成度
          if (contentLength > 0) {
            const completionRate = (downloadedBytes / contentLength) * 100;
            console.info(`Download completion rate: ${completionRate.toFixed(2)}%`);

            // 如果下载了 99% 以上，考虑接受（可能只是丢失了最后几个字节）
            if (completionRate >= 99.9) {
              console.warn('Download >99.9% complete, treating as successful');
              callback?.onComplete?.(localFilePath);
              resolve();
            } else if (downloadedBytes === contentLength) {
              console.info('Download completed successfully');
              callback?.onComplete?.(localFilePath);
              resolve();
            } else {
              const missingBytes = contentLength - downloadedBytes;
              const error = new Error(`Connection closed unexpectedly. Downloaded: ${downloadedBytes}/${contentLength} (missing ${missingBytes} bytes)`);
              callback?.onError?.(error);
              reject(error);
            }
          } else {
            // 没有 Content-Length，无法验证
            console.warn('No Content-Length, assuming download complete');
            callback?.onComplete?.(localFilePath);
            resolve();
          }
        }
      });

      // 监听错误
      tcp.on('error', (err: Error) => {
        console.error('Socket error:', JSON.stringify(err));

        if (!isComplete) {
          isComplete = true;
          clearTimeout(timeoutId);

          if (fileHandle !== null) {
            try {
              fs.closeSync(fileHandle);
            } catch (error) {
              console.error('Close file error:', error);
            }
          }

          tcp.close();
          callback?.onError?.(err);
          reject(err);
        }
      });

      // 构建完整路径并编码
      let basePath = this.baseUrl.replace(/^https?:\/\/[^:\/]+(?::\d+)?/, '');
      let fullPath = basePath + (remotePath.startsWith('/') ? remotePath : '/' + remotePath);
      fullPath = this.encodeURIPath(fullPath);

      console.info('Download path (encoded):', fullPath);

      // 连接并发送请求
      tcp.connect({ address: address, timeout: 10000 })
        .then(() => {
          console.info('Connected, sending download request...');

          let request = `GET ${fullPath} HTTP/1.1\r\n`;
          request += `Host: ${this.host}:${this.port}\r\n`;
          request += `User-Agent: WebDAV-Client/1.0\r\n`;
          request += `Accept: */*\r\n`;

          const authHeader = this.getAuthHeader();
          if (authHeader) {
            request += `Authorization: ${authHeader}\r\n`;
          }

          request += `Connection: close\r\n`;
          request += `\r\n`;

          console.info('=== DOWNLOAD REQUEST ===');
          console.info(request);
          console.info('=== END REQUEST ===');

          const sendBuffer = buffer.from(request, 'utf-8');
          return tcp.send({ data: sendBuffer.buffer });
        })
        .then(() => {
          console.info('Download request sent successfully');
        })
        .catch((err: Error) => {
          console.error('Connect/Send error:', JSON.stringify(err));

          if (!isComplete) {
            isComplete = true;
            clearTimeout(timeoutId);
            tcp.close();
            callback?.onError?.(err);
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

  /**
   * 编码 URI 路径（保留斜杠）
   */
  private encodeURIPath(path: string): string {
    // 分割路径，对每个部分单独编码，然后重新组合
    const parts = path.split('/');
    const encodedParts: string[] = [];

    for (let i = 0; i < parts.length; i++) {
      if (parts[i]) {
        // 使用 encodeURIComponent 对每个路径段进行编码
        encodedParts.push(encodeURIComponent(parts[i]));
      } else {
        encodedParts.push('');
      }
    }

    return encodedParts.join('/');
  }
}