import socket from '@ohos.net.socket';
import buffer from '@ohos.buffer';
import http from '@ohos.net.http';
import * as VidAllCorePlayerNapiModule from 'libvidall_core_player_napi.so';
import { WebDavConnection } from './WebDavConnection';
import { classifyTlsError, isTlsError, sanitizeUrlForAudit } from './WebDavUtils';

interface WebDavRequestResult {
  statusCode: number;
  body: string;
  error: string;
}

interface WebDavDownloadResult {
  statusCode: number;
  downloadedBytes: number;
  error: string;
}

interface NativeCapabilities {
  ffmpegEnabled: boolean;
  libcurlEnabled: boolean;
  libcurlVersion: string;
}

interface WebDavNapiBridge {
  webdavRequest: (
    method: string,
    url: string,
    headerLines: string,
    body: string,
    timeoutMs: number,
    tlsPolicy: string
  ) => WebDavRequestResult;
  downloadToFile: (
    method: string,
    url: string,
    headerLines: string,
    body: string,
    timeoutMs: number,
    outputPath: string,
    tlsPolicy: string
  ) => WebDavDownloadResult;
  getNativeCapabilities: () => NativeCapabilities;
}

interface WebDavNapiBridgeModule {
  default?: WebDavNapiBridge;
}

function getVidAllCorePlayerNapi(): WebDavNapiBridge {
  const bridgeModule = VidAllCorePlayerNapiModule as WebDavNapiBridgeModule | WebDavNapiBridge | undefined;
  if (bridgeModule === undefined) {
    throw new Error('libvidall_core_player_napi.so 未加载');
  }
  const defaultBridge = (bridgeModule as WebDavNapiBridgeModule).default;
  if (defaultBridge !== undefined) {
    return defaultBridge as WebDavNapiBridge;
  }
  return bridgeModule as WebDavNapiBridge;
}

export class HttpResponse {
  statusCode: number = 0;
  statusText: string = '';
  headers: Map<string, string> = new Map();
  body: string = '';
}

/**
 * WebDAV HTTP 传输层：承载 native libcurl / TCPSocket / TLSSocket 三条链路
 * 与多级降级策略，以及 HTTP 响应解析。
 * 拆分自 WebDAVClient.ets。
 */
export class WebDavHttp {
  private connection: WebDavConnection;
  // 阶段3收口：默认不再自动回退到旧 socket 链路，仅在排障时手动放开。
  private readonly allowLegacyTransportFallback: boolean = false;
  // 阶段3收口：默认禁止 HTTPS 失败后降级到明文 HTTP。
  private readonly allowInsecureHttpDowngrade: boolean = false;
  // 缓存 native libcurl 可用性（null = 未检测）
  private _nativeCurlEnabled: boolean | null = null;

  constructor(connection: WebDavConnection) {
    this.connection = connection;
  }

  /**
   * 构建 HTTP 请求字符串
   */
  private buildHttpRequestString(
    method: string,
    path: string,
    headers: Record<string, string>,
    body?: string
  ): string {
    let request = `${method} ${path} HTTP/1.1\r\n`;
    // 标准端口（HTTP:80 / HTTPS:443）不加端口号，部分服务器对带端口的 Host 头不响应
    const isStandardPort = (this.connection.isHttps && this.connection.port === 443) || (!this.connection.isHttps && this.connection.port === 80);
    const hostHeader = isStandardPort ? this.connection.host : `${this.connection.host}:${this.connection.port}`;
    request += `Host: ${hostHeader}\r\n`;

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

    return request;
  }

  /**
   * 日志输出前脱敏敏感请求头，避免凭据明文泄露。
   */
  sanitizeRequestForLog(request: string): string {
    return request.replace(/(Authorization\s*:\s*)[^\r\n]*/ig, '$1Basic ***');
  }

