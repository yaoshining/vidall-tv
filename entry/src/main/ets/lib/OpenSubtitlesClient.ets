import http from '@ohos.net.http';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppPreferences, PrefKey } from '../utils/AppPreferences';

// ─────────────────────────────────────────────
// 通道基础 URL 常量
// ─────────────────────────────────────────────

const DIRECT_BASE_URL = 'https://api.opensubtitles.com/api/v1';
const PROXY_BASE_URL = 'https://os-proxy.vidall.app/v1';

// ─────────────────────────────────────────────
// 错误类型
// ─────────────────────────────────────────────

/** 代理通道配额耗尽（HTTP 429） */
export class ProxyQuotaExceededError extends Error {
  constructor(message: string) {
    super(message);
  }
}

/** 代理网络不可达（连接失败） */
export class ProxyUnavailableError extends Error {
  constructor(message: string) {
    super(message);
  }
}

/** API Key 无效（HTTP 401） */
export class InvalidApiKeyError extends Error {
  constructor(message: string) {
    super(message);
  }
}

/** 字幕下载失败（非鉴权 / 限速类通用错误） */
export class SubtitleDownloadError extends Error {
  constructor(message: string) {
    super(message);
  }
}

// ─────────────────────────────────────────────
// API 响应内部结构（仅供本模块使用）
// ─────────────────────────────────────────────

interface OsFileItem {
  file_id: number;
  file_name: string;
}

interface OsSubtitleAttributes {
  subtitle_id: string;
  release: string;
  language: string;
  download_count: number;
  files: OsFileItem[];
}

interface OsDataItem {
  attributes: OsSubtitleAttributes;
}

interface OsSearchResponse {
  data: OsDataItem[];
}

interface OsDownloadResponse {
  link: string;
  file_name: string;
  remaining: number;
}

interface DownloadRequestBody {
  file_id: number;
}

// ─────────────────────────────────────────────
// 公共接口类型
// ─────────────────────────────────────────────

export interface SubtitleSearchResult {
  /** OpenSubtitles subtitle_id */
  subtitleId: string;
  /** srt/ass 文件名 */
  fileName: string;
  /** BCP-47，如 zh-CN */
  languageCode: string;
  downloadCount: number;
  /** 下载时需要的 file_id */
  fileId: number;
}

export interface SubtitleDownloadLink {
  /** 临时下载 URL（30 分钟有效） */
  link: string;
  fileName: string;
  /** 今日剩余下载次数 */
  remaining: number;
}

/** 可注入的 HTTP 执行器（主要用于单元测试） */
export interface OsHttpResponse {
  responseCode: number;
  result: string;
}

export type OsHttpExecutor = (
  url: string,
  method: string,
  headers: Record<string, string>,
  body?: string
) => Promise<OsHttpResponse>;

// ─────────────────────────────────────────────
// OpenSubtitlesClient
// ─────────────────────────────────────────────

export class OpenSubtitlesClient {
  private static readonly MIN_REQUEST_INTERVAL_MS: number = 300;
  private lastRequestTs: number = 0;
  /** 注入 HTTP 执行器（仅用于测试，生产环境传 null） */
  private readonly testExecutor: OsHttpExecutor | null;

  constructor(testExecutor?: OsHttpExecutor) {
    if (testExecutor !== undefined) {
      this.testExecutor = testExecutor;
    } else {
      this.testExecutor = null;
    }
  }

  /**
   * 解析当前请求通道的 base URL。
   * 有 API Key → 直连；无 Key → 代理。
   * 对外公开以便单元测试验证通道选择逻辑。
   */
  async resolveBaseUrl(): Promise<string> {
    const apiKey = await AppPreferences.get(PrefKey.OPENSUBTITLES_API_KEY, '');
    if (apiKey.length > 0) {
      return DIRECT_BASE_URL;
    }
    return PROXY_BASE_URL;
  }

  private async isDirectMode(): Promise<boolean> {
    const apiKey = await AppPreferences.get(PrefKey.OPENSUBTITLES_API_KEY, '');
    return apiKey.length > 0;
  }

  private async buildHeaders(): Promise<Record<string, string>> {
    const apiKey = await AppPreferences.get(PrefKey.OPENSUBTITLES_API_KEY, '');
    if (apiKey.length > 0) {
      const directHeaders: Record<string, string> = {
        'Api-Key': apiKey,
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      };
      return directHeaders;
    }
    const deviceId = await AppPreferences.getOrCreateDeviceId();
    const proxyHeaders: Record<string, string> = {
      'X-Device-Id': deviceId,
      'Content-Type': 'application/json',
      'Accept': 'application/json'
    };
    return proxyHeaders;
  }

  private async throttle(): Promise<void> {
    const now = Date.now();
    const elapsed = now - this.lastRequestTs;
    if (elapsed < OpenSubtitlesClient.MIN_REQUEST_INTERVAL_MS) {
      await new Promise<void>((resolve) => {
        setTimeout(resolve, OpenSubtitlesClient.MIN_REQUEST_INTERVAL_MS - elapsed);
      });
    }
    this.lastRequestTs = Date.now();
  }

