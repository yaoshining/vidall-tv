import { BusinessError } from '@kit.BasicServicesKit';
import VidAllCorePlayerNapi from 'libvidall_core_player_napi.so';

// ─────────────────────────────────────────────
// 数据结构
// ─────────────────────────────────────────────

export interface FfprobeTrack {
  index: number;
  type: 'video' | 'audio' | 'subtitle' | 'unknown';
  codecName: string;       // e.g. "hevc", "eac3", "subrip", "ass"
  codecLongName: string;   // e.g. "H.265 / HEVC"
  language: string;        // ISO 639-2, e.g. "chi", "eng", ""
  /** 字幕/音轨标题（来自 ffprobe stream.tags.title） */
  title?: string;
  // 音频专属
  channels?: number;
  sampleRate?: number;
  channelLayout?: string;  // e.g. "stereo", "5.1"
  // 视频专属
  width?: number;
  height?: number;
  frameRate?: number;      // 实际帧率
  bitrate?: number;
}

export interface FfprobeResult {
  success: boolean;
  durationMs: number;
  durationText: string;
  bitrate?: number;
  formatName?: string;     // e.g. "matroska,webm", "mov,mp4,m4a"
  videoTracks: FfprobeTrack[];
  audioTracks: FfprobeTrack[];
  subtitleTracks: FfprobeTrack[];
  errorMessage?: string;
}

// ffprobe 输出的原始 JSON 结构（内部用）
interface RawStream {
  index?: number;
  codec_type?: string;
  codec_name?: string;
  codec_long_name?: string;
  width?: number;
  height?: number;
  r_frame_rate?: string;   // e.g. "24000/1001"
  avg_frame_rate?: string;
  sample_rate?: string;
  channels?: number;
  channel_layout?: string;
  bit_rate?: string;
  tags?: RawStreamTags;
}

interface RawStreamTags {
  language?: string;
  LANGUAGE?: string;
  title?: string;
  TITLE?: string;
}

interface RawFormat {
  duration?: string;       // seconds as string
  bit_rate?: string;
  format_name?: string;
}

interface RawProbeOutput {
  streams?: RawStream[];
  format?: RawFormat;
}

// ─────────────────────────────────────────────
// 工具函数
// ─────────────────────────────────────────────

