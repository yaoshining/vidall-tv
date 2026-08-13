import { VideoDataType } from "./Constants";

/** 预置音轨信息（用于播放器就绪前展示与初始选轨） */
export interface PresetAudioTrack {
  /** ffprobe 流索引 */
  trackIndex: number;
  /** 显示名称，如 "粤语 (E-AC-3)" */
  displayName: string;
  /** ISO 639-2 语言代码，如 "chi"、"eng" */
  language?: string;
  /** MIME 类型，如 "audio/eac3" */
  mimeType?: string;
  /**
   * 声道数，如 2（立体声）、6（5.1）、8（7.1）。
   * 由调用方按 ffprobe 结果注入，用于音频路由优先级排序。
   * 未注入时 readPresetAudioHint 会从 displayName 关键字推断。
   */
  channels?: number;
  /**
   * 音频码率（bps），由调用方按 ffprobe 结果注入。
   * 用于同声道数下的高质量轨道优先选择（高码率优先）。
   */
  bitrate?: number;
  /**
   * 编解码器名称，由调用方按 ffprobe 结果注入，如 "aac"、"eac3"、"ac3"。
   * 用于 codec-aware 音轨候选选择器，避免偏好恢复时命中 AVPlayer 不支持的 codec。
   * 缺失时按未知 codec 处理，不视为可播放证明。
   */
  codecName?: string;
}

/**
 * 预置字幕轨信息。
 *
 * 由调用方（播放页）根据 ffprobe 探测结果或数据库记录手动注入，
 * 供播放器就绪后展示和选择字幕轨。
 */
export interface PresetSubtitleTrack {
  /** ffprobe 流索引 */
  trackIndex: number;
  /** 显示名称，如 "中文 (SRT)"、"英语 (ASS)" */
  displayName: string;
  /** ISO 639-2 语言代码，如 "chi"、"eng" */
  language?: string;
  /** 编解码器名称，如 "subrip"、"ass"、"hdmv_pgs_subtitle" */
  codecName?: string;
}

export interface VideoData {
  type: VideoDataType;
  videoSrc: string;
  /** 视频时长提示（毫秒），用于 native 骨架在早期阶段提供进度条/seek 上限 */
  durationHintMs?: number;
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
   * 预置音轨列表（可选），由调用方根据文件元数据手动填充。
   */
  presetAudioTracks?: PresetAudioTrack[];
  /**
   * 预置字幕轨列表（可选），通过 ffprobe 或数据库预先填充，
   * 供 VideoPlayerController 在 onReady 后展示字幕选项。
   */
  presetSubtitleTracks?: PresetSubtitleTrack[];

  /**
   * ffmpeg 软解目标声道数（可选）。
   * - 1: 单声道
   * - 2: 立体声
   * - 6: 5.1
   * - 8: 7.1
   */
  ffmpegDecodeChannels?: number;

  /**
   * 音频探测摘要（可选），用于调试/日志展示。
   */
  audioProbeSummary?: string;

  /**
   * 视频编码名称（可选），由 ffprobe 探测填充，如 'hevc', 'h264'。
   * 用于播放路由诊断和能力判断。
   */
  videoCodec?: string;

  /**
   * 刮削得到的原始标题（英文），如 "The Bad Kids"。
   * 优先用于 OpenSubtitles 搜索，避免文件名中文/混合标题解析失败。
   */
  scrapeOriginalTitle?: string;

  /**
   * TMDB ID（数字字符串），电影或剧集系列级别。
   * 传给 OpenSubtitles `tmdb_id` 参数可精准匹配字幕。
   */
  tmdbId?: string;

  /**
   * 文件源类型（可选），如 'webdav'、'smb'、'local'、'network'。
   * 由调用方从 FileSource.type 转换后传入，用于字幕本地缓存分桶。
   */
  fileSourceType?: string;

  /**
   * 文件源 ID（可选），对应数据库中 FileSource.id 转字符串。
   * 与 fileSourceType 配合作为字幕缓存路径的 sourceId 分段。
   */
  fileSourceId?: string;
}