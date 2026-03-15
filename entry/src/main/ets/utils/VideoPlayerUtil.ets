// VideoPlayerUtil.ets — ArkTS 兼容版
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';

// ─────────────────────────────────────────────
// 类型定义
// ─────────────────────────────────────────────

/** 格式验证结果 */
export interface VideoSupportResult {
  /** 是否支持播放 */
  supported: boolean;
  /**
   * 不支持的原因（仅 supported=false 时有值）
   * 'AC3_NOT_SUPPORTED' | 'DTS_NOT_SUPPORTED' | 'FORMAT_NOT_SUPPORTED'
   * | 'NETWORK_ERROR' | 'TIMEOUT' | 'CREATE_FAILED' | 'PREPARE_ERROR' | 'INVALID_PARAM'
   */
  reason?: string;
  /** AVPlayer error code */
  errorCode?: number;
  /** 详细错误信息 */
  errorMessage?: string;
}

/**
 * 传入 AVPlayer 支持的媒体源参数（三选一）
 *
 * ⚠️ 注意：请勿把正在被播放器使用的 mediaSource / fdSrc 传入此接口，
 *    checkSupport 会内部创建独立的 AVPlayer 实例，与播放器完全隔离。
 *    mediaSource 模式请传入 url + headers，由工具内部自行创建 MediaSource。
 */
export interface VideoSourceParam {
  /** 网络或本地 URI，如 http://host/path */
  url?: string;
  /** 文件描述符（沙箱内文件），适用于本地播放验证 */
  fdSrc?: media.AVFileDescriptor;
  /**
   * HTTP 请求头，仅 url 模式有效
   * 工具内部会用 media.createMediaSourceWithUrl(url, headers) 创建独立 MediaSource
   */
  headers?: Record<string, string>;
}

// ─────────────────────────────────────────────
// 常量
// ─────────────────────────────────────────────

const PREPARE_TIMEOUT_MS = 15000;

// ─────────────────────────────────────────────
// 内部辅助函数（模块级，避免类外成员访问问题）
// ─────────────────────────────────────────────

function classifyError(code: number, message: string): string {
  const lower = message.toLowerCase();
  if (lower.includes('ac3') || lower.includes('ac-3') || lower.includes('dolby')) {
    return 'AC3_NOT_SUPPORTED';
  }
  if (lower.includes('eac3') || lower.includes('e-ac')) {
    return 'AC3_NOT_SUPPORTED';
  }
  if (lower.includes('dts')) {
    return 'DTS_NOT_SUPPORTED';
  }
  if (code === 5400100 || lower.includes('network') || lower.includes('connection')) {
    return 'NETWORK_ERROR';
  }
  if (code === 5400106 || lower.includes('format') || lower.includes('unsupported')) {
    return 'FORMAT_NOT_SUPPORTED';
  }
  return 'PREPARE_ERROR';
}

function encodeUrlPath(url: string): string {
  const protocolEnd = url.indexOf('://');
  if (protocolEnd < 0) {
    return url;
  }
  const afterProtocol = url.substring(protocolEnd + 3);
  const slashIdx = afterProtocol.indexOf('/');
  if (slashIdx < 0) {
    return url;
  }
  const hostPart = url.substring(0, protocolEnd + 3 + slashIdx);
  const pathAndQuery = afterProtocol.substring(slashIdx);
  const queryIdx = pathAndQuery.indexOf('?');
  const pathOnly = queryIdx >= 0 ? pathAndQuery.substring(0, queryIdx) : pathAndQuery;
  const query = queryIdx >= 0 ? pathAndQuery.substring(queryIdx) : '';

  const encodedPath = pathOnly
    .split('/')
    .map((seg: string): string => {
      if (seg.length === 0) {
        return '';
      }
      let decoded = seg;
      try {
        decoded = decodeURIComponent(seg);
      } catch {
        decoded = seg;
      }
      return encodeURIComponent(decoded);
    })
    .join('/');

  return hostPart + encodedPath + query;
}

// ─────────────────────────────────────────────
// 核心工具类
// ─────────────────────────────────────────────

/**
 * 视频播放格式支持验证工具
 *
 * 原理：创建独立的临时 AVPlayer，走完整的 idle → initialized → prepared 流程：
 *   - 成功进入 prepared → supported = true，立即 release
 *   - 进入 error（AC-3/DTS/格式不支持）→ supported = false
 *   - 超过 PREPARE_TIMEOUT_MS → TIMEOUT
 *
 * ⚠️ 此工具创建的 AVPlayer 与播放器实例完全独立，不会干扰正常播放。
 *    不要把正在被使用的 mediaSource 对象传入，请改用 url + headers 模式。
 *
 * 使用示例：
 * ```ts
 * // URL + headers 模式（推荐，工具内部自动创建 MediaSource）
 * const r = await VideoPlayerUtil.checkSupport({
 *   url: 'http://192.168.1.1:5005/dav/movie.mkv',
 *   headers: { Authorization: 'Basic xxx' }
 * });
 *
 * // fdSrc 模式（本地文件）
 * const r = await VideoPlayerUtil.checkSupport({ fdSrc: { fd: file.fd } });
 *
 * if (!r.supported) console.warn('不支持:', r.reason, r.errorMessage);
 * ```
 */
