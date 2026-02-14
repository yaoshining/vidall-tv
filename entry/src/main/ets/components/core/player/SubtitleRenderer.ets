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
   * 自动检测字幕格式并解析
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
