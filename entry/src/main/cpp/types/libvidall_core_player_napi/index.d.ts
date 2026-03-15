export const createPlayer: () => number;
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
export const ffprobe: (url: string, headerLines: string, timeoutMs: number) => Promise<string>;
export const ffmpegSelfCheck: () => {
  avVersionInfo: string;
  avformatVersion: number;
  avutilVersion: number;
};
export const webdavRequest: (
  method: string,
  url: string,
  headerLines: string,
  body: string,
  timeoutMs: number
) => {
  statusCode: number;
  body: string;
  error: string;
};
export const getNativeCapabilities: () => {
  ffmpegEnabled: boolean;
  libcurlEnabled: boolean;
  libcurlVersion: string;
};
export const setCallbacks: (
  handle: number,
  onPrepared: () => void,
  onError: (code: number, msg: string) => void,
  onTimeUpdate: (posMs: number) => void,
  onCompleted: () => void,
  onBufferingChange: (isBuffering: boolean) => void,
  onSeekDone: () => void
) => void;