export class VideoPlayerUtil {

  /**
   * 异步验证媒体源是否能被 AVPlayer 正常 prepare
   * @param source url / fdSrc 二选一；url 模式可附带 headers
   */
  static checkSupport(source: VideoSourceParam): Promise<VideoSupportResult> {
    if (!source.url && !source.fdSrc) {
      const r: VideoSupportResult = {
        supported: false,
        reason: 'INVALID_PARAM',
        errorMessage: '必须提供 url 或 fdSrc'
      };
      return Promise.resolve(r);
    }
    return VideoPlayerUtil.doCheck(source);
  }

  /**
   * 快速静态检查（扩展名判断，无需 AVPlayer）
   * @returns true=已知支持，false=已知不支持，undefined=不确定
   */
  static quickCheck(url: string): boolean | undefined {
    const lower = url.toLowerCase();
    const lastDot = lower.lastIndexOf('.');
    if (lastDot < 0) {
      return undefined;
    }
    const ext = lower.substring(lastDot);
    if (ext === '.ac3' || ext === '.eac3' || ext === '.dts' || ext === '.truehd') {
      return false;
    }
    if (ext === '.mp4' || ext === '.m4v' || ext === '.mov' ||
      ext === '.mkv' ||
      ext === '.ts' || ext === '.m2ts' || ext === '.mts' ||
      ext === '.m4a' || ext === '.aac' || ext === '.mp3' ||
      ext === '.ogg' || ext === '.oga' ||
      ext === '.wav' || ext === '.flac' || ext === '.amr') {
      return true;
    }
    return undefined;
  }

  // ─── 私有实现 ─────────────────────────────

  private static async doCheck(source: VideoSourceParam): Promise<VideoSupportResult> {
    let player: media.AVPlayer;
    try {
      player = await media.createAVPlayer();
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[VideoPlayerUtil] createAVPlayer 失败: ${err.code} ${err.message}`);
      const r: VideoSupportResult = {
        supported: false,
        reason: 'CREATE_FAILED',
        errorCode: err.code,
        errorMessage: err.message
      };
      return r;
    }

    return new Promise<VideoSupportResult>((resolve) => {
      let settled = false;

      const finish = (r: VideoSupportResult): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        player.release().catch(() => {});
        resolve(r);
      };

      const timer = setTimeout(() => {
        console.warn(`[VideoPlayerUtil] prepare 超时 ${PREPARE_TIMEOUT_MS}ms`);
        const r: VideoSupportResult = {
          supported: false,
          reason: 'TIMEOUT',
          errorMessage: `prepare 超时（${PREPARE_TIMEOUT_MS}ms）`
        };
        finish(r);
      }, PREPARE_TIMEOUT_MS);

      // error 事件优先于 stateChange('error')，携带详细 code
      player.on('error', (err: BusinessError) => {
        console.error(`[VideoPlayerUtil] error: code=${err.code} msg=${err.message}`);
        const r: VideoSupportResult = {
          supported: false,
          reason: classifyError(err.code, err.message),
          errorCode: err.code,
          errorMessage: err.message
        };
        finish(r);
      });

      // stateChange：initialized → prepare；prepared → 成功；error → 失败
      player.on('stateChange', (state: media.AVPlayerState) => {
        console.info(`[VideoPlayerUtil] 状态: ${state}`);
        if (state === 'initialized') {
          // 不需要设置 surfaceId（只验证格式，不渲染视频）
          player.prepare().catch((e: BusinessError) => {
            const r: VideoSupportResult = {
              supported: false,
              reason: classifyError(e.code, e.message),
              errorCode: e.code,
              errorMessage: e.message
            };
            finish(r);
          });
        } else if (state === 'prepared') {
          const r: VideoSupportResult = { supported: true };
          finish(r);
        } else if (state === 'error') {
          // error 事件已处理，这里兜底
          const r: VideoSupportResult = {
            supported: false,
            reason: 'PREPARE_ERROR',
            errorMessage: 'AVPlayer 进入 error 状态'
          };
          finish(r);
        }
      });

      // 设置媒体源（赋值或 setMediaSource 都会触发 stateChange → initialized）
      if (source.fdSrc) {
        player.fdSrc = source.fdSrc;
      } else if (source.url) {
        const encoded = encodeUrlPath(source.url);
        if (source.headers) {
          // 有 headers：用 createMediaSourceWithUrl 创建独立 MediaSource
          const ms = media.createMediaSourceWithUrl(encoded, source.headers);
          player.setMediaSource(ms).catch((e: BusinessError) => {
            const r: VideoSupportResult = {
              supported: false,
              reason: classifyError(e.code, e.message),
              errorCode: e.code,
              errorMessage: e.message
            };
            finish(r);
          });
        } else {
          player.url = encoded;
        }
      }
    });
  }
}

