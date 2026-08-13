import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import buffer from '@ohos.buffer';
import { CommonConstants } from '../../../common/constants/CommonConstants';
import { FfprobeUtil, type FfprobeTrack } from '../../../utils/FfprobeUtil';
import { VideoData } from './VideoData';
import { VideoDataType } from './Constants';
import { IPlayer, SubtitleInfo, TrackInfo } from './IPlayer';
import { AssFileParser, SrtEntry, SrtParser } from './SubtitleRenderer';
import {
  findPreferredSubtitleTrackIndex,
  loadSubtitleLanguagePreference,
  SubtitleTrackLanguageCandidate
} from '../../../subtitle/SubtitleLanguagePreference';

const TAG = '[SubtitleBridgeAdapter]';
const MAX_SUBTITLE_PROBE_CANDIDATES = 12;
const SUBTITLE_PROBE_BATCH_SIZE = 4;

/**
 * 纯 JS UTF-8 解码兜底实现。
 * 在 @ohos.buffer 和 util.TextDecoder 都返回空字符串的环境（如部分 CI mock）下保底。
 */
function decodeUtf8Fallback(bytes: Uint8Array): string {
  let result = '';
  let i = 0;
  while (i < bytes.length) {
    const b0 = bytes[i];
    if (b0 < 0x80) {
      result += String.fromCharCode(b0);
      i += 1;
    } else if ((b0 & 0xE0) === 0xC0 && i + 1 < bytes.length) {
      const cp = ((b0 & 0x1F) << 6) | (bytes[i + 1] & 0x3F);
      result += String.fromCodePoint(cp);
      i += 2;
    } else if ((b0 & 0xF0) === 0xE0 && i + 2 < bytes.length) {
      const cp = ((b0 & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F);
      result += String.fromCodePoint(cp);
      i += 3;
    } else if ((b0 & 0xF8) === 0xF0 && i + 3 < bytes.length) {
      const cp = ((b0 & 0x07) << 18) | ((bytes[i + 1] & 0x3F) << 12) |
        ((bytes[i + 2] & 0x3F) << 6) | (bytes[i + 3] & 0x3F);
      result += String.fromCodePoint(cp);
      i += 4;
    } else {
      result += String.fromCharCode(0xFFFD);
      i += 1;
    }
  }
  return result;
}

function tryDecode(bytes: Uint8Array, encoding: string): string {
  if (encoding === 'utf-8' || encoding === 'utf8') {
    // 三层降级：@ohos.buffer → util.TextDecoder → 纯 JS 兜底
    try {
      const buf = buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
      const result = buf.toString('utf-8');
      if (result.length > 0) {
        return result;
      }
    } catch (e) {
      // fall through
    }
    try {
      const decoder = new util.TextDecoder('utf-8');
      const ab: ArrayBuffer = toExactArrayBuffer(bytes);
      const result = decoder.decodeToString(ab as ESObject as Uint8Array);
      if (result.length > 0) {
        return result;
      }
    } catch (e) {
      // fall through
    }
    return decodeUtf8Fallback(bytes);
  }
  const decoder = new util.TextDecoder(encoding);
  const ab: ArrayBuffer = toExactArrayBuffer(bytes);
  return decoder.decodeToString(ab as ESObject as Uint8Array);
}

function buildByteArrayFromString(text: string): Uint8Array | null {
  if (text.length === 0) {
    return new Uint8Array(0);
  }

  const bytes = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code > 0xFF) {
      return null;
    }
    bytes[i] = code;
  }
  return bytes;
}

function toExactArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const offset = bytes.byteOffset;
  const length = bytes.byteLength;
  if (offset === 0 && length === bytes.buffer.byteLength) {
    return bytes.buffer as ArrayBuffer;
  }
  return bytes.buffer.slice(offset, offset + length) as ArrayBuffer;
}

function sanitizeUrlForLog(url: string): string {
  const queryIndex = url.indexOf('?');
  const noQueryUrl = queryIndex >= 0 ? url.substring(0, queryIndex) : url;
  const schemeIndex = noQueryUrl.indexOf('://');
  if (schemeIndex < 0) {
    return queryIndex >= 0 ? `${noQueryUrl}?***` : noQueryUrl;
  }

  const pathIndex = noQueryUrl.indexOf('/', schemeIndex + 3);
  if (pathIndex < 0) {
    return queryIndex >= 0 ? `${noQueryUrl}?***` : noQueryUrl;
  }

  const origin = noQueryUrl.substring(0, pathIndex);
  const lastSlash = noQueryUrl.lastIndexOf('/');
  if (lastSlash < pathIndex) {
    return queryIndex >= 0 ? `${origin}/...?***` : `${origin}/...`;
  }

  const tail = noQueryUrl.substring(lastSlash + 1);
  if (tail.length === 0) {
    return queryIndex >= 0 ? `${origin}/.../?***` : `${origin}/.../`;
  }
  return queryIndex >= 0 ? `${origin}/.../${tail}?***` : `${origin}/.../${tail}`;
}

function createHttpBusinessError(statusCode: number, url: string): BusinessError {
  const httpError = new Error(`HTTP ${statusCode} for subtitle request: ${sanitizeUrlForLog(url)}`) as BusinessError;
  httpError.code = statusCode;
  return httpError;
}

