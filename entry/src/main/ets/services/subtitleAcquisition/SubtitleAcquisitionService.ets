// filepath: entry/src/main/ets/services/subtitleAcquisition/SubtitleAcquisitionService.ets
//
// SubtitleAcquisitionService - 字幕获取用例层 façade。
//
// 目标：把 `SubtitleSelectorDrawerDialog` 中对 `OpenSubtitlesClient` /
// `SubtitleDownloader` / `SubtitleCacheManager` 的直接依赖收口到 service。
//
// 约束：
// 1. 不修改 `OpenSubtitlesClient` / `SubtitleDownloader` / `SubtitleCacheManager` 的现有签名。
// 2. 不修改 `VideoPlayerController.addExternalSubtitle` / `switchSubtitleTrack` 的现有签名。
// 3. UI 端不再 import 4 个具体 Error 类与 Client / Downloader / CacheManager。
//
// 设计要点：
// - 每次操作内 `new` 新的 Client / Downloader / CacheManager 实例，与原 `VideoControls` 内
//   行为一致（这些类本身无状态或仅依赖 filesDir 路径参数）。
// - 4 个 Error 类通过 `classifyAcquisitionError` 归一映射到 `SubtitleAcquisitionErrorKind`，
//   UI 按 `error.kind` 决定 Toast 文案。
// - `markLastUsed` 失败时仅 warn 不抛（按 OpenSpec 3.4 scenario 2：异常不阻断下载挂载结果）。

import { hilog } from '@kit.PerformanceAnalysisKit';
import { OpenSubtitlesClient } from "../../lib/OpenSubtitlesClient";
import {
  SubtitleDownloader,
  buildSubtitlePath,
  sha256Hex
} from "../../subtitle/SubtitleDownloader";
import { SubtitleCacheManager, CachedSubtitleEntry } from "../../subtitle/SubtitleCacheManager";
import {
  SubtitleAcquisitionError,
  SubtitleClearLastUsedInput,
  SubtitleDownloadInput,
  SubtitleDownloadOutcome,
  SubtitleEnableCachedInput,
  SubtitleEnableCachedOutcome,
  SubtitleListCachedInput,
  SubtitleMarkLastUsedInput,
  SubtitleSearchInput,
  SubtitleSearchResult,
  classifyAcquisitionError
} from "./SubtitleAcquisitionTypes";

const DOMAIN = 0x0002;
const TAG = 'SubtitleAcquisitionService';

/** service 公共方法集合。 */
export class SubtitleAcquisitionService {
  /**
   * 搜索在线字幕。
   *
   * 抛出 `SubtitleAcquisitionError`，`error.kind` 决定 UI 端 Toast 文案。
   */
  async search(input: SubtitleSearchInput): Promise<SubtitleSearchResult[]> {
    try {
      const client = new OpenSubtitlesClient();
      const results = await client.search(
        input.query,
        input.languages,
        input.year,
        input.seasonNumber,
        input.episodeNumber,
        input.mediaType,
        input.tmdbId
      );
      return results;
    } catch (e) {
      const kind = classifyAcquisitionError(e as object);
      const message = (e as Record<string, string>)['message'] ?? JSON.stringify(e);
      hilog.warn(DOMAIN, TAG, `search failed: kind=${kind} msg=${message}`);
      throw new SubtitleAcquisitionError(kind, message);
    }
  }

  /**
   * 下载字幕。
   *
   * 抛出 `SubtitleAcquisitionError`。
   * 成功后返回 `localPath` / `fileName` 供 UI 调 `videoController.addExternalSubtitle`。
   */
  async download(input: SubtitleDownloadInput): Promise<SubtitleDownloadOutcome> {
    try {
      const downloader = new SubtitleDownloader({ filesDir: input.filesDir });
      const downloadResult = await downloader.download(
        input.result.fileId,
        input.stableVideoSrc,
        input.sourceType,
        input.sourceId,
        input.result.languageCode,
        input.result.downloadCount
      );
      const outcome: SubtitleDownloadOutcome = {
        localPath: downloadResult.localPath,
        fileName: downloadResult.fileName,
        languageCode: input.result.languageCode
      };
      return outcome;
    } catch (e) {
      const kind = classifyAcquisitionError(e as object);
      const message = (e as Record<string, string>)['message'] ?? JSON.stringify(e);
      hilog.warn(DOMAIN, TAG, `download failed: kind=${kind} msg=${message}`);
      throw new SubtitleAcquisitionError(kind, message);
    }
  }