  /** 统一 HTTP 执行入口：测试时走注入 executor，生产时走 @ohos.net.http */
  private async doRequest(
    url: string,
    method: string,
    headers: Record<string, string>,
    body?: string
  ): Promise<OsHttpResponse> {
    if (this.testExecutor !== null) {
      return this.testExecutor(url, method, headers, body);
    }
    const httpMethod = method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET;
    const req = http.createHttp();
    try {
      let resp: http.HttpResponse;
      if (body !== undefined) {
        resp = await req.request(url, {
          method: httpMethod,
          header: headers,
          extraData: body,
          connectTimeout: 15000,
          readTimeout: 15000
        });
      } else {
        resp = await req.request(url, {
          method: httpMethod,
          header: headers,
          connectTimeout: 15000,
          readTimeout: 15000
        });
      }
      req.destroy();
      const osResp: OsHttpResponse = {
        responseCode: resp.responseCode,
        result: resp.result as string
      };
      return osResp;
    } catch (e) {
      req.destroy();
      throw e as Error;
    }
  }

  /**
   * 搜索字幕。
   * @param query   视频标题关键词
   * @param languages BCP-47 语言代码，如 "zh-CN"
   * @returns 搜索结果列表；0 条时返回空数组（不抛错）
   */
  async search(query: string, languages: string): Promise<SubtitleSearchResult[]> {
    const baseUrl = await this.resolveBaseUrl();
    const isDirect = await this.isDirectMode();
    const headers = await this.buildHeaders();
    const encodedQuery = encodeURIComponent(query);
    const encodedLangs = encodeURIComponent(languages);
    const url = `${baseUrl}/subtitles?query=${encodedQuery}&languages=${encodedLangs}`;

    const maxRetries = 3;
    let lastError: Error = new Error('未知错误');

    for (let attempt = 0; attempt < maxRetries; attempt++) {
      await this.throttle();
      if (attempt > 0) {
        await new Promise<void>((resolve) => {
          setTimeout(resolve, 1000 * attempt);
        });
      }

      try {
        const resp = await this.doRequest(url, 'GET', headers);

        if (resp.responseCode === 401) {
          throw new InvalidApiKeyError('OpenSubtitles API Key 无效');
        }
        if (resp.responseCode === 429) {
          if (!isDirect) {
            throw new ProxyQuotaExceededError('代理配额已用尽');
          }
          lastError = new Error('OpenSubtitles 限速 429');
          continue;
        }
        if (resp.responseCode !== 200) {
          throw new Error(`OpenSubtitles HTTP ${resp.responseCode}`);
        }

        const parsed = JSON.parse(resp.result) as OsSearchResponse;
        if (!parsed.data || parsed.data.length === 0) {
          return [];
        }

        return parsed.data.map((item: OsDataItem): SubtitleSearchResult => {
          const attr = item.attributes;
          const result: SubtitleSearchResult = {
            subtitleId: attr.subtitle_id,
            fileName: attr.release,
            languageCode: attr.language,
            downloadCount: attr.download_count,
            fileId: attr.files.length > 0 ? attr.files[0].file_id : 0
          };
          return result;
        });
      } catch (e) {
        // 已分类的业务错误直接上抛，不重试
        if (e instanceof InvalidApiKeyError || e instanceof ProxyQuotaExceededError) {
          throw e as Error;
        }
        // 代理通道网络连接异常 → ProxyUnavailableError
        if (!isDirect) {
          const msg = (e as BusinessError).message ?? JSON.stringify(e);
          throw new ProxyUnavailableError(`代理不可达: ${msg}`);
        }
        const err = e as BusinessError;
        lastError = new Error(`OpenSubtitles 请求失败: ${err.message ?? JSON.stringify(e)}`);
        if (attempt < maxRetries - 1) {
          console.warn(`[OpenSubtitlesClient] 请求异常，第 ${attempt + 1} 次重试: ${lastError.message}`);
        }
      }
    }
    throw lastError;
  }

  /**
   * 获取字幕文件临时下载链接。
   * @param fileId  搜索结果中的 file_id
   */
  async getDownloadLink(fileId: number): Promise<SubtitleDownloadLink> {
    const baseUrl = await this.resolveBaseUrl();
    const isDirect = await this.isDirectMode();
    const headers = await this.buildHeaders();
    const url = `${baseUrl}/download`;

    await this.throttle();

    const requestBody: DownloadRequestBody = { file_id: fileId };
    const body = JSON.stringify(requestBody);

    try {
      const resp = await this.doRequest(url, 'POST', headers, body);

      if (resp.responseCode === 401) {
        throw new InvalidApiKeyError('OpenSubtitles API Key 无效');
      }
      if (resp.responseCode === 429) {
        if (!isDirect) {
          throw new ProxyQuotaExceededError('代理配额已用尽');
        }
        throw new SubtitleDownloadError(`下载限速: HTTP 429`);
      }
      if (resp.responseCode !== 200) {
        throw new SubtitleDownloadError(`下载失败: HTTP ${resp.responseCode}`);
      }

      const parsed = JSON.parse(resp.result) as OsDownloadResponse;
      const result: SubtitleDownloadLink = {
        link: parsed.link,
        fileName: parsed.file_name,
        remaining: parsed.remaining
      };
      return result;
    } catch (e) {
      if (
        e instanceof SubtitleDownloadError ||
        e instanceof InvalidApiKeyError ||
        e instanceof ProxyQuotaExceededError
      ) {
        throw e as Error;
      }
      if (!isDirect) {
        const msg = (e as BusinessError).message ?? JSON.stringify(e);
        throw new ProxyUnavailableError(`代理不可达: ${msg}`);
      }
      const err = e as BusinessError;
      throw new SubtitleDownloadError(`下载请求失败: ${err.message ?? JSON.stringify(e)}`);
    }
  }
}
