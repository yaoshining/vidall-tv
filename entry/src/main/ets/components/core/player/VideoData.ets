import { VideoDataType } from "./Constants";

/** 预置音轨信息（用于 ijkplayer 无法自动枚举时手动注入） */
export interface PresetAudioTrack {
  /** IjkPlayer selectTrack() 使用的流索引 */
  trackIndex: number;
  /** 显示名称，如 "粤语 (E-AC-3)" */
  displayName: string;
  /** ISO 639-2 语言代码，如 "chi"、"eng" */
  language?: string;
  /** MIME 类型，如 "audio/eac3" */
  mimeType?: string;
}

export interface VideoData {
  type: VideoDataType;
  videoSrc: string;
  httpHeader?: Record<string, string>;
  name?: ResourceStr;
  description?: ResourceStr;
  head?: Resource;
  caption?: string;
  index?: number;
  seekTime?: number;
  isMuted?: boolean;
  /**
   * 外部 SRT 字幕文件 URL（如 WebDAV 上与视频同名的 .srt 文件）
   * 若提供，播放器会下载并解析该文件做时间轴驱动字幕，
   * 优先级高于 AVPlayer 内嵌字幕回调（API 19 不支持内嵌字幕推送）
   */
  subtitleUrl?: string;
  /** 下载字幕文件时使用的 HTTP 请求头（如 Authorization: Basic xxx） */
  subtitleHeaders?: Record<string, string>;
  /**
   * 预置音轨列表（可选）。
   * 当 backend='ijkplayer' 且 IjkPlayer 无法自动枚举多音轨时使用。
   * 由调用方（播放页）根据文件元数据手动填充。
   */
  presetAudioTracks?: PresetAudioTrack[];
}