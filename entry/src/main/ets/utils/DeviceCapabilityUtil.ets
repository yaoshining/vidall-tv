import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';

// ─────────────────────────────────────────────
// 常量定义（ArkTS 不支持 as const，用 namespace 替代）
// ─────────────────────────────────────────────

/** 视频编码格式 MIME */
export namespace VIDEO_CODEC {
  export const H264  = 'video/avc';
  export const H265  = 'video/hevc';
  export const AV1   = 'video/av01';
  export const VP9   = 'video/x-vnd.on2.vp9';
  export const VP8   = 'video/x-vnd.on2.vp8';
  export const MPEG4 = 'video/mp4v-es';
  export const MPEG2 = 'video/mpeg2';
  export const VC1   = 'video/wvc1';
  export const DIVX  = 'video/divx';
}

/** 音频编码格式 MIME */
export namespace AUDIO_CODEC {
  export const AAC    = 'audio/mp4a-latm';
  export const AC3    = 'audio/ac3';
  export const EAC3   = 'audio/eac3';
  export const DTS    = 'audio/vnd.dts';
  export const DTSHD  = 'audio/vnd.dts.hd';
  export const TRUEHD = 'audio/truehd';
  export const MP3    = 'audio/mpeg';
  export const FLAC   = 'audio/flac';
  export const VORBIS = 'audio/vorbis';
  export const OPUS   = 'audio/opus';
  export const PCM    = 'audio/raw';
}

// ─────────────────────────────────────────────
// 格式支持矩阵（基于 HarmonyOS AVPlayer 实测）
// ─────────────────────────────────────────────

const AVPLAYER_SUPPORTED_VIDEO = new Set<string>([
  VIDEO_CODEC.H264,
  VIDEO_CODEC.H265,
  VIDEO_CODEC.MPEG4,
  VIDEO_CODEC.VP8,
  VIDEO_CODEC.VP9,
]);

const AVPLAYER_SUPPORTED_AUDIO = new Set<string>([
  AUDIO_CODEC.AAC,
  AUDIO_CODEC.MP3,
  AUDIO_CODEC.FLAC,
  AUDIO_CODEC.VORBIS,
  AUDIO_CODEC.OPUS,
  AUDIO_CODEC.PCM,
]);

const AVPLAYER_UNSUPPORTED_AUDIO = new Set<string>([
  AUDIO_CODEC.AC3,
  AUDIO_CODEC.EAC3,
  AUDIO_CODEC.DTS,
  AUDIO_CODEC.DTSHD,
  AUDIO_CODEC.TRUEHD,
]);

// ─────────────────────────────────────────────
// 从文件名推断格式的规则
// ─────────────────────────────────────────────

const UNSUPPORTED_AUDIO_KEYWORDS: string[] = [
  'DD.5.1', 'DD5.1', 'AC3', 'AC-3', 'Dolby', 'DTS', 'DTS-HD', 'DTSHD',
  'TrueHD', 'TRUEHD', 'Atmos', 'DTS-MA', 'DTS-X',
];

/** 视频编码关键词条目 */
interface VideoCodecKeywordEntry {
  keywords: string[];
  mime: string;
}

const VIDEO_CODEC_KEYWORDS: VideoCodecKeywordEntry[] = [
  { keywords: ['H.265', 'H265', 'HEVC', 'X265', 'x265'], mime: VIDEO_CODEC.H265  },
  { keywords: ['H.264', 'H264', 'AVC', 'X264', 'x264'],  mime: VIDEO_CODEC.H264  },
  { keywords: ['AV1', 'AV01'],                            mime: VIDEO_CODEC.AV1   },
  { keywords: ['VP9'],                                    mime: VIDEO_CODEC.VP9   },
  { keywords: ['VP8'],                                    mime: VIDEO_CODEC.VP8   },
  { keywords: ['MPEG4', 'XVID', 'DIVX'],                  mime: VIDEO_CODEC.MPEG4 },
];

