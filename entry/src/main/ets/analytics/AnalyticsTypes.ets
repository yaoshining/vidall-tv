/**
 * 埋点事件类型定义
 * 用于播放、字幕、扫描等场景的指标采集
 */

/**
 * 事件类型枚举
 */
export enum EventType {
  // 播放相关事件
  PLAY_START = 'play_start',              // 播放开始
  PLAY_PREPARED = 'play_prepared',        // 播放准备成功
  PLAY_FAILED = 'play_failed',            // 播放失败
  PLAY_FIRST_FRAME = 'play_first_frame',  // 首帧渲染

  // 字幕相关事件
  SUBTITLE_SWITCH = 'subtitle_switch',    // 字幕切换
  SUBTITLE_LOAD_SUCCESS = 'subtitle_load_success',  // 字幕加载成功
  SUBTITLE_LOAD_FAILED = 'subtitle_load_failed',    // 字幕加载失败

  // 扫描相关事件
  SCAN_COMPLETED = 'scan_completed',      // 扫描完成
  SCAN_FAILED = 'scan_failed'             // 扫描失败
}

/**
 * 错误级别枚举
 */
export enum ErrorLevel {
  INFO = 'info',        // 信息级别
  WARNING = 'warning',  // 警告级别
  ERROR = 'error',      // 错误级别
  CRITICAL = 'critical' // 严重错误级别
}

/**
 * 播放来源类型
 */
export enum SourceType {
  URL = 'url',           // 网络URL
  LOCAL = 'local',       // 本地文件
  WEBDAV = 'webdav',     // WebDAV
  UNKNOWN = 'unknown'    // 未知来源
}

/**
 * 字幕格式类型
 */
export enum SubtitleFormatType {
  EMBEDDED = 'embedded',  // 内嵌字幕
  SRT = 'srt',           // SRT 外挂字幕
  ASS = 'ass',           // ASS 外挂字幕
  VTT = 'vtt',           // VTT 字幕
  UNKNOWN = 'unknown'    // 未知格式
}

/**
 * 基础埋点事件接口
 */
export interface BaseAnalyticsEvent {
  eventType: EventType;           // 事件类型
  timestamp: number;              // 事件发生时间戳(ms)
  sessionId: string;              // 会话ID
}

/**
 * 播放开始事件
 */
export interface PlayStartEvent extends BaseAnalyticsEvent {
  eventType: EventType.PLAY_START;
  mediaId: string;                // 媒体ID（视频文件路径或唯一标识）
  sourceType: SourceType;         // 来源类型
  duration?: number;              // 视频时长(ms)
}

/**
 * 播放准备成功事件
 */
export interface PlayPreparedEvent extends BaseAnalyticsEvent {
  eventType: EventType.PLAY_PREPARED;
  mediaId: string;
  sourceType: SourceType;
  prepareTime: number;            // 准备耗时(ms)
}

/**
 * 播放失败事件
 */
export interface PlayFailedEvent extends BaseAnalyticsEvent {
  eventType: EventType.PLAY_FAILED;
  mediaId: string;
  sourceType: SourceType;
  errorCode: string;              // 错误码
  errorMessage: string;           // 错误信息
  errorLevel: ErrorLevel;         // 错误级别
}

/**
 * 首帧渲染事件
 */
export interface PlayFirstFrameEvent extends BaseAnalyticsEvent {
  eventType: EventType.PLAY_FIRST_FRAME;
  mediaId: string;
  sourceType: SourceType;
  firstFrameTime: number;         // 首帧耗时(ms)
}

/**
 * 字幕切换事件
 */
export interface SubtitleSwitchEvent extends BaseAnalyticsEvent {
  eventType: EventType.SUBTITLE_SWITCH;
  mediaId: string;
  fromTrackIndex?: number;        // 原字幕轨道索引（-1表示关闭）
  toTrackIndex: number;           // 目标字幕轨道索引（-1表示关闭）
  subtitleFormat: SubtitleFormatType; // 字幕格式
}

