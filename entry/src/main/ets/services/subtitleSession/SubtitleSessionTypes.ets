// filepath: entry/src/main/ets/services/subtitleSession/SubtitleSessionTypes.ets
//
// SubtitleSessionService 的类型契约。
//
// 背景：原 `VideoPlayerController` 内的字幕会话状态散落在多个 `@Trace` 字段与
// `subtitleAdapter` 之上：`allSubtitleTracks` / `activeSubtitleIndex` / `subtitleDelayMs` /
// `parsedSubtitle` / `subtitleUpdateCounter` / `currentSubtitleText` / `currentSubtitleTrack`。
//
// Module 4 目标：把这些字段统一封装为 `SubtitleSessionState`，
// 由 `SubtitleSessionService` 负责「会话内字幕状态」与「字幕获取」的分层。
//
// 与 `SubtitleBridgeAdapter` 的关系：
// - bridge adapter 仅负责后端字幕桥接（MPV / AV / SMB-AV）；
// - session service 负责会话级状态投影 + 调度器裁决（步骤 1 / 步骤 4）应用。
//
// 兼容性：
// - `SubtitleTrackItem` / `SubtitleBridgeState` 由本文件 re-export，
//   controller 旧 import 路径继续可用。

import type {
  SubtitleTrackItem,
  SubtitleBridgeState
} from "../../components/core/player/SubtitleBridgeAdapter";
import type { TrackInfo } from "../../components/core/player/IPlayer";
import type { ParsedSubtitle } from "../../components/core/player/SubtitleRenderer";
import type { SubtitleCacheContext } from "../../subtitle/SubtitleDispatcher";
import type { SubtitleResolution } from "../../subtitle/SubtitleDispatcher";

export type { SubtitleTrackItem, SubtitleBridgeState };

/** 字幕会话状态投影（service 持有，controller 同步到 `@Trace`）。 */
export interface SubtitleSessionState {
  /** 来自 adapter 的内嵌 TrackInfo 列表（不可写）。 */
  subtitleTracks: TrackInfo[];
  /** 完整轨道列表（内嵌 + 外置 + 已下载）。 */
  allSubtitleTracks: SubtitleTrackItem[];
  /** 当前激活轨在 `allSubtitleTracks` 中的索引（-1 = 关闭字幕）。 */
  activeSubtitleIndex: number;
  /** adapter 内部当前选中的 track index（用于内嵌字幕回写）。 */
  currentSubtitleTrack: number;
  /** 当前显示文本。 */
  currentSubtitleText: string;
  /** 字幕延迟（毫秒；正值 = 字幕延后显示）。 */
  subtitleDelayMs: number;
  /** 当前是否启用外部字幕。 */
  hasExternalActive: boolean;
  /**
   * 字幕更新计数器（用于触发 UI 重新订阅）。
   *
   * 注意：`parsedSubtitle`（每帧解析结果）**不**作为 session state 持有。
   * 设计 open question 决议（design.md §Open Questions）：保留 VideoPlayer 的
   * 解析监听逻辑；controller 的 `@Trace parsedSubtitle` 字段由 `VideoPlayer`
   * 解析监听器直接写入。如需把 parsedSubtitle 也纳入 service，可在未来 stage
   * 由 `SubtitleSessionService.setParsedSubtitle` 接管。
   */
  updateCounter: number;
}

/** 初始化 session 入参。 */
export interface SubtitleSessionInitInput {
  /** 当前 backend 对应的字幕桥接 adapter（由 backend service 创建）。 */
  bridgeKind: 'none' | 'av' | 'mpv' | 'smb-av';
  /** 当前会话稳定视频路径（用于 SMB / 缓存查询）。 */
  stableVideoPath: string;
  /** 可选缓存上下文（用于步骤 4 命中）。 */
  cacheContext?: SubtitleCacheContext;
  /** 已构造的字幕桥接 adapter 实例引用（由 caller 持有，service 仅委托调用）。 */
  // 注意：bridge 实例由 controller 持有，service 通过 interface 调用避免循环依赖。
}

/** 字幕切换指令（由 session service 解析后应用到 bridge adapter）。 */
export interface SubtitleSwitchDirective {
  allIndex: number;
  /** 切换成功后写回的用户绑定信息（仅在 controller 需要持久化时使用）。 */
  persistAs: SubtitleBindingDirective;
}

/** 字幕绑定持久化指令。 */
export interface SubtitleBindingDirective {
  type: 'disabled' | 'external-local-file' | 'external-local-path' | 'internal' | 'skip';
  /** 仅 internal 时填写（@idx:token 或 displayName）。 */
  bindingKey?: string;
  /** 仅 external-local-file 时填写（完整 URL）。 */
  url?: string;
}

/** 字幕优先级裁决结果（service 内部计算）。 */
export interface SubtitlePriorityResolution {
  resolution: SubtitleResolution;
  /** 用于 controller 决定后续动作（switchTrack / addExternalSubtitle / 不动作）。 */
  appliedVia: 'switch-track' | 'append-and-switch' | 'no-op' | 'fallback-no-bridge';
  /** append-and-switch 时使用的目标轨道索引（追加到末尾后立即切换）。 */
  newTrackIndex?: number;
}