// 用于 logAllCodecSupport 遍历的列表
interface CodecEntry {
  key: string;
  mime: string;
}

const ALL_VIDEO_CODECS: CodecEntry[] = [
  { key: 'H264',  mime: VIDEO_CODEC.H264  },
  { key: 'H265',  mime: VIDEO_CODEC.H265  },
  { key: 'AV1',   mime: VIDEO_CODEC.AV1   },
  { key: 'VP9',   mime: VIDEO_CODEC.VP9   },
  { key: 'VP8',   mime: VIDEO_CODEC.VP8   },
  { key: 'MPEG4', mime: VIDEO_CODEC.MPEG4 },
  { key: 'MPEG2', mime: VIDEO_CODEC.MPEG2 },
  { key: 'VC1',   mime: VIDEO_CODEC.VC1   },
  { key: 'DIVX',  mime: VIDEO_CODEC.DIVX  },
];

const ALL_AUDIO_CODECS: CodecEntry[] = [
  { key: 'AAC',    mime: AUDIO_CODEC.AAC    },
  { key: 'AC3',    mime: AUDIO_CODEC.AC3    },
  { key: 'EAC3',   mime: AUDIO_CODEC.EAC3   },
  { key: 'DTS',    mime: AUDIO_CODEC.DTS    },
  { key: 'DTSHD',  mime: AUDIO_CODEC.DTSHD  },
  { key: 'TRUEHD', mime: AUDIO_CODEC.TRUEHD },
  { key: 'MP3',    mime: AUDIO_CODEC.MP3    },
  { key: 'FLAC',   mime: AUDIO_CODEC.FLAC   },
  { key: 'VORBIS', mime: AUDIO_CODEC.VORBIS },
  { key: 'OPUS',   mime: AUDIO_CODEC.OPUS   },
  { key: 'PCM',    mime: AUDIO_CODEC.PCM    },
];

// ─────────────────────────────────────────────
// 对外数据结构
// ─────────────────────────────────────────────

/** 单个编解码器的支持情况 */
export interface CodecSupportResult {
  mime: string;
  supported: boolean;
  note: string;
}

/** 文件播放支持评估结果 */
export interface PlaybackSupportResult {
  likelySupported: boolean;
  guessedVideoCodec: string;
  hasUnsupportedAudio: boolean;
  matchedUnsupportedKeywords: string[];
  containerExt: string;
  message: string;
}

/** ijkplayer 硬件解码支持结果 */
export interface IjkHwDecodeSupport {
  h264: boolean;
  h265: boolean;
}

// ─────────────────────────────────────────────
// 工具类
// ─────────────────────────────────────────────

export class DeviceCapabilityUtil {
  private static readonly TAG = '[DeviceCapability]';

  // ── 1. 静态规则查询 ──────────────────────────────────────────────

  static isVideoCodecSupported(mime: string): CodecSupportResult {
    const supported = AVPLAYER_SUPPORTED_VIDEO.has(mime);
    const result: CodecSupportResult = {
      mime,
      supported,
      note: supported
        ? 'AVPlayer 已知支持'
        : (mime === VIDEO_CODEC.AV1
          ? 'AV1 需要 API 12+ 且设备支持硬解'
          : 'AVPlayer 不支持或未知')
    };
    return result;
  }

  static isAudioCodecSupported(mime: string): CodecSupportResult {
    if (AVPLAYER_UNSUPPORTED_AUDIO.has(mime)) {
      const r: CodecSupportResult = {
        mime,
        supported: false,
        note: 'AVPlayer 明确不支持（AC-3/DTS/TrueHD 需 FFmpeg）'
      };
      return r;
    }
    const supported = AVPLAYER_SUPPORTED_AUDIO.has(mime);
    const result: CodecSupportResult = {
      mime,
      supported,
      note: supported ? 'AVPlayer 已知支持' : '未在已知列表中，实际支持情况未知'
    };
    return result;
  }

