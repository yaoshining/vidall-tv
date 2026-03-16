import { VideoPlayer } from "../../components/core/player";
import { VideoDataType } from "../../components/core/player/Constants";
import { VideoData, PresetAudioTrack, PresetSubtitleTrack } from "../../components/core/player/VideoData";
import {
  VideoPlayerController,
  type PlayerBackend,
  type UnsupportedFormatFallback
} from "../../components/core/player/VideoPlayerController";
import { FileSourceDatabase } from "../../db/files/FileSourceDatabase";
import { PlayProgressEntity } from "../../db/models/MediaEntity";
import { millisecondsToTime } from "../../utils/TimeUtil";
import { PlayerEvents } from "../../components/core/player/Constants";
import { DeviceCapabilityUtil } from "../../utils/DeviceCapabilityUtil";
import { emitter } from "@kit.BasicServicesKit";

export interface PlayerPageParam {
  fileUrl?: string;
  url?: string;
  httpHeader?: Record<string, string>;
  title?: string;
  /** 视频时长提示（毫秒），用于 native 骨架阶段提供进度上限 */
  durationHintMs?: number;
  /** 预置音轨列表（可选），用于 EAC-3/AC-3 等 AVPlayer 无法探测的格式 */
  presetAudioTracks?: PresetAudioTrack[];
  /** 预置字幕轨列表（可选），来自 ffprobe 探测结果，供 ijkplayer 后端字幕枚举 */
  presetSubtitleTracks?: PresetSubtitleTrack[];
  /** 视频 DB id（用于进度持久化） */
  videoId?: number;
  /** TMDB 剧集 ID，电影为空字符串 */
  seriesProviderId?: string;
  /** 季号，电影为 0 */
  seasonNumber?: number;
  /** 集号，电影为 0 */
  episodeNumber?: number;
  /** 可选：强制指定播放后端（当前建议 avplayer / ijkplayer / native） */
  preferredBackend?: PlayerBackend;
  /** 可选：严格锁定 preferredBackend，禁止运行时自动切换到其他后端（用于调试/对照验证） */
  strictPreferredBackend?: boolean;
  /** 可选：AVPlayer 不支持格式时的自动回退后端 */
  unsupportedFormatFallback?: UnsupportedFormatFallback;
}

