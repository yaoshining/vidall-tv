// filepath: entry/src/main/ets/services/sourceAdapter/ServerCardAction.ets
//
// ServerCardAction - 影视服务器首页卡片点击行为契约 + 直播放降级校验（纯函数）。
//
// 目标：把 `MediaLibraryTab` 首页三类服务器卡片（继续观看 / 接下来 / 最近添加）的
// 点击分流与直播放上下文校验抽成可单测的纯函数，避免行为契约散落在 UI build() 里。
//
// 约束：
// - 仅包含无副作用纯函数，不依赖 UI / 网络 / 具体 server client。
// - 行为与 `MediaLibraryTab` 中卡片 wiring 保持一致（wiring 通过本模块解析）。

import type { VideoServer } from "../../db/models/VideoServerEntity";

/** 卡片类型。 */
export type ServerCardKind = 'continue-watching' | 'next-up' | 'recently-added' | 'library';

/** 点击行为：进详情 / 直播放 / 无操作。 */
export type ServerCardAction = 'open-detail' | 'direct-play' | 'none';

/** 卡片点击行为契约。 */
export interface ServerCardBehavior {
  /** 是否显示悬浮遮罩与中央播放按钮。 */
  showPlayButton: boolean;
  /** 卡片主体点击行为。 */
  itemClick: ServerCardAction;
  /** 中央播放按钮点击行为（showPlayButton=false 时为 'none'）。 */
  playClick: ServerCardAction;
}

/**
 * 解析卡片行为契约（分区分流）：
 * - 继续观看：无遮罩/无播放按钮，整卡直播放；
 * - 接下来 / 最近添加：主体进现有详情页，播放按钮直播放（互斥，不触发详情导航）；
 * - 媒体库：主体进媒体库列表，无播放按钮。
 */
export function resolveCardBehavior(kind: ServerCardKind): ServerCardBehavior {
  if (kind === 'continue-watching') {
    const behavior: ServerCardBehavior = { showPlayButton: false, itemClick: 'direct-play', playClick: 'none' };
    return behavior;
  }
  if (kind === 'next-up' || kind === 'recently-added') {
    const behavior: ServerCardBehavior = { showPlayButton: true, itemClick: 'open-detail', playClick: 'direct-play' };
    return behavior;
  }
  const behavior: ServerCardBehavior = { showPlayButton: false, itemClick: 'open-detail', playClick: 'none' };
  return behavior;
}

/**
 * 直播放上下文校验：服务器 ID 与实例均有效才允许进入播放流程；
 * 任一缺失即降级（不打开播放器、不误入详情页、不崩溃）。
 */
export function isDirectPlayContextValid(serverId: number | undefined, server: VideoServer | null): boolean {
  if (serverId === undefined) {
    return false;
  }
  if (server === null) {
    return false;
  }
  return true;
}
