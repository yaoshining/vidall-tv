// filepath: entry/src/main/ets/services/subtitleAcquisition/providers/SubtitleDeduplicator.ets
//
// 客户端内容指纹去重：OpenSubtitles 与 SubHub 可能返回同一字幕的重复条目，
// 用「归一化文件名 + 语言码」作为指纹去重，碰撞时保留 OpenSubtitles 结果
// （其携带真实 downloadCount，信息更丰富）。

import { SubtitleSearchResult } from '../SubtitleAcquisitionTypes';

/** 归一化发布名：小写、trim、去扩展名、去发布组标记、压缩非字母数字。 */
export function normalizeReleaseName(name: string): string {
  let n = name.toLowerCase().trim();
  // 去字幕文件扩展名
  n = n.replace(/\.(srt|ass|ssa|sub|vtt|txt)$/i, '');
  // 去发布组标记，如 [YTS.MX] / {ABC} / (RARBG)
  n = n.replace(/[\[\(\{][^\]\)\}]*[\]\)\}]/g, ' ');
  // 去 -RARBG 之类发布组后缀
  n = n.replace(/-rarbg\b/gi, ' ');
  // 压缩连续非字母数字为单个空格
  n = n.replace(/[^a-z0-9]+/g, ' ');
  return n.trim();
}

export class SubtitleDeduplicator {
  /** 去重：碰撞时保留 OpenSubtitles 结果；保持输入顺序。 */
  static dedupe(results: SubtitleSearchResult[]): SubtitleSearchResult[] {
    const byFingerprint = new Map<string, SubtitleSearchResult>();
    const ordered: SubtitleSearchResult[] = [];
    for (let i = 0; i < results.length; i++) {
      const item = results[i];
      const key = SubtitleDeduplicator.fingerprint(item);
      const existing = byFingerprint.get(key);
      if (existing === undefined) {
        byFingerprint.set(key, item);
        ordered.push(item);
      } else if (existing.source !== 'opensubtitles' && item.source === 'opensubtitles') {
        // OpenSubtitles 优先：用 OS 结果替换已记录的 SubHub 结果
        byFingerprint.set(key, item);
        const index = ordered.indexOf(existing);
        if (index >= 0) {
          ordered[index] = item;
        }
      }
    }
    return ordered;
  }

  static fingerprint(item: SubtitleSearchResult): string {
    const name = normalizeReleaseName(item.fileName);
    const lang = (item.languageCode ?? '').toLowerCase().trim();
    return `${name}:${lang}`;
  }
}