@ComponentV2
export struct PlayerPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  private videoPlayerController = new VideoPlayerController()
  private videoData?: VideoData
  @Local isBackPressedOnce: boolean = false
  /** 续播提示弹窗 */
  @Local showResumeDialog: boolean = false
  @Local savedPositionMs: number = 0
  @Local totalDurationMs: number = 0
  private pendingSeekMs: number = -1

  private getBackendDebugText(): string {
    const strictText = this.videoPlayerController.isStrictPreferredBackendLocked() ? ' [strict]' : '';
    const backendText = `backend=${this.videoPlayerController.backend}${strictText}`;
    const reason = this.videoPlayerController.lastErrorMessage;
    if (reason.length === 0) {
      return backendText;
    }
    return `${backendText} | ${reason}`;
  }

  private getAudioCapabilityDebugText(): string {
    const text = this.videoPlayerController.audioCapabilityText;
    return text.length > 0 ? text : '音频能力: 暂无';
  }

  private getPresetAudioDebugText(): string {
    const tracks = this.videoData?.presetAudioTracks;
    if (!tracks || tracks.length === 0) {
      return '预置音轨: 0';
    }
    const first = tracks[0];
    const format = first.mimeType && first.mimeType.length > 0 ? first.mimeType : first.displayName;
    return `预置音轨: ${tracks.length} | 首轨=${format}`;
  }

  private getRuntimeTrackDebugText(): string {
    const audioCount = this.videoPlayerController.audioTracks.length;
    const subtitleCount = this.videoPlayerController.allSubtitleTracks.length;
    return `运行时轨道: audio=${audioCount} subtitle=${subtitleCount}`;
  }

  private getActiveAudioDebugText(): string {
    const index = this.videoPlayerController.activeAudioIndex;
    const tracks = this.videoPlayerController.audioTracks;
    if (index < 0 || index >= tracks.length) {
      return '当前音轨: 未选中';
    }
    const current = tracks[index];
    return `当前音轨: ${current.displayName}`;
  }

  private getVideoCapabilityDebugText(codec: string, label: string): string {
    const summary = DeviceCapabilityUtil.buildNativeVideoCapabilitySummary(codec);
    if (!summary.supported) {
      return `${label}: 不支持`;
    }
    const capabilityText = summary.isHardware ? '硬解' : '仅软解';
    const detail = summary.message.replace(`视频能力: ${summary.codecLabel} | `, '');
    return `${label}: ${capabilityText} | ${detail}`;
  }

  private dumpNativeVideoCapabilityMatrix(): void {
    DeviceCapabilityUtil.logNativeVideoDecoderCapabilityMatrix();
  }

  private async runNativeSurfaceProbe(): Promise<void> {
    const summaries = await this.videoPlayerController.runExclusiveNativeVideoDecoderSurfaceProbes(['h264', 'h265']);
    for (let i = 0; i < summaries.length; i++) {
      console.info(`[PlayerPage] surfaceProbe ${summaries[i]}`);
    }
  }

  private switchBackend(targetBackend: PlayerBackend): void {
    this.videoPlayerController.setPreferredBackend(targetBackend, true);
  }

  private isCurrentBackend(targetBackend: PlayerBackend): boolean {
    return this.videoPlayerController.backend === targetBackend;
  }

  private getBackendButtonColor(targetBackend: PlayerBackend): string {
    if (this.isCurrentBackend(targetBackend)) {
      return '#1B78F2';
    }
    return '#333333';
  }

  @Builder
  BackendDebugPanel() {
    Column({ space: 8 }) {
      Text(this.getBackendDebugText())
        .fontSize(12)
        .fontColor('#E6FFFFFF')
        .backgroundColor('#66000000')
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(4)

      Text(this.getAudioCapabilityDebugText())
        .fontSize(11)
        .fontColor('#CCFFFFFF')
        .backgroundColor('#66000000')
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(4)

      Text(this.getPresetAudioDebugText())
        .fontSize(11)
        .fontColor('#CCFFFFFF')
        .backgroundColor('#66000000')
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(4)

      Text(this.getRuntimeTrackDebugText())
        .fontSize(11)
        .fontColor('#CCFFFFFF')
        .backgroundColor('#66000000')
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(4)

      Text(this.getActiveAudioDebugText())
        .fontSize(11)
        .fontColor('#CCFFFFFF')
        .backgroundColor('#66000000')
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(4)

      Text(this.getVideoCapabilityDebugText('h264', 'H264'))
        .fontSize(11)
        .fontColor('#CCFFFFFF')
        .backgroundColor('#66000000')
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(4)

      Text(this.getVideoCapabilityDebugText('h265', 'H265'))
        .fontSize(11)
        .fontColor('#CCFFFFFF')
        .backgroundColor('#66000000')
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(4)

      Text(this.getVideoCapabilityDebugText('av1', 'AV1'))
        .fontSize(11)
        .fontColor('#CCFFFFFF')
        .backgroundColor('#66000000')
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(4)

      Row({ space: 8 }) {
        Button('AV')
          .fontSize(11)
          .fontColor(Color.White)
          .backgroundColor(this.getBackendButtonColor('avplayer'))
          .borderRadius(4)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick(() => {
            this.switchBackend('avplayer')
          })

        Button('Native')
          .fontSize(11)
          .fontColor(Color.White)
          .backgroundColor(this.getBackendButtonColor('native'))
          .borderRadius(4)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick(() => {
            this.switchBackend('native')
          })

        Button('IJK')
          .fontSize(11)
          .fontColor(Color.White)
          .backgroundColor(this.getBackendButtonColor('ijkplayer'))
          .borderRadius(4)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick(() => {
            this.switchBackend('ijkplayer')
          })

        Button('Probe')
          .fontSize(11)
          .fontColor(Color.White)
          .backgroundColor('#5C3FB5')
          .borderRadius(4)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick(() => {
            this.dumpNativeVideoCapabilityMatrix()
          })

        Button('Surface')
          .fontSize(11)
          .fontColor(Color.White)
          .backgroundColor('#9C4A1A')
          .borderRadius(4)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick(() => {
            this.runNativeSurfaceProbe()
          })
      }
    }
    .alignItems(HorizontalAlign.Start)
  }

  static PAGE_NAME = 'player'

  /** 格式化毫秒为 MM:SS 或 HH:MM:SS */
  private formatTime(ms: number): string {
    return millisecondsToTime(ms);
  }

  @Builder
  ResumeDialog() {
    if (this.showResumeDialog) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%').height('100%')
          .backgroundColor('#88000000')

        Column({ space: 20 }) {
          Text('续播')
            .fontSize(26).fontColor(Color.White).fontWeight(FontWeight.Bold)

          Text(`上次看到 ${this.formatTime(this.savedPositionMs)}，是否继续？`)
            .fontSize(18).fontColor('#CCCCCC').textAlign(TextAlign.Center)

          Row({ space: 24 }) {
            Button('从头播放')
              .fontSize(16).fontColor(Color.White)
              .backgroundColor('#333333')
              .borderRadius(6)
              .padding({ left: 24, right: 24, top: 10, bottom: 10 })
              .onClick(() => {
                this.showResumeDialog = false;
                this.videoPlayerController.seek(0);
              })

            Button('续播')
              .fontSize(16).fontColor(Color.White)
              .backgroundColor('#1B78F2')
              .borderRadius(6)
              .padding({ left: 24, right: 24, top: 10, bottom: 10 })
              .onClick(() => {
                this.showResumeDialog = false;
                this.videoPlayerController.seek(this.pendingSeekMs);
              })
          }
          .justifyContent(FlexAlign.Center)
        }
        .padding(36)
        .backgroundColor('#222222')
        .borderRadius(16)
        .border({ width: 1, color: '#333333' })
        .width(420)
      }
      .width('100%').height('100%')
    }
  }

  build() {
    NavDestination() {
      RelativeContainer() {
        if (this.videoData) {
          VideoPlayer({
            controller: this.videoPlayerController,
            data: this.videoData,
            autoPlay: true
          })
            .alignRules({
              center: { anchor: '__container__', align: VerticalAlign.Center },
              middle: { anchor: '__container__', align: HorizontalAlign.Center }
            })
        }

        if (this.isBackPressedOnce) {
          Text("再次按返回键退出播放")
            .margin({ bottom: 100 })
            .fontSize($r('app.float.font_h7_title_small'))
            .fontColor(Color.White)
            .backgroundColor('#99000000')
            .padding(8)
            .borderRadius(4)
            .backdropBlur(0.8)
            .shadow({
              radius: 8,
              color: '#66000000',
              offsetX: 2,
              offsetY: 2,
            })
            .animation({
              duration: 200,
              curve: Curve.EaseInOut,
              iterations: 1,
              playMode: PlayMode.Normal
            })
            .alignRules({
              bottom: { anchor: '__container__', align: VerticalAlign.Bottom },
              middle: { anchor: '__container__', align: HorizontalAlign.Center }
            })
        }

        this.ResumeDialog()

        Column() {
          this.BackendDebugPanel()
        }
          .alignRules({
            top: { anchor: '__container__', align: VerticalAlign.Top },
            left: { anchor: '__container__', align: HorizontalAlign.Start }
          })
          .margin({ top: 20, left: 20 })

        XComponent({
          id: 'nativeProbeXComponent',
          type: XComponentType.SURFACE,
          libraryname: 'vidall_core_player_napi'
        })
          .onLoad((context: object) => {
            this.videoPlayerController.setNativeProbeContext(context, 'nativeProbeXComponent')
          })
          .width(8)
          .height(8)
          .opacity(0.01)
          .backgroundColor(Color.Transparent)
          .alignRules({
            bottom: { anchor: '__container__', align: VerticalAlign.Bottom },
            right: { anchor: '__container__', align: HorizontalAlign.End }
          })
          .margin({ bottom: 4, right: 4 })
      }
      .height('100%')
      .width('100%')
    }
    .onReady((context) => {
      // 订阅 App 切后台事件，确保进度立即落盘
      emitter.on(PlayerEvents.APP_BACKGROUND, () => {
        this.videoPlayerController.saveProgressNow();
      });

      let pageParam = context.pathInfo.param as PlayerPageParam
      if (pageParam) {
        if (pageParam.preferredBackend) {
          this.videoPlayerController.setPreferredBackend(
            pageParam.preferredBackend,
            pageParam.strictPreferredBackend === true
          );
        }
        if (pageParam.unsupportedFormatFallback) {
          this.videoPlayerController.setUnsupportedFormatFallback(pageParam.unsupportedFormatFallback);
        }

        if (pageParam.url) {
          this.videoData = {
            type: VideoDataType.URL,
            videoSrc: pageParam.url
          }
        } else if (pageParam.fileUrl) {
          this.videoData = {
            type: VideoDataType.FILE_URI,
            videoSrc: pageParam.fileUrl
          }
        }
        if (this.videoData) {
          this.videoData.httpHeader = pageParam.httpHeader
          this.videoData.name = pageParam.title
          if (pageParam.durationHintMs !== undefined && pageParam.durationHintMs > 0) {
            this.videoData.durationHintMs = pageParam.durationHintMs
          }
          if (pageParam.presetAudioTracks && pageParam.presetAudioTracks.length > 0) {
            this.videoData.presetAudioTracks = pageParam.presetAudioTracks
          }
          if (pageParam.presetSubtitleTracks && pageParam.presetSubtitleTracks.length > 0) {
            this.videoData.presetSubtitleTracks = pageParam.presetSubtitleTracks
          }
        }

        // 设置进度上下文（有 videoId 才启用进度功能）
        if (pageParam.videoId !== undefined && pageParam.videoId > 0) {
          const ctx: PlayProgressEntity = {
            videoId: pageParam.videoId,
            seriesProviderId: pageParam.seriesProviderId ?? '',
            seasonNumber: pageParam.seasonNumber ?? 0,
            episodeNumber: pageParam.episodeNumber ?? 0,
            positionMs: 0,
            durationMs: 0,
            updatedAt: 0
          };
          this.videoPlayerController.progressContext = ctx;

          // 播放器 prepared 后检查是否有已保存进度
          emitter.once(PlayerEvents.PREPARED, () => {
            const videoId = pageParam.videoId ?? 0;
            FileSourceDatabase.getInstance().getPlayProgress(videoId).then((saved) => {
              if (saved !== null && saved.positionMs > 0) {
                const dur = this.videoPlayerController.duration;
                const isWatched = dur > 0 && saved.positionMs >= dur * 0.95;
                this.savedPositionMs = saved.positionMs;
                this.totalDurationMs = dur > 0 ? dur : saved.durationMs;
                if (isWatched) {
                  // 视为看完，默认从头，仍弹提示
                  this.pendingSeekMs = 0;
                } else {
                  this.pendingSeekMs = saved.positionMs;
                }
                this.showResumeDialog = true;
              }
            }).catch(() => {});
          });
        }
      }
    })
    .onBackPressed(() => {
      if (this.isBackPressedOnce) {
        return false
      } else {
        this.isBackPressedOnce = true
        setTimeout(() => {
          this.isBackPressedOnce = false
        }, 2000)
        return true
      }
    })
    .hideTitleBar(true)
  }

  aboutToDisappear(): void {
    emitter.off(PlayerEvents.APP_BACKGROUND.eventId)
    this.videoPlayerController.saveProgressNow()
    this.videoPlayerController.release()
  }
}