  /** 懒检测 native libcurl 是否可用 */
  checkNativeCurlEnabled(): boolean {
    if (this._nativeCurlEnabled === null) {
      try {
        const caps = getVidAllCorePlayerNapi().getNativeCapabilities();
        this._nativeCurlEnabled = caps.libcurlEnabled;
      } catch (e) {
        this._nativeCurlEnabled = false;
      }
    }
    return this._nativeCurlEnabled;
  }

  /**
   * 记录 TLS 审计日志（脱敏 URL，保留错误信息以供排障）。
   * TAG：VidAll_TLS_Audit，可通过 hilog | grep VidAll_TLS_Audit 提取。
   */
  private logTlsAudit(op: string, rawUrl: string, errorMsg: string): void {
    const sanitizedUrl = sanitizeUrlForAudit(rawUrl);
    console.error(`[VidAll_TLS_Audit] op=${op} url=${sanitizedUrl} error=${errorMsg}`);
  }

  /**
   * 通过 native libcurl 发送 WebDAV 请求（仅在 libcurlEnabled 时调用）。
   * 失败时由上层 sendRawHttpRequest 捕获并回退到 socket 实现。
   * webdavRequest NAPI 为异步 Promise，必须 await，禁止同步调用。
   */
  private async sendViaNative(
    method: string,
    encodedPath: string,
    headers: Record<string, string>,
    body?: string
  ): Promise<HttpResponse> {
    const isStd = (this.connection.isHttps && this.connection.port === 443) || (!this.connection.isHttps && this.connection.port === 80);
    const portStr = isStd ? '' : `:${this.connection.port}`;
    const scheme = this.connection.isHttps ? 'https' : 'http';
    const fullUrl = `${scheme}://${this.connection.host}${portStr}${encodedPath}`;

    const keys = Object.keys(headers);
    const parts: string[] = [];
    for (let i = 0; i < keys.length; i++) {
      const item: string = `${keys[i]}: ${headers[keys[i]]}`;
      parts.push(item);
    }
    const headerLines = parts.join('\r\n');

    const result = await getVidAllCorePlayerNapi().webdavRequest(
      method, fullUrl, headerLines, body ?? '', this.connection.timeout, this.connection.tlsCertPolicy
    );

    if (result.error) {
      if (isTlsError(result.error)) {
        this.logTlsAudit(method, fullUrl, result.error);
        const userMsg = classifyTlsError(result.error);
        throw new Error(userMsg !== null ? userMsg + ' [' + result.error + ']' : result.error);
      }
      throw new Error('native curl: ' + result.error);
    }

    const resp = new HttpResponse();
    resp.statusCode = result.statusCode;
    resp.body = result.body;
    return resp;
  }

  private buildNativeUrl(encodedPath: string): string {
    const isStd = (this.connection.isHttps && this.connection.port === 443) || (!this.connection.isHttps && this.connection.port === 80);
    const portStr = isStd ? '' : `:${this.connection.port}`;
    const scheme = this.connection.isHttps ? 'https' : 'http';
    return `${scheme}://${this.connection.host}${portStr}${encodedPath}`;
  }

  private buildHeaderLines(headers: Record<string, string>): string {
    const keys = Object.keys(headers);
    const parts: string[] = [];
    for (let i = 0; i < keys.length; i++) {
      const item: string = `${keys[i]}: ${headers[keys[i]]}`;
      parts.push(item);
    }
    return parts.join('\r\n');
  }

  async downloadViaNative(
    encodedPath: string,
    localFilePath: string,
    headers: Record<string, string>
  ): Promise<WebDavDownloadResult> {
    const fullUrl = this.buildNativeUrl(encodedPath);
    const headerLines = this.buildHeaderLines(headers);
    const result = await getVidAllCorePlayerNapi().downloadToFile(
      'GET', fullUrl, headerLines, '', this.connection.timeout * 2, localFilePath, this.connection.tlsCertPolicy
    );
    if (result.error && isTlsError(result.error)) {
      this.logTlsAudit('GET_DOWNLOAD', fullUrl, result.error);
      const userMsg = classifyTlsError(result.error);
      const finalMsg = userMsg !== null ? userMsg + ' [' + result.error + ']' : result.error;
      const enhanced: WebDavDownloadResult = {
        statusCode: result.statusCode,
        downloadedBytes: result.downloadedBytes,
        error: finalMsg
      };
      return enhanced;
    }
    return result;
  }