/**
 * 字幕加载成功事件
 */
export interface SubtitleLoadSuccessEvent extends BaseAnalyticsEvent {
  eventType: EventType.SUBTITLE_LOAD_SUCCESS;
  mediaId: string;
  trackIndex: number;             // 字幕轨道索引
  subtitleFormat: SubtitleFormatType; // 字幕格式
  loadTime: number;               // 加载耗时(ms)
}

/**
 * 字幕加载失败事件
 */
export interface SubtitleLoadFailedEvent extends BaseAnalyticsEvent {
  eventType: EventType.SUBTITLE_LOAD_FAILED;
  mediaId: string;
  trackIndex?: number;            // 字幕轨道索引
  subtitleFormat: SubtitleFormatType; // 字幕格式
  errorCode: string;              // 错误码
  errorMessage: string;           // 错误信息
  errorLevel: ErrorLevel;         // 错误级别
}

/**
 * 扫描完成事件
 */
export interface ScanCompletedEvent extends BaseAnalyticsEvent {
  eventType: EventType.SCAN_COMPLETED;
  sourceId: string;               // 文件源ID
  sourceName: string;             // 文件源名称
  totalFiles: number;             // 扫描总文件数
  successFiles: number;           // 成功处理文件数
  failedFiles: number;            // 失败文件数
  scanTime: number;               // 扫描总耗时(ms)
  coverageRate: number;           // 扫描覆盖率（0-1）
}

/**
 * 扫描失败事件
 */
export interface ScanFailedEvent extends BaseAnalyticsEvent {
  eventType: EventType.SCAN_FAILED;
  sourceId: string;               // 文件源ID
  sourceName: string;             // 文件源名称
  failedFilesList: string[];      // 失败文件列表（路径）
  errorCode: string;              // 错误码
  errorMessage: string;           // 错误信息
  errorLevel: ErrorLevel;         // 错误级别
}

/**
 * 所有埋点事件的联合类型
 */
export type AnalyticsEvent =
  | PlayStartEvent
  | PlayPreparedEvent
  | PlayFailedEvent
  | PlayFirstFrameEvent
  | SubtitleSwitchEvent
  | SubtitleLoadSuccessEvent
  | SubtitleLoadFailedEvent
  | ScanCompletedEvent
  | ScanFailedEvent;

/**
 * 错误码定义
 */
export class ErrorCode {
  // 播放错误码 (1xxx)
  static readonly PLAY_INIT_FAILED = '1001';           // 播放器初始化失败
  static readonly PLAY_PREPARE_FAILED = '1002';        // 播放准备失败
  static readonly PLAY_SOURCE_INVALID = '1003';        // 播放源无效
  static readonly PLAY_NETWORK_ERROR = '1004';         // 网络错误
  static readonly PLAY_DECODE_ERROR = '1005';          // 解码错误
  static readonly PLAY_UNKNOWN_ERROR = '1099';         // 未知播放错误

  // 字幕错误码 (2xxx)
  static readonly SUBTITLE_PARSE_FAILED = '2001';      // 字幕解析失败
  static readonly SUBTITLE_LOAD_FAILED = '2002';       // 字幕加载失败
  static readonly SUBTITLE_FORMAT_UNSUPPORTED = '2003'; // 字幕格式不支持
  static readonly SUBTITLE_FILE_NOT_FOUND = '2004';    // 字幕文件不存在
  static readonly SUBTITLE_UNKNOWN_ERROR = '2099';     // 未知字幕错误

  // 扫描错误码 (3xxx)
  static readonly SCAN_ACCESS_DENIED = '3001';         // 扫描访问被拒绝
  static readonly SCAN_NETWORK_ERROR = '3002';         // 扫描网络错误
  static readonly SCAN_PATH_NOT_FOUND = '3003';        // 扫描路径不存在
  static readonly SCAN_TIMEOUT = '3004';               // 扫描超时
  static readonly SCAN_UNKNOWN_ERROR = '3099';         // 未知扫描错误
}
