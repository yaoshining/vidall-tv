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
import { SubtitleDownloader } from "../../subtitle/SubtitleDownloader";
import { SubtitleCacheManager } from "../../subtitle/SubtitleCacheManager";
import {
  SubtitleAcquisitionError,
  SubtitleClearLastUsedInput,
  SubtitleDownloadInput,
  SubtitleDownloadOutcome,
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
   * 调用场景：用户在播放器内主动"关闭字幕"。
   * 关闭动作除了清掉 `SubtitleDispatcher` 中的用户绑定（`AppPreferences` 里的 binding key）
   * 之外，还应同时清掉 `SubtitleCacheManager` 的 `lastUsed`，否则下次进入同一视频时
   * `SubtitleDispatcher.resolveSubtitle` 步骤 4 仍会命中 lastUsed 自动恢复字幕。
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
}

/** 默认 service 实例，便于 UI 端按需 import。 */
export const defaultSubtitleAcquisitionService = new SubtitleAcquisitionService();
