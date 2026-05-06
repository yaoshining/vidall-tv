import { IPlayer, SubtitleInfo, TrackInfo } from './IPlayer';
import { VideoData } from './VideoData';
import { media } from '@kit.MediaKit';
import fs from '@ohos.file.fs';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AVPlayerState, VideoDataType } from './Constants';
import { CommonConstants } from '../../../common/constants/CommonConstants';

const TAG = '[AVPlayerAdapter]';

// 轨道信息诊断日志：常态开启，记录字幕轨道 language/mimeType 完整度（#17/#63）
const ENABLE_AVPLAYER_TRACK_DIAG_LOG = true;
const ENABLE_AVPLAYER_SUBTITLE_DIAG_LOG = false;

// AVPlayer 在 API 23+ 的 demux 层可识别这些 codec 并进入 PREPARED，
// 但 decoder 层静默放弃解码导致无声（Issue #212）。
// 需在 PREPARED 时主动检测，若全部音频轨道均属此列则触发 fallback。
// 与 VideoPlayerController.SYSTEM_SOFT_FALLBACK_CODECS 保持内容同步（MIME 格式）。
const UNSUPPORTED_AUDIO_CODECS: string[] = [
  'audio/ac3',        // Dolby Digital (AC-3)
  'audio/eac3',       // Dolby Digital Plus / Atmos (E-AC-3)
  'audio/truehd',     // Dolby TrueHD / Atmos
  'audio/vnd.dts',    // DTS Core
  'audio/vnd.dts.hd', // DTS-HD
  'audio/mlp',        // MLP (Meridian Lossless Packing)
  'audio/vivid',      // Audio Vivid
];

/**
 * AVPlayer 播放内核适配器
 *
 * 封装 HarmonyOS media.AVPlayer 的所有操作，实现 IPlayer 接口。
 * VideoPlayerController 通过 IPlayer 接口调用，不直接依赖此类。
 *
 * 扩展其他内核时（如 IjkPlayer），新建对应 Adapter 实现 IPlayer 即可，
 * VideoPlayerController 无需任何改动。
 */
export class AVPlayerAdapter implements IPlayer {
  private avPlayer?: media.AVPlayer;
  private _surfaceId: string = '';

  // ─── 回调存储 ───
  private _onReadyCb?: () => void;
  private _onPlayCb?: () => void;
  private _onPausedCb?: () => void;
  private _onCompletedCb?: () => void;
  private _onStoppedCb?: () => void;
  private _onTimeUpdateCb?: (currentTime: number) => void;
  private _onErrorCb?: (error: Error) => void;
  private _onUnsupportedFormatCb?: () => void;
  private _onSeekDoneCb?: () => void;
  /** 最近一次 AVPlayer error 事件的错误码，用于在 stateChange(ERROR) 时区分错误类型 */
  private _lastErrorCode: number = 0;
  private _onSubtitleUpdateCb?: (info: SubtitleInfo) => void;

  // ─── IPlayer 属性 ───
  get duration(): number {
    return this.avPlayer?.duration ?? 0;
  }

  get currentTime(): number {
    return this.avPlayer?.currentTime ?? 0;
  }

  // ─── 生命周期 ───

  async init(videoData: VideoData, surfaceId: string): Promise<void> {
    this._surfaceId = surfaceId;
    try {
      const player = await media.createAVPlayer();
      this.avPlayer = player;
      player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;

      // 注册所有 AVPlayer 内部事件，桥接到 IPlayer 回调
      this.bindAVPlayerEvents(player);

      // 设置媒体源
      if (videoData.type === VideoDataType.URL) {
        const playbackStrategy: media.PlaybackStrategy = {
          preferredWidth: 1,
          preferredHeight: 2,
          preferredBufferDuration: 3,
          preferredHdr: true
        };
        const mediaSource = media.createMediaSourceWithUrl(
          videoData.videoSrc,
          videoData.httpHeader
        );
        player.setMediaSource(mediaSource, playbackStrategy);
      } else if (videoData.type === VideoDataType.FILE_URI) {
        const file = fs.openSync(videoData.videoSrc, fs.OpenMode.READ_ONLY);
        player.fdSrc = { fd: file.fd };
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `init 失败: code=${err.code} msg=${err.message}`);
      throw new Error(`AVPlayerAdapter init failed: ${err.message}`);
    }
  }

  async play(): Promise<void> {
    if (!this.avPlayer) {
      return Promise.reject(new Error('AVPlayer not initialized') as BusinessError);
    }
    try {
      return await this.avPlayer.play();
    } catch (e) {
      return Promise.reject(e as BusinessError);
    }
  }

  async pause(): Promise<void> {
    if (!this.avPlayer) {
      return Promise.reject(new Error('AVPlayer not initialized') as BusinessError);
    }
    if (this.avPlayer.state !== AVPlayerState.PLAYING) {
      return Promise.resolve();
    }
    try {
      return await this.avPlayer.pause();
    } catch (e) {
      return Promise.reject(e as BusinessError);
    }
  }

