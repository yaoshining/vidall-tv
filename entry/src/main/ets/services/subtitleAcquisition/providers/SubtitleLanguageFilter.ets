// filepath: entry/src/main/ets/services/subtitleAcquisition/providers/SubtitleLanguageFilter.ets
//
// SubHub 结果的语言过滤（App 侧兜底）。
//
// 背景：SubHub 的 xunlei provider 返回的 `language` 字段不规范（空串 / "默认" /
// "CHSEN_权游" 等），而 releaseName 里通常带有语言信号（中文字符、_zh_、简体、中文、
// _en_、CHS 等）。因此 App 侧对 SubHub 不传 `language`，改为在本地按 releaseName 优先、
// language 字段兜底的方式过滤。
//
// SubHub 侧会在 adapter 层做权威归一化（见 issue #202），本文件是 App 侧的双保险。

/** 中文语言码正则（zh / zho / chi / chs / cht / chn / cn）。 */
const CHINESE_LANG_RE = /(zh|zho|chi|chs|cht|chn|cn)/i;

/** 判断语言偏好列表是否「中文向」（如 "zh-CN,zh-TW"）。 */
export function isChineseLanguagePreference(languagesParam: string): boolean {
  const parts = languagesParam.split(',');
  for (let i = 0; i < parts.length; i++) {
    const t = parts[i].trim().toLowerCase();
    if (CHINESE_LANG_RE.test(t) || t.includes('中文') || t.includes('简') || t.includes('繁')) {
      return true;
    }
  }
  return false;
}

/**
 * 判断一条字幕是否为中文。
 * 优先级：releaseName 显式英文标记（排除）→ releaseName 显式中文标记 → releaseName
 * 含汉字 → language 字段兜底。
 */
export function isChineseSubtitle(fileName: string, languageCode: string): boolean {
  const rel = (fileName ?? '').toLowerCase();

  // 1) releaseName 显式英文标记（en/eng/english，词边界）→ 非中文；中英双语除外
  if (/(^|[_ .\-])(en|eng|english)([_ .\-]|$)/.test(rel)) {
    if (!/(中英|双语|chsen|en.?chs|chs.?en)/.test(rel)) {
      return false;
    }
  }

  // 2) releaseName 显式中文标记
  if (/(_zh|_zho|_chi|_chs|_cht|简体|繁体|简中|繁中|中文|中英|双语|chinese)/.test(rel)) {
    return true;
  }

  // 3) releaseName 含汉字（CJK 统一表意文字，天然排除韩文谚文/日文假名）
  if (/[\u4e00-\u9fff\u3400-\u4dbf]/.test(fileName)) {
    return true;
  }

  // 4) language 字段兜底
  const lang = (languageCode ?? '').toLowerCase();
  if (lang.length === 0) {
    return false;
  }
  return CHINESE_LANG_RE.test(lang) || lang.includes('中文') || lang.includes('简') || lang.includes('繁');
}
