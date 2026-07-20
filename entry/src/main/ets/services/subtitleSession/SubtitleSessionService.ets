// filepath: entry/src/main/ets/services/subtitleSession/SubtitleSessionService.ets
//
// SubtitleSessionService - 字幕会话级状态管理。
//
// 目标：把 `VideoPlayerController` 中以下职责迁移到本 service：
//   1. 字幕轨列表（allSubtitleTracks / subtitleTracks / currentSubtitleTrack）
//   2. 激活状态（activeSubtitleIndex / currentSubtitleText / parsedSubtitle）
//   3. 字幕延迟（subtitleDelayMs）
//   4. 外置字幕追加（addExternalSubtitle）
//   5. 稳定 source key（currentVideoData 配合 smbOriginalSrc）
//   6. 字幕优先级裁决（步骤 1 用户绑定 / 步骤 4 本地缓存）
//
// 约束：
// - 不直接依赖具体 adapter；通过 `ISubtitleBridgeAdapter` 接口调用（service 持有
//   状态，bridge adapter 持有后端字幕桥接；controller 负责注入与生命周期）。
// - 不修改 `SubtitleDispatcher` / `ISubtitleBridgeAdapter` / `IPlayer` 现有签名。
// - 不修改 `VideoPlayerController.switchSubtitleTrack` / `loadSubtitleTracks` 等
//   公开方法签名；旧方法保留为 thin wrapper 调用本 service。
//
// 设计要点：
// - `initialize(input)` 触发 subtitle bridge init + 优先级裁决 + 状态投影。
// - `applyBridgeState()` 读取 bridge adapter 当前状态并同步到 session 字段。
// - `switchToTrack(allIndex)` 应用用户切换；触发持久化指令返回 controller。
// - `adjustDelay(deltaMs)` 调整延迟；通过 bridge adapter 透传。
// - `addLocalSubtitle(localPath)` 追加下载字幕；返回新轨道索引。
//
// 兼容性：
// - controller 内的 `loadSubtitleTracks` / `switchSubtitleTrack` /
//   `adjustSubtitleDelay` / `addExternalSubtitle` 旧方法保留为 thin wrapper，
//   确保外部 import 兼容。
// - 持久化（saveUserBinding / clearUserBinding）由 controller 持有 service
//   返回的 directive 后执行，避免 service 直接依赖 AppPreferences。
//
// 实例化策略（Module 4 fix #2）：
// - 本 service 不再导出全局单例。
// - 每个 `VideoPlayerController` 在自己生命周期内 `new SubtitleSessionService()`，
//   让 service 内部持有的 mutable state 与 controller 生命周期一一对应，
//   避免多 controller / 多播放会话状态串扰。
// - 旧版的全局单例 `subtitleSessionService` 已删除。

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CommonConstants } from "../../common/constants/CommonConstants";
import { VideoData } from "../../components/core/player/VideoData";
import { VideoDataType } from "../../components/core/player/Constants";
import { IPlayer } from "../../components/core/player/IPlayer";
import {
  ISubtitleBridgeAdapter,
  SubtitleBridgeState,
  SubtitleTrackItem
} from "../../components/core/player/SubtitleBridgeAdapter";
import { ParsedSubtitle } from "../../components/core/player/SubtitleRenderer";
import {
  SubtitleDispatcher,
  SubtitleCacheContext,
  SubtitleResolution
} from "../../subtitle/SubtitleDispatcher";
import {
  SubtitleSessionState,
  SubtitleBindingDirective,
  SubtitlePriorityResolution
} from "./SubtitleSessionTypes";

const TAG = '[SubtitleSessionService]';

/** 默认空 session 状态。 */
function buildEmptySessionState(): SubtitleSessionState {
  const state: SubtitleSessionState = {
    subtitleTracks: [],
    allSubtitleTracks: [],
    activeSubtitleIndex: -1,
    currentSubtitleTrack: -1,
    currentSubtitleText: '',
    subtitleDelayMs: 0,
    hasExternalActive: false,
    updateCounter: 0
  };
  return state;
}

