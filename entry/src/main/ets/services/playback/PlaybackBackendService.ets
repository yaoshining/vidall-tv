// filepath: entry/src/main/ets/services/playback/PlaybackBackendService.ets
//
// PlaybackBackendService - 播放内核后端选择、adapter 生命周期与 fallback 编排。
//
// 目标：把 `VideoPlayerController` 中以下职责迁移到本 service：
//   1. 自动音频路由决策（`resolveAudioRoutingDecision`）
//   2. 适配器工厂（`IjkPlayerAdapter` / `AVPlayerAdapter` / `VidAllPlayerAdapter`）
//   3. SMB 代理生命周期（`VidAllPlayerAdapter.startSmbProxy` / `cleanupOrphanedProxies`）
//   4. XComponent 上下文绑定时序（`setIjkContext` / `setNativeContext`）
//   5. unsupported format / native → IJK fallback 编排
//
// 约束：
// - 不修改 `IPlayer` / `AVPlayerAdapter` / `IjkPlayerAdapter` / `VidAllPlayerAdapter` 现有签名。
// - 不修改 `VideoPlayerController.initPlayer` / `setIjkContext` / `setNativeContext` 公开方法签名；
//   旧方法保留为 thin wrapper 调用本 service。
// - 不修改 `VideoPlayer` UI 触发入口；UI 仍调用 controller.setIjkContext(...) /
//   controller.setNativeContext(...)。
//
// 设计要点：
// - `chooseBackend(videoData)` 返回 backend decision（pure service）。
// - `prepareAdapter(decision, context)` 编排 SMB 代理 + 工厂 + 上下文时序。
// - `bindIjkContext(adapter, context, id)` / `bindNativeContext(...)` 处理 XComponent 时序。
// - `release()` 释放 adapter + 清理 SMB 代理。
// - 续播状态由 controller 持有（service 不持有 resume session 状态）。
//
// 兼容性：
// - controller 内的 `initPlayer` / `setIjkContext` / `setNativeContext` /
//   `release` 旧方法保留为 thin wrapper 调用本 service，确保外部 import 兼容。
// - `PlayerBackend` / `UnsupportedFormatFallback` 由 `PlaybackBackendTypes.ets` re-export。

import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CommonConstants } from '../../common/constants/CommonConstants';
import buffer from '@ohos.buffer';
import { VideoData } from '../../components/core/player/VideoData';
import { IPlayer } from '../../components/core/player/IPlayer';
import { AVPlayerAdapter } from '../../components/core/player/AVPlayerAdapter';
import { IjkPlayerAdapter } from '../../components/core/player/IjkPlayerAdapter';
import { VidAllPlayerAdapter } from '../../components/core/player/VidAllPlayerAdapter';
import { MpvPlayerAdapter } from '../../components/core/player/MpvPlayerAdapter';
import {
  AvSubtitleBridgeAdapter,
  IjkSubtitleBridgeAdapter,
  ISubtitleBridgeAdapter,
  MpvSubtitleBridgeAdapter,
  NoSubtitleBridgeAdapter
} from '../../components/core/player/SubtitleBridgeAdapter';
import { SmbAvSubtitleBridgeAdapter } from '../../components/core/player/SmbSubtitleBridgeAdapter';
import {
  buildDefaultBackendDecision,
  PlaybackAdapterHandle,
  PlaybackBackendDecision,
  ServicePlayerBackend as PlayerBackend,
  ServiceUnsupportedFormatFallback as UnsupportedFormatFallback,
  SubtitleBridgeKind,
  ResumeAutoplayDecision,
  ResumeAutoplayInput
} from './PlaybackBackendTypes';
import {
  audioTrackRoutingService,
  AudioTrackRoutingService
} from '../audioRouting/AudioTrackRoutingService';
import type { AudioRoutingDecision } from '../audioRouting/AudioRoutingTypes';

const TAG = '[PlaybackBackendService]';

