/**
 * 字幕渲染器
 * 支持多种字幕格式的解析和渲染
 */

/**
 * 字幕格式类型
 */
export enum SubtitleFormat {
  PLAIN_TEXT = 'plain',      // 纯文本
  ASS = 'ass',               // ASS/SSA 格式
  SRT = 'srt',               // SRT 格式
  VTT = 'vtt'                // WebVTT 格式
}

/** SRT 字幕条目（时间轴驱动用） */
export interface SrtEntry {
  startMs: number;
  endMs: number;
  text: string;
}

/**
 * 解析后的字幕片段
 */
export class SubtitleSegment {
  text: string = '';              // 文本内容
  fontSize?: number;              // 字体大小
  fontColor?: string;             // 字体颜色
  bold?: boolean;                 // 是否粗体
  italic?: boolean;               // 是否斜体
  underline?: boolean;            // 是否下划线

  constructor(text: string) {
    this.text = text;
  }

  // 复制构造函数
  static copy(source: SubtitleSegment): SubtitleSegment {
    const segment = new SubtitleSegment('');
    segment.text = source.text;
    segment.fontSize = source.fontSize;
    segment.fontColor = source.fontColor;
    segment.bold = source.bold;
    segment.italic = source.italic;
    segment.underline = source.underline;
    return segment;
  }
}

/**
 * 解析后的字幕行
 */
export class ParsedSubtitle {
  lines: SubtitleSegment[][] = [];
  format: SubtitleFormat = SubtitleFormat.PLAIN_TEXT;

  constructor(lines: SubtitleSegment[][], format: SubtitleFormat) {
    this.lines = lines;
    this.format = format;
  }
}

/**
 * ASS/SSA 格式解析器
 */
export class AssSubtitleParser {
  /**
   * 解析 ASS 格式字幕
   */
  static parse(text: string): ParsedSubtitle {
    // 按 \N 换行符分割
    const rawLines = AssSubtitleParser.splitByNewline(text);
    const lines: SubtitleSegment[][] = [];

    for (let i = 0; i < rawLines.length; i++) {
      const segments = AssSubtitleParser.parseLine(rawLines[i]);
      if (segments.length > 0) {
        lines.push(segments);
      }
    }

    return new ParsedSubtitle(lines, SubtitleFormat.ASS);
  }

  /**
   * 分割换行符
   */
  private static splitByNewline(text: string): string[] {
    const result: string[] = [];
    let current = '';

    for (let i = 0; i < text.length; i++) {
      if (text[i] === '\\' && i + 1 < text.length && text[i + 1] === 'N') {
        result.push(current);
        current = '';
        i++; // 跳过 'N'
      } else if (text[i] === '\\' && i + 1 < text.length && text[i + 1] === 'n') {
        result.push(current);
        current = '';
        i++; // 跳过 'n'
      } else {
        current += text[i];
      }
    }

    if (current.length > 0) {
      result.push(current);
    }

    return result;
  }

  /**
   * 解析单行字幕
   */
  private static parseLine(line: string): SubtitleSegment[] {
    const segments: SubtitleSegment[] = [];
    let currentSegment = new SubtitleSegment('');
    let i = 0;

    while (i < line.length) {
      // 检查是否是样式标签开始 {
      if (line[i] === '{') {
        // 保存当前片段
        if (currentSegment.text.length > 0) {
          segments.push(currentSegment);
          // 创建新片段，继承样式
          const newSegment = new SubtitleSegment('');
          newSegment.fontSize = currentSegment.fontSize;
          newSegment.fontColor = currentSegment.fontColor;
          newSegment.bold = currentSegment.bold;
          newSegment.italic = currentSegment.italic;
          newSegment.underline = currentSegment.underline;
          currentSegment = newSegment;
        }

        // 查找标签结束位置
        const endIndex = line.indexOf('}', i);
        if (endIndex !== -1) {
          const tag = line.substring(i + 1, endIndex);
          AssSubtitleParser.applyTag(tag, currentSegment);
          i = endIndex + 1;
          continue;
        }
      }

      // 普通文本
      currentSegment.text += line[i];
      i++;
    }

    // 保存最后一个片段
    if (currentSegment.text.length > 0) {
      segments.push(currentSegment);
    }

    return segments;
  }

