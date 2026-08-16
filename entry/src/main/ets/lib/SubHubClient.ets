import http from '@ohos.net.http';
import buffer from '@ohos.buffer';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppEnv } from '../config/AppEnv';

// ─────────────────────────────────────────────
// 错误类型
// ─────────────────────────────────────────────

/**
 * SubHub 统一错误响应中的 error.code 枚举（与 openapi.yaml 对齐）。
 */
export type SubHubErrorCode =
  | 'AUTHENTICATION_REQUIRED'
  | 'FORBIDDEN'
  | 'VALIDATION_FAILED'
  | 'SERVICE_NOT_READY'
  | 'CALLER_KEY_INVALID'
  | 'CALLER_KEY_SUSPENDED'
  | 'PROVIDER_UNAVAILABLE'
  | 'PROVIDER_CREDENTIAL_EXHAUSTED'
  | 'NO_RESULTS'
  | 'SUBTITLE_NOT_FOUND'
  | 'UPSTREAM_FAILED'
  | 'TIMEOUT';

/** SubHub 业务错误：携带统一错误结构中的 code / message / HTTP 状态码。 */
export class SubHubApiError extends Error {
  readonly code: SubHubErrorCode;
  readonly statusCode: number;
  constructor(code: SubHubErrorCode, statusCode: number, message: string) {
    super(message);
    this.code = code;
    this.statusCode = statusCode;
  }
}

/** 网络层失败（连接失败 / 超时），无可用 HTTP 响应。 */
export class SubHubNetworkError extends Error {
  constructor(message: string) {
    super(message);
  }
}

// ─────────────────────────────────────────────
// 响应内部结构（仅供本模块解析使用）
// ─────────────────────────────────────────────

interface SubHubErrorResponse {
  error: SubHubErrorPayload;
}

interface SubHubErrorPayload {
  code: string;
  message?: string;
  target?: string;
}

interface SubHubSearchData {
  status?: string;
  results?: SubHubRawResult[];
  provider_failures?: SubHubProviderFailure[];
}

interface SubHubSearchResponse {
  data?: SubHubSearchData;
}

interface SubHubRawResult {
  id?: string;
  provider?: string;
  language?: string | null;
  releaseName?: string | null;
  format?: string;
  downloadUrl?: string;
  score?: number | null;
  raw?: Record<string, Object> | null;
}

export interface SubHubProviderFailure {
  provider?: string;
  reason?: string;
  message?: string;
}

// ─────────────────────────────────────────────
// 公共接口类型
// ─────────────────────────────────────────────

/** 搜索输入。 */
export interface SubHubSearchInput {
  /** 必填：视频标题关键词。 */
  title: string;
  year?: number;
  season?: number;
  episode?: number;
  /** 语言，如 "chi" / "zho" / "eng"。 */
  language?: string;
  /** IMDb ID，格式 tt + 数字。 */
  imdbId?: string;
  /** TMDb ID。 */
  tmdbId?: number;
  /** 媒体类型过滤。 */
  type?: 'movie' | 'episode';
  /** 自由文本检索（与 title 共同构成 free-text 兜底）。 */
  query?: string;
}

/** 搜索结果条目。 */
export interface SubHubSearchResult {
  /** 网关字幕引用，可直接用于下载接口 subtitleId。 */
  id: string;
  provider: string;
  language: string | null;
  releaseName: string | null;
  format: string;
  /** 已含完整 subtitleId 查询参数的下载路径。 */
  downloadUrl: string;
  score: number | null;
  raw: Record<string, Object> | null;
}

/** 搜索聚合结果。 */
export interface SubHubSearchOutcome {
  status: string;
  results: SubHubSearchResult[];
  providerFailures: SubHubProviderFailure[];
}

/** 下载结果。 */
export interface SubHubDownloadResult {
  /** 字幕文件内容（二进制）。 */
  content: ArrayBuffer;
  /** 由 Content-Disposition 解析或调用方兜底的文件名。 */
  fileName: string;
  /** 字幕文件 MIME，如 application/x-subrip。 */
  mime: string;
}

/** 可注入的 HTTP 执行器（主要用于单元测试）。 */
export interface SubHubHttpResponse {
  responseCode: number;
  result: string | ArrayBuffer;
  headers: Record<string, string>;
}

export type SubHubHttpExecutor = (
  url: string,
  method: string,
  headers: Record<string, string>,
  expectArrayBuffer: boolean
) => Promise<SubHubHttpResponse>;

// ─────────────────────────────────────────────
// 工具函数
// ─────────────────────────────────────────────

/**
 * 从 Content-Disposition 头中提取 filename（支持 filename= / filename*=UTF-8''）。
 * 解析失败返回空字符串。
 */