function scoreChineseReadability(text: string): number {
  if (text.length === 0) {
    return -999999;
  }

  let score = 0;
  const sampleLen = Math.min(text.length, 4000);

  // 常见中文停用字，命中越多通常越接近正确解码结果
  const commonChars: string[] = [
    '的', '了', '是', '我', '你', '他', '她', '不', '在', '有', '这', '這', '个', '個',
    '人', '们', '們', '和', '就', '要', '到', '也', '都', '吗', '嗎', '呢', '啊', '吧',
    '一', '二', '三', '四', '五', '季', '集', '王', '权', '權', '力', '游', '遊', '戏', '戲'
  ];

  for (let i = 0; i < commonChars.length; i++) {
    const ch = commonChars[i];
    let idx = text.indexOf(ch);
    while (idx >= 0 && idx < sampleLen) {
      score += 5;
      idx = text.indexOf(ch, idx + 1);
    }
  }

  for (let i = 0; i < sampleLen; i++) {
    const code = text.charCodeAt(i);
    // 中日韩统一表意文字
    if (code >= 0x4E00 && code <= 0x9FFF) {
      score += 1;
      continue;
    }
    // 常见字幕标点
    if (code === 0x3002 || code === 0xFF0C || code === 0x3001 || code === 0xFF1F ||
      code === 0xFF01 || code === 0xFF1A || code === 0x2014 || code === 0x2026) {
      score += 1;
      continue;
    }
    // Unicode replacement char，强烈减分
    if (code === 0xFFFD) {
      score -= 30;
      continue;
    }
    // 控制字符（保留换行与制表）
    if ((code < 0x20 && code !== 0x0A && code !== 0x0D && code !== 0x09) || code === 0x7F) {
      score -= 8;
    }
  }

  return score;
}

function scoreSubtitleTextReadability(text: string): number {
  if (text.length === 0) {
    return -999999;
  }

  let score = scoreChineseReadability(text);
  const sampleLen = Math.min(text.length, 4000);
  const mojibakeMarkers: string[] = ['Ã', 'Â', 'â', 'ð', '¤', '¦'];

  for (let i = 0; i < sampleLen; i++) {
    const code = text.charCodeAt(i);
    if ((code >= 0x20 && code <= 0x7E) || code === 0x0A || code === 0x0D || code === 0x09) {
      score += 1;
      continue;
    }
    if (code >= 0x80 && code <= 0x9F) {
      score -= 10;
      continue;
    }
  }

  for (let i = 0; i < mojibakeMarkers.length; i++) {
    const marker = mojibakeMarkers[i];
    let idx = text.indexOf(marker);
    while (idx >= 0 && idx < sampleLen) {
      score -= 4;
      idx = text.indexOf(marker, idx + 1);
    }
  }

  return score;
}

/**
 * 将字幕文件的原始字节解码为字符串，自动识别 UTF-8 / UTF-16 / GBK / Big5 编码。
 * 判断依据：
 *   1. BOM 优先：UTF-8 / UTF-16LE / UTF-16BE
 *   2. 无 BOM 时：启发式判断 UTF-8 合法性
 *   3. 否则同时尝试 GBK 与 Big5，并以中文可读性评分选择更优结果
 */
function decodeSubtitleBytes(arrayBuffer: ArrayBuffer): string {
  const bytes = new Uint8Array(arrayBuffer);

  if (bytes.length === 0) {
    return '';
  }

  // UTF-8 BOM: EF BB BF
  if (bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) {
    try {
      const buf = buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
      return buf.toString('utf-8').replace(/^\uFEFF/, '');
    } catch (_e) {
      // fall through
    }
  }

  // UTF-16 LE BOM: FF FE
  if (bytes.length >= 2 && bytes[0] === 0xFF && bytes[1] === 0xFE) {
    const decoder = new util.TextDecoder('utf-16le', { ignoreBOM: true });
    const ab: ArrayBuffer = toExactArrayBuffer(bytes);
    return decoder.decodeToString(ab as ESObject as Uint8Array);
  }

  // UTF-16 BE BOM: FE FF
  if (bytes.length >= 2 && bytes[0] === 0xFE && bytes[1] === 0xFF) {
    const decoder = new util.TextDecoder('utf-16be', { ignoreBOM: true });
    const ab: ArrayBuffer = toExactArrayBuffer(bytes);
    return decoder.decodeToString(ab as ESObject as Uint8Array);
  }

  // 启发式检测：扫描前 4KB，判断是否为合法 UTF-8
  const sampleLen = Math.min(bytes.length, 4096);
  let isUtf8 = true;
  let i = 0;
  while (i < sampleLen) {
    const b = bytes[i];
    if (b < 0x80) {
      i++;
      continue;
    }
    let extraBytes = 0;
    if ((b & 0xE0) === 0xC0) { extraBytes = 1; }
    else if ((b & 0xF0) === 0xE0) { extraBytes = 2; }
    else if ((b & 0xF8) === 0xF0) { extraBytes = 3; }
    else {
      isUtf8 = false;
      break;
    }
    for (let j = 1; j <= extraBytes; j++) {
      if (i + j >= sampleLen || (bytes[i + j] & 0xC0) !== 0x80) {
        isUtf8 = false;
        break;
      }
    }
    if (!isUtf8) {
      break;
    }
    i += 1 + extraBytes;
  }

  if (isUtf8) {
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[decodeSubtitleBytes] 检测编码=utf-8 sampleLen=${sampleLen}`);
    return tryDecode(bytes, 'utf-8');
  }

  let gbkText = '';
  let big5Text = '';
  let gbkOk = false;
  let big5Ok = false;

  try {
    gbkText = tryDecode(bytes, 'gbk');
    gbkOk = true;
  } catch (e) {}

  // HarmonyOS TextDecoder 常见实现支持 big5；若不支持则自动跳过
  try {
    big5Text = tryDecode(bytes, 'big5');
    big5Ok = true;
  } catch (e) {}

  if (gbkOk && big5Ok) {
    const gbkScore = scoreChineseReadability(gbkText);
    const big5Score = scoreChineseReadability(big5Text);
    const bestScore = gbkScore > big5Score ? gbkScore : big5Score;
    if (bestScore < 0) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `[decodeSubtitleBytes] gbk/big5 评分均低于 0 (gbk=${gbkScore}, big5=${big5Score})，回退 utf-8`);
      return tryDecode(bytes, 'utf-8');
    }
    const preferBig5 = big5Score > gbkScore;
    const selectedEncoding = preferBig5 ? 'big5' : 'gbk';
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[decodeSubtitleBytes] 候选编码 gbk=${gbkScore} big5=${big5Score} -> ${selectedEncoding}`);
    return preferBig5 ? big5Text : gbkText;
  }

  if (big5Ok) {
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      '[decodeSubtitleBytes] 仅 big5 可用，采用 big5');
    return big5Text;
  }

  if (gbkOk) {
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      '[decodeSubtitleBytes] 仅 gbk 可用，采用 gbk');
    return gbkText;
  }

  // 兜底：尽量避免抛错影响播放流程
  hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
    '[decodeSubtitleBytes] gbk/big5 均不可用，回退 utf-8');
  return tryDecode(bytes, 'utf-8');
}

