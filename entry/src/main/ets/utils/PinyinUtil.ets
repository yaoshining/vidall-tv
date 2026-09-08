import { pinyin } from 'pinyin-pro';

/** Shared normalization for local title indexes and queries; ü / u: / v are equivalent. */
export function normalizeSearchText(text: string): string {
  return text.normalize('NFKC').toLowerCase().replace(/u:/g, 'v')
    .replace(/[üǖǘǚǜ]/g, 'v').normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .replace(/[\s\-_'’·.,，。:：!?！？、()（）\[\]【】]/g, '');
}

function titleParts(text: string): string[] {
  // Phrase-level conversion preserves contextual readings (重庆、长安、音乐).
  const parts = pinyin(text.normalize('NFKC').replace(/u:/gi, 'v'), { toneType: 'none', type: 'array', nonZh: 'consecutive' }) as string[];
  const result: string[] = [];
  for (const part of parts) {
    for (const word of part.split(/[\s\-_'’·.,，。:：!?！？、()（）\[\]【】]+/)) {
      const normalized = normalizeSearchText(word);
      if (normalized.length > 0) { result.push(normalized); }
    }
  }
  return result;
}

export function toPinyinFull(text: string): string {
  return titleParts(text).join('');
}

export function toPinyinInitials(text: string): string {
  // `initial` means 声母 (zh/ch/sh), whereas `first` means one initial per Han character.
  const parts = pinyin(text.normalize('NFKC').replace(/u:/gi, 'v'), { pattern: 'first', type: 'array', toneType: 'none' }) as string[];
  return normalizeSearchText(parts.join(''));
}

/** Suffixes start only at syllable/Latin-word boundaries, never inside a syllable.
 * Bound auxiliary storage to 64 starts × 256 characters for pathological metadata.
 */
export function toPinyinSegments(text: string): string {
  const parts = titleParts(text);
  const suffixes: string[] = [];
  for (let i = 1; i < Math.min(parts.length, 65); i++) {
    suffixes.push(parts.slice(i).join('').slice(0, 256));
  }
  return '|' + suffixes.join('|') + '|';
}