export function extractFileNameFromContentDisposition(headerValue: string): string {
  if (headerValue.length === 0) {
    return '';
  }
  // 优先解析 RFC 5987 的 filename*=UTF-8''xxx
  const starMatch = /filename\*=UTF-8''([^;]+)/i.exec(headerValue);
  if (starMatch !== null && starMatch[1] !== undefined) {
    return decodeURIComponent(starMatch[1].trim());
  }
  const plainMatch = /filename="?([^";]+)"?/i.exec(headerValue);
  if (plainMatch !== null && plainMatch[1] !== undefined) {
    return plainMatch[1].trim();
  }
  return '';
}

/** 从错误响应体解析统一错误结构；无法解析时返回 null。 */
function parseErrorPayload(result: string | ArrayBuffer): SubHubErrorPayload | null {
  let text: string;
  if (typeof result === 'string') {
    text = result;
  } else {
    // 下载路径 expectArrayBuffer=true，错误体是 ArrayBuffer，先解码为 UTF-8 字符串
    const bytes = new Uint8Array(result);
    text = buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString('utf-8');
  }
  if (text.length === 0) {
    return null;
  }
  try {
    const parsed = JSON.parse(text) as SubHubErrorResponse;
    if (parsed.error !== undefined && parsed.error.code !== undefined) {
      return parsed.error;
    }
    return null;
  } catch {
    return null;
  }
}

// ─────────────────────────────────────────────
// SubHubClient
// ─────────────────────────────────────────────

/**
 * SubHub 统一字幕出口 API 客户端。
 *
 * 参考：https://subhub.softeehub.com/docs/api
 * - 搜索：GET /api/subtitles/search?title=...
 * - 下载：GET /api/subtitles/download?subtitleId=...
 * - 鉴权：Authorization: Bearer <CallerKey>
 */
export class SubHubClient {
  private readonly baseUrl: string;
  private readonly callerKey: string;
  /** 注入 HTTP 执行器（仅用于测试，生产环境传 null） */
  private readonly testExecutor: SubHubHttpExecutor | null;

  constructor(baseUrl?: string, callerKey?: string, testExecutor?: SubHubHttpExecutor) {
    this.baseUrl = baseUrl !== undefined && baseUrl.length > 0
      ? baseUrl
      : AppEnv.SUBHUB_BASE_URL;
    this.callerKey = callerKey !== undefined ? callerKey : AppEnv.SUBHUB_API_KEY;
    if (testExecutor !== undefined) {
      this.testExecutor = testExecutor;
    } else {
      this.testExecutor = null;
    }
  }

  private buildHeaders(): Record<string, string> {
    const headers: Record<string, string> = {
      'Accept': 'application/json',
      'User-Agent': 'VidAll-TV-SubHub-Demo/1.0'
    };
    if (this.callerKey.length > 0) {
      headers['Authorization'] = `Bearer ${this.callerKey}`;
    }
    return headers;
  }

  /**
   * 请求前校验 Caller Key 已配置：为空时明确拒绝，而不是静默省略 Authorization 头。
   * 抛出的错误会被 classifyAcquisitionError 归类为 subhub_auth_invalid。
   */
  private requireCallerKey(): void {
    if (this.callerKey.length === 0) {
      throw new SubHubApiError('AUTHENTICATION_REQUIRED', 0, 'SubHub Caller Key 未配置，无法访问字幕服务');
    }
  }

  private async doRequest(
    url: string,
    method: string,
    expectArrayBuffer: boolean
  ): Promise<SubHubHttpResponse> {
    if (this.testExecutor !== null) {
      return this.testExecutor(url, method, this.buildHeaders(), expectArrayBuffer);
    }
    const httpMethod = method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET;
    const req = http.createHttp();
    try {
      const headers = this.buildHeaders();
      let resp: http.HttpResponse;
      if (expectArrayBuffer) {
        resp = await req.request(url, {
          method: httpMethod,
          header: headers,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: 15000,
          readTimeout: 30000
        });
      } else {
        resp = await req.request(url, {
          method: httpMethod,
          header: headers,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 15000,
          readTimeout: 30000
        });
      }
      req.destroy();
      let headersOut: Record<string, string> = {};
      try {
        headersOut = resp.header as Record<string, string>;
      } catch {
        headersOut = {};
      }
      return {
        responseCode: resp.responseCode,
        result: resp.result as string | ArrayBuffer,
        headers: headersOut
      };
    } catch (e) {
      req.destroy();
      const be = e as BusinessError;
      throw new SubHubNetworkError(`HTTP 请求失败: code=${be.code ?? ''} ${be.message ?? JSON.stringify(e)}`);
    }
  }