function formatDuration(ms: number): string {
  if (ms <= 0) { return '00:00:00'; }
  const totalSeconds = Math.floor(ms / 1000);
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const s = totalSeconds % 60;
  return `${h.toString().padStart(2, '0')}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
}

function parseFrameRate(rateStr: string): number {
  // e.g. "24000/1001" → 23.976, "30/1" → 30
  if (!rateStr || rateStr === '0/0') { return 0; }
  const parts = rateStr.split('/');
  if (parts.length !== 2) { return parseFloat(rateStr) || 0; }
  const num = parseFloat(parts[0]);
  const den = parseFloat(parts[1]);
  if (den === 0) { return 0; }
  const fps = num / den;
  return Math.round(fps * 1000) / 1000;
}

function parseRawStream(raw: RawStream): FfprobeTrack {
  const codecType = raw.codec_type ?? '';
  let type: 'video' | 'audio' | 'subtitle' | 'unknown' = 'unknown';
  if (codecType === 'video') { type = 'video'; }
  else if (codecType === 'audio') { type = 'audio'; }
  else if (codecType === 'subtitle') { type = 'subtitle'; }

  const lang = raw.tags?.language ?? raw.tags?.LANGUAGE ?? '';

  const track: FfprobeTrack = {
    index: raw.index ?? 0,
    type,
    codecName: raw.codec_name ?? '',
    codecLongName: raw.codec_long_name ?? '',
    language: lang.toLowerCase() === 'und' ? '' : lang,
    title: raw.tags?.title ?? raw.tags?.TITLE,
  };

  if (type === 'audio') {
    track.channels = raw.channels;
    track.sampleRate = raw.sample_rate ? parseInt(raw.sample_rate) : undefined;
    track.channelLayout = raw.channel_layout;
    track.bitrate = raw.bit_rate ? parseInt(raw.bit_rate) : undefined;
  } else if (type === 'video') {
    track.width = raw.width;
    track.height = raw.height;
    const fpsStr = raw.r_frame_rate && raw.r_frame_rate !== '0/0'
      ? raw.r_frame_rate
      : (raw.avg_frame_rate ?? '');
    track.frameRate = parseFrameRate(fpsStr);
    track.bitrate = raw.bit_rate ? parseInt(raw.bit_rate) : undefined;
  }

  return track;
}

// ─────────────────────────────────────────────
// 核心工具类
// ─────────────────────────────────────────────

/**
 * 基于 @sj/ffmpeg 的 ffprobe 命令封装。
 *
 * 支持所有 FFmpeg 能识别的视频格式：
 * MKV、MP4、AVI、TS、MOV、FLV、WMV 等。
 *
 * 支持 HTTP/HTTPS 远程 URL，通过 headers 传入 Authorization。
 *
 * 使用示例：
 * const result = await FfprobeUtil.probe(url, { Authorization: 'Basic xxx' });
 */
export class FfprobeUtil {
  /**
   * 探测视频文件的完整媒体信息
   * @param url       视频 URL（支持 http/https/本地路径）
   * @param headers   HTTP 请求头（可选），如 { Authorization: 'Basic xxx' }
   * @param timeoutMs 超时时间，默认 20000ms
   */
  static async probe(
    url: string,
    headers?: Record<string, string>,
    timeoutMs: number = 20000
  ): Promise<FfprobeResult> {
    let headersStr = '';
    if (headers) {
      const keys = Object.keys(headers);
      for (const key of keys) {
        headersStr += `${key}: ${headers[key]}\r\n`;
      }
    }

    const commands: string[] = [
      'ffprobe',
      '-v', 'quiet',
      '-of', 'json',
      '-show_streams',
      '-show_format',
    ];

    if (headersStr.length > 0) {
      commands.push('-headers', headersStr);
    }

    commands.push('-i', url);

    console.info(`[FfprobeUtil] 开始探测: ${url}`);
    const safeCommands = commands.map((c) => {
      if (typeof c === 'string' && c.toLowerCase().includes('authorization:')) {
        return c.replace(/Authorization:[^\r\n]*/gi, 'Authorization: ***');
      }
      return c;
    });
    console.info(`[FfprobeUtil] 命令: ${safeCommands.join(' ')}`);

    try {
      const outputJson = VidAllCorePlayerNapi.ffprobe(url, headersStr, timeoutMs);
      console.info(`[FfprobeUtil] 探测完成，输出长度=${outputJson.length}`);
      return FfprobeUtil.parseOutput(url, outputJson);
    } catch (e) {
      const err = e as BusinessError;
      const message = err.message ? err.message : JSON.stringify(err);
      console.error(`[FfprobeUtil] 探测失败: ${message}`);
      return FfprobeUtil.buildErrorResult(url, message);
    }
  }

  private static parseOutput(url: string, outputJson: string): FfprobeResult {
    if (!outputJson || outputJson.trim().length === 0) {
      return FfprobeUtil.buildErrorResult(url, 'ffprobe 无输出');
    }

    try {
      const raw = JSON.parse(outputJson) as RawProbeOutput;

      const videoTracks: FfprobeTrack[] = [];
      const audioTracks: FfprobeTrack[] = [];
      const subtitleTracks: FfprobeTrack[] = [];

      const streams = raw.streams ?? [];
      for (const s of streams) {
        const track = parseRawStream(s);
        if (track.type === 'video') { videoTracks.push(track); }
        else if (track.type === 'audio') { audioTracks.push(track); }
        else if (track.type === 'subtitle') { subtitleTracks.push(track); }
      }

      const durationSec = raw.format?.duration ? parseFloat(raw.format.duration) : 0;
      const durationMs = Math.round(durationSec * 1000);
      const totalBitrate = raw.format?.bit_rate ? parseInt(raw.format.bit_rate) : undefined;
      const formatName = raw.format?.format_name;

      console.info(
        `[FfprobeUtil] 解析成功 — 时长=${formatDuration(durationMs)} | ` +
        `视频轨=${videoTracks.length} 音轨=${audioTracks.length} 字幕轨=${subtitleTracks.length} | ` +
        `格式=${formatName ?? '?'}`
      );
      audioTracks.forEach((t, i) => {
        console.info(
          `[FfprobeUtil]   音轨[${i}] codec=${t.codecName} ` +
          `${t.sampleRate ?? '?'}Hz ${t.channels ?? '?'}ch ` +
          `layout=${t.channelLayout ?? '?'} lang=${t.language || '(未知)'}`
        );
      });
      subtitleTracks.forEach((t, i) => {
        console.info(
          `[FfprobeUtil]   字幕轨[${i}] codec=${t.codecName} lang=${t.language || '(未知)'}` +
          ` title=${t.title ?? '(无)'}`
        );
      });

      const result: FfprobeResult = {
        success: true,
        durationMs,
        durationText: formatDuration(durationMs),
        bitrate: totalBitrate,
        formatName,
        videoTracks,
        audioTracks,
        subtitleTracks,
      };
      return result;
    } catch (e) {
      const msg = `JSON 解析失败: ${JSON.stringify(e)}`;
      console.error(`[FfprobeUtil] ${msg}`);
      console.error(`[FfprobeUtil] 原始输出前500字: ${outputJson.substring(0, 500)}`);
      return FfprobeUtil.buildErrorResult(url, msg);
    }
  }

  private static buildErrorResult(url: string, errorMessage: string): FfprobeResult {
    const result: FfprobeResult = {
      success: false,
      durationMs: 0,
      durationText: '00:00:00',
      videoTracks: [],
      audioTracks: [],
      subtitleTracks: [],
      errorMessage,
    };
    return result;
  }

  /**
   * 将 FfprobeTrack 的 codecName 转换为友好的格式显示名
   * e.g. "eac3" → "E-AC-3", "truehd" → "TrueHD"
   */
  static getCodecDisplayName(codecName: string): string {
    const map: Record<string, string> = {
      'aac': 'AAC',
      'mp3': 'MP3',
      'ac3': 'AC-3',
      'eac3': 'E-AC-3',
      'truehd': 'TrueHD',
      'dts': 'DTS',
      'flac': 'FLAC',
      'opus': 'Opus',
      'vorbis': 'Vorbis',
      'pcm_s16le': 'PCM',
      'pcm_s24le': 'PCM',
      'hevc': 'H.265',
      'h264': 'H.264',
      'av1': 'AV1',
      'vp9': 'VP9',
      'mpeg4': 'MPEG-4',
      'subrip': 'SRT',
      'ass': 'ASS',
      'hdmv_pgs_subtitle': 'PGS',
    };
    return map[codecName.toLowerCase()] ?? codecName.toUpperCase();
  }

  /**
   * ISO 639-2 语言代码转中文显示名
   */
  static getLanguageDisplayName(lang: string): string {
    if (!lang) { return ''; }
    const normalized = lang.toLowerCase();
    const map: Record<string, string> = {
      'chi': '中文', 'zho': '中文', 'zh': '中文',
      'chs': '中文(简体)', 'cht': '中文(繁体)',
      'zh-cn': '中文(简体)', 'zh-hans': '中文(简体)',
      'zh-tw': '中文(繁体)', 'zh-hant': '中文(繁体)', 'zh-hk': '中文(繁体,香港)',
      'eng': '英语', 'en': '英语',
      'jpn': '日语', 'ja': '日语',
      'kor': '韩语', 'ko': '韩语',
      'fra': '法语', 'fre': '法语',
      'deu': '德语', 'ger': '德语',
      'alb': '阿尔巴尼亚语', 'sqi': '阿尔巴尼亚语',
      'arm': '亚美尼亚语', 'hye': '亚美尼亚语',
      'baq': '巴斯克语', 'eus': '巴斯克语',
      'bul': '保加利亚语',
      'cat': '加泰罗尼亚语',
      'ces': '捷克语', 'cze': '捷克语',
      'hrv': '克罗地亚语',
      'dan': '丹麦语',
      'ell': '希腊语', 'gre': '希腊语',
      'est': '爱沙尼亚语',
      'fin': '芬兰语',
      'fil': '菲律宾语', 'tgl': '他加禄语',
      'nld': '荷兰语', 'dut': '荷兰语',
      'swe': '瑞典语',
      'nor': '挪威语',
      'pol': '波兰语',
      'ron': '罗马尼亚语', 'rum': '罗马尼亚语',
      'hun': '匈牙利语',
      'slk': '斯洛伐克语', 'slo': '斯洛伐克语',
      'slv': '斯洛文尼亚语',
      'srp': '塞尔维亚语',
      'lav': '拉脱维亚语',
      'lit': '立陶宛语',
      'ukr': '乌克兰语',
      'heb': '希伯来语',
      'urd': '乌尔都语',
      'hin': '印地语',
      'tur': '土耳其语',
      'tam': '泰米尔语',
      'tel': '泰卢固语',
      'ben': '孟加拉语',
      'mar': '马拉地语',
      'mal': '马拉雅拉姆语',
      'kan': '卡纳达语',
      'guj': '古吉拉特语',
      'pan': '旁遮普语',
      'spa': '西班牙语',
      'por': '葡萄牙语',
      'glg': '加利西亚语',
      'isl': '冰岛语', 'ice': '冰岛语',
      'gle': '爱尔兰语',
      'cym': '威尔士语', 'wel': '威尔士语',
      'mlt': '马耳他语',
      'mkd': '马其顿语', 'mac': '马其顿语',
      'rus': '俄语',
      'bel': '白俄罗斯语',
      'tha': '泰语',
      'vie': '越南语',
      'ara': '阿拉伯语',
      'fas': '波斯语', 'per': '波斯语',
      'pus': '普什图语',
      'kur': '库尔德语',
      'ita': '意大利语',
      'lat': '拉丁语',
      'ind': '印尼语',
      'msa': '马来语', 'may': '马来语',
      'mya': '缅甸语', 'bur': '缅甸语',
      'khm': '高棉语',
      'lao': '老挝语',
      'mon': '蒙古语',
      'kaz': '哈萨克语',
      'uzb': '乌兹别克语',
      'aze': '阿塞拜疆语',
      'kat': '格鲁吉亚语', 'geo': '格鲁吉亚语',
      'swa': '斯瓦希里语',
      'amh': '阿姆哈拉语',
      'som': '索马里语',
      'yor': '约鲁巴语',
      'ibo': '伊博语',
      'hau': '豪萨语',
      'zul': '祖鲁语',
      'xho': '科萨语',
      'afr': '南非荷兰语',
      'und': '未定义'
    };

    if (map[normalized]) {
      return map[normalized];
    }

    // 兼容 zh-CN / zh-TW / en-US 这类带区域后缀的语言标记
    const base = normalized.split('-')[0];
    if (map[base]) {
      return map[base];
    }

    return lang.toUpperCase();
  }

  /** 从字幕语言码/标题推断第三层标签（简体/繁体/香港/自定义标题） */
  private static getSubtitleTier3Label(track: FfprobeTrack, index: number): string {
    const lang = (track.language ?? '').toLowerCase();
    const title = (track.title ?? '').trim();
    const titleLower = title.toLowerCase();

    // 优先识别中文简繁体信息
    const isChinese =
      lang === 'chi' || lang === 'zho' || lang === 'zh' ||
      lang === 'chs' || lang === 'cht' ||
      lang.startsWith('zh-');

    if (isChinese) {
      // 使用单词边界匹配 'sc'/'tc'，避免 "Science"、"Action" 等词误命中
      const scExact = /(?:^|[\s._\-[\]()])sc(?:$|[\s._\-[\]()])/.test(titleLower);
      const tcExact = /(?:^|[\s._\-[\]()])tc(?:$|[\s._\-[\]()])/.test(titleLower);
      if (title.includes('简体') || titleLower.includes('chs') ||
        titleLower.includes('zh-cn') || titleLower.includes('hans') || scExact) {
        return '简体';
      }
      if (title.includes('繁体') && (title.includes('香港') || titleLower.includes('hk'))) {
        return '繁体(香港)';
      }
      if (title.includes('繁体') || titleLower.includes('cht') ||
        titleLower.includes('zh-tw') || titleLower.includes('hant') || tcExact) {
        return '繁体';
      }

      if (lang === 'chs' || lang === 'zh-cn') {
        return '简体';
      }
      if (lang === 'cht' || lang === 'zh-tw') {
        return '繁体';
      }
      if (lang === 'zh-hk') {
        return '繁体(香港)';
      }
    }

    // 非中文或中文未识别到脚本信息：回退到标题
    if (title.length > 0) {
      return title;
    }

    // 对中文字幕，优先给出语义化兜底，避免全部显示轨道编号
    if (isChinese) {
      return '未标注';
    }

    // 非中文无 title 时，保留最弱兜底信息
    return `轨道${index + 1}`;
  }

  /**
   * 构建音轨显示名称
   * e.g. "中文 (E-AC-3 • 5.1)"
   */
  static buildAudioTrackDisplayName(track: FfprobeTrack, index: number): string {
    const langName = track.language
      ? FfprobeUtil.getLanguageDisplayName(track.language)
      : `音轨 ${index + 1}`;
    const codecName = FfprobeUtil.getCodecDisplayName(track.codecName);
    const layout = track.channelLayout ?? (track.channels ? `${track.channels}ch` : '');
    if (codecName && layout) {
      return `${langName} (${codecName} • ${layout})`;
    } else if (codecName) {
      return `${langName} (${codecName})`;
    }
    return langName;
  }

  /**
   * 构建字幕轨显示名称
   * e.g. "中文 (SRT)", "英语 (ASS)", "字幕 1"
   */
  static buildSubtitleTrackDisplayName(track: FfprobeTrack, index: number): string {
    const langName = track.language
      ? FfprobeUtil.getLanguageDisplayName(track.language)
      : `字幕 ${index + 1}`;
    const codecDisplay = track.codecName
      ? FfprobeUtil.getCodecDisplayName(track.codecName)
      : '';
    const tier3 = FfprobeUtil.getSubtitleTier3Label(track, index);

    if (codecDisplay) {
      // 有编解码显示名称时：语言 (编码)，与 buildAudioTrackDisplayName 风格一致
      // tier3 为语义标签（简体/繁体/香港）时追加，通用兜底（'未标注'/'轨道N'）时省略
      const isSemanticTier3 = tier3.length > 0 && tier3 !== '未标注' && !tier3.startsWith('轨道');
      if (isSemanticTier3) {
        return `${langName} (${codecDisplay}) ${tier3}`;
      }
      return `${langName} (${codecDisplay})`;
    }
    return langName;
  }
}