  /**
   * 应用样式标签到片段
   */
  private static applyTag(tag: string, segment: SubtitleSegment): void {
    // 字体大小: \fs<size> 或 fs<size>
    if (AssSubtitleParser.startsWith(tag, '\\fs') || AssSubtitleParser.startsWith(tag, 'fs')) {
      const sizeStr = AssSubtitleParser.extractNumber(tag);
      if (sizeStr.length > 0) {
        segment.fontSize = parseFloat(sizeStr);
        return;
      }
    }

    // 粗体: \b1 或 b1
    if (tag === '\\b1' || tag === 'b1') {
      segment.bold = true;
      return;
    }

    // 斜体: \i1 或 i1
    if (tag === '\\i1' || tag === 'i1') {
      segment.italic = true;
      return;
    }

    // 下划线: \u1 或 u1
    if (tag === '\\u1' || tag === 'u1') {
      segment.underline = true;
      return;
    }
  }

  /**
   * 提取数字
   */
  private static extractNumber(str: string): string {
    let result = '';
    let foundDigit = false;

    for (let i = 0; i < str.length; i++) {
      const char = str[i];
      if ((char >= '0' && char <= '9') || char === '.') {
        result += char;
        foundDigit = true;
      } else if (foundDigit) {
        break;
      }
    }

    return result;
  }

  /**
   * 检查字符串是否以指定前缀开始
   */
  private static startsWith(str: string, prefix: string): boolean {
    if (str.length < prefix.length) {
      return false;
    }

    for (let i = 0; i < prefix.length; i++) {
      if (str[i] !== prefix[i]) {
        return false;
      }
    }

    return true;
  }
}

/**
 * 纯文本格式解析器
 */
export class PlainTextParser {
  static parse(text: string): ParsedSubtitle {
    const rawLines = PlainTextParser.splitLines(text);
    const lines: SubtitleSegment[][] = [];

    for (let i = 0; i < rawLines.length; i++) {
      const line = rawLines[i];
      if (line.length > 0) {
        const segment = new SubtitleSegment(line);
        lines.push([segment]);
      }
    }

    return new ParsedSubtitle(lines, SubtitleFormat.PLAIN_TEXT);
  }

  /**
   * 分割文本行
   */
  private static splitLines(text: string): string[] {
    const result: string[] = [];
    let current = '';

    for (let i = 0; i < text.length; i++) {
      if (text[i] === '\n') {
        result.push(current);
        current = '';
      } else if (text[i] === '\r') {
        if (i + 1 < text.length && text[i + 1] === '\n') {
          result.push(current);
          current = '';
          i++; // 跳过 \n
        } else {
          result.push(current);
          current = '';
        }
      } else {
        current += text[i];
      }
    }

    if (current.length > 0) {
      result.push(current);
    }

    return result;
  }
}

/**
 * 字幕解析器工厂
 */
export class SubtitleParserFactory {
  /**
   * 自动检测字幕格式并解析（用于 ASS 内嵌字幕文本片段的渲染）
   */
  static parse(text: string): ParsedSubtitle {
    if (!text || text.trim().length === 0) {
      return new ParsedSubtitle([], SubtitleFormat.PLAIN_TEXT);
    }

    // 检测是否包含 ASS 标签
    if (SubtitleParserFactory.isAssFormat(text)) {
      return AssSubtitleParser.parse(text);
    }

    // 默认作为纯文本处理
    return PlainTextParser.parse(text);
  }

  /**
   * 检测是否是 ASS 格式
   */
  private static isAssFormat(text: string): boolean {
    // 检查是否包含 \N 换行符
    if (text.indexOf('\\N') !== -1) {
      return true;
    }

    // 检查是否包含 ASS 样式标签 {\ ... }
    for (let i = 0; i < text.length - 2; i++) {
      if (text[i] === '{' && text[i + 1] === '\\') {
        return true;
      }
      if (text[i] === '{' && text[i + 1] === 'f' && text[i + 2] === 's') {
        return true;
      }
    }

    return false;
  }
}

// ─────────────────────────────────────────────
// 共用工具函数（模块级，供 SrtParser / AssFileParser 共用）
// ─────────────────────────────────────────────

/** 统一换行符：\r\n → \n，单独 \r → \n（不用正则） */
function normalizeNewlines(text: string): string {
  let result = '';
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '\r') {
      result += '\n';
      if (i + 1 < text.length && text[i + 1] === '\n') {
        i++;
      }
    } else {
      result += text[i];
    }
  }
  return result;
}