  /**
   * 标记最近使用字幕。
   *
   * 失败仅 warn，不抛（按 OpenSpec 3.4 scenario 2：异常不会改变当前下载字幕已经成功挂载的结果）。
   * 调用方可在 UI 编排中以 fire-and-forget 方式调用。
   */
  async markLastUsed(input: SubtitleMarkLastUsedInput): Promise<void> {
    try {
      const cacheManager = new SubtitleCacheManager();
      await cacheManager.setLastUsedSubtitle(
        input.filesDir,
        input.sourceType,
        input.sourceId,
        input.stableVideoSrc,
        input.fileName
      );
    } catch (e) {
      const errMsg = (e as Record<string, string>)['message'] ?? JSON.stringify(e);
      hilog.warn(DOMAIN, TAG, `markLastUsed failed (non-fatal): ${errMsg}`);
    }
  }

  /**
   * 清除最近使用字幕标记。
   *
   * 调用场景：仅在**显式重置最近使用记录**时调用（例如菜单中"清除 lastUsed"操作）。
   *
   * 注意：`SubtitleDispatcher` 当前已采用 disabled 绑定标记策略——
   * 用户关闭字幕时通过 `clearUserBinding` 写入 `{ subtitleType: 'disabled' }`，
   * `resolveSubtitle` 步骤 1 即返回 `{ type: 'user-specified', trackIndex: -1 }`，
   * 短路步骤 4 的 lastUsed 自动恢复。因此**用户主动关闭字幕**的场景**无需**调用本方法；
   * 错误的"为防 lastUsed 恢复而调用"会导致 lastUsed 指针丢失，影响后续手动选轨时缓存提示。
   *
   * 失败仅 warn，不抛（与 `markLastUsed` 风格一致）。
   */
  async clearLastUsed(input: SubtitleClearLastUsedInput): Promise<void> {
    try {
      const cacheManager = new SubtitleCacheManager();
      await cacheManager.clearLastUsedSubtitle(
        input.filesDir,
        input.sourceType,
        input.sourceId,
        input.stableVideoSrc
      );
    } catch (e) {
      const errMsg = (e as Record<string, string>)['message'] ?? JSON.stringify(e);
      hilog.warn(DOMAIN, TAG, `clearLastUsed failed (non-fatal): ${errMsg}`);
    }
  }

  /**
   * 列出某视频已下载的所有字幕缓存条目。
   *
   * 用于 UI 端在"关闭字幕"后仍能展示"已下载字幕"分组，供用户主动重新启用。
   * 失败返回空数组（与 `listCachedSubtitles` 实现一致），不抛。
   */
  async listCached(input: SubtitleListCachedInput): Promise<CachedSubtitleEntry[]> {
    try {
      const cacheManager = new SubtitleCacheManager();
      return await cacheManager.listCachedSubtitles(
        input.filesDir,
        input.sourceType,
        input.sourceId,
        input.stableVideoSrc
      );
    } catch (e) {
      const errMsg = (e as Record<string, string>)['message'] ?? JSON.stringify(e);
      hilog.warn(DOMAIN, TAG, `listCached failed: ${errMsg}`);
      return [];
    }
  }

  /**
   * 计算缓存字幕的本地绝对路径，供 UI 调 `videoController.addExternalSubtitle`。
   *
   * 之所以 service 暴露此路径而不是 UI 端自行调用 `buildSubtitlePath`：
   * 1. `buildSubtitlePath` 是 `SubtitleDownloader` 的内部实现细节，UI 不应直接 import
   * 2. 路径计算涉及 SHA-256（异步），service 统一封装避免 UI 端遗漏 await
   *
   * 调用时机：用户在字幕菜单"已下载"分组中点击某条缓存字幕。
   */
  async enableCached(input: SubtitleEnableCachedInput): Promise<SubtitleEnableCachedOutcome> {
    const hash = await sha256Hex(input.stableVideoSrc);
    const localPath = buildSubtitlePath(
      input.filesDir,
      input.sourceType,
      input.sourceId,
      hash,
      input.fileName
    );
    const outcome: SubtitleEnableCachedOutcome = {
      localPath,
      fileName: input.fileName
    };
    return outcome;
  }
}

/** 默认 service 实例，便于 UI 端按需 import。 */
export const defaultSubtitleAcquisitionService = new SubtitleAcquisitionService();
