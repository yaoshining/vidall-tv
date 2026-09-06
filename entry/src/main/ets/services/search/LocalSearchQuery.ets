import { normalizeSearchText, toPinyinFull, toPinyinInitials } from '../../utils/PinyinUtil';

export interface LocalSearchQuery {
  whereClause: string;
  whereParams: string[];
  rankExpression: string;
  rankParams: string[];
}

interface SearchMatch {
  sql: string;
  params: string[];
}

/** Escape LIKE metacharacters before adding intentional prefix/contains wildcards. */
export function escapeSearchLike(value: string): string {
  return value.replace(/\\/g, '\\\\').replace(/%/g, '\\%').replace(/_/g, '\\_');
}

function titleMatch(columns: string[], values: string[], exact: boolean): SearchMatch {
  const sql: string[] = [];
  const params: string[] = [];
  for (const column of columns) {
    for (const value of values) {
      sql.push(exact ? `${column} = ? COLLATE NOCASE` : `${column} LIKE ? ESCAPE '\\'`);
      params.push(value);
    }
  }
  return { sql: '(' + sql.join(' OR ') + ')', params: params };
}

function pinyinMatch(column: string, value: string, exact: boolean, hanParts: string[]): SearchMatch {
  const alternatives: string[] = [];
  const params: string[] = [];
  for (const alias of ['m', 'ts']) {
    const constraints: string[] = [exact ? `${alias}.${column} = ?` : `${alias}.${column} LIKE ? ESCAPE '\\'`];
    params.push(value);
    // Keep actual Chinese text on the same row; mixed queries must not expand to homophones.
    for (const part of hanParts) {
      constraints.push(`${alias}.title_normalized LIKE ? ESCAPE '\\'`);
      params.push('%' + escapeSearchLike(part) + '%');
    }
    alternatives.push('(' + constraints.join(' AND ') + ')');
  }
  return { sql: '(' + alternatives.join(' OR ') + ')', params: params };
}

/** Shared WHERE/rank predicates keep recall and relevance identical; no SQL contains user text. */
export function buildLocalSearchQuery(keyword: string): LocalSearchQuery {
  const raw = keyword.trim();
  if (raw.length === 0) {
    return { whereClause: '', whereParams: [], rankExpression: '0', rankParams: [] };
  }
  const normalized = normalizeSearchText(raw);
  const titleValues: string[] = [raw];
  const compatibilityText = raw.normalize('NFKC').trim();
  if (compatibilityText.length > 0 && compatibilityText !== raw) {
    titleValues.push(compatibilityText);
  }
  // Preserve Latin word spacing in original titles. Han input also gets a compact literal candidate.
  if (normalized.length > 0 && /[\u3400-\u9fff]/.test(normalized) && !titleValues.includes(normalized)) {
    titleValues.push(normalized);
  }
  const prefixes: string[] = [];
  const contains: string[] = [];
  for (const value of titleValues) {
    const escaped = escapeSearchLike(value);
    prefixes.push(escaped + '%');
    contains.push('%' + escaped + '%');
  }
  const columns: string[] = ['m.title', 'ts.title', 's.title', 'm.original_title', 'ts.original_title'];
  const matches: SearchMatch[] = [
    titleMatch(columns, titleValues, true),
    titleMatch(columns, prefixes, false),
    titleMatch(columns, contains, false)
  ];
  // 标题与查询采用相同规范化；只为含汉字的查询扩展，保留拉丁字面量及通配符语义。
  if (normalized.length > 0 && /[\u3400-\u9fff]/.test(normalized)) {
    const normalizedColumns: string[] = ['m.title_normalized', 'ts.title_normalized'];
    const escaped = escapeSearchLike(normalized);
    const normalizedMatches: SearchMatch[] = [
      titleMatch(normalizedColumns, [normalized], true),
      titleMatch(normalizedColumns, [escaped + '%'], false),
      titleMatch(normalizedColumns, ['%' + escaped + '%'], false)
    ];
    for (let i = 0; i < normalizedMatches.length; i++) {
      matches[i].sql = '(' + matches[i].sql + ' OR ' + normalizedMatches[i].sql + ')';
      matches[i].params.push(...normalizedMatches[i].params);
    }
  }
  const hanParts: string[] = normalized.match(/[\u3400-\u9fff]+/g) ?? [];
  const hasLatin = /[a-z]/.test(normalized);
  // Pure Chinese queries use literal titles only. Punctuation-only input cannot become LIKE '%'.
  if (hasLatin) {
    const full = hanParts.length > 0 ? toPinyinFull(raw) : normalized;
    const initials = hanParts.length > 0 ? toPinyinInitials(raw) : normalized;
    if (/^[a-z0-9]+$/.test(full)) {
      matches.push(pinyinMatch('title_pinyin', full, true, hanParts));
      if (full.length > 1) {
        matches.push(pinyinMatch('title_pinyin', escapeSearchLike(full) + '%', false, hanParts));
        matches.push(pinyinMatch('title_pinyin_segments', '%|' + escapeSearchLike(full) + '%', false, hanParts));
      }
    }
    if (/^[a-z0-9]+$/.test(initials)) {
      matches.push(pinyinMatch('title_initials', initials, true, hanParts));
      if (initials.length > 1) {
        matches.push(pinyinMatch('title_initials', escapeSearchLike(initials) + '%', false, hanParts));
      }
    }
  }
  const where: string[] = [];
  const whereParams: string[] = [];
  const ranks: string[] = [];
  const rankParams: string[] = [];
  for (let i = 0; i < matches.length; i++) {
    const match = matches[i];
    where.push(match.sql);
    whereParams.push(...match.params);
    ranks.push(`WHEN ${match.sql} THEN ${i}`);
    rankParams.push(...match.params);
  }
  return {
    whereClause: '(' + where.join(' OR ') + ')',
    whereParams: whereParams,
    rankExpression: 'CASE ' + ranks.join(' ') + ` ELSE ${matches.length} END`,
    rankParams: rankParams
  };
}