/**
 * 按空行分割文本块（不用正则）
 * 连续空行或只含空白的行视为分隔符
 */
function splitByBlankLine(text: string): string[] {
  const blocks: string[] = [];
  const lines = text.split('\n');
  let current = '';
  for (const line of lines) {
    if (line.trim().length === 0) {
      if (current.length > 0) {
        blocks.push(current);
        current = '';
      }
    } else {
      if (current.length > 0) {
        current += '\n';
      }
      current += line;
    }
  }
  if (current.length > 0) {
    blocks.push(current);
  }
  return blocks;
}

// ─────────────────────────────────────────────
// SRT 解析器（外部字幕文件，时间轴驱动）
// ─────────────────────────────────────────────

/**
 * SRT / subrip 格式解析器
 *
 * SRT 格式示例：
 * ```
 * 1
 * 00:00:01,000 --> 00:00:03,500
 * Hello, world!
 *
 * 2
 * 00:00:04,000 --> 00:00:06,000
 * Second subtitle line
 * ```
 *
 * 用法：
 * const entries = SrtParser.parse(srtText);
 * const current = SrtParser.findAt(entries, currentTimeMs);
 */
export class SrtParser {

  static parse(content: string): SrtEntry[] {
    const entries: SrtEntry[] = [];
    const normalized = normalizeNewlines(content);
    const blocks = splitByBlankLine(normalized);

    for (const block of blocks) {
      const trimmed = block.trim();
      if (trimmed.length === 0) {
        continue;
      }
      const entry = SrtParser.parseBlock(trimmed);
      if (entry !== null) {
        entries.push(entry);
      }
    }

    entries.sort((a: SrtEntry, b: SrtEntry) => a.startMs - b.startMs);
    return entries;
  }

  /**
   * 根据当前播放时间（ms）查找对应字幕，没有则返回空字符串
   */
  static findAt(entries: SrtEntry[], currentMs: number): string {
    for (const entry of entries) {
      if (currentMs >= entry.startMs && currentMs <= entry.endMs) {
        return entry.text;
      }
    }
    return '';
  }

  /**
   * 解析单个 SRT 块
   */
  private static parseBlock(block: string): SrtEntry | null {
    const lines = block.split('\n');
    if (lines.length < 2) {
      return null;
    }

    // 第一行是序号（跳过）
    // 找时间轴行（包含 -->）
    let timeLine = '';
    let textStartIndex = 0;

    for (let i = 0; i < lines.length; i++) {
      if (lines[i].indexOf('-->') !== -1) {
        timeLine = lines[i];
        textStartIndex = i + 1;
        break;
      }
    }

    if (timeLine.length === 0) {
      return null;
    }

    const times = SrtParser.parseTimeLine(timeLine);
    if (times === null) {
      return null;
    }

    // 剩余行是字幕文本，去除 HTML 标签（如 <i>、<b>）
    const textLines: string[] = [];
    for (let i = textStartIndex; i < lines.length; i++) {
      const cleaned = SrtParser.stripHtml(lines[i].trim());
      if (cleaned.length > 0) {
        textLines.push(cleaned);
      }
    }

    if (textLines.length === 0) {
      return null;
    }

    const entry: SrtEntry = {
      startMs: times[0],
      endMs: times[1],
      text: textLines.join('\n')
    };
    return entry;
  }

  /**
   * 解析时间轴行 "00:00:01,000 --> 00:00:03,500"
   * 返回 [startMs, endMs]，失败返回 null
   */
  private static parseTimeLine(line: string): number[] | null {
    const arrowIdx = line.indexOf('-->');
    if (arrowIdx < 0) {
      return null;
    }
    const startStr = line.substring(0, arrowIdx).trim();
    const endStr = line.substring(arrowIdx + 3).trim();

    const startMs = SrtParser.parseTimestamp(startStr);
    const endMs = SrtParser.parseTimestamp(endStr);

    if (startMs < 0 || endMs < 0) {
      return null;
    }
    const result: number[] = [startMs, endMs];
    return result;
  }

