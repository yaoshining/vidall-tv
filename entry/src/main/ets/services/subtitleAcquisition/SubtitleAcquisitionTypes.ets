// filepath: entry/src/main/ets/services/subtitleAcquisition/SubtitleAcquisitionTypes.ets
//
// 字幕获取 service 的类型契约。
//
// 背景：原 `SubtitleSelectorDrawerDialog`（在 `VideoControls.ets` 内）直接 import：
//   - `OpenSubtitlesClient` + 4 个 Error 类
//   - `SubtitleDownloader` + `SubtitleStorageContext`
//   - `SubtitleCacheManager`
// 用于搜索 / 下载 / 标记 lastUsed 三个用例。
//
// Module 3 目标：把以上 3 个基础设施的 import 收口到 `SubtitleAcquisitionService`，
// UI 仅依赖本文件的类型 + 业务错误 `SubtitleAcquisitionError`（带 `kind` 字段）。
//
// 兼容性：
// - `SubtitleSearchResult` 直接复用 `OpenSubtitlesClient.SubtitleSearchResult`，
//   UI 端无需改字段访问。
// - 4 个具体 Error 类的 Toast 文案映射在 UI 端按 `error.kind` 决定，service 不发 Toast。

import {
  ProxyQuotaExceededError,
  ProxyUnavailableError,
  InvalidApiKeyError,
  SubtitleDownloadError,
  SubtitleSearchResult
} from "../../lib/OpenSubtitlesClient";

/** 字幕搜索结果（直接复用 OpenSubtitlesClient 类型）。 */
export type { SubtitleSearchResult };

/** 字幕获取错误分类。 */
export type SubtitleAcquisitionErrorKind =
  /** 代理通道配额耗尽（HTTP 429）。 */
  | 'proxy_quota_exceeded'
  /** 代理网络不可达（连接失败）。 */
  | 'proxy_unavailable'
  /** API Key 无效（HTTP 401）。 */
  | 'invalid_api_key'
  /** 字幕下载失败（非鉴权/限速类通用错误）。 */
  | 'download_failed'
  /** 其它未分类错误。 */
  | 'unknown';

/** 字幕获取业务错误。 */
export class SubtitleAcquisitionError extends Error {
  readonly kind: SubtitleAcquisitionErrorKind;
  constructor(kind: SubtitleAcquisitionErrorKind, message: string) {
    super(message);
    this.kind = kind;
  }
}

/** 搜索输入。 */
export interface SubtitleSearchInput {
  query: string;
  /** OpenSubtitles 语言参数，如 "chi,zho,eng"。 */
  languages: string;
  year?: number;
  seasonNumber?: number;
  episodeNumber?: number;
  mediaType?: 'movie' | 'tv';
  /** TMDB ID 数字字符串，启用精准匹配。 */
  tmdbId?: string;
}

/** 下载输入。 */
export interface SubtitleDownloadInput {
  result: SubtitleSearchResult;
  /** 视频源稳定身份（用于缓存目录命名）。 */
  stableVideoSrc: string;
  sourceType: string;
  sourceId: string;
  filesDir: string;
}

/** 下载成功结果，供 UI 调 `videoController.addExternalSubtitle`。 */
export interface SubtitleDownloadOutcome {
  localPath: string;
  fileName: string;
  languageCode: string;
}

/** 标记最近使用输入。 */
export interface SubtitleMarkLastUsedInput {
  fileName: string;
  stableVideoSrc: string;
  sourceType: string;
  sourceId: string;
  filesDir: string;
}

/** 清除最近使用输入（与 `SubtitleMarkLastUsedInput` 同形，但无需 fileName）。 */
export interface SubtitleClearLastUsedInput {
  stableVideoSrc: string;
  sourceType: string;
  sourceId: string;
  filesDir: string;
}

/**
 * 把已知的 4 个具体 Error 类归一映射为业务错误分类。
 *
 * 仅在 service 内部使用，UI 端通过 `error.kind` 决定 Toast 文案。
 */
export function classifyAcquisitionError(e: object): SubtitleAcquisitionErrorKind {
  if (e instanceof ProxyQuotaExceededError) {
    return 'proxy_quota_exceeded';
  }
  if (e instanceof ProxyUnavailableError) {
    return 'proxy_unavailable';
  }
  if (e instanceof InvalidApiKeyError) {
    return 'invalid_api_key';
  }
  if (e instanceof SubtitleDownloadError) {
    return 'download_failed';
  }
  return 'unknown';
}
