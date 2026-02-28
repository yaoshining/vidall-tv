import { VideoData } from './VideoData';

export enum PlayerEvents {
  PLAY = "play",
  TIME_UPDATE = "timeUpdate"
}

/** 通用轨道信息（字幕/音频/视频） */
export interface TrackInfo {
  /** 在播放器内部使用的轨道索引（用于 selectTrack） */
  trackIndex: number;
  /** 轨道类型：'video' | 'audio' | 'subtitle' */
  trackType: 'video' | 'audio' | 'subtitle';
  /** MIME 类型，如 "audio/mp4a-latm"、"application/x-subrip" */
  mimeType?: string;
  /** 语言代码，如 "chi"、"eng" */
  language?: string;
}

export interface SubtitleInfo {
  duration?: number;
  startTime?: number;
  text?: string;
}

/**
 * 统一播放器接口
 * 所有播放内核（AVPlayer、IjkPlayer 等）均须实现此接口，
 * VideoPlayerController 只依赖此接口，不依赖具体内核。
 */
export interface IPlayer {
  // ─── 只读属性 ───
  readonly duration: number;
  readonly currentTime: number;

  // ─── 生命周期 ───
  /** 异步初始化播放器，完成后触发 onReady 回调 */
  init(videoData: VideoData, surfaceId: string): Promise<void>;
  play(): Promise<void>;
  pause(): Promise<void>;
  toggle(): Promise<void>;
  release(): Promise<void>;

  // ─── 播放控制 ───
  seek(timeMs: number): void;
  forward(milliseconds: number): Promise<void>;
  backward(milliseconds: number): Promise<void>;

  // ─── 轨道 ───
  /** 获取所有轨道信息（在 onReady 之后才有效） */
  getTrackInfos(): Promise<TrackInfo[]>;
  /** 选择指定轨道（字幕/音频），-1 表示关闭 */
  selectTrack(trackIndex: number): Promise<void>;

  // ─── 事件回调 ───
  onReady(callback: () => void): void;
  onPlay(callback: () => void): void;
  onPaused(callback: () => void): void;
  onCompleted(callback: () => void): void;
  onStopped(callback: () => void): void;
  onTimeUpdate(callback: (currentTime: number) => void): void;
  onError(callback: (error: Error) => void): void;
  /**
   * 格式不支持回调：播放器遇到无法解码的格式时触发（如 AVPlayer 遇到 AC-3/EAC-3）。
   * VideoPlayerController 收到此回调后会自动切换到 ijkplayer。
   */
  onUnsupportedFormat(callback: () => void): void;
  onSeekDone(callback: () => void): void;
  onSubtitleUpdate(callback: (info: SubtitleInfo) => void): void;
}