  /**
   * 使用 Socket 发送请求 - 支持 HTTP（TCP）和 HTTPS（http 模块）。
   * 若 native libcurl 可用则优先走 native，失败自动回退到 socket/http 实现。
   */
  async sendRawHttpRequest(
    method: string,
    path: string,
    headers: Record<string, string>,
    body?: string
  ): Promise<HttpResponse> {
    // ── native libcurl 优先路径 ────────────────────────────────────────────
    if (this.checkNativeCurlEnabled()) {
      try {
        return await this.sendViaNative(method, path, headers, body);
      } catch (e) {
        const nativeErr = (e as Error).message;
        if (!this.allowLegacyTransportFallback) {
          throw new Error(`native transport failed: ${nativeErr}`);
        }
        console.warn(`WebDAV native fallback enabled: ${nativeErr}`);
      }
    }
    if (!this.allowLegacyTransportFallback) {
      throw new Error('legacy transport fallback disabled');
    }
    // ── 回退：现有 socket / http 实现 ──────────────────────────────────────
    if (this.connection.isHttps) {
      return this.sendHttpsRequestViaHttpModule(method, path, headers, body);
    }
    return this.sendRawHttpPlainRequest(method, path, headers, body);
  }

  /**
   * HTTPS WebDAV 请求 — 三级降级策略：
   *  Level 1: POST + X-HTTP-Method-Override（Nextcloud/Apache/Synology 等支持）
   *  Level 2: TLSSocket 直接发 PROPFIND（对 TLSSocket message 事件正常的设备）
   *  Level 3: HTTP 明文降级（443→80，其他端口保持），兜底方案
   * @ohos.net.http 枚举白名单在 native 层校验无法绕过，不在此处使用自定义 method。
   */
  private async sendHttpsRequestViaHttpModule(
    method: string,
    path: string,
    headers: Record<string, string>,
    body?: string
  ): Promise<HttpResponse> {
    const isStdPort = this.connection.port === 443;
    const portStr = isStdPort ? '' : `:${this.connection.port}`;
    const url = `https://${this.connection.host}${portStr}${path}`;
    console.info(`WebDAV HTTPS: ${method} ${url}`);

    // ── Level 1: POST + X-HTTP-Method-Override ──────────────────────────────
    try {
      const result = await this.tryHttpsViaPostOverride(method, url, headers, body);
      // 410/405/400/501 表示服务器不支持 Override，需继续降级
      // 其余状态码（含 207/404/401 等）表示服务器正确处理了请求
      const s = result.statusCode;
      if (s !== 410 && s !== 405 && s !== 400 && s !== 501) {
        console.info(`WebDAV HTTPS Level1 OK: ${s}`);
        return result;
      }
      console.warn(`WebDAV HTTPS Level1 fallback (status=${s}), trying TLSSocket...`);
    } catch (e) {
      console.warn(`WebDAV HTTPS Level1 error: ${(e as Error).message}, trying TLSSocket...`);
    }

    // ── Level 2: TLSSocket 直接发 PROPFIND ──────────────────────────────────
    try {
      const result = await this.sendRawHttpsRequest(method, path, headers, body);
      console.info(`WebDAV HTTPS Level2 (TLS) OK: ${result.statusCode}`);
      return result;
    } catch (e) {
      console.warn(`WebDAV HTTPS Level2 (TLS) error: ${(e as Error).message}, trying HTTP fallback...`);
    }

    if (!this.allowInsecureHttpDowngrade) {
      throw new Error('HTTPS fallback exhausted and insecure HTTP downgrade is disabled');
    }

    // ── Level 3: HTTP 明文降级（443→80，其他端口保持） ───────────────────────
    const httpPort = this.connection.port === 443 ? 80 : this.connection.port;
    console.warn(`WebDAV HTTPS Level3: HTTP fallback to ${this.connection.host}:${httpPort}`);
    return this.sendRawHttpPlainRequest(method, path, headers, body, this.connection.host, httpPort);
  }

