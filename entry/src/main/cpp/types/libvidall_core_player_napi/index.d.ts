export const createPlayer: () => number;
export const setPreferredDecodePath: (handle: number, path: string) => void;
export const setSource: (handle: number, url: string) => void;
export const setDurationHint: (handle: number, durationMs: number) => void;
export const setHeaders: (handle: number, headersJson: string) => void;
export const setXComponent: (handle: number, context: Object, xComponentId: string) => void;
export const prepare: (handle: number) => void;
export const play: (handle: number) => void;
export const pause: (handle: number) => void;
export const seek: (handle: number, positionMs: number) => void;
export const selectTrack: (handle: number, trackIndex: number) => void;
export const release: (handle: number) => void;
export const getCurrentTime: (handle: number) => number;
export const getDuration: (handle: number) => number;

/** ffprobe 异步探测：返回 JSON 字符串，包含轨道、编码、时长等信息 */
export const ffprobe: (url: string, headerLines: string, timeoutMs: number) => Promise<string>;

export const ffmpegSelfCheck: () => {
  avVersionInfo: string;
  avformatVersion: number;
  avutilVersion: number;
};

/**
 * 通过 libcurl 发送 WebDAV / HTTP 请求（异步 NAPI，不阻塞主线程）。
 *
 * @param method      HTTP 方法，如 'PROPFIND'、'GET'、'PUT'
 * @param url         完整 URL（含协议、主机、端口、路径），支持 http:// 和 https://
 * @param headerLines 以 \r\n 分隔的 Header 行，如 'Authorization: Basic xxx\r\nDepth: 1'
 * @param body        请求体，无则传空字符串
 * @param timeoutMs   超时时间（毫秒）
 * @param tlsPolicy   TLS 校验策略：'allow_self_signed'（默认，跳过证书验证）| 'strict'（严格校验系统 CA）
 * @returns           statusCode / body / error（error 非空表示 libcurl 层错误，如 [CURL:60]）
 */
export const webdavRequest: (
  method: string,
  url: string,
  headerLines: string,
  body: string,
  timeoutMs: number,
  tlsPolicy?: string
) => Promise<{
  statusCode: number;
  body: string;
  error: string;
}>;

/**
 * 通过 libcurl 将远端文件下载到本地路径（异步 NAPI，不阻塞主线程）。
 *
 * @param method      HTTP 方法，通常为 'GET'
 * @param url         完整 URL
 * @param headerLines 以 \r\n 分隔的 Header 行
 * @param body        请求体，通常为空字符串
 * @param timeoutMs   超时时间（毫秒，建议 webdavRequest 的 2 倍）
 * @param outputPath  本地落盘路径
 * @param tlsPolicy   TLS 校验策略，同 webdavRequest
 * @returns           statusCode / downloadedBytes / error
 */
export const downloadToFile: (
  method: string,
  url: string,
  headerLines: string,
  body: string,
  timeoutMs: number,
  outputPath: string,
  tlsPolicy?: string
) => Promise<{
  statusCode: number;
  downloadedBytes: number;
  error: string;
}>;

/** 查询 native 层能力（libcurl/ffmpeg 是否可用及版本信息） */
export const getNativeCapabilities: () => {
  ffmpegEnabled: boolean;
  libcurlEnabled: boolean;
  libcurlVersion: string;
};

export const queryAudioDecoderCapability: (codecOrMime: string) => {
  capabilityKnown: boolean;
  supported: boolean;
  isHardware: boolean;
  maxChannels: number;
  decoderName: string;
  mimeType: string;
  errorMessage: string;
};

export const queryVideoDecoderCapability: (codecOrMime: string) => {
  capabilityKnown: boolean;
  supported: boolean;
  isHardware: boolean;
  maxWidth: number;
  maxHeight: number;
  minWidth: number;
  minHeight: number;
  maxFrameRate: number;
  minFrameRate: number;
  widthAlignment: number;
  heightAlignment: number;
  maxInstances: number;
  decoderName: string;
  mimeType: string;
  errorMessage: string;
};

export const probeVideoDecoderSurface: (handle: number, codecOrMime: string) => {
  success: boolean;
  stage: string;
  capabilityKnown: boolean;
  isHardware: boolean;
  decoderName: string;
  mimeType: string;
  stateSummary: string;
  errorMessage: string;
};

export const setCallbacks: (
  handle: number,
  onPrepared: () => void,
  onError: (code: number, msg: string) => void,
  onTimeUpdate: (posMs: number) => void,
  onCompleted: () => void,
  onBufferingChange: (isBuffering: boolean) => void,
  onSeekDone: () => void,
  onFfmpegSwitching: () => void,
  onSubtitleUpdate: (info: { duration: number; startTime: number; text: string }) => void
) => void;
