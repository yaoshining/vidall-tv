/**
 * VideoInfoUtil.ets
 *
 * 统一的视频轨道信息获取工具。
 *
 * 路由逻辑：
 *   - smb:// URL → FfprobeUtil.probe()（AVPlayer 不支持 SMB 协议）
 *   - http/https URL → AVPlayer prepare 路径（原有机制，保持与 VideoPlayerUtil 一致）
 *
 * SMB 认证说明：
 *   libsmb2 / FFmpeg 通过 URL 内嵌凭据识别 SMB 鉴权：
 *     smb://username:password@host/share/path
 *   调用方（如 SMBAdapter）负责将用户名密码拼入 URL；
 *   本工具不额外处理 SMB 凭据，直接将 URL 透传给 FfprobeUtil。
 *
 * 返回类型：
 *   VideoInfo = FfprobeResult，包含 videoTracks / audioTracks / subtitleTracks 等字段，
 *   与 VideoScannerUtil（WebDAV 路径）保持完全一致。
 */

import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FfprobeUtil, FfprobeResult, FfprobeTrack } from './FfprobeUtil';

/**
 * VideoInfo 是 FfprobeResult 的类型别名。
 * 两条路径（AVPlayer 与 SMB）均返回相同结构，调用方无需区分来源。
 */
export type VideoInfo = FfprobeResult;

// 重新导出 FfprobeTrack，方便调用方访问轨道类型
export { FfprobeTrack } from './FfprobeUtil';

// ─────────────────────────────────────────────
// 内部辅助函数
// ─────────────────────────────────────────────

