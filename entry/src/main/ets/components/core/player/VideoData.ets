import { VideoDataType } from "./Constants";

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
  /** 视频数据库ID，用于播放进度持久化 */
  videoId?: number;
}