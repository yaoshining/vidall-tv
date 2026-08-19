import http from '@ohos.net.http';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 通用 JSON HTTP 响应结构
 */
export interface JsonHttpResponse {
  statusCode: number;
  body: string;
}

/**
 * 影视服务器客户端共用的 JSON HTTP 传输层。
 * 基于 @ohos.net.http，承载 GET/POST JSON 请求（Jellyfin / Emby / Plex 均为标准 REST）。
 */
export class JsonHttpClient {
  private static request(
    method: http.RequestMethod,
    url: string,
    headers: Record<string, string>,
    body: string | undefined,
    timeoutMs: number
  ): Promise<JsonHttpResponse> {
    return new Promise((resolve, reject) => {
      const req = http.createHttp();
      const options: http.HttpRequestOptions = {
        method,
        header: headers,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING
      };
      if (body !== undefined) {
        options.extraData = body;
      }
      req.request(url, options, (err, data) => {
        if (err) {
          const bizErr = err as BusinessError;
          req.destroy();
          reject(new Error(bizErr.message || 'HTTP request failed'));
          return;
        }
        const response: JsonHttpResponse = {
          statusCode: data.responseCode as number,
          body: typeof data.result === 'string' ? data.result : ''
        };
        resolve(response);
        // 成功路径在读取 responseCode / result 后再销毁请求对象。
        req.destroy();
      });
    });
  }

  static get(url: string, headers: Record<string, string>, timeoutMs: number = 10000): Promise<JsonHttpResponse> {
    return JsonHttpClient.request(http.RequestMethod.GET, url, headers, undefined, timeoutMs);
  }

  static post(
    url: string,
    headers: Record<string, string>,
    body: string,
    timeoutMs: number = 10000
  ): Promise<JsonHttpResponse> {
    return JsonHttpClient.request(http.RequestMethod.POST, url, headers, body, timeoutMs);
  }

  /**
   * 将 HTTP 状态码 / 错误信息映射为可读的中文失败原因。
   */
  static classifyError(statusCode: number, message: string): string {
    if (statusCode === 401 || statusCode === 403) {
      return '鉴权失败，请检查凭据';
    }
    const lower = message.toLowerCase();
    if (lower.includes('timeout') || lower.includes('timed out')) {
      return '连接超时';
    }
    if (lower.includes('refused') || lower.includes('econnrefused')) {
      return '连接被拒绝';
    }
    if (lower.includes('unknownhost') || lower.includes('getaddrinfo') || lower.includes('nodename')) {
      return '无法解析服务器地址';
    }
    if (statusCode > 0) {
      return `服务器返回错误 (${statusCode})`;
    }
    return message.length > 0 ? message : '未知错误';
  }
}