export function decodeSubtitlePayload(payload: Object | string | ArrayBuffer): string {
  if (typeof payload === 'string') {
    const originalText = payload;
    const rawBytes = buildByteArrayFromString(originalText);
    if (rawBytes === null) {
      return originalText;
    }

    const recoveredText = decodeSubtitleBytes(rawBytes.buffer as ArrayBuffer);
    const originalScore = scoreSubtitleTextReadability(originalText);
    const recoveredScore = scoreSubtitleTextReadability(recoveredText);
    if (recoveredScore > originalScore) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[decodeSubtitlePayload] 字符串恢复成功 originalScore=${originalScore} recoveredScore=${recoveredScore}`);
      return recoveredText;
    }
    return originalText;
  }

  if (payload instanceof ArrayBuffer) {
    return decodeSubtitleBytes(payload);
  }

  if (payload instanceof Uint8Array) {
    const exactBuffer = toExactArrayBuffer(payload);
    return decodeSubtitleBytes(exactBuffer);
  }

  hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
    `[decodeSubtitlePayload] 未识别的响应类型=${typeof payload}`);
  return '';
}

export interface SubtitleTrackItem {
  kind: 'internal' | 'external';
  displayName: string;
  internalIndex?: number;
  srtEntries?: SrtEntry[];
  url?: string;
  language?: string;
}

export interface SubtitleBridgeState {
  subtitleTracks: TrackInfo[];
  allSubtitleTracks: SubtitleTrackItem[];
  activeSubtitleIndex: number;
  currentSubtitleTrack: number;
  currentSubtitleText: string;
  subtitleDelayMs: number;
  hasExternalActive: boolean;
}

export interface ISubtitleBridgeAdapter {
  init(player: IPlayer, videoData?: VideoData): Promise<void>;
  onTimeUpdate(currentTimeMs: number): void;
  onSubtitleUpdate(info: SubtitleInfo): void;
  onEmbeddedTimedText(text: string): void;
  switchTrack(allIndex: number): Promise<void>;
  adjustDelay(deltaMs: number): void;
  onSeekSync(): void;
  getState(): SubtitleBridgeState;
  release(): void;
  /** 将已下载到本地的字幕文件追加到轨道列表（不切换到该轨道）。 */
  addLocalSubtitle(localPath: string): Promise<void>;
}

export class BaseSubtitleBridgeAdapter implements ISubtitleBridgeAdapter {
  protected player?: IPlayer;
  protected videoData?: VideoData;
  protected subtitleTracks: TrackInfo[] = [];
  protected allSubtitleTracks: SubtitleTrackItem[] = [];
  protected activeSubtitleIndex: number = -1;
  protected currentSubtitleTrack: number = -1;
  protected currentSubtitleText: string = '';
  protected subtitleDelayMs: number = 0;
  protected srtEntries: SrtEntry[] = [];
  protected lastSrtText: string = '';

  // 指标字段：seek 后字幕恢复时延测量（#17）
  private _seekStartMs: number = 0;
  // 防止漂移日志过于频繁：每 5s 输出一次
  private _lastDriftLogMs: number = 0;

  async init(player: IPlayer, videoData?: VideoData): Promise<void> {
    this.player = player;
    this.videoData = videoData;
    this.subtitleTracks = [];
    this.allSubtitleTracks = [];
    this.activeSubtitleIndex = -1;
    this.currentSubtitleTrack = -1;
    this.currentSubtitleText = '';
    this.subtitleDelayMs = 0;
    this.srtEntries = [];
    this.lastSrtText = '';

    const internalItems = await this.loadInternalTracks();
    const mergedItems: SubtitleTrackItem[] = [];
    for (let i = 0; i < internalItems.length; i++) {
      mergedItems.push(internalItems[i]);
    }

    const externalItems = await this.loadExternalTracks();
    for (let i = 0; i < externalItems.length; i++) {
      mergedItems.push(externalItems[i]);
    }

    this.allSubtitleTracks = mergedItems;

    if (this.allSubtitleTracks.length > 0) {
      const preferredIndex = await this.findPreferredTrackIndex();
      if (preferredIndex >= 0) {
        // 不 await：auto-select 的轨道切换可能包含长时间异步操作（如 SMB 内嵌字幕 30s 提取）
        // fire-and-forget，初始化立即完成，字幕在提取完成后自动开始渲染
        this.switchTrack(preferredIndex).catch(() => {
          hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
            `[字幕指标] 自动选轨异常，降级无字幕`);
        });
        const selected = this.allSubtitleTracks[preferredIndex];
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[字幕指标] 初始化完成: 内嵌=${internalItems.length} 外置=${externalItems.length}` +
          ` 自动选中[${preferredIndex}]=${selected.displayName}(${selected.kind})`);
      } else {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[字幕指标] 初始化完成: 内嵌=${internalItems.length} 外置=${externalItems.length} 无偏好匹配，保持关闭字幕`);
      }
    } else {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[字幕指标] 初始化完成: 内嵌=0 外置=0 无字幕轨道`);
    }
  }

  protected async findPreferredTrackIndex(): Promise<number> {
    const preference = await loadSubtitleLanguagePreference()
    const trackCandidates: SubtitleTrackLanguageCandidate[] = []
    for (let index = 0; index < this.allSubtitleTracks.length; index++) {
      const item = this.allSubtitleTracks[index]
      const candidate: SubtitleTrackLanguageCandidate = {
        displayName: item.displayName
      }
      if (item.kind === 'internal') {
        const language = this.findInternalTrackLanguage(item.internalIndex)
        if (language !== undefined && language.length > 0) {
          candidate.language = language
        }
      }
      trackCandidates.push(candidate)
    }

    return findPreferredSubtitleTrackIndex(trackCandidates, preference)
  }

  private findInternalTrackLanguage(trackIndex: number | undefined): string | undefined {
    if (trackIndex === undefined) {
      return undefined
    }
    for (let index = 0; index < this.subtitleTracks.length; index++) {
      const track = this.subtitleTracks[index]
      if (track.trackIndex === trackIndex) {
        return track.language
      }
    }
    return undefined
  }

  onTimeUpdate(currentTimeMs: number): void {
    // 时间源异常守卫：NaN / 负值自动降级跳过，避免阻断播放
    if (isNaN(currentTimeMs) || currentTimeMs < 0) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `[字幕指标] 时间源异常 currentTimeMs=${currentTimeMs}，跳过本次字幕更新`);
      return;
    }
    if (this.srtEntries.length === 0) {
      return;
    }
    const adjustedTime = currentTimeMs - this.subtitleDelayMs;
    const text = SrtParser.findAt(this.srtEntries, adjustedTime);
    if (text !== this.lastSrtText) {
      // seek 后恢复时延：首次字幕文本改变时记录
      if (this._seekStartMs > 0) {
        const recoveryMs = Date.now() - this._seekStartMs;
        this._seekStartMs = 0;
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[字幕指标] seek恢复时延=${recoveryMs}ms（目标≤200ms）`);
      }
      this.lastSrtText = text;
      this.currentSubtitleText = text;
    }

    // 漂移监测：每 5s 输出一次，记录调整后时间与系统时间的差值供分析
    if (this.subtitleDelayMs !== 0) {
      const now = Date.now();
      if (now - this._lastDriftLogMs >= 5000) {
        this._lastDriftLogMs = now;
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[字幕指标] 当前延迟偏移=${this.subtitleDelayMs}ms pts=${currentTimeMs}ms adjustedPts=${adjustedTime}ms`);
      }
    }
  }

  onSubtitleUpdate(info: SubtitleInfo): void {
    // 字幕已关闭时（activeSubtitleIndex < 0），忽略 AVPlayer 仍在推送的 onTimedText 回调
    if (this.activeSubtitleIndex < 0) {
      return;
    }
    if (this.srtEntries.length > 0) {
      return;
    }
    this.currentSubtitleText = info.text ?? '';
  }

  onEmbeddedTimedText(_text: string): void { /* 子类按需覆盖 */ }

  async switchTrack(allIndex: number): Promise<void> {
    if (!this.player) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `[字幕] switchTrack(${allIndex}): player 未初始化`);
      return;
    }

    if (allIndex < 0) {
      this.activeSubtitleIndex = -1;
      this.currentSubtitleText = '';
      this.srtEntries = [];
      this.lastSrtText = '';
      this.currentSubtitleTrack = -1;
      await this.player.selectTrack(-1);
      return;
    }

    if (allIndex >= this.allSubtitleTracks.length) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `[字幕] switchTrack(${allIndex}): 超出范围 (total=${this.allSubtitleTracks.length})`);
      return;
    }

    this.activeSubtitleIndex = allIndex;
    this.currentSubtitleText = '';

    const target = this.allSubtitleTracks[allIndex];
    if (target.kind === 'external') {
      const entries = target.srtEntries ?? [];
      this.srtEntries = entries;
      this.lastSrtText = '';
      this.currentSubtitleTrack = -1;
      await this.player.selectTrack(-1);
      return;
    }

    this.srtEntries = [];
    this.lastSrtText = '';
    const internalIndex = target.internalIndex ?? -1;
    this.currentSubtitleTrack = internalIndex;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[字幕] switchTrack: allIndex=${allIndex} internalIndex=${internalIndex} displayName=${target.displayName}`);
    await this.player.selectTrack(internalIndex);
  }

  adjustDelay(deltaMs: number): void {
    this.subtitleDelayMs += deltaMs;
    this.lastSrtText = '';
  }

  onSeekSync(): void {
    // 记录 seek 开始时间，用于计算字幕恢复时延（#17）
    this._seekStartMs = Date.now();
    this.lastSrtText = '';
  }

  getState(): SubtitleBridgeState {
    const state: SubtitleBridgeState = {
      subtitleTracks: this.subtitleTracks,
      allSubtitleTracks: this.allSubtitleTracks,
      activeSubtitleIndex: this.activeSubtitleIndex,
      currentSubtitleTrack: this.currentSubtitleTrack,
      currentSubtitleText: this.currentSubtitleText,
      subtitleDelayMs: this.subtitleDelayMs,
      hasExternalActive: this.srtEntries.length > 0
    };
    return state;
  }

  async addLocalSubtitle(localPath: string): Promise<void> {
    const fileName = localPath.split('/').pop() ?? localPath;
    const lower = fileName.toLowerCase();
    const isAss = lower.endsWith('.ass') || lower.endsWith('.ssa');
    const isVtt = lower.endsWith('.vtt');
    const formatLabel = isAss ? 'ASS' : (isVtt ? 'VTT' : 'SRT');

    let text = ''
    try {
      const stat = fs.statSync(localPath);
      const buf = new ArrayBuffer(stat.size);
      const file = fs.openSync(localPath, fs.OpenMode.READ_ONLY);
      try {
        fs.readSync(file.fd, buf);
      } finally {
        fs.closeSync(file);
      }
      text = decodeSubtitlePayload(buf);
    } catch (e) {
      const error = e as BusinessError;
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `[addLocalSubtitle] 读取或解码本地字幕失败: ${error.message}`);
      throw new Error(`读取或解码本地字幕失败: ${error.message}`);
    }
    const entries = isAss ? AssFileParser.parse(text) : SrtParser.parse(text);

    const baseName: string = ((this.videoData?.videoSrc ?? '').split('/').pop() ?? '').replace(/\.[^.]+$/, '');
    const langLabel = this.extractLangLabel(fileName, baseName);
    const langCode = this.extractLangCode(fileName, baseName);

    const item: SubtitleTrackItem = {
      kind: 'external',
      displayName: langLabel.length > 0
        ? `${langLabel} [本地·${formatLabel}]`
        : `字幕 [本地·${formatLabel}]`,
      url: `file://${localPath}`,
      srtEntries: entries,
      language: langCode
    };

    this.allSubtitleTracks = [...this.allSubtitleTracks, item];
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[addLocalSubtitle] 已追加本地字幕: ${item.displayName} path=${localPath}`);
  }

  release(): void {
    this.subtitleTracks = [];
    this.allSubtitleTracks = [];
    this.activeSubtitleIndex = -1;
    this.currentSubtitleTrack = -1;
    this.currentSubtitleText = '';
    this.subtitleDelayMs = 0;
    this.srtEntries = [];
    this.lastSrtText = '';
    this._seekStartMs = 0;
    this._lastDriftLogMs = 0;
    this.player = undefined;
    this.videoData = undefined;
  }

  protected async loadInternalTracks(): Promise<SubtitleTrackItem[]> {
    return [];
  }

  protected async loadExternalTracks(): Promise<SubtitleTrackItem[]> {
    if (!this.videoData || this.videoData.type !== VideoDataType.URL) {
      return [];
    }

    const videoUrl = this.videoData.videoSrc;
    const lastSlash = videoUrl.lastIndexOf('/');
    const dirUrl = lastSlash >= 0 ? videoUrl.substring(0, lastSlash + 1) : videoUrl + '/';
    const fileName = lastSlash >= 0 ? videoUrl.substring(lastSlash + 1) : videoUrl;
    const cleanFileName = fileName.split('?')[0];
    // 视频URL中的文件名可能已经是URL编码形式（如 %E6%9D%83...）
    // 必须先解码还原为真实文件名，再重新 encodeURIComponent 拼接候选路径
    // 否则 encodeURIComponent 会对 % 再次编码，产生双重编码（%25E6%259D%2583...）
    let decodedFileName = cleanFileName;
    try {
      decodedFileName = decodeURIComponent(cleanFileName);
    } catch (e) {
      decodedFileName = cleanFileName;
    }
    const dotIdx = decodedFileName.lastIndexOf('.');
    const baseName = dotIdx >= 0 ? decodedFileName.substring(0, dotIdx) : decodedFileName;

    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[外置字幕探测] video=${sanitizeUrlForLog(videoUrl)}`);
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[外置字幕探测] dir=${sanitizeUrlForLog(dirUrl)} fileName=${cleanFileName} baseName=${baseName}`);

    const subtitleExts: string[] = ['srt', 'ass', 'ssa', 'vtt'];
    const langTags: string[] = [
      'chi', 'chs', 'cht', 'zho', 'eng',
      'jpn', 'kor', 'fra', 'deu', 'spa', 'rus',
      'zh', 'zh-CN', 'zh-TW', 'en', 'ja', 'ko'
    ];

    const candidates: string[] = [];
    for (let i = 0; i < subtitleExts.length; i++) {
      const ext = subtitleExts[i];
      candidates.push(`${baseName}.${ext}`);
    }
    for (let i = 0; i < langTags.length; i++) {
      const lang = langTags[i];
      for (let j = 0; j < subtitleExts.length; j++) {
        const ext = subtitleExts[j];
        candidates.push(`${baseName}.${lang}.${ext}`);
      }
    }

    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[外置字幕探测] 生成 ${candidates.length} 个候选字幕文件`);
    const limitedCandidates: string[] = candidates.length > MAX_SUBTITLE_PROBE_CANDIDATES
      ? candidates.slice(0, MAX_SUBTITLE_PROBE_CANDIDATES)
      : candidates;
    if (limitedCandidates.length < candidates.length) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[外置字幕探测] 候选过多，按优先级仅探测前 ${limitedCandidates.length} 个`);
    }

    const headers: Record<string, string> = { 'User-Agent': 'VidALL/1.0.0' };
    const sourceHeaders = this.videoData.subtitleHeaders && Object.keys(this.videoData.subtitleHeaders).length > 0
      ? this.videoData.subtitleHeaders
      : this.videoData.httpHeader;
    if (sourceHeaders) {
      const keys = Object.keys(sourceHeaders);
      for (let i = 0; i < keys.length; i++) {
        const k = keys[i];
        headers[k] = sourceHeaders[k];
      }
    }

    const found: SubtitleTrackItem[] = [];
    for (let start = 0; start < limitedCandidates.length; start += SUBTITLE_PROBE_BATCH_SIZE) {
      const end = Math.min(start + SUBTITLE_PROBE_BATCH_SIZE, limitedCandidates.length);
      const batchPromises: Array<Promise<boolean>> = [];
      for (let i = start; i < end; i++) {
        const probeCandidate = limitedCandidates[i];
        const probeTarget = dirUrl + encodeURIComponent(probeCandidate);
        batchPromises.push(this.probeUrl(probeTarget, headers));
      }

      const batchResults = await Promise.all(batchPromises);
      for (let i = start; i < end; i++) {
        const candidate = limitedCandidates[i];
        const url = dirUrl + encodeURIComponent(candidate);
        const exists = batchResults[i - start];
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[外置字幕探测] candidate=${candidate} url=${sanitizeUrlForLog(url)} exists=${exists}`);
        if (!exists) {
          continue;
        }

        const lower = candidate.toLowerCase();
        const isSrt = lower.endsWith('.srt');
        const isAss = lower.endsWith('.ass') || lower.endsWith('.ssa');
        const isVtt = lower.endsWith('.vtt');
        if (!isSrt && !isAss && !isVtt) {
          continue;
        }

        try {
          let entries: SrtEntry[] = [];
          if (isAss) {
            entries = await this.fetchAss(url, headers);
          } else {
            entries = await this.fetchSrt(url, headers);
          }
          const langLabel = this.extractLangLabel(candidate, baseName);
          // 缺陷 3 修复：提取原始语言代码（如 'zh'/'en'），用于埋点语言统计
          const langCode = this.extractLangCode(candidate, baseName);
          const formatLabel = isAss ? 'ASS' : (isVtt ? 'VTT' : 'SRT');
          const item: SubtitleTrackItem = {
            kind: 'external',
            displayName: langLabel.length > 0
              ? `${langLabel} [外部·${formatLabel}]`
              : `字幕 [外部·${formatLabel}]`,
            url,
            srtEntries: entries,
            language: langCode
          };
          found.push(item);
        } catch (e) {
          const err = e as BusinessError;
          hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
            `外部字幕处理失败: code=${err.code} msg=${err.message}`);
        }
      }
    }

    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[外置字幕探测完成] 找到 ${found.length} 个外置字幕`);
    return found;
  }

  protected probeUrl(url: string, headers: Record<string, string>): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      const req = http.createHttp();
      req.request(url, {
        method: http.RequestMethod.HEAD,
        header: headers,
        connectTimeout: 5000,
        readTimeout: 5000
      }, (err: BusinessError, resp: http.HttpResponse) => {
        req.destroy();
        if (err) {
          resolve(false);
          return;
        }
        const code = resp.responseCode;
        resolve(code === 200 || code === 206);
      });
    });
  }

  /**
   * 从字幕文件名中提取原始语言代码（如 'zh'、'en'、'chi'）。
   * 适配命名规范：<baseName>.<langCode>.<ext>（如 movie.zh.srt → 'zh'）。
   * 若文件名与视频同名或无法识别语言后缀，返回 undefined。
   */
  protected extractLangCode(candidate: string, baseName: string): string | undefined {
    const dotIdx = candidate.lastIndexOf('.');
    const withoutExt = dotIdx >= 0 ? candidate.substring(0, dotIdx) : candidate;
    if (withoutExt === baseName) {
      return undefined;
    }
    const prefix = baseName + '.';
    if (withoutExt.startsWith(prefix)) {
      const code = withoutExt.substring(prefix.length);
      return code.length > 0 ? code : undefined;
    }
    return undefined;
  }

  protected extractLangLabel(candidate: string, baseName: string): string {
    const dotIdx = candidate.lastIndexOf('.');
    const withoutExt = dotIdx >= 0 ? candidate.substring(0, dotIdx) : candidate;
    if (withoutExt === baseName) {
      return '';
    }
    const prefix = baseName + '.';
    if (withoutExt.startsWith(prefix)) {
      const lang = withoutExt.substring(prefix.length);
      return FfprobeUtil.getLanguageDisplayName(lang) || lang;
    }
    return withoutExt;
  }

  protected fetchSrt(url: string, headers: Record<string, string>): Promise<SrtEntry[]> {
    return new Promise<SrtEntry[]>((resolve, reject) => {
      const req = http.createHttp();
      req.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 10000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      }, (err: BusinessError, resp: http.HttpResponse) => {
        req.destroy();
        if (err) {
          reject(err);
          return;
        }
        if (resp.responseCode !== 200 && resp.responseCode !== 206) {
          reject(createHttpBusinessError(resp.responseCode, url));
          return;
        }
        const body = decodeSubtitlePayload(resp.result);
        resolve(SrtParser.parse(body));
      });
    });
  }

  protected fetchAss(url: string, headers: Record<string, string>): Promise<SrtEntry[]> {
    return new Promise<SrtEntry[]>((resolve, reject) => {
      const req = http.createHttp();
      req.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 10000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      }, (err: BusinessError, resp: http.HttpResponse) => {
        req.destroy();
        if (err) {
          reject(err);
          return;
        }
        if (resp.responseCode !== 200 && resp.responseCode !== 206) {
          reject(createHttpBusinessError(resp.responseCode, url));
          return;
        }
        const body = decodeSubtitlePayload(resp.result);
        resolve(AssFileParser.parse(body));
      });
    });
  }
}

export class AvSubtitleBridgeAdapter extends BaseSubtitleBridgeAdapter {
  override onSeekSync(): void {
    super.onSeekSync();
    // seek 后 AVPlayer 会重新推送当前位置的字幕，清空旧文本避免 applySubtitleBridgeState 还原过期字幕
    this.currentSubtitleText = '';
  }

  protected async loadInternalTracks(): Promise<SubtitleTrackItem[]> {
    const items: SubtitleTrackItem[] = [];
    if (!this.player) {
      return items;
    }

    const allTracks = await this.player.getTrackInfos();
    const subtitleTracks: TrackInfo[] = allTracks.filter((t: TrackInfo) => t.trackType === 'subtitle');
    this.subtitleTracks = subtitleTracks;

    // 统计轨道元信息可读率（#17）
    let readableCount = 0;
    for (let i = 0; i < subtitleTracks.length; i++) {
      const track = subtitleTracks[i];
      const hasLang = track.language !== undefined && track.language.length > 0;
      const hasMime = track.mimeType !== undefined && track.mimeType.length > 0;
      if (hasLang || hasMime) {
        readableCount++;
      }
      const languageName = hasLang
        ? FfprobeUtil.getLanguageDisplayName(track.language!)
        : '';
      // 字幕名添加格式标识：从 mimeType 或 codec 提取
      const formatTag = this.extractFormatTag(track.mimeType, track.codec);
      const displayName = languageName.length > 0
        ? (formatTag.length > 0 ? `${languageName}(${formatTag})` : languageName)
        : (formatTag.length > 0 ? `字幕 ${i + 1}(${formatTag})` : `字幕 ${i + 1}`);
      const item: SubtitleTrackItem = {
        kind: 'internal',
        displayName,
        internalIndex: track.trackIndex,
        language: track.language
      };
      items.push(item);
    }

    if (subtitleTracks.length > 0) {
      const rate = Math.round(readableCount / subtitleTracks.length * 100);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[字幕指标] 内嵌字幕轨道识别率=${rate}% (${readableCount}/${subtitleTracks.length})`);
    }

    return items;
  }

  /** 从 mimeType 或 codec 提取字幕格式标识 */
  private extractFormatTag(mimeType?: string, codec?: string): string {
    // 优先从 codec 提取
    if (codec !== undefined && codec.length > 0) {
      return this.codecToFormatTag(codec);
    }
    // 回退到 mimeType
    if (mimeType !== undefined && mimeType.length > 0) {
      const lower = mimeType.toLowerCase();
      if (lower.includes('subrip') || lower.includes('srt')) { return 'SRT'; }
      if (lower.includes('ass') || lower.includes('ssa')) { return 'ASS'; }
      if (lower.includes('webvtt') || lower.includes('vtt')) { return 'VTT'; }
      if (lower.includes('ttml') || lower.includes('dfxp')) { return 'TTML'; }
      if (lower.includes('pgs')) { return 'PGS'; }
      if (lower.includes('vobsub')) { return 'VOBSUB'; }
    }
    return '';
  }

  /** codec 名称映射为格式标识 */
  private codecToFormatTag(codec: string): string {
    const lower = codec.toLowerCase();
    if (lower === 'ass') { return 'ASS'; }
    if (lower === 'ssa') { return 'SSA'; }
    if (lower === 'subrip' || lower === 'srt') { return 'SRT'; }
    if (lower === 'hdmv_pgs_subtitle' || lower === 'pgs') { return 'PGS'; }
    if (lower === 'vobsub' || lower === 'dvd_subtitle') { return 'VOBSUB'; }
    if (lower === 'webvtt' || lower === 'vtt') { return 'VTT'; }
    if (lower === 'mov_text' || lower === 'tx3g') { return 'TX3G'; }
    if (lower.length > 0) { return codec.toUpperCase(); }
    return '';
  }
}

