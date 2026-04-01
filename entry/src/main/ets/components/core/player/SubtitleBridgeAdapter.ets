import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import util from '@ohos.util';
import { CommonConstants } from '../../../common/constants/CommonConstants';
import { FfprobeUtil, type FfprobeTrack } from '../../../utils/FfprobeUtil';
import { VideoData } from './VideoData';
import { VideoDataType } from './Constants';
import { IPlayer, SubtitleInfo, TrackInfo } from './IPlayer';
import { AssFileParser, SrtEntry, SrtParser } from './SubtitleRenderer';

const TAG = '[SubtitleBridgeAdapter]';
const MAX_SUBTITLE_PROBE_CANDIDATES = 12;
const SUBTITLE_PROBE_BATCH_SIZE = 4;

function tryDecode(bytes: Uint8Array, encoding: string): string {
  const decoder = new util.TextDecoder(encoding);
  return decoder.decodeWithStream(bytes);
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
    const decoder = new util.TextDecoder('utf-8', { ignoreBOM: true });
    return decoder.decodeWithStream(bytes);
  }

  // UTF-16 LE BOM: FF FE
  if (bytes.length >= 2 && bytes[0] === 0xFF && bytes[1] === 0xFE) {
    const decoder = new util.TextDecoder('utf-16le', { ignoreBOM: true });
    return decoder.decodeWithStream(bytes);
  }

  // UTF-16 BE BOM: FE FF
  if (bytes.length >= 2 && bytes[0] === 0xFE && bytes[1] === 0xFF) {
    const decoder = new util.TextDecoder('utf-16be', { ignoreBOM: true });
    return decoder.decodeWithStream(bytes);
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
      const preferredIndex = this.findPreferredTrackIndex();
      // 不 await：auto-select 的轨道切换可能包含长时间异步操作（如 SMB 内嵌字幕 30s 提取）
      // fire-and-forget，初始化立即完成，字幕在提取完成后自动开始渲染
      this.switchTrack(preferredIndex).catch(() => {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `[字幕指标] 自动选轨异常，降级无字幕`);
      });
      const selected = this.allSubtitleTracks[preferredIndex];
      if (selected) {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[字幕指标] 初始化完成: 内嵌=${internalItems.length} 外置=${externalItems.length}` +
          ` 自动选中[${preferredIndex}]=${selected.displayName}(${selected.kind})`);
      } else {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[字幕指标] 初始化完成: 内嵌=${internalItems.length} 外置=${externalItems.length} 轨道索引越界`);
      }
    } else {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[字幕指标] 初始化完成: 内嵌=0 外置=0 无字幕轨道`);
    }
  }

  /** 默认优先选择第一条内嵌字幕，没有内嵌字幕再选第一条外置字幕 */
  protected findPreferredTrackIndex(): number {
    // 先找内嵌字幕
    for (let i = 0; i < this.allSubtitleTracks.length; i++) {
      if (this.allSubtitleTracks[i].kind === 'internal') {
        return i;
      }
    }
    // 没有内嵌字幕则找外置字幕
    for (let i = 0; i < this.allSubtitleTracks.length; i++) {
      if (this.allSubtitleTracks[i].kind === 'external') {
        return i;
      }
    }
    return 0;
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
    if (this.srtEntries.length > 0) {
      return;
    }
    this.currentSubtitleText = info.text ?? '';
  }

  onEmbeddedTimedText(_text: string): void { /* 子类按需覆盖 */ }

  async switchTrack(allIndex: number): Promise<void> {
    if (!this.player) {
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
          const formatLabel = isAss ? 'ASS' : (isVtt ? 'VTT' : 'SRT');
          const item: SubtitleTrackItem = {
            kind: 'external',
            displayName: langLabel.length > 0
              ? `${langLabel} [外部·${formatLabel}]`
              : `字幕 [外部·${formatLabel}]`,
            url,
            srtEntries: entries
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

export class IjkSubtitleBridgeAdapter extends BaseSubtitleBridgeAdapter {
  protected async loadInternalTracks(): Promise<SubtitleTrackItem[]> {
    if (!this.videoData) {
      return [];
    }

    // 通过 FfprobeUtil 探测内嵌字幕轨道（stream index 与 IJKPlayer selectTrack 一致）
    const probe = await FfprobeUtil.probe(
      this.videoData.videoSrc,
      this.videoData.httpHeader,
      9000
    );
    if (!probe.success || probe.subtitleTracks.length === 0) {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '[IjkSub] 无内嵌字幕轨道');
      return [];
    }

    const rawTracks = probe.subtitleTracks;
    // 过滤掉图像型字幕编解码器（PGS/BD/DVD/DVB），这类轨道只有位图数据，文本管线无法处理
    const IMAGE_CODECS: string[] = ['hdmv_pgs_subtitle', 'dvd_subtitle', 'dvb_subtitle',
      'dvb_teletext', 'eia_608', 'eia_708'];
    const textTracks = rawTracks.filter((ft: FfprobeTrack) => {
      const codec = (ft.codecName ?? '').toLowerCase();
      return !IMAGE_CODECS.includes(codec);
    });
    const newSubtitleTracks: TrackInfo[] = [];
    for (let i = 0; i < textTracks.length; i++) {
      const ft: FfprobeTrack = textTracks[i];
      const ti: TrackInfo = {
        trackIndex: ft.index,
        trackType: 'subtitle',
        language: ft.language,
        mimeType: ft.codecName
      };
      newSubtitleTracks.push(ti);
    }
    this.subtitleTracks = newSubtitleTracks;

    const items: SubtitleTrackItem[] = [];
    for (let i = 0; i < textTracks.length; i++) {
      const ft: FfprobeTrack = textTracks[i];
      // 直接用描述作为显示名，外部字幕已有标识，内嵌字幕不再加前缀
      const displayName = FfprobeUtil.buildSubtitleTrackDisplayName(ft, i);
      const item: SubtitleTrackItem = {
        kind: 'internal',
        displayName,
        internalIndex: ft.index
      };
      items.push(item);
    }
    hilog.info(CommonConstants.LOG_DOMAIN, TAG, `[IjkSub] 内嵌字幕轨道数=${items.length}`);
    return items;
  }

  /**
   * 对于 IjkPlayer：内嵌字幕走实时 onTimedText 路径。
   * CI 构建的 ohos_ijkplayer 已启用 subrip/ass 解码器，FFP_MSG_TIMED_TEXT 会实时回调。
   * 选轨后直接调用 selectTrack，等待 onEmbeddedTimedText 回调更新字幕文本。
   */
  override async switchTrack(allIndex: number): Promise<void> {
    if (!this.player) {
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
      return;
    }

    this.activeSubtitleIndex = allIndex;
    this.currentSubtitleText = '';

    const target = this.allSubtitleTracks[allIndex];
    if (target.kind === 'external') {
      // 外置 SRT：填充 srtEntries，不选内嵌轨道
      const entries = target.srtEntries ?? [];
      this.srtEntries = entries;
      this.lastSrtText = '';
      this.currentSubtitleTrack = -1;
      await this.player.selectTrack(-1);
      return;
    }

    // 内嵌轨道：实时模式 —— 告知 ijkplayer 选轨，onTimedText 回调负责更新字幕文本
    const internalIndex = target.internalIndex ?? -1;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[IjkSub] 选择内嵌字幕轨 stream=${internalIndex}，等待 onTimedText 实时回调`);

    this.srtEntries = [];
    this.lastSrtText = '';
    this.currentSubtitleTrack = internalIndex;

    if (internalIndex >= 0) {
      await this.player.selectTrack(internalIndex);
    }
  }

  /**
   * 处理 IJKPlayer onTimedText 实时回调。
   * - 外置 SRT 激活时（srtEntries > 0）不覆盖
   * - 需要内嵌字幕轨道已被选中（currentSubtitleTrack >= 0）
   * - 自动剥离 ASS override codes {..} 和 HTML 标签 <..>
   */
  onEmbeddedTimedText(text: string): void {
    if (this.srtEntries.length > 0) {
      return; // 外置 SRT 优先，不覆盖
    }
    if (this.currentSubtitleTrack < 0) {
      return; // 未选中内嵌轨道
    }
    const parsed = IjkSubtitleBridgeAdapter.parseAssIfNeeded(text);
    this.currentSubtitleText = IjkSubtitleBridgeAdapter.stripSubtitleMarkup(parsed);
  }

  /**
   * 解析 ijkplayer 内嵌字幕 ASS 格式，提取纯文本。
   *
   * rect->ass 的实际格式是完整 Dialogue 行（"Dialogue" 单词可能被乱码替换）：
   *   <garbled>: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
   * 冒号+空格（": "）是稳定的 ASCII 标记，": " 之后需跳过 9 个逗号才能到 Text 字段。
   *
   * 若不含 ": "，尝试 MKV 包格式（ReadOrder 为数字开头，跳 8 逗号）。
   * 都不匹配则视为清除信号，返回空字符串。
   */
  private static parseAssIfNeeded(raw: string): string {
    hilog.debug(CommonConstants.LOG_DOMAIN, TAG,
      `[IjkSub ASS raw] len=${raw.length}`);

    // 策略 1：完整 Dialogue 行格式 — 查找 ": "（冒号+空格），之后跳 9 个逗号
    const colonSpaceIdx = raw.indexOf(': ');
    if (colonSpaceIdx >= 0) {
      const afterColon = raw.substring(colonSpaceIdx + 2);
      let pos = 0;
      let commaCount = 0;
      while (pos < afterColon.length && commaCount < 9) {
        if (afterColon[pos] === ',') {
          commaCount++;
        }
        pos++;
      }
      if (commaCount === 9) {
        let textField = afterColon.substring(pos);
        let end = textField.length;
        while (end > 0 && (textField[end - 1] === '\r' || textField[end - 1] === '\n')) {
          end--;
        }
        textField = textField.substring(0, end);
        textField = textField.split('\\N').join('\n');
        hilog.debug(CommonConstants.LOG_DOMAIN, TAG,
          `[IjkSub ASS parsed] dialogue+9commas len=${textField.length}`);
        return textField;
      }
    }

    // 策略 2：MKV 包格式 — 第一字段为纯数字（ReadOrder），跳 8 个逗号
    const firstCommaIdx = raw.indexOf(',');
    if (firstCommaIdx > 0 && firstCommaIdx < 10) {
      let isNumeric = true;
      for (let _c = 0; _c < firstCommaIdx; _c++) {
        const code = raw.charCodeAt(_c);
        if (code < 48 || code > 57) {
          isNumeric = false;
          break;
        }
      }
      if (isNumeric) {
        let pos = 0;
        let commaCount = 0;
        while (pos < raw.length && commaCount < 8) {
          if (raw[pos] === ',') {
            commaCount++;
          }
          pos++;
        }
        if (commaCount === 8) {
          let textField = raw.substring(pos);
          let end = textField.length;
          while (end > 0 && (textField[end - 1] === '\r' || textField[end - 1] === '\n')) {
            end--;
          }
          textField = textField.substring(0, end);
          textField = textField.split('\\N').join('\n');
          hilog.debug(CommonConstants.LOG_DOMAIN, TAG,
            `[IjkSub ASS parsed] readorder+8commas len=${textField.length}`);
          return textField;
        }
      }
    }

    // 无法识别结构 → 清除信号或垃圾包，返回空字符串
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `[IjkSub ASS fallback] no structure, returning empty`);
    return '';
  }

  /** 剥离 ASS override codes {..} 与 HTML 标签 <..>，返回纯文本 */
  private static stripSubtitleMarkup(raw: string): string {
    let result = '';
    let depth = 0;
    let inHtml = false;
    for (let i = 0; i < raw.length; i++) {
      const ch = raw[i];
      if (ch === '{') { depth++; continue; }
      if (ch === '}') { if (depth > 0) { depth--; } continue; }
      if (depth > 0) { continue; }
      if (ch === '<') {
        // 只有 <字母 或 </ 才认为是 HTML/ASS 标签，避免误吃 "1 < 2" 这样的内容
        const next = i + 1 < raw.length ? raw[i + 1] : '';
        const isTag = (next >= 'a' && next <= 'z') || (next >= 'A' && next <= 'Z') || next === '/';
        if (isTag) { inHtml = true; continue; }
      }
      if (ch === '>' && inHtml) { inHtml = false; continue; }
      if (!inHtml) { result += ch; }
    }
    return result.trim();
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
      const displayName = languageName.length > 0 ? languageName : `字幕 ${i + 1}`;
      const item: SubtitleTrackItem = {
        kind: 'internal',
        displayName,
        internalIndex: track.trackIndex
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

  release(): void {}
}