  static logAllCodecSupport(): void {
    console.info(`${DeviceCapabilityUtil.TAG} ===== AVPlayer 编解码支持矩阵 =====`);
    console.info(`${DeviceCapabilityUtil.TAG} --- 视频编码 ---`);
    for (const entry of ALL_VIDEO_CODECS) {
      const r = DeviceCapabilityUtil.isVideoCodecSupported(entry.mime);
      console.info(
        `${DeviceCapabilityUtil.TAG}   ${entry.key} (${entry.mime}): ` +
        `${r.supported ? '✅ 支持' : '❌ 不支持'} — ${r.note}`
      );
    }
    console.info(`${DeviceCapabilityUtil.TAG} --- 音频编码 ---`);
    for (const entry of ALL_AUDIO_CODECS) {
      const r = DeviceCapabilityUtil.isAudioCodecSupported(entry.mime);
      console.info(
        `${DeviceCapabilityUtil.TAG}   ${entry.key} (${entry.mime}): ` +
        `${r.supported ? '✅ 支持' : '❌ 不支持'} — ${r.note}`
      );
    }
    console.info(`${DeviceCapabilityUtil.TAG} =====================================`);
  }

  // ── 2. 从文件名推断播放可行性 ────────────────────────────────────

  static assessFilePlayback(fileName: string): PlaybackSupportResult {
    const upper = fileName.toUpperCase();

    const dotIdx = fileName.lastIndexOf('.');
    const containerExt = dotIdx >= 0 ? fileName.substring(dotIdx).toLowerCase() : '';

    let guessedVideoCodec = '';
    for (const entry of VIDEO_CODEC_KEYWORDS) {
      let matched = false;
      for (const kw of entry.keywords) {
        if (upper.includes(kw.toUpperCase())) {
          matched = true;
          break;
        }
      }
      if (matched) {
        guessedVideoCodec = entry.mime;
        break;
      }
    }

    const matchedUnsupportedKeywords: string[] = [];
    for (const kw of UNSUPPORTED_AUDIO_KEYWORDS) {
      if (upper.includes(kw.toUpperCase())) {
        matchedUnsupportedKeywords.push(kw);
      }
    }
    const hasUnsupportedAudio = matchedUnsupportedKeywords.length > 0;

    const videoOk = guessedVideoCodec === '' || AVPLAYER_SUPPORTED_VIDEO.has(guessedVideoCodec);
    const likelySupported = videoOk && !hasUnsupportedAudio;

    let message: string;
    if (likelySupported) {
      message = `可能支持播放（视频=${guessedVideoCodec || '未知'}，音频无已知问题）`;
    } else {
      const reasons: string[] = [];
      if (!videoOk) {
        reasons.push(`视频编码 ${guessedVideoCodec} 不支持`);
      }
      if (hasUnsupportedAudio) {
        reasons.push(`音频包含不支持格式（${matchedUnsupportedKeywords.join(', ')}）`);
      }
      message = `AVPlayer 可能无法播放：${reasons.join('；')}`;
    }

    console.info(
      `${DeviceCapabilityUtil.TAG} [评估] ${fileName} | ` +
      `容器=${containerExt} 视频=${guessedVideoCodec || '未知'} ` +
      `不支持音频=${hasUnsupportedAudio} | ` +
      `结论=${likelySupported ? '✅ 可能支持' : '❌ 可能不支持'}`
    );

    const result: PlaybackSupportResult = {
      likelySupported,
      guessedVideoCodec,
      hasUnsupportedAudio,
      matchedUnsupportedKeywords,
      containerExt,
      message
    };
    return result;
  }

  // ── 3. 动态探测（实际尝试 prepare）──────────────────────────────