/**
 * MPV 后端字幕桥接适配器。
 *
 * MPV 字幕桥接行为：
 * 1. loadInternalTracks 使用 player.getTrackInfos()（MPV tracks 事件缓存），
 *    而非 FfprobeUtil.probe()——MPV 已有精确的轨道信息，无需额外探测。
 * 2. onEmbeddedTimedText 不检查 currentSubtitleTrack：
 *    MPV 的 subtitleText 事件自带选轨语义（选中文本字幕轨后才有输出），
 *    空文本回调用于及时清理已经结束的字幕。
 * 3. 不需要 parseAssIfNeeded：libmpv 已将 ASS raw 转为纯文本后输出。
 *
 * spec 约束：MPV 后端默认不选中文本字幕轨，subtitleText 事件驱动 TV 端 SubtitleRenderer 绘制。
 */
export class MpvSubtitleBridgeAdapter extends BaseSubtitleBridgeAdapter {
  override onSeekSync(): void {
    super.onSeekSync();
    this.currentSubtitleText = '';
  }

  protected async loadInternalTracks(): Promise<SubtitleTrackItem[]> {
    const items: SubtitleTrackItem[] = [];
    if (!this.player) {
      return items;
    }

    const allTracks = await this.player.getTrackInfos();
    // 过滤字幕轨道，排除图形字幕（PGS/VobSub 等）
    const subtitleTracks: TrackInfo[] = allTracks.filter((t: TrackInfo) => {
      if (t.trackType !== 'subtitle') {
        return false;
      }
      // 图形字幕过滤：mimeType 以 "image/" 开头 或 codec 包含已知图形字幕编解码器
      const mime = t.mimeType ?? '';
      const codec = t.codec ?? '';
      const isGraphicMime = mime.startsWith('image/');
      const isGraphicCodec = codec.includes('hdmv_pgs_subtitle') ||
        codec.includes('vobsub') || codec.includes('dvd_subtitle');
      if (isGraphicMime || isGraphicCodec) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[MpvSub] 跳过图形字幕: index=${t.trackIndex} mime=${mime} codec=${codec}`);
        return false;
      }
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[MpvSub] 保留文本字幕: index=${t.trackIndex} mime=${mime} codec=${codec} lang=${t.language ?? ''}`);
      return true;
    });
    this.subtitleTracks = subtitleTracks;