/** 字幕会话 service。 */
export class SubtitleSessionService {
  private state: SubtitleSessionState = buildEmptySessionState();
  private readonly subtitleDispatcher: SubtitleDispatcher = new SubtitleDispatcher();

  /** 读取当前 session 状态（深拷贝避免外部修改）。 */
  getState(): SubtitleSessionState {
    const next: SubtitleSessionState = {
      subtitleTracks: this.state.subtitleTracks.slice(),
      allSubtitleTracks: this.state.allSubtitleTracks.slice(),
      activeSubtitleIndex: this.state.activeSubtitleIndex,
      currentSubtitleTrack: this.state.currentSubtitleTrack,
      currentSubtitleText: this.state.currentSubtitleText,
      subtitleDelayMs: this.state.subtitleDelayMs,
      hasExternalActive: this.state.hasExternalActive,
      updateCounter: this.state.updateCounter
    };
    return next;
  }

  /** 重置 session（用于 initPlayer 切换源时清理上一次残留）。 */
  reset(): void {
    this.state = buildEmptySessionState();
  }

  /**
   * 初始化字幕 session。
   *
   * 行为与原 `VideoPlayerController.loadSubtitleTracks` 字节级一致：
   * - 触发 subtitleAdapter.init
   * - 同步 bridge state 到 session state
   * - 计算稳定视频路径（优先 smbOriginalSrc）
   * - 调用 SubtitleDispatcher.resolveSubtitle
   * - 根据 resolution.type 应用：switch-track / append-and-switch / no-op
   */
  async initialize(
    subtitleAdapter: ISubtitleBridgeAdapter,
    player: IPlayer | undefined,
    videoData: VideoData | undefined,
    smbOriginalSrc: string,
    cacheContext: SubtitleCacheContext | undefined
  ): Promise<SubtitlePriorityResolution> {
    if (!player) {
      return { resolution: { type: 'none' }, appliedVia: 'fallback-no-bridge' };
    }
    if (!videoData) {
      return { resolution: { type: 'none' }, appliedVia: 'no-op' };
    }

    try {
      await subtitleAdapter.init(player, videoData);
      this.applyBridgeState(subtitleAdapter.getState());
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `字幕适配器初始化失败，回退无字幕模式: code=${err.code} msg=${err.message}`);
      subtitleAdapter.release();
      const next: SubtitleSessionState = buildEmptySessionState();
      this.state = next;
      return { resolution: { type: 'none' }, appliedVia: 'fallback-no-bridge' };
    }

    // 计算稳定视频路径
    const rawVideoSrc = videoData.videoSrc ?? '';
    const videoPath = smbOriginalSrc.length > 0 ? smbOriginalSrc : rawVideoSrc;
    if (videoPath.length === 0) {
      return { resolution: { type: 'none' }, appliedVia: 'no-op' };
    }

