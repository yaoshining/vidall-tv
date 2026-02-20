import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';

// ─────────────────────────────────────────────
// 数据结构
// ─────────────────────────────────────────────

/** 单条轨道信息 */
export interface TrackInfo {
  index: number;
  type: 'video' | 'audio' | 'subtitle' | 'unknown';
  codec?: string;
  width?: number;
  height?: number;
  /** 实际帧率（非 x100） */
  frameRate?: number;
  bitrate?: number;
  sampleRate?: number;
  channelCount?: number;
  language?: string;
}

/** 视频媒体完整信息 */
export interface VideoInfo {
  url: string;
  durationMs: number;
  durationText: string;
  videoTracks: TrackInfo[];
  audioTracks: TrackInfo[];
  subtitleTracks: TrackInfo[];
  width?: number;
  height?: number;
  frameRate?: number;
  bitrate?: number;
  videoCodec?: string;
  success: boolean;
  errorMessage?: string;
}

// ─────────────────────────────────────────────
// 内部工具函数
// ─────────────────────────────────────────────

function formatDuration(ms: number): string {
  if (ms <= 0) {
    return '00:00:00';
  }
  const totalSeconds = Math.floor(ms / 1000);
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const s = totalSeconds % 60;
  return `${h.toString().padStart(2, '0')}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
}

function mapTrackType(type: number): 'video' | 'audio' | 'subtitle' | 'unknown' {
  switch (type) {
    case media.MediaType.MEDIA_TYPE_VID:
      return 'video';
    case media.MediaType.MEDIA_TYPE_AUD:
      return 'audio';
    case media.MediaType.MEDIA_TYPE_SUBTITLE:
      return 'subtitle';
    default:
      return 'unknown';
  }
}

function parseTrack(raw: media.MediaDescription): TrackInfo {
  const index = raw[media.MediaDescriptionKey.MD_KEY_TRACK_INDEX] as number ?? -1;
  const typeRaw = raw[media.MediaDescriptionKey.MD_KEY_TRACK_TYPE] as number ?? -1;
  const info: TrackInfo = { index, type: mapTrackType(typeRaw) };

  const codec = raw[media.MediaDescriptionKey.MD_KEY_CODEC_MIME] as string;
  if (codec) { info.codec = codec; }
  const width = raw[media.MediaDescriptionKey.MD_KEY_WIDTH] as number;
  if (width) { info.width = width; }
  const height = raw[media.MediaDescriptionKey.MD_KEY_HEIGHT] as number;
  if (height) { info.height = height; }
  // 帧率：部分情况返回 x100（如 2397），统一修正为实际值
  const frameRateRaw = raw[media.MediaDescriptionKey.MD_KEY_FRAME_RATE] as number;
  if (frameRateRaw) {
    info.frameRate = frameRateRaw > 200 ? Math.round(frameRateRaw / 100 * 100) / 100 : frameRateRaw;
  }
  const bitrate = raw[media.MediaDescriptionKey.MD_KEY_BITRATE] as number;
  if (bitrate) { info.bitrate = bitrate; }
  const sampleRate = raw[media.MediaDescriptionKey.MD_KEY_AUD_SAMPLE_RATE] as number;
  if (sampleRate) { info.sampleRate = sampleRate; }
  const channelCount = raw[media.MediaDescriptionKey.MD_KEY_AUD_CHANNEL_COUNT] as number;
  if (channelCount) { info.channelCount = channelCount; }
  const language = raw[media.MediaDescriptionKey.MD_KEY_LANGUAGE] as string;
  if (language) { info.language = language; }

  return info;
}

// ─────────────────────────────────────────────
// 核心工具类
// ─────────────────────────────────────────────

/**
 * 视频媒体信息抓取工具
 *
 * 原理：创建临时 AVPlayer，只走到 PREPARED 状态后调用 getTrackDescription()，
 * 拿到分辨率、时长、编码、音轨、字幕轨等信息后立即 release()，不真正播放。
 * Basic Auth 凭据直接嵌入 URL（http://user:pass@host/path）兼容 WebDAV 服务器。
 *
 * 使用示例：
 * const info = await VideoInfoUtil.fetch(url, { 'Authorization': 'Basic xxx' });
 */
export class VideoInfoUtil {
  /** 最大并发 AVPlayer 数量，超出时排队等待 */
  static readonly MAX_CONCURRENT = 2;
  private static runningCount: number = 0;
  private static waitQueue: Array<() => void> = [];

  private static next(): void {
    if (VideoInfoUtil.waitQueue.length > 0 && VideoInfoUtil.runningCount < VideoInfoUtil.MAX_CONCURRENT) {
      const fn = VideoInfoUtil.waitQueue.shift()!;
      VideoInfoUtil.runningCount++;
      fn();
    }
  }

  private static acquire(): Promise<void> {
    if (VideoInfoUtil.runningCount < VideoInfoUtil.MAX_CONCURRENT) {
      VideoInfoUtil.runningCount++;
      return Promise.resolve();
    }
    return new Promise<void>((resolve) => {
      VideoInfoUtil.waitQueue.push(resolve);
    });
  }

  private static release(): void {
    VideoInfoUtil.runningCount--;
    VideoInfoUtil.next();
  }

  /**
   * 对 URL 路径段做编码，保留 scheme://host:port，只编码各路径段
   * 避免中文、空格、[] 等字符导致 HTTP 400
   */
  private static encodeUrl(url: string): string {
    const schemeEnd = url.indexOf('://');
    if (schemeEnd === -1) { return url; }
    const afterScheme = url.indexOf('/', schemeEnd + 3);
    if (afterScheme === -1) { return url; }
    const origin = url.substring(0, afterScheme);
    const rawPath = url.substring(afterScheme);
    const segments = rawPath.split('/');
    const encodedSegments: string[] = [];
    for (const seg of segments) {
      if (seg === '') {
        encodedSegments.push('');
        continue;
      }
      try {
        const decoded = decodeURIComponent(seg);
        if (encodeURIComponent(decoded) === seg) {
          encodedSegments.push(seg);
        } else {
          encodedSegments.push(encodeURIComponent(decoded));
        }
      } catch (_) {
        encodedSegments.push(encodeURIComponent(seg));
      }
    }
    return origin + encodedSegments.join('/');
  }

  /**
   * 抓取远程视频的媒体信息
   * @param url        视频完整 URL
   * @param httpHeader 请求头，如 { 'Authorization': 'Basic xxx' }
   * @param timeoutMs  超时时间（毫秒），默认 20000
   */
  static async fetch(
    url: string,
    httpHeader?: Record<string, string>,
    timeoutMs: number = 20000
  ): Promise<VideoInfo> {
    await VideoInfoUtil.acquire();

    const encodedUrl = VideoInfoUtil.encodeUrl(url);
    console.info(`[VideoInfoUtil] 开始抓取 (并发=${VideoInfoUtil.runningCount}/${VideoInfoUtil.MAX_CONCURRENT}): ${encodedUrl}`);

    return new Promise<VideoInfo>((resolve) => {
      let avPlayer: media.AVPlayer | null = null;
      let settled = false;
      let lastErrorCode: number = 0;
      let lastErrorMsg: string = 'unknown';

      const done = (info: VideoInfo): void => {
        if (settled) { return; }
        settled = true;
        if (avPlayer !== null) {
          try { avPlayer.release(); } catch (_) {}
        }
        VideoInfoUtil.release();
        resolve(info);
      };

      const fail = (msg: string): void => {
        if (settled) { return; }
        console.error(`[VideoInfoUtil][ERROR] ${msg}`);
        done({
          url,
          durationMs: 0,
          durationText: '00:00:00',
          videoTracks: [],
          audioTracks: [],
          subtitleTracks: [],
          success: false,
          errorMessage: msg
        });
      };

      const timeoutId = setTimeout(() => {
        fail(`抓取超时（>${timeoutMs}ms）`);
      }, timeoutMs);

      media.createAVPlayer().then((player: media.AVPlayer) => {
        avPlayer = player;

        player.on('stateChange', async (state: string) => {
          if (settled) { return; }
          console.info(`[VideoInfoUtil] 状态: ${state}`);

          if (state === 'initialized') {
            player.prepare().catch((err: BusinessError) => {
              clearTimeout(timeoutId);
              fail(`prepare 失败: code=${err.code} msg=${err.message}`);
            });
          } else if (state === 'prepared') {
            clearTimeout(timeoutId);
            try {
              const durationMs = player.duration ?? 0;
              const rawTracks = await player.getTrackDescription();

              const videoTracks: TrackInfo[] = [];
              const audioTracks: TrackInfo[] = [];
              const subtitleTracks: TrackInfo[] = [];

              for (const raw of rawTracks) {
                const track = parseTrack(raw);
                if (track.type === 'video') {
                  videoTracks.push(track);
                } else if (track.type === 'audio') {
                  audioTracks.push(track);
                } else if (track.type === 'subtitle') {
                  subtitleTracks.push(track);
                }
              }

              const mainVideo = videoTracks.length > 0 ? videoTracks[0] : undefined;

              const info: VideoInfo = {
                url,
                durationMs,
                durationText: formatDuration(durationMs),
                videoTracks,
                audioTracks,
                subtitleTracks,
                width: mainVideo?.width,
                height: mainVideo?.height,
                frameRate: mainVideo?.frameRate,
                bitrate: mainVideo?.bitrate,
                videoCodec: mainVideo?.codec,
                success: true
              };

              console.info(
                `[VideoInfoUtil] 抓取成功 — ` +
                `时长=${info.durationText} | ` +
                `分辨率=${info.width ?? '?'}x${info.height ?? '?'} | ` +
                `编码=${info.videoCodec ?? '?'} | ` +
                `帧率=${info.frameRate ?? '?'}fps | ` +
                `码率=${info.bitrate !== undefined ? Math.round(info.bitrate / 1000) + 'kbps' : '?'} | ` +
                `视频轨=${videoTracks.length} 音轨=${audioTracks.length} 字幕轨=${subtitleTracks.length}`
              );

              audioTracks.forEach((t, i) => {
                console.info(
                  `[VideoInfoUtil]   音轨[${i}] codec=${t.codec ?? '?'} ` +
                  `${t.sampleRate ?? '?'}Hz ${t.channelCount ?? '?'}ch 语言=${t.language ?? '?'}`
                );
              });

              subtitleTracks.forEach((t, i) => {
                console.info(
                  `[VideoInfoUtil]   字幕轨[${i}] codec=${t.codec ?? '?'} 语言=${t.language ?? '?'}`
                );
              });

              done(info);
            } catch (err) {
              fail(`getTrackDescription 失败: ${JSON.stringify(err)}`);
            }
          } else if (state === 'error') {
            clearTimeout(timeoutId);
            // code=0 msg=unknown 通常意味着 on('error') 未触发，AVPlayer 在 prepare 阶段
            // 因不支持的编解码（如 AC-3/Dolby Digital 音轨）直接进入 error 状态
            const reason = lastErrorCode === 0
              ? '可能原因：编解码格式不受支持（如 AC-3/DD 音轨），AVPlayer 无法 prepare'
              : `code=${lastErrorCode} msg=${lastErrorMsg}`;
            fail(`AVPlayer 进入 error 状态: ${reason}`);
          }
        });

        player.on('error', (err: BusinessError) => {
          clearTimeout(timeoutId);
          lastErrorCode = err.code;
          lastErrorMsg = err.message;
          fail(`AVPlayer error: code=${err.code} msg=${err.message}`);
        });

        // 使用 setMediaSource 传递 Authorization header，比嵌入 URL 更可靠
        const playbackStrategy: media.PlaybackStrategy = {
          preferredWidth: 0,
          preferredHeight: 0,
          preferredBufferDuration: 3,
          preferredHdr: false
        };
        const mediaSource = media.createMediaSourceWithUrl(encodedUrl,
          httpHeader ?? ({} as Record<string, string>));
        player.setMediaSource(mediaSource, playbackStrategy);
      }).catch((err: BusinessError) => {
        clearTimeout(timeoutId);
        fail(`createAVPlayer 失败: code=${err.code} msg=${err.message}`);
      });
    });
  }
}