/** 字幕更新 payload（与 IPlayer.SubtitleInfo 同形，但 ArkTS 不允许 inline object literal 作类型）。 */
export interface PlaybackSubtitleInfo {
  duration?: number;
  startTime?: number;
  text?: string;
}

/** Adapter 事件绑定 callback 集合（controller 持有实现，service 只负责注册）。 */
export interface PlaybackAdapterCallbacks {
  onReady: () => void;
  onPlay: () => void;
  onPaused: () => void;
  onCompleted: () => void;
  onStopped: () => void;
  onTimeUpdate: (currentTime: number) => void;
  onError: (error: Error) => void;
  onUnsupportedFormat: () => void;
  onSeekDone: () => void;
  onSubtitleUpdate: (info: PlaybackSubtitleInfo) => void;
  onBuffering: (isBuffering: boolean) => void;
  /** IJK 字幕桥接：onEmbeddedTimedText 由 controller 注入并传递。 */
  onEmbeddedTimedText?: (text: string) => void;
  /** IJK 视频比例回调（prepared 后 DAR）。 */
  onVideoRatio?: (ratio: number) => void;
}

const EMPTY_CALLBACKS: PlaybackAdapterCallbacks = {
  onReady: () => {},
  onPlay: () => {},
  onPaused: () => {},
  onCompleted: () => {},
  onStopped: () => {},
  onTimeUpdate: () => {},
  onError: () => {},
  onUnsupportedFormat: () => {},
  onSeekDone: () => {},
  onSubtitleUpdate: () => {},
  onBuffering: () => {}
};

/** PlaybackBackendService façade。 */
export class PlaybackBackendService {
  private readonly routingService: AudioTrackRoutingService = audioTrackRoutingService;