    let resolution: SubtitleResolution;
    try {
      resolution = await this.subtitleDispatcher.resolveSubtitle(
        videoPath,
        this.state.allSubtitleTracks,
        cacheContext
      );
    } catch (e) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `resolveSubtitle 失败，保留 adapter 自动选轨: ${String(e)}`);
      return { resolution: { type: 'none' }, appliedVia: 'no-op' };
    }

    if (resolution.type === 'user-specified' && resolution.trackIndex !== undefined) {
      const targetIndex = resolution.trackIndex;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[loadSubtitleTracks] 调度器覆盖选轨: trackIndex=${targetIndex}`);
      await subtitleAdapter.switchTrack(targetIndex);
      this.applyBridgeState(subtitleAdapter.getState());
      return { resolution, appliedVia: 'switch-track' };
    }

    if (resolution.type === 'local-cache' && resolution.localPath !== undefined) {
      const localPath = resolution.localPath;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[loadSubtitleTracks] 步骤4命中缓存字幕，追加到轨道列表并切换: ${localPath}`);
      try {
        const trackCountBeforeAppend = this.state.allSubtitleTracks.length;
        await subtitleAdapter.addLocalSubtitle(localPath);
        this.applyBridgeState(subtitleAdapter.getState());
        if (this.state.allSubtitleTracks.length <= trackCountBeforeAppend) {
          throw new Error('缓存字幕未能追加到轨道列表');
        }
        const newIndex = this.state.allSubtitleTracks.length - 1;
        await subtitleAdapter.switchTrack(newIndex);
        this.applyBridgeState(subtitleAdapter.getState());
        return { resolution, appliedVia: 'append-and-switch', newTrackIndex: newIndex };
      } catch (e) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `追加缓存字幕失败: ${String(e)}`);
        return { resolution, appliedVia: 'no-op' };
      }
    }

    return { resolution, appliedVia: 'no-op' };
  }

  /**
   * 用户切换字幕轨。
   *
   * 返回 binding directive 由 controller 持久化（service 不直接操作 AppPreferences）。
   */
  async switchToTrack(
    subtitleAdapter: ISubtitleBridgeAdapter,
    videoData: VideoData | undefined,
    smbOriginalSrc: string,
    allIndex: number
  ): Promise<SubtitleBindingDirective> {
    await subtitleAdapter.switchTrack(allIndex);
    this.applyBridgeState(subtitleAdapter.getState());

    if (!videoData) {
      return { type: 'skip' };
    }
    const rawVideoSrc = videoData.videoSrc ?? '';
    const videoPath = smbOriginalSrc.length > 0 ? smbOriginalSrc : rawVideoSrc;
    if (videoPath.length === 0) {
      return { type: 'skip' };
    }
    if (allIndex === -1) {
      return { type: 'disabled' };
    }
    if (allIndex < 0 || allIndex >= this.state.allSubtitleTracks.length) {
      return { type: 'skip' };
    }
    const track = this.state.allSubtitleTracks[allIndex];
    if (track.kind === 'external' && track.url !== undefined && track.url.length > 0) {
      return { type: 'external-local-file', url: track.url };
    }
    if (track.kind === 'internal') {
      const bindingKey = track.internalIndex !== undefined
        ? `@idx:${track.internalIndex}`
        : track.displayName;
      return { type: 'internal', bindingKey };
    }
    return { type: 'skip' };
  }

  /** 追加本地字幕文件到轨道列表，返回新轨道索引。 */
  async addLocalSubtitle(
    subtitleAdapter: ISubtitleBridgeAdapter,
    localPath: string
  ): Promise<number> {
    await subtitleAdapter.addLocalSubtitle(localPath);
    this.applyBridgeState(subtitleAdapter.getState());
    const newIndex = this.state.allSubtitleTracks.length - 1;
    return newIndex;
  }

  /** 调整字幕延迟。 */
  adjustDelay(subtitleAdapter: ISubtitleBridgeAdapter, deltaMs: number): void {
    subtitleAdapter.adjustDelay(deltaMs);
    this.applyBridgeState(subtitleAdapter.getState());
  }

  /** 同步 bridge adapter 当前状态到 session state（不重新初始化）。 */
  applyBridgeState(bridgeState: SubtitleBridgeState): void {
    const prevText = this.state.currentSubtitleText;
    this.state.subtitleTracks = bridgeState.subtitleTracks.slice();
    this.state.allSubtitleTracks = bridgeState.allSubtitleTracks.slice();
    this.state.activeSubtitleIndex = bridgeState.activeSubtitleIndex;
    this.state.currentSubtitleTrack = bridgeState.currentSubtitleTrack;
    this.state.currentSubtitleText = bridgeState.currentSubtitleText;
    this.state.subtitleDelayMs = bridgeState.subtitleDelayMs;
    this.state.hasExternalActive = bridgeState.hasExternalActive;
    if (prevText !== this.state.currentSubtitleText) {
      this.state.updateCounter++;
    }
  }

  /** 是否当前正在使用外部 SRT 字幕（供 UI 判断）。 */
  hasSrtSubtitle(): boolean {
    return this.state.hasExternalActive;
  }
}