  private static parseTimestamp(ts: string): number {
    let normalized = '';
    for (let i = 0; i < ts.length; i++) {
      normalized += ts[i] === ',' ? '.' : ts[i];
    }
    const parts = normalized.split(':');
    if (parts.length !== 3) {
      return -1;
    }
    const p0 = parts[0];
    const p1 = parts[1];
    const p2 = parts[2];
    if (p0 === undefined || p1 === undefined || p2 === undefined) {
      return -1;
    }
    const h = parseInt(p0);
    const m = parseInt(p1);
    const secParts = p2.split('.');
    const sp0 = secParts[0];
    if (sp0 === undefined) {
      return -1;
    }
    const s = parseInt(sp0);
    const sp1 = secParts[1];
    let msStr = sp1 !== undefined ? sp1.substring(0, 3) : '0';
    while (msStr.length < 3) {
      msStr += '0';
    }
    const ms = parseInt(msStr);
    if (isNaN(h) || isNaN(m) || isNaN(s) || isNaN(ms)) {
      return -1;
    }
    return ((h * 3600 + m * 60 + s) * 1000) + ms;
  }

  private static stripHtml(text: string): string {
    let result = '';
    let inTag = false;
    for (let i = 0; i < text.length; i++) {
      if (text[i] === '<') {
        inTag = true;
      } else if (text[i] === '>') {
        inTag = false;
      } else if (!inTag) {
        result += text[i];
      }
    }
    return result;
  }
}

// ─────────────────────────────────────────────
// ASS/SSA 文件解析器（时间轴驱动，外部字幕文件用）
// ─────────────────────────────────────────────

/**
 * 解析完整 ASS/SSA 字幕文件，返回 SrtEntry[] 时间轴条目
 *
 * ASS Dialogue 行格式（[Events] 节）：
 *   Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
 *   字段索引：  0      1     2    3      4     5        6       7      8      9
 *
 * 时间格式：H:MM:SS.cs（H=小时，cs=百分之一秒）
 *   例：0:01:23.45 → 83450 ms
 *
 * 用法：
 *   const entries = AssFileParser.parse(assFileContent);
 *   const text = SrtParser.findAt(entries, currentMs);
 */
export class AssFileParser {

  static parse(content: string): SrtEntry[] {
    // 去除 UTF-8 BOM（0xEF 0xBB 0xBF，字符串中表现为 '\uFEFF'）
    let raw = content;
    if (raw.length > 0 && raw.charCodeAt(0) === 0xFEFF) {
      raw = raw.substring(1);
    }

    const entries: SrtEntry[] = [];
    const normalized = normalizeNewlines(raw);
    const lines = normalized.split('\n');

    let inEvents = false;
    let startIdx = 1;
    let endIdx = 2;
    let textIdx = 9;

    // 用 Map 合并同时段多条 Dialogue（key = "startMs_endMs"）
    const mergeMap: Map<string, SrtEntry> = new Map();

    for (const rawLine of lines) {
      const line = rawLine.trim();
      if (line.length === 0) {
        continue;
      }

      // 检测节标题
      if (line.charAt(0) === '[') {
        const lower = line.toLowerCase();
        inEvents = lower === '[events]';
        continue;
      }

      if (!inEvents) {
        continue;
      }

      // Format 行
      if (line.startsWith('Format:')) {
        const formatStr = line.substring('Format:'.length).trim();
        const rawFields = formatStr.split(',');
        const fields: string[] = [];
        for (const f of rawFields) {
          fields.push(f.trim().toLowerCase());
        }
        const si = fields.indexOf('start');
        const ei = fields.indexOf('end');
        const ti = fields.indexOf('text');
        startIdx = si >= 0 ? si : 1;
        endIdx   = ei >= 0 ? ei : 2;
        textIdx  = ti >= 0 ? ti : 9;
        continue;
      }

      // Comment 行跳过
      if (line.startsWith('Comment:')) {
        continue;
      }

      // Dialogue 行
      if (!line.startsWith('Dialogue:')) {
        continue;
      }

      const entry = AssFileParser.parseDialogue(line, startIdx, endIdx, textIdx);
      if (entry === null) {
        continue;
      }

      // 合并同时段多条 Dialogue（libass 行为：叠加显示）
      const key = `${entry.startMs}_${entry.endMs}`;
      const existing = mergeMap.get(key);
      if (existing !== undefined) {
        // 同时段追加，用换行分隔
        if (entry.text.trim().length > 0) {
          existing.text = existing.text + '\n' + entry.text;
        }
      } else {
        mergeMap.set(key, entry);
      }
    }

    // 收集并排序
    mergeMap.forEach((entry: SrtEntry) => {
      entries.push(entry);
    });
    entries.sort((a: SrtEntry, b: SrtEntry) => a.startMs - b.startMs);
    return entries;
  }