  /** Level 1 实现：POST + X-HTTP-Method-Override（返回 Promise，便于 try/catch） */
  private tryHttpsViaPostOverride(
    method: string,
    url: string,
    headers: Record<string, string>,
    body?: string
  ): Promise<HttpResponse> {
    return new Promise((resolve, reject) => {
      const overrideHeaders: Record<string, string> = {};
      const hkeys = Object.keys(headers);
      for (let i = 0; i < hkeys.length; i++) {
        overrideHeaders[hkeys[i]] = headers[hkeys[i]];
      }
      overrideHeaders['X-HTTP-Method-Override'] = method;

      const httpReq = http.createHttp();
      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: overrideHeaders,
        connectTimeout: this.connection.timeout,
        readTimeout: this.connection.timeout,
        expectDataType: http.HttpDataType.STRING
      };
      if (body) {
        opts.extraData = body;
      }
      httpReq.request(url, opts, (err, data) => {
        httpReq.destroy();
        if (err) {
          const bizErr = err as BusinessError;
          reject(new Error(bizErr.message || 'POST+Override request failed'));
          return;
        }
        const response = new HttpResponse();
        response.statusCode = data.responseCode as number;
        response.statusText = '';
        response.body = typeof data.result === 'string' ? data.result : '';
        const respHeaders = data.header as Record<string, string>;
        const rkeys = Object.keys(respHeaders);
        for (let i = 0; i < rkeys.length; i++) {
          response.headers.set(rkeys[i].toLowerCase(), respHeaders[rkeys[i]]);
        }
        console.info(`WebDAV HTTPS POST+Override: ${response.statusCode}, body=${response.body.length}chars`);
        resolve(response);
      });
    });
  }

  /**
   * HTTP 明文请求（TCPSocket）
   * overrideHost/overridePort：供 HTTPS 降级时替换连接目标
   */
  private async sendRawHttpPlainRequest(
    method: string,
    path: string,
    headers: Record<string, string>,
    body?: string,
    overrideHost?: string,
    overridePort?: number
  ): Promise<HttpResponse> {
    return new Promise((resolve, reject) => {
      const tcp = socket.constructTCPSocketInstance();
      let fullResponseData = '';
      let isComplete = false;
      let hasReceivedData = false;
      let contentLength = 0;

      const connectHost = overrideHost ?? this.connection.host;
      const connectPort = overridePort ?? this.connection.port;

      const address: socket.NetAddress = {
        address: connectHost,
        port: connectPort,
        family: 1
      };

      console.info(`WebDAV: Connecting to ${connectHost}:${connectPort}`);

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
      }, this.connection.timeout);

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

          // HTTPS 降级时，用实际连接的 host:port 覆盖 Host 头
          if (overrideHost !== undefined || overridePort !== undefined) {
            const h = overrideHost ?? this.connection.host;
            const p = overridePort ?? this.connection.port;
            headers['Host'] = (p === 80) ? h : `${h}:${p}`;
          }
          const request = this.buildHttpRequestString(method, path, headers, body);
          const sanitizedRequestLog = this.sanitizeRequestForLog(request);

          console.info('=== REQUEST ===');
          console.info(sanitizedRequestLog);
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
   * HTTPS 加密请求（TLSSocket）
   * bind/connect/send 全部用 Promise 链，确保时序正确。
   * message 事件 + close 事件双重兜底接收响应数据。
   */
  private async sendRawHttpsRequest(
    method: string,
    path: string,
    headers: Record<string, string>,
    body?: string
  ): Promise<HttpResponse> {
    return new Promise((resolve, reject) => {
      const tls = socket.constructTLSSocketInstance();
      const receivedChunks: ArrayBuffer[] = [];
      let isComplete = false;

      const tlsConnectOptions: socket.TLSConnectOptions = {
        address: { address: this.connection.host, port: this.connection.port, family: 1 },
        secureOptions: {
          useRemoteCipherPrefer: true,
          protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13],
          signatureAlgorithms: 'rsa_pss_rsae_sha256:ECDSA+SHA256'
        }
      };

      console.info(`WebDAV TLS: start — ${this.connection.host}:${this.connection.port}`);

      const flushChunks = (): string => {
        let totalLen = 0;
        for (let i = 0; i < receivedChunks.length; i++) {
          totalLen += receivedChunks[i].byteLength;
        }
        const merged = new Uint8Array(totalLen);
        let offset = 0;
        for (let i = 0; i < receivedChunks.length; i++) {
          merged.set(new Uint8Array(receivedChunks[i]), offset);
          offset += receivedChunks[i].byteLength;
        }
        return buffer.from(merged.buffer as ArrayBuffer).toString('utf-8');
      };

      const doResolve = (text: string): void => {
        if (isComplete) return;
        isComplete = true;
        clearTimeout(timeoutId);
        try { tls.close(); } catch (_) {}
        try { resolve(this.parseHttpResponse(text)); } catch (e) {
          reject(new Error('TLS: parse failed'));
        }
      };

      const doReject = (msg: string): void => {
        if (isComplete) return;
        isComplete = true;
        clearTimeout(timeoutId);
        try { tls.close(); } catch (_) {}
        reject(new Error(msg));
      };

      const timeoutId = setTimeout(() => {
        console.error(`WebDAV TLS: timeout after ${this.connection.timeout}ms, chunks=${receivedChunks.length}`);
        const text = flushChunks();
        if (text.length > 0) {
          doResolve(text);
        } else {
          doReject('TLS Timeout - no data received');
        }
      }, this.connection.timeout);

      // message 事件（部分设备可触发）
      tls.on('message', (value: socket.SocketMessageInfo) => {
        if (isComplete) return;
        const chunk = value.message as ArrayBuffer;
        if (!chunk || chunk.byteLength === 0) return;
        receivedChunks.push(chunk);
        console.info(`WebDAV TLS: message ${chunk.byteLength} bytes, total=${receivedChunks.length}`);
        const text = flushChunks();
        if (this.isHttpResponseComplete(text)) {
          console.info('WebDAV TLS: complete via message');
          doResolve(text);
        }
      });

      // close 事件兜底：Connection:close 时服务器会主动断开
      tls.on('close', () => {
        console.info(`WebDAV TLS: closed, chunks=${receivedChunks.length}`);
        if (!isComplete) {
          const text = flushChunks();
          if (text.length > 0) {
            doResolve(text);
          } else {
            doReject('TLS closed without data');
          }
        }
      });

      tls.on('error', (err: Error) => {
        console.error(`WebDAV TLS: socket error: ${JSON.stringify(err)}`);
        doReject(`TLS error: ${JSON.stringify(err)}`);
      });

      const localAddr: socket.NetAddress = { address: '0.0.0.0', port: 0, family: 1 };
      tls.bind(localAddr)
        .then(() => {
          console.info('WebDAV TLS: bind ok, connecting...');
          return tls.connect(tlsConnectOptions);
        })
        .then(() => {
          console.info('WebDAV TLS: connected, building request...');
          const request = this.buildHttpRequestString(method, path, headers, body);
          console.info('WebDAV TLS request:\n' + this.sanitizeRequestForLog(request));
          const buf = buffer.from(request, 'utf-8');
          // 强制用 string 发送（某些版本 ArrayBuffer 发送后服务器收不到完整数据）
          return tls.send(request);
        })
        .then(() => {
          console.info('WebDAV TLS: send ok, waiting for response...');
        })
        .catch((err: Error) => {
          console.error(`WebDAV TLS: connect/send error: ${JSON.stringify(err)}`);
          doReject(`TLS connect/send error: ${JSON.stringify(err)}`);
        });
    });
  }

  isHttpResponseComplete(data: string): boolean {
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

  parseHttpResponse(responseText: string): HttpResponse {
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
}