/** 毫秒 → HH:MM:SS */
function formatDuration(ms: number): string {
  if (ms <= 0) { return '00:00:00'; }
  const totalSeconds = Math.floor(ms / 1000);
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const s = totalSeconds % 60;
  return `${h.toString().padStart(2, '0')}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
}

/**
 * MIME 类型 → 简短 codec 名（e.g. "video/hevc" → "hevc"，"audio/mp4a-latm" → "aac"）
 */
function mimeToCodecName(mime: string): string {
  if (!mime) { return ''; }
  const slash: number = mime.indexOf('/');
  if (slash < 0) { return mime.toLowerCase(); }
  const sub: string = mime.substring(slash + 1).toLowerCase();
  if (sub === 'avc' || sub === 'h264') { return 'h264'; }
  if (sub === 'hevc' || sub === 'h265') { return 'hevc'; }
  if (sub === 'mp4a-latm' || sub === 'mp4a') { return 'aac'; }
  return sub;
}

/**
 * 对 URL 路径段做安全编码（与 VideoPlayerUtil 保持一致）。
 */
function encodeUrlPath(url: string): string {
  const protocolEnd: number = url.indexOf('://');
  if (protocolEnd < 0) { return url; }
  const afterProtocol: string = url.substring(protocolEnd + 3);
  const slashIdx: number = afterProtocol.indexOf('/');
  if (slashIdx < 0) { return url; }
  const hostPart: string = url.substring(0, protocolEnd + 3 + slashIdx);
  const pathAndQuery: string = afterProtocol.substring(slashIdx);
  const queryIdx: number = pathAndQuery.indexOf('?');
  const pathOnly: string = queryIdx >= 0 ? pathAndQuery.substring(0, queryIdx) : pathAndQuery;
  const query: string = queryIdx >= 0 ? pathAndQuery.substring(queryIdx) : '';
  const encodedPath: string = pathOnly
    .split('/')
    .map((seg: string): string => {
      if (seg.length === 0) { return ''; }
      let decoded: string = seg;
      try { decoded = decodeURIComponent(seg); } catch { decoded = seg; }
      return encodeURIComponent(decoded);
    })
    .join('/');
  return hostPart + encodedPath + query;
}

function buildErrorResult(errorMessage: string): VideoInfo {
  const result: VideoInfo = {
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
 * 将 AVPlayer.getTrackDescription() 返回的描述转换为 FfprobeTrack 列表。
 */
function buildTracksFromDescs(
  descs: media.MediaDescription[],
  videoOut: FfprobeTrack[],
  audioOut: FfprobeTrack[],
  subtitleOut: FfprobeTrack[]
): void {
  for (const desc of descs) {
    const rawType: number = desc[media.MediaDescriptionKey.MD_KEY_TRACK_TYPE] as number;
    const mime: string = (desc[media.MediaDescriptionKey.MD_KEY_CODEC_MIME] as string) ?? '';
    const lang: string = (desc[media.MediaDescriptionKey.MD_KEY_LANGUAGE] as string) ?? '';
    const index: number = (desc[media.MediaDescriptionKey.MD_KEY_TRACK_INDEX] as number) ?? 0;
    const codecName: string = mimeToCodecName(mime);

    if (rawType === media.MediaType.MEDIA_TYPE_VID) {
      const track: FfprobeTrack = {
        index,
        type: 'video',
        codecName,
        codecLongName: codecName,
        language: lang,
        width: desc[media.MediaDescriptionKey.MD_KEY_WIDTH] as number | undefined,
        height: desc[media.MediaDescriptionKey.MD_KEY_HEIGHT] as number | undefined,
        bitrate: desc[media.MediaDescriptionKey.MD_KEY_BITRATE] as number | undefined,
      };
      videoOut.push(track);
    } else if (rawType === media.MediaType.MEDIA_TYPE_AUD) {
      const track: FfprobeTrack = {
        index,
        type: 'audio',
        codecName,
        codecLongName: codecName,
        language: lang,
        channels: desc[media.MediaDescriptionKey.MD_KEY_CHANNEL_COUNT] as number | undefined,
        sampleRate: desc[media.MediaDescriptionKey.MD_KEY_SAMPLE_RATE] as number | undefined,
        bitrate: desc[media.MediaDescriptionKey.MD_KEY_BITRATE] as number | undefined,
      };
      audioOut.push(track);
    } else if (rawType === media.MediaType.MEDIA_TYPE_SUBTITLE) {
      const track: FfprobeTrack = {
        index,
        type: 'subtitle',
        codecName,
        codecLongName: codecName,
        language: lang,
      };
      subtitleOut.push(track);
    }
  }
}

/**
 * 使用 AVPlayer prepare 路径探测 HTTP/HTTPS 视频信息。
 * 与 VideoPlayerUtil.checkSupport 同源，额外在 prepared 状态提取 duration + 轨道描述。
 */
function probeViaAvPlayer(
  url: string,
  headers: Record<string, string> | undefined,
  timeoutMs: number
): Promise<VideoInfo> {
  return media.createAVPlayer().then((player: media.AVPlayer) => {
    return new Promise<VideoInfo>((resolve) => {
      let settled: boolean = false;

      const finish = (r: VideoInfo): void => {
        if (settled) { return; }
        settled = true;
        clearTimeout(timer);
        player.release().catch(() => {});
        resolve(r);
      };

      const timer: number = setTimeout(() => {
        console.warn(`[VideoInfoUtil] AVPlayer prepare 超时 ${timeoutMs}ms`);
        finish(buildErrorResult(`AVPlayer prepare 超时（${timeoutMs}ms）`));
      }, timeoutMs);

      // error 事件：携带详细 code，优先于 stateChange('error')
      player.on('error', (err: BusinessError) => {
        console.error(`[VideoInfoUtil] AVPlayer error: code=${err.code} msg=${err.message}`);
        finish(buildErrorResult(`AVPlayer error ${err.code}: ${err.message}`));
      });

      // stateChange 驱动：initialized → prepare → prepared → 提取信息
      player.on('stateChange', (state: media.AVPlayerState) => {
        console.info(`[VideoInfoUtil] AVPlayer stateChange: ${state}`);
        if (state === 'initialized') {
          player.prepare().catch((e: BusinessError) => {
            finish(buildErrorResult(`AVPlayer prepare 失败: ${e.message}`));
          });
        } else if (state === 'prepared') {
          const durationMs: number = player.duration > 0 ? player.duration : 0;

          // 提取轨道描述；失败时仍返回 success=true（时长已知）
          const doExtract = async (): Promise<void> => {
            const videoTracks: FfprobeTrack[] = [];
            const audioTracks: FfprobeTrack[] = [];
            const subtitleTracks: FfprobeTrack[] = [];
            try {
              const descs: media.MediaDescription[] = await player.getTrackDescription();
              buildTracksFromDescs(descs, videoTracks, audioTracks, subtitleTracks);
            } catch {
              console.warn('[VideoInfoUtil] getTrackDescription 失败，轨道列表为空');
            }
            console.info(
              `[VideoInfoUtil] AVPlayer 探测完成 — 时长=${formatDuration(durationMs)} | ` +
              `视频轨=${videoTracks.length} 音轨=${audioTracks.length} 字幕轨=${subtitleTracks.length}`
            );
            const result: VideoInfo = {
              success: true,
              durationMs,
              durationText: formatDuration(durationMs),
              videoTracks,
              audioTracks,
              subtitleTracks,
            };
            finish(result);
          };
          doExtract().catch(() => {
            finish(buildErrorResult('轨道提取意外失败'));
          });
        } else if (state === 'error') {
          // error 事件已处理，此处兜底
          finish(buildErrorResult('AVPlayer 进入 error 状态'));
        }
      });

      // 设置媒体源（触发 stateChange → initialized）
      const encoded: string = encodeUrlPath(url);
      if (headers) {
        const ms: media.MediaSource = media.createMediaSourceWithUrl(encoded, headers);
        player.setMediaSource(ms).catch((e: BusinessError) => {
          finish(buildErrorResult(`setMediaSource 失败: ${e.message}`));
        });
      } else {
        player.url = encoded;
      }
    });
  }).catch((e: BusinessError) => {
    console.error(`[VideoInfoUtil] createAVPlayer 失败: ${e.code} ${e.message}`);
    return buildErrorResult(`createAVPlayer 失败: ${e.message}`);
  });
}

// ─────────────────────────────────────────────
// 公开工具类
// ─────────────────────────────────────────────

export class VideoInfoUtil {
  /**
   * 获取视频轨道信息（分辨率、编码、音轨列表、字幕列表等）。
   *
   * @param url       视频 URL
   *   - HTTP/HTTPS：如 "http://192.168.1.1:5005/dav/movie.mkv"（走 AVPlayer prepare）
   *   - SMB：如 "smb://user:pass@192.168.1.100/Movies/movie.mkv"（走 FfprobeUtil）
   * @param headers   HTTP 请求头，仅对 http/https 生效；SMB 路径忽略此参数
   * @param timeoutMs 探测超时时间（毫秒），默认 20000
   * @returns         VideoInfo（即 FfprobeResult），包含 success 标志与轨道列表
   */
  static async getVideoInfo(
    url: string,
    headers?: Record<string, string>,
    timeoutMs: number = 20000
  ): Promise<VideoInfo> {
    if (url.startsWith('smb://')) {
      // SMB：AVPlayer 不支持 smb:// 协议，走 FfprobeUtil
      // 日志脱敏：smb://user:pass@host → smb://***@host
      console.info(`[VideoInfoUtil] SMB URL → FfprobeUtil: ${VideoInfoUtil.maskSmbCredentials(url)}`);
      return FfprobeUtil.probe(url, undefined, timeoutMs);
    }

    // HTTP/HTTPS：保持原有 AVPlayer prepare 路径
    console.info('[VideoInfoUtil] HTTP/HTTPS URL → AVPlayer prepare');
    return probeViaAvPlayer(url, headers, timeoutMs);
  }

  /**
   * 对日志输出中的 SMB URL 做凭据脱敏：
   *   smb://user:secret@host/share → smb://***@host/share
   */
  private static maskSmbCredentials(url: string): string {
    const atIdx: number = url.indexOf('@');
    if (atIdx < 0) { return url; }
    const protoEnd: number = url.indexOf('://');
    if (protoEnd < 0 || atIdx < protoEnd) { return url; }
    const proto: string = url.substring(0, protoEnd + 3); // "smb://"
    const rest: string = url.substring(atIdx);             // "@host/share/..."
    return `${proto}***${rest}`;
  }
}
