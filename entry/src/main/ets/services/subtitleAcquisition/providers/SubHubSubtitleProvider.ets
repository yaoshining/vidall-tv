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
    const outcome = await this.client.search({
      title: input.query,
      // xunlei provider 需要 query（映射上游 name）；与 title 同值，避免 skipped_missing_fields
      query: input.query,
      language: this.firstLanguage(input.languages),
      year: input.year,
      season: input.seasonNumber,
      episode: input.episodeNumber,
      type: input.mediaType === 'movie' ? 'movie' : (input.mediaType === 'tv' ? 'episode' : undefined),
      tmdbId: this.parseTmdbId(input.tmdbId)
    });
    return outcome.results.map((r: ShSearchResult): SubtitleSearchResult => {
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
  }

  async download(result: SubtitleSearchResult, ctx: SubtitleDownloadContext): Promise<SubtitleDownloadOutcome> {
    const subtitleRef = result.subtitleRef !== undefined ? result.subtitleRef : result.subtitleId;
    const fallbackName = result.fileName.length > 0 ? result.fileName : 'subtitle.srt';
    const downloaded = await this.client.download(subtitleRef, fallbackName);
    const localPath = await writeSubtitleContentToCache(
      ctx.filesDir, ctx.sourceType, ctx.sourceId, ctx.stableVideoSrc, downloaded.fileName, downloaded.content
    );

    // 发布下载完成事件，供 UI 刷新缓存列表
    emitter.emit({ eventId: SUBTITLE_DOWNLOADED_EVENT_ID }, {
      data: { localPath: localPath, fileName: downloaded.fileName }
    });

    // 写入字幕缓存 metadata（fire-and-forget，失败不影响下载结果）
    const cacheEntry: CachedSubtitleEntry = {
      fileName: downloaded.fileName,
      language: result.languageCode,
      downloadedAt: new Date().toISOString(),
      source: 'subhub',
      subDownloadCount: result.downloadCount
    };
    this.cacheManager.saveSubtitle(
      ctx.filesDir, ctx.sourceType, ctx.sourceId, ctx.stableVideoSrc, cacheEntry
    ).catch(() => {
      console.warn('[SubHubProvider] saveSubtitle 失败（非致命）');
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
