// filepath: entry/src/main/ets/services/subtitleAcquisition/providers/SubtitleLanguageFilter.ets
//
// SubHub 结果的语言过滤（App 侧兜底）。
//
// 背景：SubHub 的 xunlei provider 返回的 `language` 字段不规范（空串 / "默认" /
// "CHSEN_权游" 等），而 releaseName 里通常带有语言信号。因此 App 侧对 SubHub 不传
// `language`，改为本地过滤。
//
// 判定优先级：language 字段（可靠时）优先于 releaseName 启发式；只有 language 字段
// 为空/不可信（迅雷）时才用 releaseName 判定。这样能避免「releaseName 带 .en 的
// 中文/双语字幕（language=zh-CN,en）被误判成英文」。
//
// SubHub 侧会在 adapter 层做权威归一化（见 issue #202），本文件是 App 侧的双保险。

/** 中文语言码正则（zh / zho / chi / chs / cht / chn / cn）。 */
const CHINESE_LANG_RE = /(zh|zho|chi|chs|cht|chn|cn)/i;

/** 英文语言码正则（en / eng / english）。 */
const ENGLISH_LANG_RE = /(en|eng|english)/i;

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

/** language 字段是否为中文族（含双语 zh-CN,en / CHSEN）。 */
function isChineseLangTag(lang: string): boolean {
  return CHINESE_LANG_RE.test(lang) || lang.includes('中文') || lang.includes('简') || lang.includes('繁');
}

/** language 字段是否为英文族。 */
function isEnglishLangTag(lang: string): boolean {
  return ENGLISH_LANG_RE.test(lang);
}

/** 仅靠 releaseName 启发式判定是否为中文（用于 language 字段不可信的场景）。 */
function isChineseByReleaseName(fileName: string): boolean {
  const rel = (fileName ?? '').toLowerCase();

  // 1) 显式英文标记（en/eng/english，词边界）→ 非中文；中英双语除外
  if (/(^|[_ .\-])(en|eng|english)([_ .\-]|$)/.test(rel)) {
    if (!/(中英|双语|chsen|en.?chs|chs.?en)/.test(rel)) {
      return false;
    }
  }

  // 2) 显式中文标记
  if (/(_zh|_zho|_chi|_chs|_cht|简体|繁体|简中|繁中|中文|中英|双语|chinese)/.test(rel)) {
    return true;
  }

  // 3) releaseName 含汉字（CJK 统一表意文字，天然排除韩文谚文/日文假名）
  return /[\u4e00-\u9fff\u3400-\u4dbf]/.test(fileName);
}

/**
 * 判断一条字幕是否为中文。
 * language 字段优先（可靠），仅当其不可信（空/迅雷脏值）时才用 releaseName 启发式。
 */
export function isChineseSubtitle(fileName: string, languageCode: string): boolean {
  const lang = (languageCode ?? '').toLowerCase();

  // 1) language 字段是中文族（含双语 zh-CN,en / CHSEN）→ 保留
  if (isChineseLangTag(lang)) {
    return true;
  }
  // 2) language 字段是英文族 → 排除
  if (isEnglishLangTag(lang)) {
    return false;
  }
  // 3) language 字段为空/不可信 → releaseName 启发式
  return isChineseByReleaseName(fileName);
}
