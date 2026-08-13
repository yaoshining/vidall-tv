import socket from '@ohos.net.socket';
import buffer from '@ohos.buffer';
import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
import { WebDavConnection } from './WebDavConnection';
import { WebDavHttp } from './WebDavHttp';
import { WebDavXmlParser } from './WebDavXmlParser';
import { StreamDownloadCallback } from './WebDavTypes';

/**
 * WebDAV 流式下载（含 302 重定向与 HTTPS 支持）。
 * 拆分自 WebDAVClient.ets。
 */
export class WebDavDownloader {
  private connection: WebDavConnection;
  private http: WebDavHttp;
  private xmlParser: WebDavXmlParser;

  constructor(connection: WebDavConnection, http: WebDavHttp, xmlParser: WebDavXmlParser) {
    this.connection = connection;
    this.http = http;
    this.xmlParser = xmlParser;
  }

  /**
   * 流式下载文件（带进度回调）- 修复版，支持302重定向，支持HTTPS
   * @param remotePath 远程文件路径
   * @param localFilePath 本地保存路径
   * @param callback 进度回调
   * @param redirectCount 重定向计数（内部使用，防止无限重定向）
   */
  async downloadFileStream(
    remotePath: string,
    localFilePath: string,
    callback?: StreamDownloadCallback,
    redirectCount: number = 0
  ): Promise<void> {
    // 防止无限重定向
    const MAX_REDIRECTS = 5;
    if (redirectCount > MAX_REDIRECTS) {
      const error = new Error(`Too many redirects (>${MAX_REDIRECTS})`);
      callback?.onError?.(error);
      throw error;
    }

    const fullPath = this.connection.buildEncodedPath(remotePath);

    const downloadHeaders: Record<string, string> = {
      'User-Agent': 'WebDAV-Client/1.0',
      'Accept': '*/*'
    };
    const authHeader = this.connection.getAuthHeader();
    if (authHeader) {
      downloadHeaders['Authorization'] = authHeader;
    }

    if (this.http.checkNativeCurlEnabled()) {
      try {
        const nativeResult = await this.http.downloadViaNative(fullPath, localFilePath, downloadHeaders);
        if (nativeResult.error.length > 0) {
          throw new Error(`native curl download failed: ${nativeResult.error}`);
        }
        if (nativeResult.statusCode < 200 || nativeResult.statusCode >= 300) {
          throw new Error(`native curl download HTTP ${nativeResult.statusCode}`);
        }
        if (nativeResult.downloadedBytes <= 0) {
          throw new Error('native curl download received 0 bytes');
        }
        callback?.onProgress?.(nativeResult.downloadedBytes, nativeResult.downloadedBytes);
        callback?.onComplete?.(localFilePath);
        return;
      } catch (e) {
        console.warn(`WebDAV native download fallback: ${(e as Error).message}`);
      }
    }

    // HTTPS 协议直接使用 http 模块（支持 TLS），不走明文 TCP
    if (this.connection.isHttps) {
      console.info(`WebDAV Stream Download (HTTPS): ${fullPath}`);
      return this.downloadWithHttpModule(this.connection.host, this.connection.port, fullPath, localFilePath, callback, redirectCount);
    }

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
        address: this.connection.host,
        port: this.connection.port,
        family: 1
      };

