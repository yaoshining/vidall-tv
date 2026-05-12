import { pinyin } from 'pinyin-pro';

/**
 * 汉字转全拼（无声调，小写，连续字符串）
 * 非汉字字符原样保留（ASCII 字母/数字）。
 * 示例："斗罗大陆" → "douluodalu"
 */
export function toPinyinFull(text: string): string {
  if (text.length === 0) {
    return '';
  }
  // pattern: 'pinyin' 不带声调；type: 'array' 返回逐字数组
  const parts: string[] = pinyin(text, { toneType: 'none', type: 'array' }) as string[];
  return parts.join('').toLowerCase();
}

/**
 * 汉字转首字母（小写）
 * 示例："斗罗大陆" → "dldl"
 */
export function toPinyinInitials(text: string): string {
  if (text.length === 0) {
    return '';
  }
  const parts: string[] = pinyin(text, { pattern: 'initial', type: 'array', toneType: 'none' }) as string[];
  return parts.join('').toLowerCase();
}
