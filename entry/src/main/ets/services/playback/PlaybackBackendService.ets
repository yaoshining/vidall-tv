// filepath: entry/src/main/ets/services/playback/PlaybackBackendService.ets
//
// PlaybackBackendService - 播放内核后端选择、adapter 生命周期与 fallback 编排。
//
// 目标：把 `VideoPlayerController` 中以下职责迁移到本 service：
//   1. 自动音频路由决策（`resolveAudioRoutingDecision`）
//   2. AVPlayer、MPV 与兼容后端的 adapter 工厂
//   3. AVPlayer 所需的 SMB HTTP 代理生命周期
//   4. MPV XComponent surface 绑定时序
//   5. unsupported format → MPV fallback 编排
//
// 设计要点：
// - `chooseBackend(videoData)` 返回 backend decision（pure service）。
// - `prepareAdapter(decision, context)` 编排 SMB 源处理、工厂和事件绑定。
// - `bindMpvSurface(adapter, surfaceId)` 处理 MPV XComponent 时序。
// - `release()` 释放 adapter；代理跟随 native bridge 的普通生命周期结束。
// - 续播状态由 controller 持有（service 不持有 resume session 状态）。
// - `PlayerBackend` / `UnsupportedFormatFallback` 由 `PlaybackBackendTypes.ets` re-export。

import { hilog } from '@kit.PerformanceAnalysisKit';
import { CommonConstants } from '../../common/constants/CommonConstants';
import buffer from '@ohos.buffer';
import { VideoData } from '../../components/core/player/VideoData';
import { IPlayer } from '../../components/core/player/IPlayer';
import { AVPlayerAdapter } from '../../components/core/player/AVPlayerAdapter';
import { VidAllPlayerAdapter } from '../../components/core/player/VidAllPlayerAdapter';
import { MpvPlayerAdapter } from '../../components/core/player/MpvPlayerAdapter';
import {
  AvSubtitleBridgeAdapter,
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
  /** MPV 内嵌字幕回调。 */
  onEmbeddedTimedText?: (text: string) => void;
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
   * - 整组音轨全部应软解 → preferredBackend=avplayer + fallback=mpv
   * - 探测完全失败且无任何音轨提示 → 仍先尝试 AVPlayer，再按不支持格式回退
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
   * 1. 为 AVPlayer 启动 SMB HTTP 代理（如适用），MPV 保持 SMB 直连
   * 2. 根据 backend 创建 MPV 或 AVPlayer adapter
   * 3. 注入字幕桥接 adapter
   * 4. 注册所有 IPlayer 事件回调
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
      onEmbeddedTimedText: callbacks.onEmbeddedTimedText
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

    // AVPlayer 不支持直接拉取 SMB，需经 HTTP 代理。MPV 使用无 userinfo 的 SMB URI，
    // 并保留 Basic Authorization 给 VidAll_Player 的内部 native bridge 解码后注入 Samba。
    this.normalizeSmbPlaybackSource(videoData);
    let smbOriginalUrl = '';
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

    if (backend === 'mpv') {
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
    };
    return handle;
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

  /** 将历史入口的 URI userinfo 转为独立 Basic header，避免 MPV 拒绝媒体 URI。 */
  private normalizeSmbPlaybackSource(videoData: VideoData): void {
    const smbUri = videoData.videoSrc;
    const schemeEnd = smbUri.indexOf('://');
    if (schemeEnd < 0) {
      return;
    }
    if (smbUri.substring(0, schemeEnd).toLowerCase() !== 'smb') {
      return;
    }
    const authorityStart = schemeEnd + 3;
    const authorityEnd = smbUri.indexOf('/', authorityStart);
    const authority = authorityEnd >= 0
      ? smbUri.substring(authorityStart, authorityEnd)
      : smbUri.substring(authorityStart);
    const atIndex = authority.lastIndexOf('@');
    if (atIndex < 0) {
      return;
    }

    const userInfo = authority.substring(0, atIndex);
    const separator = userInfo.indexOf(':');
    const encodedUsername = separator >= 0 ? userInfo.substring(0, separator) : userInfo;
    const encodedPassword = separator >= 0 ? userInfo.substring(separator + 1) : '';
    try {
      const username = decodeURIComponent(encodedUsername);
      const password = decodeURIComponent(encodedPassword);
      const headerNames = videoData.httpHeader === undefined ? [] : Object.keys(videoData.httpHeader);
      let hasAuthorization = false;
      for (let index = 0; index < headerNames.length; index++) {
        if (headerNames[index].toLowerCase() === 'authorization') {
          hasAuthorization = true;
          break;
        }
      }
      if (!hasAuthorization && (username.length > 0 || password.length > 0)) {
        if (videoData.httpHeader === undefined) {
          videoData.httpHeader = {};
        }
        const credentials = buffer.from(`${username}:${password}`).toString('base64');
        videoData.httpHeader['Authorization'] = `Basic ${credentials}`;
      }
      const hostPort = authority.substring(atIndex + 1);
      const suffix = authorityEnd >= 0 ? smbUri.substring(authorityEnd) : '';
      videoData.videoSrc = `${smbUri.substring(0, authorityStart)}${hostPort}${suffix}`;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '已规范化 SMB 播放源：URI userinfo 已迁移到 header');
    } catch (e) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, 'SMB URI userinfo 解码失败，保持原始播放源');
    }
  }

  /**
   * 仅为 AVPlayer 的本地代理恢复 URI userinfo；MPV 始终消费无凭据 URI 与 Basic header。
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

  /** 释放 adapter；独立 SMB 代理由会话调用方显式释放。 */
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