  async toggle(): Promise<void> {
    if (!this.avPlayer) { return; }
    if (this.avPlayer.state === AVPlayerState.PLAYING) {
      await this.pause();
    } else {
      await this.play();
    }
  }

  async release(): Promise<void> {
    if (this.avPlayer) {
      try {
        await this.avPlayer.release();
      } catch (e) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG, `release 异常: ${JSON.stringify(e)}`);
      }
      this.avPlayer = undefined;
    }
  }

  /**
   * 动态更新渲染目标 Surface（用于 VPE 质量切换）。
   * AVPlayer 在 prepared/playing/paused 状态下允许修改 surfaceId。
   */
  updateSurfaceId(newSurfaceId: string): void {
    this._surfaceId = newSurfaceId;
    if (this.avPlayer) {
      this.avPlayer.surfaceId = newSurfaceId;
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, `surfaceId 已更新: ${newSurfaceId}`);
    }
  }

  seek(timeMs: number): void {
    this.avPlayer?.seek(timeMs);
  }

  async forward(milliseconds: number): Promise<void> {
    this.seek((this.avPlayer?.currentTime ?? 0) + milliseconds);
  }

  async backward(milliseconds: number): Promise<void> {
    this.seek((this.avPlayer?.currentTime ?? 0) - milliseconds);
  }

  // ─── 轨道 ───

  async getTrackInfos(): Promise<TrackInfo[]> {
    if (!this.avPlayer) { return []; }
    try {
      const descs = await this.avPlayer.getTrackDescription();
      const result: TrackInfo[] = [];
      for (const desc of descs) {
        const rawType = desc[media.MediaDescriptionKey.MD_KEY_TRACK_TYPE] as number;
        let trackType: 'video' | 'audio' | 'subtitle' = 'video';
        if (rawType === media.MediaType.MEDIA_TYPE_AUD) {
          trackType = 'audio';
        } else if (rawType === media.MediaType.MEDIA_TYPE_SUBTITLE) {
          trackType = 'subtitle';
        } else if (rawType === media.MediaType.MEDIA_TYPE_VID) {
          trackType = 'video';
        }
        const info: TrackInfo = {
          trackIndex: desc[media.MediaDescriptionKey.MD_KEY_TRACK_INDEX] as number,
          trackType,
          mimeType: desc[media.MediaDescriptionKey.MD_KEY_CODEC_MIME] as string | undefined,
          language: desc[media.MediaDescriptionKey.MD_KEY_LANGUAGE] as string | undefined
        };
        result.push(info);
      }
      if (ENABLE_AVPLAYER_TRACK_DIAG_LOG) {
        const subtitleCount = result.filter((t: TrackInfo) => t.trackType === 'subtitle').length;
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `[轨道识别] 总轨道=${result.length} 字幕轨道=${subtitleCount}`);
        for (let i = 0; i < result.length; i++) {
          const track = result[i];
          if (track.trackType !== 'subtitle') {
            continue;
          }
          const hasLang = track.language !== undefined && track.language.length > 0;
          const hasMime = track.mimeType !== undefined && track.mimeType.length > 0;
          const completeness = (hasLang ? 1 : 0) + (hasMime ? 1 : 0);
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `[轨道识别] 字幕[${i}] index=${track.trackIndex}` +
            ` lang=${track.language ?? '(空)'}` +
            ` mime=${track.mimeType ?? '(空)'}` +
            ` 完整度=${completeness}/2`);
        }
      }
      return result;
    } catch (e) {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `getTrackInfos 失败: ${JSON.stringify(e)}`);
      return [];
    }
  }

  async selectTrack(trackIndex: number): Promise<void> {
    if (!this.avPlayer) { return; }
    if (trackIndex < 0) {
      // 关闭字幕：AVPlayer 暂无 deselectTrack API，只重置状态
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '关闭字幕轨道（无 deselectTrack API）');
      return;
    }
    const wasPlaying = this.avPlayer.state === AVPlayerState.PLAYING;
    try {
      if (wasPlaying) { await this.avPlayer.pause(); }
      await this.avPlayer.selectTrack(trackIndex);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, `selectTrack(${trackIndex}) 成功`);
      if (wasPlaying) { await this.avPlayer.play(); }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `selectTrack(${trackIndex}) 失败: code=${err.code} msg=${err.message}`);
      if (wasPlaying) {
        try { await this.avPlayer?.play(); } catch (_) {}
      }
      throw new Error(`selectTrack(${trackIndex}) failed: ${err.message}`);
    }
  }

  /**
   * 设置字幕延迟偏移。
   *
   * AVPlayerAdapter 中此方法是空实现：字幕延迟由 VideoPlayerController
   * 在 SRT 时间轴查找时应用（currentTime - subtitleDelayMs），无需底层支持。
   */
  setSubtitleDelay(_delayMs: number): void {
    // no-op: 延迟偏移由上层 SRT 查找逻辑处理
  }

  /**
   * 设置播放速率。
   * 将浮点速率映射到 media.PlaybackSpeed 枚举后调用 AVPlayer.setSpeed()。
   * 支持：0.5 / 0.75 / 1.0 / 1.25 / 1.5 / 2.0；其余值回退到正常速度。
   */
  setPlaybackSpeed(speed: number): void {
    if (!this.avPlayer) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, `setPlaybackSpeed(${speed}) 忽略：AVPlayer 未初始化`);
      return;
    }
    const playbackSpeed = this.speedToPlaybackSpeed(speed);
    try {
      this.avPlayer.setSpeed(playbackSpeed);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, `setPlaybackSpeed: speed=${speed} enum=${playbackSpeed}`);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `setSpeed 异常，降级为 1.0x: code=${err.code} msg=${err.message}`);
      // 降级：回退到正常速度，避免异常中断调用方后续流程
      try {
        this.avPlayer.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_1_00_X);
      } catch (_) {
        // 降级也失败时静默忽略（播放器可能未就绪或已 release）
      }
    }
  }

  /** 将浮点速率映射到 media.PlaybackSpeed 枚举，不支持的值回退到 1.0x */
  private speedToPlaybackSpeed(speed: number): media.PlaybackSpeed {
    if (speed === 0.5) { return media.PlaybackSpeed.SPEED_FORWARD_0_50_X; }
    if (speed === 0.75) { return media.PlaybackSpeed.SPEED_FORWARD_0_75_X; }
    if (speed === 1.25) { return media.PlaybackSpeed.SPEED_FORWARD_1_25_X; }
    if (speed === 1.5) { return media.PlaybackSpeed.SPEED_FORWARD_1_50_X; }
    if (speed === 2.0) { return media.PlaybackSpeed.SPEED_FORWARD_2_00_X; }
    // 默认/未知速率回退到 1.0x
    return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
  }

  // ─── 事件回调注册 ───

  onReady(callback: () => void): void {
    this._onReadyCb = callback;
  }

  onPlay(callback: () => void): void {
    this._onPlayCb = callback;
  }

  onPaused(callback: () => void): void {
    this._onPausedCb = callback;
  }

  onCompleted(callback: () => void): void {
    this._onCompletedCb = callback;
  }

  onStopped(callback: () => void): void {
    this._onStoppedCb = callback;
  }

  onTimeUpdate(callback: (currentTime: number) => void): void {
    this._onTimeUpdateCb = callback;
  }

  onError(callback: (error: Error) => void): void {
    this._onErrorCb = callback;
  }

  onUnsupportedFormat(callback: () => void): void {
    this._onUnsupportedFormatCb = callback;
  }

  onSeekDone(callback: () => void): void {
    this._onSeekDoneCb = callback;
  }

  onSubtitleUpdate(callback: (info: SubtitleInfo) => void): void {
    this._onSubtitleUpdateCb = callback;
  }

  onBuffering(_callback: (isBuffering: boolean) => void): void {
    // AVPlayer 现阶段仍由控制器基于现有 ready/play 事件维护 loading，不在适配器层追加映射。
  }

  // ─── 内部实现 ───

  /**
   * 绑定 AVPlayer 原生事件到 IPlayer 回调
   * 在 init() 里调用一次即可
   */
  private bindAVPlayerEvents(player: media.AVPlayer): void {
    // stateChange 统一分发
    player.on('stateChange', (state: string) => {
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, `stateChange: ${state}`);
      switch (state) {
        case AVPlayerState.IDLE:
          break;
        case AVPlayerState.INITIALIZED:
          // 设置 Surface 并触发 prepare
          player.surfaceId = this._surfaceId;
          player.prepare().catch((err: BusinessError) => {
            hilog.error(CommonConstants.LOG_DOMAIN, TAG,
              `prepare 失败: code=${err.code} msg=${err.message}`);
          });
          break;
        case AVPlayerState.PREPARED:
          // API 23 eac3 静默失败修复（Issue #212）：
          // demux 可识别 eac3 进入 PREPARED，但 decoder 静默放弃导致无声、不报 error。
          // 在此主动检测所有音频轨道 codec，全为不支持格式时触发 fallback，而非直接调 _onReadyCb。
          player.getTrackDescription().then((tracks: Array<media.MediaDescription>) => {
            // [DIAG] 保留轨道诊断日志
            hilog.info(CommonConstants.LOG_DOMAIN, TAG,
              `[DIAG] PREPARED trackCount=${tracks.length}`);
            for (let i = 0; i < tracks.length; i++) {
              const t = tracks[i];
              hilog.info(CommonConstants.LOG_DOMAIN, TAG,
                `[DIAG] track[${i}] codec=${t[media.MediaDescriptionKey.MD_KEY_CODEC_MIME] ?? 'N/A'} type=${t[media.MediaDescriptionKey.MD_KEY_TRACK_TYPE] ?? 'N/A'} channels=${t[media.MediaDescriptionKey.MD_KEY_AUD_CHANNEL_COUNT] ?? 'N/A'}`);
            }
            // 统计音频轨道中属于不支持格式的数量
            let audioCount = 0;
            let unsupportedCount = 0;
            for (let i = 0; i < tracks.length; i++) {
              const t = tracks[i];
              const trackType = t[media.MediaDescriptionKey.MD_KEY_TRACK_TYPE] as number;
              if (trackType !== media.MediaType.MEDIA_TYPE_AUD) {
                continue;
              }
              audioCount++;
              const mimeType = t[media.MediaDescriptionKey.MD_KEY_CODEC_MIME] as string | undefined;
              if (mimeType !== undefined) {
                const codecLower = mimeType.toLowerCase();
                if (UNSUPPORTED_AUDIO_CODECS.indexOf(codecLower) >= 0) {
                  unsupportedCount++;
                }
              }
            }
            if (audioCount > 0 && audioCount === unsupportedCount) {
              hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
                `所有音频轨道均为不支持格式，主动触发 fallback（音频轨道数=${audioCount}）`);
              if (this._onUnsupportedFormatCb) { this._onUnsupportedFormatCb(); }
              return;
            }
            // 正常 ready 路径
            if (this._onReadyCb) { this._onReadyCb(); }
          }).catch((e: BusinessError) => {
            hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
              `[DIAG] getTrackDescription 失败: ${e.message}`);
            // 无法读取轨道时降级为正常 ready，避免永久阻塞
            if (this._onReadyCb) { this._onReadyCb(); }
          });
          break;
        case AVPlayerState.PLAYING:
          if (this._onPlayCb) { this._onPlayCb(); }
          break;
        case AVPlayerState.PAUSED:
          if (this._onPausedCb) { this._onPausedCb(); }
          break;
        case AVPlayerState.COMPLETED:
          if (this._onCompletedCb) { this._onCompletedCb(); }
          break;
        case AVPlayerState.STOPPED:
          if (this._onStoppedCb) { this._onStoppedCb(); }
          break;
        case AVPlayerState.ERROR:
          // error 事件在 stateChange(ERROR) 之后才触发（实测顺序）
          // 因此这里不能直接用 _lastErrorCode，改为在 error 事件里统一分发
          // 仅做日志，实际回调由下方 error 事件处理
          hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
            `stateChange: error（等待 error 事件获取 code 后分发）`);
          break;
        default:
          break;
      }
    });

    // timeUpdate
    player.on('timeUpdate', () => {
      if (this._onTimeUpdateCb) {
        this._onTimeUpdateCb(player.currentTime);
      }
    });

    // error —— 实测在 stateChange('error') 之后触发，在此统一分发回调
    player.on('error', (error: Error) => {
      const bizErr = error as BusinessError;
      const code = bizErr.code ?? 0;
      this._lastErrorCode = code;
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `AVPlayer error: code=${code} msg=${bizErr.message}`);

      // 格式/流不支持 → 触发 fallback 切换 ijkplayer
      if (code === 5400106 || code === 5400103) {
        hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
          `格式不支持 (code=${code})，触发 onUnsupportedFormat`);
        if (this._onUnsupportedFormatCb) { this._onUnsupportedFormatCb(); }
      } else {
        // 其他错误（网络、文件缺失等）走普通 onError
        if (this._onErrorCb) { this._onErrorCb(error); }
      }
    });

    // seekDone
    player.on('seekDone', () => {
      if (this._onSeekDoneCb) { this._onSeekDoneCb(); }
    });

    // subtitleUpdate
    try {
      player.on('subtitleUpdate', (info: media.SubtitleInfo) => {
        if (ENABLE_AVPLAYER_SUBTITLE_DIAG_LOG) {
          hilog.info(CommonConstants.LOG_DOMAIN, TAG,
            `subtitleUpdate: text="${info.text?.substring(0, 80) ?? ''}" start=${info.startTime ?? 0} duration=${info.duration ?? 0}`);
        }
        if (this._onSubtitleUpdateCb) {
          const si: SubtitleInfo = {
            text: info.text,
            startTime: info.startTime,
            duration: info.duration
          };
          this._onSubtitleUpdateCb(si);
        }
      });
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, '内嵌字幕监听已注册');
    } catch (e) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
        `subtitleUpdate 注册失败（可能当前 API 不支持）: ${JSON.stringify(e)}`);
    }
  }
}