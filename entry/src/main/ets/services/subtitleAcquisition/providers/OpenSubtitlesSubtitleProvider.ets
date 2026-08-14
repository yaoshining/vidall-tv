// filepath: entry/src/main/ets/services/subtitleAcquisition/providers/OpenSubtitlesSubtitleProvider.ets
//
// OpenSubtitles 字幕 provider：包装 `OpenSubtitlesClient`（搜索/下载链接）与
// `SubtitleDownloader`（落盘），映射为 `source=opensubtitles` 的统一结果。
// 该 provider 仅在设置了 OPENSUBTITLES_API_KEY（直连模式）时由 Resolver 返回。

import {
  OpenSubtitlesClient,
  SubtitleSearchResult as OsSearchResult
} from '../../../lib/OpenSubtitlesClient';
import { SubtitleDownloader } from '../../../subtitle/SubtitleDownloader';
import {
  SubtitleSearchResult,
  SubtitleSearchInput,
  SubtitleDownloadOutcome
} from '../SubtitleAcquisitionTypes';
import { SubtitleProvider, SubtitleDownloadContext } from './SubtitleProvider';

export class OpenSubtitlesSubtitleProvider implements SubtitleProvider {
  readonly source: 'opensubtitles' = 'opensubtitles';
  private readonly client: OpenSubtitlesClient;

  constructor(client?: OpenSubtitlesClient) {
    if (client !== undefined) {
      this.client = client;
    } else {
      this.client = new OpenSubtitlesClient();
    }
  }

  async search(input: SubtitleSearchInput): Promise<SubtitleSearchResult[]> {
    const osResults: OsSearchResult[] = await this.client.search(
      input.query,
      input.languages,
      input.year,
      input.seasonNumber,
      input.episodeNumber,
      input.mediaType,
      input.tmdbId,
      input.imdbId
    );
    return osResults.map((r: OsSearchResult): SubtitleSearchResult => {
      const result: SubtitleSearchResult = {
        subtitleId: r.subtitleId,
        source: 'opensubtitles',
        fileName: r.fileName,
        languageCode: r.languageCode,
        downloadCount: r.downloadCount,
        fileId: r.fileId
      };
      return result;
    });
  }

  async download(result: SubtitleSearchResult, ctx: SubtitleDownloadContext): Promise<SubtitleDownloadOutcome> {
    const downloader = new SubtitleDownloader({ filesDir: ctx.filesDir });
    const downloadResult = await downloader.download(
      result.fileId ?? 0,
      ctx.stableVideoSrc,
      ctx.sourceType,
      ctx.sourceId,
      result.languageCode,
      result.downloadCount
    );
    const outcome: SubtitleDownloadOutcome = {
      localPath: downloadResult.localPath,
      fileName: downloadResult.fileName,
      languageCode: result.languageCode
    };
    return outcome;
  }
}