  /**
   * 选择 backend 决策。
   *
   * 这是 backend 选择的统一入口。controller 不得绕过本方法直接调 routing service。
   * 本方法内部委托 `AudioTrackRoutingService.resolveRoutingDecision` 计算整组音轨分析，
   * 并把结果包装为 `PlaybackBackendDecision` 暴露给 controller。
   *
   * 行为：
   * - 探测 ffprobe 失败时降级 preset hint
   * - 整组音轨存在至少一条稳态可硬解轨道 → preferredBackend=avplayer（让 avplayer 尝试，
   *   由 `loadAudioTracks` 阶段的 `resolveInitialTrackIndex` 选中最优可硬解轨）
   * - 整组音轨全部应软解 → preferredBackend=avplayer + fallback=ijkplayer
   * - 探测完全失败且无任何音轨提示 → preferredBackend=ijkplayer
   */
  async chooseBackend(videoData: VideoData): Promise<PlaybackBackendDecision> {
    try {
      const decision: AudioRoutingDecision = await this.routingService.resolveRoutingDecision(videoData);
      // service 内部完成 audio routing 决策 → 包装为 PlaybackBackendDecision
      // 字段映射基于已升级的整组音轨分析（anyHardSupported / allSoftDecodeOnly / anyPlayable / anyUnplayable）
      return {
        preferredBackend: decision.preferredBackend,
        fallback: decision.fallback,
        preferredChannels: decision.preferredChannels,
        summary: decision.summary,
        detectedCodec: decision.detectedCodec,
        detectedChannels: decision.detectedChannels,
        anyHardSupported: decision.anyHardSupported,
        allSoftDecodeOnly: decision.allSoftDecodeOnly,
        anyPlayable: decision.anyPlayable,
        anyUnplayable: decision.anyUnplayable,
        precheckProbeFailed: decision.precheckProbeFailed,
        precheckProbeError: decision.precheckProbeError,
        videoCodecName: decision.videoCodecName,
        trackAnalyses: decision.trackAnalyses
      };
    } catch (e) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `路由决策异常，降级到默认: ${String(e)}`);
      return buildDefaultBackendDecision();
    }
  }

  /**
   * 准备 adapter 工厂。
   *
   * 流程：
   * 1. 启动 SMB 代理（如适用）
   * 2. 根据 backend 选 factory：ijkplayer → IjkPlayerAdapter；其余 → AVPlayerAdapter
   * 3. 注入字幕桥接 adapter
   * 4. 注册所有 IPlayer 事件回调
   *
   * 注：UI 触发入口（`setIjkContext` / `setNativeContext`）由 controller 持有，
   * service 暴露 `bindIjkContext` / `bindNativeContext` 供 controller 调用。
   */
  prepareAdapter(
    videoData: VideoData,
    backend: PlayerBackend,
    callbacks: PlaybackAdapterCallbacks
  ): PlaybackAdapterHandle {
    // ArkTS 不允许 spread 对象字面量，手动合并回调（优先用调用方传入的回调）。
    const cb: PlaybackAdapterCallbacks = {
      onReady: callbacks.onReady ?? EMPTY_CALLBACKS.onReady,
      onPlay: callbacks.onPlay ?? EMPTY_CALLBACKS.onPlay,
      onPaused: callbacks.onPaused ?? EMPTY_CALLBACKS.onPaused,
      onCompleted: callbacks.onCompleted ?? EMPTY_CALLBACKS.onCompleted,
      onStopped: callbacks.onStopped ?? EMPTY_CALLBACKS.onStopped,
      onTimeUpdate: callbacks.onTimeUpdate ?? EMPTY_CALLBACKS.onTimeUpdate,
      onError: callbacks.onError ?? EMPTY_CALLBACKS.onError,
      onUnsupportedFormat: callbacks.onUnsupportedFormat ?? EMPTY_CALLBACKS.onUnsupportedFormat,
      onSeekDone: callbacks.onSeekDone ?? EMPTY_CALLBACKS.onSeekDone,
      onSubtitleUpdate: callbacks.onSubtitleUpdate ?? EMPTY_CALLBACKS.onSubtitleUpdate,
      onBuffering: callbacks.onBuffering ?? EMPTY_CALLBACKS.onBuffering,
      onEmbeddedTimedText: callbacks.onEmbeddedTimedText,
      onVideoRatio: callbacks.onVideoRatio
    };
    const effectiveCallbacks: PlaybackAdapterCallbacks = {
      onReady: cb.onReady,
      onPlay: cb.onPlay,
      onPaused: cb.onPaused,
      onCompleted: cb.onCompleted,
      onStopped: cb.onStopped,
      onTimeUpdate: cb.onTimeUpdate,
      onError: cb.onError,
      onUnsupportedFormat: cb.onUnsupportedFormat,
      onSeekDone: cb.onSeekDone,
      onSubtitleUpdate: cb.onSubtitleUpdate,
      onBuffering: cb.onBuffering
    };

    // AVPlayer/IJK 不支持直接拉取 SMB，需经 HTTP 代理。MPV 使用无 userinfo 的 SMB URI，
    // 并保留 Basic Authorization 给 VidAll_Player 的内部 native bridge 解码后注入 Samba。
    let smbOriginalUrl = '';
    let smbProxyActive = false;
    let effectiveVideoSrc = videoData.videoSrc;
    if (videoData.videoSrc.startsWith('smb://')) {
      smbOriginalUrl = videoData.videoSrc;
      if (backend === 'mpv') {
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          'SMB 源直传 VidAll_Player MPV 后端，不启动 HTTP 代理');
      } else {
        const proxySmbUrl = this.buildSmbProxyUrl(smbOriginalUrl, videoData.httpHeader);
        const proxyUrl = VidAllPlayerAdapter.startSmbProxy(proxySmbUrl);
        if (proxyUrl.length > 0) {
          effectiveVideoSrc = proxyUrl;
          smbProxyActive = true;
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `SMB 源已通过代理 URL 转交 ${backend}（proxy started → rewritten to ${proxyUrl}）`);
        } else {
          smbOriginalUrl = '';
          hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
            `SMB 代理启动失败，backend=${backend} 将使用原始 smb:// URL`);
        }
      }
    }

    let adapter: IPlayer;
    let subtitleBridge: ISubtitleBridgeAdapter = new NoSubtitleBridgeAdapter();
    let subtitleBridgeKind: SubtitleBridgeKind = 'none';

    if (backend === 'ijkplayer') {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        'initPlayer: 使用 IjkPlayerAdapter，等待 UI 层调用 setIjkContext()');
      const ijkAdapter = new IjkPlayerAdapter();
      const ijkSubAdapter = new IjkSubtitleBridgeAdapter();
      subtitleBridge = ijkSubAdapter;
      subtitleBridgeKind = 'ijk';
      // 内嵌字幕回调
      if (cb.onEmbeddedTimedText !== undefined) {
        const onEmbedded = cb.onEmbeddedTimedText;
        ijkAdapter.setOnEmbeddedSubtitleCallback((text: string) => {
          onEmbedded(text);
        });
      }
      // 视频比例回调（prepared 后 DAR）
      if (cb.onVideoRatio !== undefined) {
        const onRatio = cb.onVideoRatio;
        ijkAdapter.setOnVideoRatioCallback((ratio: number) => {
          onRatio(ratio);
        });
      }
      adapter = ijkAdapter;
    } else if (backend === 'mpv') {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        'initPlayer: 使用 MpvPlayerAdapter，等待 UI 层调用 setMpvSurface()');
      const mpvAdapter = new MpvPlayerAdapter();
      const mpvSubAdapter = new MpvSubtitleBridgeAdapter();
      subtitleBridge = mpvSubAdapter;
      subtitleBridgeKind = 'mpv';
      // 内嵌字幕回调 — mpv 也通过 subtitleText 事件输出文本字幕
      if (cb.onEmbeddedTimedText !== undefined) {
        const onEmbedded = cb.onEmbeddedTimedText;
        mpvAdapter.setOnEmbeddedSubtitleCallback((text: string) => {
          onEmbedded(text);
        });
      }
      adapter = mpvAdapter;
    } else {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        'initPlayer: 使用 AVPlayerAdapter');
      adapter = new AVPlayerAdapter();
      if (smbOriginalUrl.length > 0) {
        subtitleBridge = new SmbAvSubtitleBridgeAdapter(smbOriginalUrl);
        subtitleBridgeKind = 'smb-av';
      } else {
        subtitleBridge = new AvSubtitleBridgeAdapter();
        subtitleBridgeKind = 'av';
      }
    }

    // 注册所有 IPlayer 事件回调
    this.registerAdapterCallbacks(adapter, effectiveCallbacks);

    const handle: PlaybackAdapterHandle = {
      backend,
      player: adapter,
      subtitleBridge,
      subtitleBridgeKind,
      effectiveVideoSrc,
      smbOriginalSrc: smbOriginalUrl,
      smbProxyActive
    };
    return handle;
  }

  /**
   * 绑定 IJK XComponent 上下文。
   *
   * 行为与原 `VideoPlayerController.setIjkContext` 字节级一致：
   * - 校验 adapter 类型
   * - setPendingContext 由 adapter 持有
   * - 调 adapter.init(videoData, surfaceId)
   */
  async bindIjkContext(
    adapter: IPlayer | undefined,
    context: object,
    xComponentId: string,
    videoData: VideoData,
    surfaceId: string
  ): Promise<void> {
    if (!(adapter instanceof IjkPlayerAdapter)) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        'bindIjkContext 收到非 IjkPlayerAdapter，跳过绑定');
      return;
    }
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `setIjkContext: 绑定 XComponent id=${xComponentId}，开始完整 init 流程...`);
    adapter.setPendingContext(context, xComponentId);
    try {
      await adapter.init(videoData, surfaceId);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `setIjkContext init 失败: ${err.message}`);
      throw new Error(`setIjkContext init 失败: ${err.message ?? 'unknown'}`);
    }
  }

  /**
   * 绑定 MPV XComponent 上下文。
   *
   * MPV 使用 XComponentController 模式（与 avplayer 相同），
   * 通过 MpvPlayerAdapter.getSurfaceAdapter().onLoad(surfaceId, width, height) 绑定 surface，
   * 然后调 init() 启动播放。
   * @param width XComponent 有效宽度（必须 > 0，由 onAreaChange 提供）
   * @param height XComponent 有效高度（必须 > 0，由 onAreaChange 提供）
   */
  async bindMpvContext(
    adapter: IPlayer | undefined,
    surfaceId: string,
    videoData: VideoData,
    width: number,
    height: number
  ): Promise<void> {
    if (!(adapter instanceof MpvPlayerAdapter)) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        'bindMpvContext 收到非 MpvPlayerAdapter，跳过绑定');
      return;
    }
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `setMpvSurface: 绑定 XComponent surfaceId=${surfaceId}，width=${width}，height=${height}，开始 init...`);
    try {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `bindMpvContext: 调用 surfaceAdapter.onLoad(${surfaceId.substring(0, 8)}..., ${width}, ${height})`);
      await adapter.getSurfaceAdapter().onLoad(surfaceId, width, height);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `bindMpvContext: surfaceAdapter.onLoad 完成，开始 adapter.init()`);
      await adapter.init(videoData, surfaceId);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `setMpvSurface init 失败: ${err.message}`);
      throw new Error(`setMpvSurface init 失败: ${err.message ?? 'unknown'}`);
    }
  }

  /**
   * 绑定 native XComponent 上下文。
   *
   * 行为与原 `VideoPlayerController.setNativeContext` 字节级一致。
   */
  async bindNativeContext(
    adapter: IPlayer | undefined,
    context: object,
    xComponentId: string,
    videoData: VideoData,
    surfaceId: string
  ): Promise<void> {
    if (!(adapter instanceof VidAllPlayerAdapter)) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        'bindNativeContext 收到非 VidAllPlayerAdapter，跳过绑定');
      return;
    }
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `setNativeContext: 绑定 XComponent id=${xComponentId}，开始 native 骨架 init...`);
    let safeContext: object = context;
    if (safeContext === null || safeContext === undefined) {
      const fallbackContext: Record<string, string> = {};
      safeContext = fallbackContext as object;
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `setNativeContext: onLoad context 为空，使用空对象兜底 id=${xComponentId}`);
    }
    try {
      await adapter.initWithContext(videoData, surfaceId, safeContext, xComponentId);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `setNativeContext init 失败: ${err.message}`);
      throw new Error(`setNativeContext init 失败: ${err.message ?? 'unknown'}`);
    }
  }

  /**
   * 仅为 AVPlayer/IJK 的本地代理恢复 URI userinfo；MPV 始终消费无凭据 URI 与 Basic header。
   */
  private buildSmbProxyUrl(smbUri: string, headers: Record<string, string> | undefined): string {
    if (headers === undefined) {
      return smbUri;
    }
    const headerNames = Object.keys(headers);
    let authorization = '';
    for (let index = 0; index < headerNames.length; index++) {
      const name = headerNames[index];
      if (name.toLowerCase() === 'authorization') {
        authorization = headers[name];
        break;
      }
    }
    if (!authorization.startsWith('Basic ')) {
      return smbUri;
    }
    try {
      const credentials = buffer.from(authorization.substring('Basic '.length), 'base64').toString('utf-8');
      const separator = credentials.indexOf(':');
      if (separator < 0) {
        return smbUri;
      }
      const username = credentials.substring(0, separator);
      const password = credentials.substring(separator + 1);
      if (username.length === 0 && password.length === 0) {
        return smbUri;
      }
      const schemeEnd = smbUri.indexOf('://');
      if (schemeEnd < 0) {
        return smbUri;
      }
      const authorityStart = schemeEnd + 3;
      const authorityEnd = smbUri.indexOf('/', authorityStart);
      const authority = authorityEnd >= 0
        ? smbUri.substring(authorityStart, authorityEnd)
        : smbUri.substring(authorityStart);
      if (authority.includes('@')) {
        return smbUri;
      }
      const userInfo = `${encodeURIComponent(username)}:${encodeURIComponent(password)}@`;
      return `${smbUri.substring(0, authorityStart)}${userInfo}${smbUri.substring(authorityStart)}`;
    } catch (_) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, 'SMB 代理认证解码失败，按匿名 SMB 启动代理');
      return smbUri;
    }
  }

  /**
   * SMB 代理重启：用于 avplayer → ijkplayer fallback 场景。
   * 行为与原 `VideoPlayerController.setIjkContext` 内部 SMB 处理字节级一致。
   */
  restartSmbProxyForFallback(smbOriginalSrc: string, videoData: VideoData): boolean {
    if (smbOriginalSrc.length === 0) {
      return false;
    }
    const proxySmbUrl = this.buildSmbProxyUrl(smbOriginalSrc, videoData.httpHeader);
    const newProxyUrl = VidAllPlayerAdapter.startSmbProxy(proxySmbUrl);
    if (newProxyUrl.length > 0) {
      videoData.videoSrc = newProxyUrl;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG,
        `[setIjkContext] SMB fallback 重启代理成功: ${newProxyUrl}`);
      return true;
    }
    videoData.videoSrc = smbOriginalSrc;
    hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
      `[setIjkContext] SMB fallback 代理重启失败，已回退到原始 SMB URL: ${smbOriginalSrc}`);
    return false;
  }

  /**
   * 清理 SMB 孤立代理线程。controller 在切换源前调用，避免 keepProxy=true 释放后的线程泄漏。
   */
  cleanupOrphanedProxies(): void {
    VidAllPlayerAdapter.cleanupOrphanedProxies();
  }

  /** 释放 adapter 与 SMB 代理。 */
  async release(handle: PlaybackAdapterHandle | undefined): Promise<void> {
    if (handle === undefined) {
      return;
    }
    if (handle.player !== undefined) {
      try {
        await handle.player.release();
      } catch (e) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `adapter.release 失败: ${String(e)}`);
      }
    }
    if (handle.smbProxyActive) {
      VidAllPlayerAdapter.cleanupOrphanedProxies();
    }
  }

  /**
   * 纯函数：续播自动播放决策。
   * 行为与原 `VideoPlayerController.resolvePendingResumeAutoplayDecision` 一致。
   */
  resolveResumeAutoplayDecision(
    input: ResumeAutoplayInput,
    currentShouldResumePlay: boolean,
    currentSource: string,
    currentOrigin: string
  ): ResumeAutoplayDecision {
    if (currentSource.length > 0 && currentSource !== 'compat_override' && currentSource !== 'transient_player_state') {
      return {
        shouldResumePlay: currentShouldResumePlay,
        source: currentSource,
        origin: currentOrigin
      };
    }
    let shouldResumePlay: boolean;
    let source: string;
    let origin: string;
    if (input.isPlaying || input.isSeeking) {
      shouldResumePlay = true;
      source = 'transient_player_state';
      origin = 'transient';
    } else {
      shouldResumePlay = currentShouldResumePlay;
      source = currentSource.length > 0 ? currentSource : 'transient_player_state';
      origin = currentOrigin.length > 0 ? currentOrigin : 'transient';
    }
    return { shouldResumePlay, source, origin };
  }

  /** 私有：注册 IPlayer 事件回调。 */
  private registerAdapterCallbacks(
    adapter: IPlayer,
    cb: PlaybackAdapterCallbacks
  ): void {
    adapter.onReady(cb.onReady);
    adapter.onPlay(cb.onPlay);
    adapter.onPaused(cb.onPaused);
    adapter.onCompleted(cb.onCompleted);
    adapter.onStopped(cb.onStopped);
    adapter.onTimeUpdate(cb.onTimeUpdate);
    adapter.onError(cb.onError);
    adapter.onUnsupportedFormat(cb.onUnsupportedFormat);
    adapter.onSeekDone(cb.onSeekDone);
    adapter.onSubtitleUpdate(cb.onSubtitleUpdate);
    adapter.onBuffering(cb.onBuffering);
  }
}

/** 默认无依赖实例。 */
export const playbackBackendService: PlaybackBackendService = new PlaybackBackendService();
