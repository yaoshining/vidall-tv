import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import util from '@ohos.util';
import { CommonConstants } from '../../../common/constants/CommonConstants';
import { FfprobeUtil } from '../../../utils/FfprobeUtil';
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
  switchTrack(allIndex: number): Promise<void>;
  adjustDelay(deltaMs: number): void;
  onSeekSync(): void;
  getState(): SubtitleBridgeState;
  release(): void;
}

class BaseSubtitleBridgeAdapter implements ISubtitleBridgeAdapter {
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
      await this.switchTrack(preferredIndex);
      const selected = this.allSubtitleTracks[preferredIndex];
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[字幕指标] 初始化完成: 内嵌=${internalItems.length} 外置=${externalItems.length}` +
        ` 自动选中[${preferredIndex}]=${selected.displayName}(${selected.kind})`);
    } else {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[字幕指标] 初始化完成: 内嵌=0 外置=0 无字幕轨道`);
    }
  }

  /** 默认优先选择外置字幕，其次才是第一条内嵌字幕 */
  protected findPreferredTrackIndex(): number {
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
    // 隐藏内嵌字幕以避免长时间的字幕提取等待
    // 扫描时仍然会保存所有轨道信息到数据库（供未来优化使用）
    // 运行时只通过 loadExternalTracks() 加载外置字幕
    return [];
  }
}

export class AvSubtitleBridgeAdapter extends BaseSubtitleBridgeAdapter {
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
      const displayName = languageName.length > 0
        ? `字幕 ${i + 1} (${languageName})`
        : `字幕 ${i + 1}`;
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
