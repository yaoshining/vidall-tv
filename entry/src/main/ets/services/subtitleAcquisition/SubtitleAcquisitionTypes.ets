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
// - 搜索结果 `SubtitleSearchResult` 现在是「多 provider 统一结果」，新增 `source` 字段，
//   用于区分 `opensubtitles`（直连）与 `subhub`（SubHub 网关）两条链路。
// - 4 个 OS Error 类 + 4 个 SubHub Error 类的 Toast 文案映射在 UI 端按 `error.kind` 决定。

import {
  ProxyQuotaExceededError,
  ProxyUnavailableError,
  InvalidApiKeyError,
  SubtitleDownloadError
} from "../../lib/OpenSubtitlesClient";
import { SubHubApiError, SubHubNetworkError } from "../../lib/SubHubClient";
import { CachedSubtitleEntry } from "../../subtitle/SubtitleCacheManager";

/** 字幕来源。 */
export type SubtitleSource = 'opensubtitles' | 'subhub';

/** 统一字幕搜索结果（聚合 OpenSubtitles 与 SubHub 两源）。 */
export interface SubtitleSearchResult {
  /** 稳定唯一 key：OpenSubtitles 用 subtitle_id，SubHub 用网关引用 id。 */
  subtitleId: string;
  source: SubtitleSource;
  fileName: string;
  languageCode: string;
  downloadCount: number;
  /** 仅 opensubtitles：下载用 file_id。 */
  fileId?: number;
  /** 仅 subhub：下载用完整网关引用（`opensubtitles:{providerId}:{file_id}`）。 */
  subtitleRef?: string;
}

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
  /** SubHub Caller Key 无效或权限不足。 */
  | 'subhub_auth_invalid'
  /** SubHub 上游凭据耗尽。 */
  | 'subhub_quota_exhausted'
  /** SubHub 服务不可用或上游失败/超时。 */
  | 'subhub_unavailable'
  /** SubHub 字幕已失效（下载时 ID 不存在）。 */
  | 'subhub_not_found'
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
  /** OpenSubtitles 语言参数，如 "chi,zho,eng"（SubHub 侧取首个语言码）。 */
  languages: string;
  year?: number;
  seasonNumber?: number;
  episodeNumber?: number;
  mediaType?: 'movie' | 'tv';
  /** TMDB ID 数字字符串，启用精准匹配。 */
  tmdbId?: string;
  /** IMDb ID（tt + 数字），存在时优先于 tmdbId 精准匹配。 */
  imdbId?: string;
  /** 用户可见标题（中文名优先），用于标题相关性过滤。 */
  displayTitle?: string;
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

/** 列出已下载字幕条目输入。 */
export interface SubtitleListCachedInput {
  stableVideoSrc: string;
  sourceType: string;
  sourceId: string;
  filesDir: string;
}

/** 启用已下载字幕输入（计算 localPath 供 UI 调 `videoController.addExternalSubtitle`）。 */
export interface SubtitleEnableCachedInput {
  stableVideoSrc: string;
  sourceType: string;
  sourceId: string;
  filesDir: string;
  fileName: string;
}

/** 启用已下载字幕结果。 */
export interface SubtitleEnableCachedOutcome {
  localPath: string;
  fileName: string;
}

/** 已下载字幕条目（re-export，UI 端无需直接 import SubtitleCacheManager）。 */
export type { CachedSubtitleEntry };

/**
 * 把已知的具体 Error 类归一映射为业务错误分类。
 *
 * 仅在 service 内部使用，UI 端通过 `error.kind` 决定 Toast 文案。
 */
export function classifyAcquisitionError(e: object): SubtitleAcquisitionErrorKind {
  if (e instanceof SubHubApiError) {
    const code = (e as SubHubApiError).code;
    if (code === 'CALLER_KEY_INVALID' || code === 'CALLER_KEY_SUSPENDED' || code === 'FORBIDDEN') {
      return 'subhub_auth_invalid';
    }
    if (code === 'PROVIDER_CREDENTIAL_EXHAUSTED') {
      return 'subhub_quota_exhausted';
    }
    if (code === 'SUBTITLE_NOT_FOUND') {
      return 'subhub_not_found';
    }
    return 'subhub_unavailable';
  }
  if (e instanceof SubHubNetworkError) {
    return 'subhub_unavailable';
  }
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
