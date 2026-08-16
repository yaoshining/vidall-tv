// filepath: entry/src/main/ets/services/subtitleAcquisition/providers/SubtitleRelevanceFilter.ets
//
// 标题相关性过滤：去掉「片名模糊匹配」产生的无关结果。
//
// 背景：OpenSubtitles 对中文内容的英文标题做模糊匹配时，会返回大量其它影片的
// 字幕（例：搜 "The Lychee Road" 得到 "Hallow Road" / "Ice Road Vengeance" 等）。
// 这些结果与目标片名无关，却因下载量排序把真正匹配的字幕（含 xunlei 中文名结果）
// 淹没在列表深处。
//
// 匹配策略（分三条路径，命中任意一条即判定相关）：
//   1. 显示标题（中文名）归一化后整串「包含」在文件名里 —— 命中 xunlei 中文名结果。
//      例：displayTitle="长安的荔枝"，文件名 "长安的荔枝.ass" → 相关。
//   2. 英文搜索词拆成「显著 token」（去停用词 the/a/an/of…、去纯数字、长度≥2），
//      要求所有 token 都出现在文件名里 —— 命中英文原名结果，同时过滤掉只撞一个
//      常见词（Road）的无关影片。
//      例：query="The Lychee Road" → tokens=[lychee,road]，"The.Lychee.Road.2025" ✓、
//      "Hallow.Road.2025" ✗（缺 lychee）；query="The Matrix" → tokens=[matrix]，
//      "Matrix.1999" ✓（不再因 "The" 前缀误判）。
//   3. 无英文 token（中文 / 纯数字 query）：整串包含兜底。
//
// 归一化：小写 + 仅保留 [a-z0-9] 与 CJK 汉字，去掉大小写 / 标点 / 空格差异。
//
// 不再做「过滤后为空则回退原列表」：当片名完全匹配不到任何结果时（迅雷超时只剩
// OpenSubtitles 垃圾、或本片确实无字幕），宁可返回空让 UI 显示「无相关结果」，
// 也不把一整屏无关结果重新塞给用户。

import { SubtitleSearchResult } from "../SubtitleAcquisitionTypes";

/** 英文停用词（标题里不具区分度的冠词/介词）。 */
const STOP_WORDS = ['the', 'a', 'an', 'and', 'or', 'of', 'in', 'on', 'at', 'to',
  'for', 'with', 'by', 'de', 'la', 'le', 'el', 'der', 'die', 'das'];

/** 归一化：小写 + 仅保留 [a-z0-9] 与 CJK 汉字。 */
export function normalizeForMatch(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9\u4e00-\u9fff]/g, '');
}

/** 提取英文显著 token：去停用词、去纯数字、去长度<2、去季集标记（s01/e02）。 */
function significantEnglishTokens(query: string): string[] {
  const parts = query.toLowerCase().split(/[^a-z0-9]+/);
  const tokens: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    const w = parts[i];
    const isSeasonEpisodeMarker = /^s\d{1,2}$/.test(w) || /^e\d{1,3}$/.test(w);
    if (w.length >= 2 && STOP_WORDS.indexOf(w) < 0 && /[a-z]/.test(w) && !isSeasonEpisodeMarker) {
      tokens.push(w);
    }
  }
  return tokens;
}

/** 判断单条结果的文件名是否与搜索词 / 显示标题相关。 */
export function isTitleRelevant(fileName: string, query: string, displayTitle?: string): boolean {
  const normFile = normalizeForMatch(fileName);
  if (normFile.length === 0) {
    // 文件名无有效字符时无法判断，放行。
    return true;
  }

  // 1) 显示标题（中文名）整串包含 → 相关
  const normTitle = displayTitle ? normalizeForMatch(displayTitle) : '';
  if (normTitle.length > 0 && normFile.includes(normTitle)) {
    return true;
  }

  // 2) 英文搜索词：所有显著 token 都出现在文件名里才相关
  const tokens = significantEnglishTokens(query);
  if (tokens.length > 0) {
    for (let i = 0; i < tokens.length; i++) {
      if (!normFile.includes(tokens[i])) {
        return false;
      }
    }
    return true;
  }

  // 3) 无英文 token（中文 / 纯数字 query）：整串包含兜底
  const normQuery = normalizeForMatch(query);
  if (normQuery.length > 0) {
    return normFile.includes(normQuery);
  }
  return true;
}

/** 按标题相关性过滤结果（可能返回空数组）。 */
export function filterByTitleRelevance(
  results: SubtitleSearchResult[],
  query: string,
  displayTitle?: string
): SubtitleSearchResult[] {
  const relevant: SubtitleSearchResult[] = [];
  for (let i = 0; i < results.length; i++) {
    const r = results[i];
    if (isTitleRelevant(r.fileName, query, displayTitle)) {
      relevant.push(r);
    }
  }
  return relevant;
}