  private throwApiError(statusCode: number, result: string | ArrayBuffer): never {
    const payload = parseErrorPayload(result);
    if (payload !== null) {
      const code = payload.code as SubHubErrorCode;
      const message = payload.message ?? code;
      throw new SubHubApiError(code, statusCode, message);
    }
    throw new SubHubApiError('UPSTREAM_FAILED', statusCode, `SubHub HTTP ${statusCode}`);
  }

  /**
   * 搜索字幕。
   *
   * HTTP 404 + code=NO_RESULTS 视为无结果（返回空列表），不抛错。
   */
  async search(input: SubHubSearchInput): Promise<SubHubSearchOutcome> {
    this.requireCallerKey();
    let url = `${this.baseUrl}/api/subtitles/search?title=${encodeURIComponent(input.title)}`;
    if (input.year !== undefined) {
      url += `&year=${input.year}`;
    }
    if (input.season !== undefined) {
      url += `&season=${input.season}`;
    }
    if (input.episode !== undefined) {
      url += `&episode=${input.episode}`;
    }
    if (input.language !== undefined && input.language.length > 0) {
      url += `&language=${encodeURIComponent(input.language)}`;
    }
    if (input.imdbId !== undefined && input.imdbId.length > 0) {
      url += `&imdb_id=${encodeURIComponent(input.imdbId)}`;
    }
    if (input.tmdbId !== undefined) {
      url += `&tmdb_id=${input.tmdbId}`;
    }
    if (input.type !== undefined) {
      url += `&type=${input.type}`;
    }
    if (input.query !== undefined && input.query.length > 0) {
      url += `&query=${encodeURIComponent(input.query)}`;
    }

    const resp = await this.doRequest(url, 'GET', false);

    if (resp.responseCode === 404) {
      const payload = parseErrorPayload(resp.result);
      if (payload !== null && payload.code === 'NO_RESULTS') {
        return { status: 'success', results: [], providerFailures: [] };
      }
    }
    if (resp.responseCode !== 200) {
      this.throwApiError(resp.responseCode, resp.result);
    }

    const parsed = JSON.parse(resp.result as string) as SubHubSearchResponse;
    const data = parsed.data;
    if (data === undefined || data.results === undefined) {
      return { status: data?.status ?? 'success', results: [], providerFailures: [] };
    }

    const results: SubHubSearchResult[] = data.results.map((item: SubHubRawResult): SubHubSearchResult => {
      return {
        id: item.id ?? '',
        provider: item.provider ?? '',
        language: item.language ?? null,
        releaseName: item.releaseName ?? null,
        format: item.format ?? 'srt',
        downloadUrl: item.downloadUrl ?? '',
        score: item.score ?? null,
        raw: item.raw ?? null
      };
    });

    const providerFailures: SubHubProviderFailure[] = (data.provider_failures ?? []).map(
      (item: SubHubProviderFailure): SubHubProviderFailure => {
        return {
          provider: item.provider ?? '',
          reason: item.reason ?? '',
          message: item.message ?? ''
        };
      }
    );

    return {
      status: data.status ?? 'success',
      results: results,
      providerFailures: providerFailures
    };
  }

  /**
   * 下载字幕文件。
   *
   * @param subtitleId        来自搜索响应 results[].id 的完整网关字幕引用。
   * @param fallbackFileName  无法从 Content-Disposition 解析文件名时的兜底文件名。
   */
  async download(subtitleId: string, fallbackFileName: string): Promise<SubHubDownloadResult> {
    this.requireCallerKey();
    const url = `${this.baseUrl}/api/subtitles/download?subtitleId=${encodeURIComponent(subtitleId)}`;
    const resp = await this.doRequest(url, 'GET', true);

    if (resp.responseCode !== 200) {
      this.throwApiError(resp.responseCode, resp.result);
    }

    const content = resp.result as ArrayBuffer;
    const headerNames = ['Content-Disposition', 'content-disposition'];
    let fileName = '';
    for (let i = 0; i < headerNames.length; i++) {
      const value = resp.headers[headerNames[i]];
      if (value !== undefined && value.length > 0) {
        fileName = extractFileNameFromContentDisposition(value);
        if (fileName.length > 0) {
          break;
        }
      }
    }
    if (fileName.length === 0) {
      fileName = fallbackFileName.length > 0 ? fallbackFileName : 'subtitle.srt';
    }

    const mime = resp.headers['Content-Type'] ?? resp.headers['content-type'] ?? 'application/x-subrip';
    return { content: content, fileName: fileName, mime: mime };
  }
}
