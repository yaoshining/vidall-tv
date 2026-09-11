import { MediaItem } from '../../db/models/MediaEntity';
import { SearchScope } from '../../models/search/SearchScope';

/** Reuse accepted local search results so completion has the same matching and ranking. */
export function titleSuggestions(scope: SearchScope, items: MediaItem[]): string[] {
  if (scope.kind !== 'localFiles') { return []; }
  const titles: string[] = [];
  const seen: Set<string> = new Set<string>();
  for (const item of items) {
    const title = (item.title ?? '').trim();
    if (title.length === 0 || seen.has(title.toLowerCase())) { continue; }
    seen.add(title.toLowerCase());
    titles.push(title);
    if (titles.length === 20) { break; }
  }
  return titles;
}

/** Examples describe input syntax, never claim that a title exists in the source. */
export function searchInputExample(scope: SearchScope): string {
  if (scope.kind === 'localFiles') { return '输入示例：流浪地球 / liulangdiqiu / lldq（仅搜索本地文件源）'; }
  if (scope.kind === 'videoServer') { return '输入示例：片名或片名中的文字，如 Dune（仅搜索当前服务器，不代表已收录）'; }
  return '';
}