      console.info(`WebDAV Stream Download: Connecting to ${this.connection.host}:${this.connection.port}`);

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
      }, this.connection.timeout * 2); // 增加超时时间

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

                // 处理重定向 (301, 302, 303, 307, 308)
                if (statusCode === 301 || statusCode === 302 || statusCode === 303 ||
                    statusCode === 307 || statusCode === 308) {
                  console.info(`Redirect detected: ${statusCode}`);

                  // 提取 Location 头
                  const locationMatch = headerSection.match(/Location:\s*(.+)/i);
                  if (locationMatch) {
                    const redirectUrl = locationMatch[1].trim();
                    console.info(`Redirect to: ${redirectUrl}`);

                    // 关闭当前连接
                    isComplete = true;
                    clearTimeout(timeoutId);
                    tcp.close();

                    // 解析重定向URL并递归调用
                    try {
                      const parsedUrl = this.xmlParser.parseRedirectUrl(
                        redirectUrl, this.connection.host, this.connection.port, this.connection.isHttps
                      );
                      console.info(`Parsed redirect: host=${parsedUrl.host}, port=${parsedUrl.port}, path=${parsedUrl.path}`);

                      // 调用重定向下载
                      this.downloadFileStreamWithRedirect(
                        parsedUrl.host,
                        parsedUrl.port,
                        parsedUrl.path,
                        parsedUrl.isHttps,
                        localFilePath,
                        callback,
                        redirectCount + 1
                      ).then(() => {
                        resolve();
                      }).catch((err: Error) => {
                        reject(err);
                      });

                      return; // 退出当前处理
                    } catch (parseError) {
                      const error = new Error(`Failed to parse redirect URL: ${parseError}`);
                      callback?.onError?.(error);
                      reject(error);
                      return;
                    }
                  } else {
                    const error = new Error(`Redirect ${statusCode} without Location header`);
                    throw error;
                  }
                }

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

      // 与播放地址使用同一套路径规范化和编码逻辑。
      const fullPath2 = this.connection.buildEncodedPath(remotePath);

      console.info('Download path (encoded):', fullPath2);

      // 连接并发送请求
      tcp.connect({ address: address, timeout: 10000 })
        .then(() => {
          console.info('Connected, sending download request...');

          let request = `GET ${fullPath2} HTTP/1.1\r\n`;
          request += `Host: ${this.connection.host}:${this.connection.port}\r\n`;
          request += `User-Agent: WebDAV-Client/1.0\r\n`;
          request += `Accept: */*\r\n`;

          const authHeader2 = this.connection.getAuthHeader();
          if (authHeader2) {
            request += `Authorization: ${authHeader2}\r\n`;
          }

          request += `Connection: close\r\n`;
          request += `\r\n`;

          console.info('=== DOWNLOAD REQUEST ===');
          console.info(this.http.sanitizeRequestForLog(request));
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

  /**
   * 使用指定的host和port进行重定向下载
   */
  private async downloadFileStreamWithRedirect(
    host: string,
    port: number,
    path: string,
    isHttps: boolean,
    localFilePath: string,
    callback?: StreamDownloadCallback,
    redirectCount: number = 0
  ): Promise<void> {
    // 如果是HTTPS，使用http模块
    if (isHttps || port === 443) {
      console.info('Using http module for HTTPS redirect download');
      return this.downloadWithHttpModule(host, port, path, localFilePath, callback, redirectCount);
    }

    // 否则使用socket（HTTP）
    return new Promise((resolve, reject) => {
      const tcp = socket.constructTCPSocketInstance();
      let fileHandle: fs.File | null = null;
      let isComplete = false;
      let headerReceived = false;
      let contentLength = 0;
      let downloadedBytes = 0;
      let headerData = '';
      let headerBuffer: ArrayBuffer[] = [];
      let noDataCount = 0;

      const address: socket.NetAddress = {
        address: host,
        port: port,
        family: 1
      };

      console.info(`WebDAV Redirect Download: Connecting to ${host}:${port}, path: ${path}`);

      const timeoutId = setTimeout(() => {
        if (!isComplete) {
          console.error(`Redirect download timeout. Downloaded: ${downloadedBytes}/${contentLength}`);
          isComplete = true;
          if (fileHandle !== null) {
            try {
              fs.closeSync(fileHandle);
            } catch (error) {
              console.error('Close file error:', error);
            }
          }
          tcp.close();

          if (contentLength > 0 && downloadedBytes > contentLength * 0.95) {
            console.warn('Downloaded >95%, treating as complete');
            callback?.onComplete?.(localFilePath);
            resolve();
          } else {
            callback?.onError?.(new Error('Redirect download timeout'));
            reject(new Error('Redirect download timeout'));
          }
        }
      }, this.connection.timeout * 2);

      // 监听数据接收
      tcp.on('message', (value: socket.SocketMessageInfo) => {
        if (isComplete) return;

        try {
          if (!value.message || (value.message as ArrayBuffer).byteLength === 0) {
            noDataCount++;
            console.warn(`Received empty data, count: ${noDataCount}`);
            if (noDataCount > 5) {
              console.error('Too many empty data packets');
            }
            return;
          }

          noDataCount = 0;
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

              console.info('=== REDIRECT HTTP RESPONSE HEADER ===');
              console.info(headerSection);
              console.info('=== END HEADER ===');

              const statusMatch = headerSection.match(/HTTP\/[\d.]+\s+(\d+)\s+(.+)/);
              if (statusMatch) {
                const statusCode = parseInt(statusMatch[1]);
                const statusText = statusMatch[2];

                console.info(`HTTP Status: ${statusCode} ${statusText}`);

                // 再次处理重定向（递归）
                if (statusCode === 301 || statusCode === 302 || statusCode === 303 ||
                    statusCode === 307 || statusCode === 308) {
                  console.info(`Another redirect detected: ${statusCode}`);

                  const locationMatch = headerSection.match(/Location:\s*(.+)/i);
                  if (locationMatch) {
                    const redirectUrl = locationMatch[1].trim();
                    console.info(`Redirect again to: ${redirectUrl}`);

                    isComplete = true;
                    clearTimeout(timeoutId);
                    tcp.close();

                    try {
                      const parsedUrl = this.xmlParser.parseRedirectUrl(
                        redirectUrl, this.connection.host, this.connection.port, this.connection.isHttps
                      );
                      this.downloadFileStreamWithRedirect(
                        parsedUrl.host,
                        parsedUrl.port,
                        parsedUrl.path,
                        parsedUrl.isHttps,
                        localFilePath,
                        callback,
                        redirectCount + 1
                      ).then(() => {
                        resolve();
                      }).catch((err: Error) => {
                        reject(err);
                      });
                      return;
                    } catch (parseError) {
                      const error = new Error(`Failed to parse redirect URL: ${parseError}`);
                      callback?.onError?.(error);
                      reject(error);
                      return;
                    }
                  }
                }

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

              // 写入body数据
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
                const firstBuf = headerBuffer[headerEndBufferIndex];
                const firstBufStr = buffer.from(firstBuf).toString('utf-8');
                const headerBytesInFirstBuf = buffer.from(firstBufStr.substring(0, headerEndByteOffset), 'utf-8').length;

                if (headerBytesInFirstBuf < firstBuf.byteLength) {
                  const firstBodyData = firstBuf.slice(headerBytesInFirstBuf);
                  fs.writeSync(fileHandle.fd, firstBodyData);
                  downloadedBytes += firstBodyData.byteLength;
                  console.info(`Wrote first body chunk: ${firstBodyData.byteLength} bytes`);
                }

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
          console.error('Redirect download error:', JSON.stringify(error));
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
        console.info(`Redirect connection closed. Downloaded: ${downloadedBytes}/${contentLength}`);

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

          if (contentLength > 0) {
            const completionRate = (downloadedBytes / contentLength) * 100;
            console.info(`Download completion rate: ${completionRate.toFixed(2)}%`);

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
            console.warn('No Content-Length, assuming download complete');
            callback?.onComplete?.(localFilePath);
            resolve();
          }
        }
      });

      // 监听错误
      tcp.on('error', (err: Error) => {
        console.error('Redirect socket error:', JSON.stringify(err));

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

      // 连接并发送请求
      tcp.connect({ address: address, timeout: 10000 })
        .then(() => {
          console.info('Connected to redirect target, sending download request...');

          let request = `GET ${path} HTTP/1.1\r\n`;
          request += `Host: ${host}\r\n`;  // 不要包含端口号在Host头中（对于标准端口）
          request += `User-Agent: WebDAV-Client/1.0\r\n`;
          request += `Accept: */*\r\n`;

          // 重定向请求通常不需要原始的认证信息
          // CDN和文件服务器使用URL中的签名参数进行验证
          // 只有当重定向到同一主机时才发送认证信息
          if (host === this.connection.host && port === this.connection.port) {
            const authHeader = this.connection.getAuthHeader();
            if (authHeader) {
              request += `Authorization: ${authHeader}\r\n`;
              console.info('Redirect to same host, including auth');
            }
          } else {
            console.info('Redirect to different host, skipping auth (using URL signature)');
          }

          request += `Connection: close\r\n`;
          request += `\r\n`;

          console.info('=== REDIRECT DOWNLOAD REQUEST ===');
          console.info(this.http.sanitizeRequestForLog(request));
          console.info('=== END REQUEST ===');

          const sendBuffer = buffer.from(request, 'utf-8');
          return tcp.send({ data: sendBuffer.buffer });
        })
        .then(() => {
          console.info('Redirect download request sent successfully');
        })
        .catch((err: Error) => {
          console.error('Redirect connect/send error:', JSON.stringify(err));

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

  /**
   * 使用http模块处理HTTPS重定向下载
   */
  private async downloadWithHttpModule(
    host: string,
    port: number,
    path: string,
    localFilePath: string,
    callback?: StreamDownloadCallback,
    redirectCount: number = 0
  ): Promise<void> {
    return new Promise((resolve, reject) => {
      const protocol = port === 443 ? 'https' : 'http';
      const portStr = (port === 443 || port === 80) ? '' : `:${port}`;
      const url = `${protocol}://${host}${portStr}${path}`;

      console.info(`Downloading with http module: ${url}`);

      const httpRequest = http.createHttp();
      let fileHandle: fs.File | null = null;
      let downloadedBytes = 0;
      let contentLength = 0;

      // 监听进度事件
      httpRequest.on('dataReceive', (data: ArrayBuffer) => {
        try {
          if (fileHandle === null) {
            fileHandle = fs.openSync(localFilePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
          }

          fs.writeSync(fileHandle.fd, data);
          downloadedBytes += data.byteLength;

          if (contentLength > 0) {
            const percentage = ((downloadedBytes / contentLength) * 100).toFixed(2);
            console.info(`HTTP download progress: ${downloadedBytes}/${contentLength} (${percentage}%)`);
            callback?.onProgress?.(downloadedBytes, contentLength);
          } else {
            console.info(`HTTP download progress: ${downloadedBytes} bytes`);
          }
        } catch (error) {
          console.error('Data receive error:', JSON.stringify(error));
        }
      });

      // 监听响应头
      httpRequest.on('headersReceive', (headers: object) => {
        console.info('=== HTTP HEADERS RECEIVED ===');
        console.info(JSON.stringify(headers));

        const contentLengthHeader = (headers['content-length'] || headers['Content-Length']) as string;
        if (contentLengthHeader) {
          contentLength = parseInt(contentLengthHeader as string);
          console.info(`Content-Length from headers: ${contentLength} bytes (${(contentLength/1024/1024).toFixed(2)} MB)`);
        }
      });

      // 同主机（含 WebDAV HTTPS 初始请求）需要携带认证头
      const requestHeaders: Record<string, string> = {
        'User-Agent': 'WebDAV-Client/1.0',
        'Accept': '*/*'
      };
      if (host === this.connection.host) {
        const authHeader = this.connection.getAuthHeader();
        if (authHeader) {
          requestHeaders['Authorization'] = authHeader;
          console.info('downloadWithHttpModule: including Authorization header');
        }
      }

      try {
        httpRequest.request(url, {
          method: http.RequestMethod.GET,
          connectTimeout: this.connection.timeout,
          readTimeout: this.connection.timeout * 2,
          header: requestHeaders,
          expectDataType: http.HttpDataType.ARRAY_BUFFER  // 使用ArrayBuffer接收数据
        }, (err, data) => {
          if (err) {
            console.error('HTTP request error:', JSON.stringify(err));

            if (fileHandle !== null) {
              try {
                fs.closeSync(fileHandle);
              } catch (e) {
                console.error('Close file error:', e);
              }
            }

            httpRequest.off('dataReceive');
            httpRequest.off('headersReceive');
            httpRequest.destroy();
            callback?.onError?.(err as Error);
            reject(err);
            return;
          }

          const responseCode = data.responseCode;
          console.info(`HTTP response code: ${responseCode}`);

          // 处理重定向
          if (responseCode === 301 || responseCode === 302 || responseCode === 303 ||
              responseCode === 307 || responseCode === 308) {
            const location = (data.header['location'] || data.header['Location']) as string;

            if (location) {
              console.info(`HTTP module detected redirect to: ${location}`);

              if (fileHandle !== null) {
                try {
                  fs.closeSync(fileHandle);
                  fileHandle = null;
                } catch (e) {
                  console.error('Close file error:', e);
                }
              }

              httpRequest.off('dataReceive');
              httpRequest.off('headersReceive');
              httpRequest.destroy();

              try {
                const parsedUrl = this.xmlParser.parseRedirectUrl(
                  location as string, this.connection.host, this.connection.port, this.connection.isHttps
                );
                this.downloadFileStreamWithRedirect(
                  parsedUrl.host,
                  parsedUrl.port,
                  parsedUrl.path,
                  parsedUrl.isHttps,
                  localFilePath,
                  callback,
                  redirectCount + 1
                ).then(() => {
                  resolve();
                }).catch((err: Error) => {
                  reject(err);
                });
              } catch (parseError) {
                const error = new Error(`Failed to parse redirect URL: ${parseError}`);
                callback?.onError?.(error);
                reject(error);
              }
              return;
            }
          }

          // 检查响应状态
          if (responseCode !== 200) {
            const error = new Error(`HTTP ${responseCode}`);

            if (fileHandle !== null) {
              try {
                fs.closeSync(fileHandle);
              } catch (e) {
                console.error('Close file error:', e);
              }
            }

            httpRequest.off('dataReceive');
            httpRequest.off('headersReceive');
            httpRequest.destroy();
            callback?.onError?.(error);
            reject(error);
            return;
          }

          // 如果downloadedBytes为0，说明dataReceive事件没有触发，需要从result中获取数据
          if (downloadedBytes === 0 && data.result) {
            console.info('Data not received via dataReceive event, using result directly');

            try {
              // 获取Content-Length
              if (contentLength === 0) {
                const contentLengthHeader = (data.header['content-length'] || data.header['Content-Length']) as string;
                if (contentLengthHeader) {
                  contentLength = parseInt(contentLengthHeader);
                  console.info(`Content-Length: ${contentLength} bytes`);
                }
              }

              // 处理result数据
              let resultData: ArrayBuffer;

              if (typeof data.result === 'string') {
                console.info('Result is string, converting to ArrayBuffer');
                resultData = buffer.from(data.result, 'utf-8').buffer;
              } else if (data.result instanceof ArrayBuffer) {
                console.info('Result is ArrayBuffer');
                resultData = data.result;
              } else if (data.result instanceof Object) {
                console.info('Result is Object, converting to string first');
                const resultStr = JSON.stringify(data.result);
                resultData = buffer.from(resultStr, 'utf-8').buffer;
              } else {
                throw new Error('Unsupported response type: ' + typeof data.result);
              }

              downloadedBytes = resultData.byteLength;
              console.info(`Writing ${downloadedBytes} bytes to file`);

              // 写入文件
              if (fileHandle === null) {
                fileHandle = fs.openSync(localFilePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
              }
              fs.writeSync(fileHandle.fd, resultData);

              console.info('File written successfully via result');

              if (contentLength > 0) {
                callback?.onProgress?.(downloadedBytes, contentLength);
              }
            } catch (writeError) {
              console.error('File write error:', JSON.stringify(writeError));

              if (fileHandle !== null) {
                try {
                  fs.closeSync(fileHandle);
                } catch (e) {
                  console.error('Close file error:', e);
                }
              }

              httpRequest.off('dataReceive');
              httpRequest.off('headersReceive');
              httpRequest.destroy();
              callback?.onError?.(writeError as Error);
              reject(writeError);
              return;
            }
          }

          // 下载完成
          console.info(`HTTP download completed: ${downloadedBytes} bytes`);

          if (fileHandle !== null) {
            try {
              fs.closeSync(fileHandle);
              fileHandle = null;
            } catch (e) {
              console.error('Close file error:', e);
            }
          }

          httpRequest.off('dataReceive');
          httpRequest.off('headersReceive');
          httpRequest.destroy();

          if (downloadedBytes === 0) {
            const error = new Error('No data received from server');
            callback?.onError?.(error);
            reject(error);
          } else {
            callback?.onComplete?.(localFilePath);
            resolve();
          }
        });
      } catch (error) {
        console.error('HTTP module error:', JSON.stringify(error));

        if (fileHandle !== null) {
          try {
            fs.closeSync(fileHandle);
          } catch (e) {
            console.error('Close file error:', e);
          }
        }

        httpRequest.off('dataReceive');
        httpRequest.off('headersReceive');
        httpRequest.destroy();
        callback?.onError?.(error as Error);
        reject(error);
      }
    });
  }
}
