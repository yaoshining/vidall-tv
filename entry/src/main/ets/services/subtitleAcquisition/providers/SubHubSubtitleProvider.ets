// filepath: entry/src/main/ets/services/subtitleAcquisition/providers/SubHubSubtitleProvider.ets
//
// SubHub 字幕 provider：包装 `SubHubClient`，把 SubHub 搜索结果映射为
// `source=subhub` 的统一结果；下载走 SubHub `GET /download` 二进制流并落盘。

import { emitter } from '@kit.BasicServicesKit';
import { SubHubClient, SubHubSearchResult as ShSearchResult } from '../../../lib/SubHubClient';
import { SubtitleCacheManager, CachedSubtitleEntry } from '../../../subtitle/SubtitleCacheManager';
import {
  writeSubtitleContentToCache,
  SUBTITLE_DOWNLOADED_EVENT_ID
} from '../../../subtitle/SubtitleDownloader';
import {
  SubtitleSearchResult,
  SubtitleSearchInput,
  SubtitleDownloadOutcome
} from '../SubtitleAcquisitionTypes';
import { SubtitleProvider, SubtitleDownloadContext } from './SubtitleProvider';
import { isChineseLanguagePreference, isChineseSubtitle } from './SubtitleLanguageFilter';

export class SubHubSubtitleProvider implements SubtitleProvider {
  readonly source: 'subhub' = 'subhub';
  private readonly client: SubHubClient;
  private readonly cacheManager: SubtitleCacheManager;

  constructor(client?: SubHubClient, cacheManager?: SubtitleCacheManager) {
    if (client !== undefined) {
      this.client = client;
    } else {
      this.client = new SubHubClient();
    }
    if (cacheManager !== undefined) {
      this.cacheManager = cacheManager;
    } else {
      this.cacheManager = new SubtitleCacheManager();
    }
  }

  async search(input: SubtitleSearchInput): Promise<SubtitleSearchResult[]> {
    // 传 language：opensubtitles 依赖服务端按语言过滤（不传会被其它语言结果淹没，
    // 中文结果排不进前 50 条）。xunlei 侧由 SubHub PR #203 归一化后再过滤，App 端不处理。
    const outcome = await this.client.search({
      title: input.query,
      // xunlei provider 用 query（映射上游 name）：传中文显示名以命中「中文名命名」的字幕
      // （如韩剧 权欲之巅 的迅雷结果叫 "权欲之巅KR.E01"，英文名 "Climax" 匹配不到）；
      // 无中文显示名时回退英文原名。
      query: (input.displayTitle !== undefined && input.displayTitle.trim().length > 0)
        ? input.displayTitle.trim()
        : input.query,
      language: this.firstLanguage(input.languages),
      year: input.year,
      season: input.seasonNumber,
      episode: input.episodeNumber,
      type: input.mediaType === 'movie' ? 'movie' : (input.mediaType === 'tv' ? 'episode' : undefined),
      tmdbId: this.parseTmdbId(input.tmdbId),
      imdbId: input.imdbId !== undefined && input.imdbId.length > 0 ? input.imdbId : undefined
    });
    const mapped: SubtitleSearchResult[] = outcome.results.map((r: ShSearchResult): SubtitleSearchResult => {
      const result: SubtitleSearchResult = {
        subtitleId: r.id,
        source: 'subhub',
        fileName: r.releaseName !== null && r.releaseName !== undefined ? r.releaseName : 'subtitle',
        languageCode: r.language !== null && r.language !== undefined ? r.language : '',
        downloadCount: this.readDownloadCount(r),
        subtitleRef: r.id
      };
      return result;
    });

    // 双保险：中文向偏好时本地再过滤一道（language 字段可靠时优先，迅雷脏值时按 releaseName）。
    if (isChineseLanguagePreference(input.languages)) {
      const filtered = mapped.filter((r: SubtitleSearchResult): boolean =>
        isChineseSubtitle(r.fileName, r.languageCode)
      );
      // 避免「过滤后全空」静默无感知：有结果被全部滤掉时记一条日志
      if (mapped.length > 0 && filtered.length === 0) {
        console.warn(`[SubHubProvider] 中文过滤清空了全部 ${mapped.length} 条结果（language/releaseName 均不可用）`);
      }
      return filtered;
    }
    return mapped;
  }

  async download(result: SubtitleSearchResult, ctx: SubtitleDownloadContext): Promise<SubtitleDownloadOutcome> {
    const subtitleRef = result.subtitleRef !== undefined ? result.subtitleRef : result.subtitleId;
    const fallbackName = result.fileName.length > 0 ? result.fileName : 'subtitle.srt';
    const downloaded = await this.client.download(subtitleRef, fallbackName);
    const localPath = await writeSubtitleContentToCache(
      ctx.filesDir, ctx.sourceType, ctx.sourceId, ctx.stableVideoSrc, downloaded.fileName, downloaded.content
    );

    // 先写缓存 metadata（失败仅 warn，不阻断下载结果），再发布事件，确保监听方读到已更新的 metadata
    const cacheEntry: CachedSubtitleEntry = {
      fileName: downloaded.fileName,
      language: result.languageCode,
      downloadedAt: new Date().toISOString(),
      source: 'subhub',
      subDownloadCount: result.downloadCount
    };
    await this.cacheManager.saveSubtitle(
      ctx.filesDir, ctx.sourceType, ctx.sourceId, ctx.stableVideoSrc, cacheEntry
    ).catch(() => {
      console.warn('[SubHubProvider] saveSubtitle 失败（非致命）');
    });

    // 发布下载完成事件，供 UI 刷新缓存列表
    emitter.emit({ eventId: SUBTITLE_DOWNLOADED_EVENT_ID }, {
      data: { localPath: localPath, fileName: downloaded.fileName }
    });

    const outcome: SubtitleDownloadOutcome = {
      localPath: localPath,
      fileName: downloaded.fileName,
      languageCode: result.languageCode
    };
    return outcome;
  }

  /** 取偏好语言列表的首个语言码（SubHub 的 language 只接受单个值）。 */
  private firstLanguage(languages: string): string | undefined {
    const trimmed = languages.trim();
    if (trimmed.length === 0) {
      return undefined;
    }
    const first = trimmed.split(',')[0];
    const lang = first.trim();
    return lang.length > 0 ? lang : undefined;
  }

  /** 解析 TMDB ID 字符串为数字（非法/为空返回 undefined）。 */
  private parseTmdbId(tmdbId?: string): number | undefined {
    if (tmdbId === undefined || tmdbId.trim().length === 0) {
      return undefined;
    }
    const n = Number(tmdbId);
    return Number.isNaN(n) || n < 1 ? undefined : n;
  }

  private readDownloadCount(r: ShSearchResult): number {
    if (r.raw !== null && r.raw !== undefined) {
      const raw = r.raw['download_count'];
      return typeof raw === 'number' ? raw : 0;
    }
    return 0;
  }
}