  static async probePlayable(
    url: string,
    httpHeader?: Record<string, string>,
    timeoutMs: number = 15000
  ): Promise<boolean> {
    console.info(`${DeviceCapabilityUtil.TAG} [动态探测] 开始: ${url}`);

    return new Promise<boolean>((resolve) => {
      let avPlayer: media.AVPlayer | null = null;
      let settled = false;

      const done = (result: boolean, reason: string): void => {
        if (settled) { return; }
        settled = true;
        if (avPlayer !== null) {
          try { avPlayer.release(); } catch (_) {}
        }
        console.info(
          `${DeviceCapabilityUtil.TAG} [动态探测] 结果=${result ? '✅ 可播放' : '❌ 不可播放'} 原因=${reason}`
        );
        resolve(result);
      };

      const timeoutId = setTimeout(() => {
        done(false, `超时（>${timeoutMs}ms）`);
      }, timeoutMs);

      media.createAVPlayer().then((player: media.AVPlayer) => {
        avPlayer = player;

        player.on('stateChange', (state: string) => {
          if (settled) { return; }
          if (state === 'initialized') {
            player.prepare().catch((err: BusinessError) => {
              clearTimeout(timeoutId);
              done(false, `prepare 失败: code=${err.code}`);
            });
          } else if (state === 'prepared') {
            clearTimeout(timeoutId);
            done(true, 'prepare 成功');
          } else if (state === 'error') {
            clearTimeout(timeoutId);
            done(false, 'AVPlayer 进入 error 状态');
          }
        });

        player.on('error', (err: BusinessError) => {
          clearTimeout(timeoutId);
          done(false, `error 事件: code=${err.code} msg=${err.message}`);
        });

        const playbackStrategy: media.PlaybackStrategy = {
          preferredWidth: 0,
          preferredHeight: 0,
          preferredBufferDuration: 3,
          preferredHdr: false
        };
        const header = httpHeader ?? ({} as Record<string, string>);
        const mediaSource = media.createMediaSourceWithUrl(url, header);
        player.setMediaSource(mediaSource, playbackStrategy);
      }).catch((err: BusinessError) => {
        clearTimeout(timeoutId);
        done(false, `createAVPlayer 失败: code=${err.code}`);
      });
    });
  }

  // ── 4. ijkplayer 硬件解码可用性查询 ─────────────────────────────

  private static _ijkHwDecodeH264: boolean | undefined = undefined;
  private static _ijkHwDecodeH265: boolean | undefined = undefined;

  /**
   * 查询设备是否支持 H264/H265 硬件解码（供 IjkPlayerAdapter 使用）。
   * 结果缓存，整个 App 生命周期只查询一次。
   *
   * 注意：鸿蒙 ArkTS 层暂无公开的 getMediaCapability API（该能力在 Native C 层），
   * 当前保守返回 false（全部软解），待官方开放 ArkTS 接口后可补充实现。
   */
  static async checkIjkHardwareDecodeSupport(): Promise<IjkHwDecodeSupport> {
    if (DeviceCapabilityUtil._ijkHwDecodeH264 !== undefined &&
        DeviceCapabilityUtil._ijkHwDecodeH265 !== undefined) {
      const cached: IjkHwDecodeSupport = {
        h264: DeviceCapabilityUtil._ijkHwDecodeH264,
        h265: DeviceCapabilityUtil._ijkHwDecodeH265
      };
      return cached;
    }

    // 鸿蒙 ArkTS 层无公开 getMediaCapability，保守返回软解
    // 如后续官方开放 API，在此处补充动态查询逻辑
    const h264 = false;
    const h265 = false;

    DeviceCapabilityUtil._ijkHwDecodeH264 = h264;
    DeviceCapabilityUtil._ijkHwDecodeH265 = h265;

    console.info(
      `${DeviceCapabilityUtil.TAG} 硬件解码查询: H264=${h264 ? '✅' : '❌(软解)'} ` +
      `H265=${h265 ? '✅' : '❌(软解)'}`
    );

    const result: IjkHwDecodeSupport = { h264, h265 };
    return result;
  }
}
