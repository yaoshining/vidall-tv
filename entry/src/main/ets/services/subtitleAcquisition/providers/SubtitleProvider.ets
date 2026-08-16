// filepath: entry/src/main/ets/services/subtitleAcquisition/providers/SubtitleProvider.ets
//
// 字幕 provider 抽象：统一 OpenSubtitles（直连）与 SubHub 两条字幕源的
// 搜索与下载契约，供 `SubtitleAcquisitionService` 聚合。

import {
  SubtitleSearchResult,
  SubtitleSearchInput,
  SubtitleDownloadOutcome,
  SubtitleSource
} from '../SubtitleAcquisitionTypes';

/** 下载上下文：路径信息与 `SubtitleDownloadInput` 一致，供各 provider 落盘。 */
export interface SubtitleDownloadContext {
  stableVideoSrc: string;
  sourceType: string;
  sourceId: string;
  filesDir: string;
}

/** 字幕 provider 契约。 */
export interface SubtitleProvider {
  readonly source: SubtitleSource;
  search(input: SubtitleSearchInput): Promise<SubtitleSearchResult[]>;
  download(result: SubtitleSearchResult, ctx: SubtitleDownloadContext): Promise<SubtitleDownloadOutcome>;
}