    for (let i = 0; i < subtitleTracks.length; i++) {
      const track = subtitleTracks[i];
      const hasLang = track.language !== undefined && track.language.length > 0;
      const languageName = hasLang
        ? FfprobeUtil.getLanguageDisplayName(track.language!)
        : '';
      // 字幕名添加格式标识：codec 映射为大写格式名，如 "ass" → "ASS", "subrip" → "SRT"
      const codec = track.codec ?? '';
      const formatTag = this.codecToFormatTag(codec);
      const displayName = languageName.length > 0
        ? (formatTag.length > 0 ? `${languageName}(${formatTag})` : languageName)
        : (formatTag.length > 0 ? `字幕 ${i + 1}(${formatTag})` : `字幕 ${i + 1}`);
      const item: SubtitleTrackItem = {
        kind: 'internal',
        displayName,
        internalIndex: track.trackIndex,
        language: track.language
      };
      items.push(item);
    }

    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[MpvSub] 内嵌字幕轨道数=${items.length} (原始=${allTracks.filter((t: TrackInfo) => t.trackType === 'subtitle').length})`);
    return items;
  }

  /**
  * 将 mpv codec 名称映射为用户友好的格式标识。
  * 如 "ass" → "ASS", "subrip" → "SRT", "hdmv_pgs_subtitle" → "PGS"
  */
    private codecToFormatTag(codec: string): string {
   const lower = codec.toLowerCase();
   if (lower === 'ass') { return 'ASS'; }
   if (lower === 'ssa') { return 'SSA'; }
   if (lower === 'subrip' || lower === 'srt') { return 'SRT'; }
   if (lower === 'hdmv_pgs_subtitle' || lower === 'pgs') { return 'PGS'; }
   if (lower === 'vobsub' || lower === 'dvd_subtitle') { return 'VOBSUB'; }
   if (lower === 'webvtt' || lower === 'vtt') { return 'VTT'; }
   if (lower === 'mov_text' || lower === 'tx3g') { return 'TX3G'; }
   if (lower.length > 0) { return codec.toUpperCase(); }
   return '';
    }

    /**
  * MPV 的 subtitleText 事件输出纯文本（libmpv 已解析 ASS raw），
  * 不需要 parseAssIfNeeded，也不检查 currentSubtitleTrack：
  * MPV subtitleText 仅在选中文本字幕轨后才有输出，自带选轨语义。
  */
    override onEmbeddedTimedText(text: string): void {
   if (this.srtEntries.length > 0) {
     return; // 外置 SRT 优先，不覆盖
   }
   // MPV 的 subtitleText 已是纯文本，直接赋值
   this.currentSubtitleText = text;
    }

  /**
   * MPV 后端 switchTrack 无需额外处理：
   * - 选中文本字幕 → MpvPlayerAdapter.selectTrack 已设置 sub-visibility=no
   * - 关闭字幕 → MpvPlayerAdapter.selectTrack(-1) 已设置 sub-visibility=yes
   * - 外置字幕 → selectTrack(-1) 关闭内嵌轨，sub-visibility=yes 无害（无内嵌轨可渲染）
   */
}

export class NoSubtitleBridgeAdapter implements ISubtitleBridgeAdapter {
  private state: SubtitleBridgeState = {
    subtitleTracks: [],
    allSubtitleTracks: [],
    activeSubtitleIndex: -1,
    currentSubtitleTrack: -1,
    currentSubtitleText: '',
    subtitleDelayMs: 0,
    hasExternalActive: false
  };

  async init(_player: IPlayer, _videoData?: VideoData): Promise<void> {
    return Promise.resolve();
  }

  onTimeUpdate(_currentTimeMs: number): void {}

  onSubtitleUpdate(_info: SubtitleInfo): void {}

  onEmbeddedTimedText(_text: string): void {}

  async switchTrack(_allIndex: number): Promise<void> {
    return Promise.resolve();
  }

  adjustDelay(_deltaMs: number): void {}

  onSeekSync(): void {}

  getState(): SubtitleBridgeState {
    return this.state;
  }

  async addLocalSubtitle(_localPath: string): Promise<void> {}

  release(): void {}
}