  private static parseDialogue(
    line: string,
    startIdx: number,
    endIdx: number,
    textIdx: number
  ): SrtEntry | null {
    const content = line.substring('Dialogue:'.length).trim();
    const maxSplit = textIdx + 1;
    const parts = AssFileParser.splitN(content, ',', maxSplit);

    if (parts.length < textIdx + 1) {
      return null;
    }

    const startPart = parts[startIdx];
    const endPart   = parts[endIdx];
    const textPart  = parts[textIdx];
    if (startPart === undefined || endPart === undefined || textPart === undefined) {
      return null;
    }

    const startMs = AssFileParser.parseAssTime(startPart.trim());
    const endMs   = AssFileParser.parseAssTime(endPart.trim());
    if (startMs < 0 || endMs < 0) {
      return null;
    }

    const cleanText = AssFileParser.stripAssTags(textPart);
    if (cleanText.trim().length === 0) {
      return null;
    }

    const entry: SrtEntry = { startMs, endMs, text: cleanText };
    return entry;
  }

  private static parseAssTime(ts: string): number {
    const colonParts = ts.split(':');
    if (colonParts.length !== 3) {
      return -1;
    }
    const p0 = colonParts[0];
    const p1 = colonParts[1];
    const p2 = colonParts[2];
    if (p0 === undefined || p1 === undefined || p2 === undefined) {
      return -1;
    }
    const h = parseInt(p0);
    const m = parseInt(p1);
    const secParts = p2.split('.');
    const sp0 = secParts[0];
    if (sp0 === undefined) {
      return -1;
    }
    const s = parseInt(sp0);
    const sp1 = secParts[1];
    let csStr = sp1 !== undefined ? sp1.substring(0, 2) : '0';
    while (csStr.length < 2) {
      csStr += '0';
    }
    const cs = parseInt(csStr);
    if (isNaN(h) || isNaN(m) || isNaN(s) || isNaN(cs)) {
      return -1;
    }
    return (h * 3600 + m * 60 + s) * 1000 + cs * 10;
  }

  /**
   * 剥除 ASS 样式标签，参照 libass 规范：
   *
   * 1. {tags} 块整体跳过（包括 \t(...) 等复杂标签）
   * 2. 未闭合的 { 直接跳过（libass 行为：忽略到行尾）
   * 3. \N / \n → 换行
   * 4. \h → 不间断空格（U+00A0）
   * 5. \{ → 字面 {（转义）
   * 6. \} → 字面 }（转义）
   * 7. \q0~\q3 → 忽略
   * 8. 连续换行去重（libass 不会叠加空行）
   */
  static stripAssTags(text: string): string {
    let result = '';
    let i = 0;
    while (i < text.length) {
      const ch = text[i];

      // 转义序列
      if (ch === '\\' && i + 1 < text.length) {
        const next = text[i + 1];
        if (next === 'N' || next === 'n') {
          result += '\n';
          i += 2;
          continue;
        }
        if (next === 'h') {
          result += '\u00A0'; // 不间断空格
          i += 2;
          continue;
        }
        // \{ 和 \} 转义
        if (next === '{' || next === '}') {
          result += next;
          i += 2;
          continue;
        }
        // \q 换行模式（\q0~\q3）—— 忽略整个 \qN
        if (next === 'q' && i + 2 < text.length) {
          const qn = text[i + 2];
          if (qn >= '0' && qn <= '3') {
            i += 3;
            continue;
          }
        }
        // 其他 \ 序列原样输出（比如 \K、\k 等 karaoke 标签在大括号外罕见，保留）
        result += ch;
        i++;
        continue;
      }

      // {tags} 块：跳过到 }
      if (ch === '{') {
        const end = text.indexOf('}', i + 1);
        if (end >= 0) {
          i = end + 1; // 跳过整个 {tags}
        } else {
          // 未闭合 {：libass 行为是忽略到行尾
          i = text.length;
        }
        continue;
      }

      result += ch;
      i++;
    }

    return result.trim();
  }

  private static splitN(str: string, sep: string, n: number): string[] {
    const result: string[] = [];
    let remaining = str;
    for (let i = 0; i < n - 1; i++) {
      const idx = remaining.indexOf(sep);
      if (idx < 0) {
        break;
      }
      result.push(remaining.substring(0, idx));
      remaining = remaining.substring(idx + sep.length);
    }
    result.push(remaining);
    return result;
  }
}














