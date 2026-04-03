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
import { MediaProgressStore } from "../../db/MediaProgressStore";
import { millisecondsToTime } from "../../utils/TimeUtil";
import { PlayerEvents } from "../../components/core/player/Constants";
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
  /** 可选：AVPlayer 不支持格式时的自动回退后端 */
  unsupportedFormatFallback?: UnsupportedFormatFallback;
  /**
   * 媒体级进度 key（由 MediaProgressStore.seriesKey / movieKey 生成）。
   * 设置后，播放器使用媒体级进度续播（直接 seek，不弹续播弹窗），
   * 并在退出/切后台时回写媒体级进度，完播时自动清除。
   */
  mediaKey?: string;
  /**
   * 集内起播位置（毫秒）。由调用方从 play_progress 表按 videoId 查出后传入。
   * 优先级高于 mediaKey 路径的 MediaProgressStore.get() seek。
   * 若未设置或为 0，则回退到 media_progress 同季同集匹配 seek 逻辑。
   */
  startPositionMs?: number;
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
  /** 媒体级进度 key（来自 PlayerPageParam.mediaKey） */
  private currentMediaKey: string = '';
  /** 媒体级进度：当前集季号 */
  private currentMediaSeason: number = 0;
  /** 媒体级进度：当前集号 */
  private currentMediaEpisode: number = 0;
  /** media_progress 周期写入定时器 ID，-1 表示未启动 */
  private mediaProgressTimerId: number = -1;

  private getBackendDebugText(): string {
    const proto = this.videoPlayerController.sourceProtocol;
    const rawBackend = this.videoPlayerController.backend;
    // SMB 源实际走 OH_AVPlayer + C++ HTTP 代理，显示更具体的标签
    const backendLabel = (rawBackend === 'native' && proto === 'SMB')
      ? 'avplayer(smb-proxy)'
      : rawBackend;
    const protoSuffix = proto.length > 0 ? ` | ${proto}` : '';
    const backendText = `backend=${backendLabel}${protoSuffix}`;
    const reason = this.videoPlayerController.lastErrorMessage;
    if (reason.length === 0) {
      return backendText;
    }
    return `${backendText} | ${reason}`;
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

        Text(this.getBackendDebugText())
          .fontSize(12)
          .fontColor('#E6FFFFFF')
          .backgroundColor('#66000000')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(4)
          .alignRules({
            top: { anchor: '__container__', align: VerticalAlign.Top },
            left: { anchor: '__container__', align: HorizontalAlign.Start }
          })
          .margin({ top: 20, left: 20 })
      }
      .height('100%')
      .width('100%')
    }
    .onReady((context) => {
      // 订阅 App 切后台事件，确保进度立即落盘
      emitter.on(PlayerEvents.APP_BACKGROUND, () => {
        this.videoPlayerController.saveProgressNow();
        // 媒体级进度：切后台时保存当前位置
        if (this.currentMediaKey.length > 0) {
          const posMs = this.videoPlayerController.currentTime;
          const durMs = this.videoPlayerController.duration;
          if (posMs > 0 && durMs > 0) {
            MediaProgressStore.save(
              this.currentMediaKey, posMs, durMs,
              this.currentMediaSeason, this.currentMediaEpisode
            ).catch(() => {});
          }
        }
      });

      // 每 10 秒写入一次 media_progress，避免退出时异步写与 onShown 读产生竞态
      this.mediaProgressTimerId = setInterval(() => {
        if (this.currentMediaKey.length > 0) {
          const posMs: number = this.videoPlayerController.currentTime;
          const durMs: number = this.videoPlayerController.duration;
          if (posMs > 0 && durMs > 0) {
            MediaProgressStore.save(
              this.currentMediaKey, posMs, durMs,
              this.currentMediaSeason, this.currentMediaEpisode
            ).catch(() => {});
          }
        }
      }, 10000);

      let pageParam = context.pathInfo.param as PlayerPageParam
      if (pageParam) {
        if (pageParam.preferredBackend) {
          this.videoPlayerController.backend = pageParam.preferredBackend === 'ffmpeg'
            ? 'ijkplayer'
            : pageParam.preferredBackend;
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

          const mKey = pageParam.mediaKey ?? '';
          if (mKey.length > 0) {
            // ── 媒体级入口：直接 seek，不弹续播弹窗 ──────────────────────
            this.currentMediaKey = mKey;
            this.currentMediaSeason = pageParam.seasonNumber ?? 0;
            this.currentMediaEpisode = pageParam.episodeNumber ?? 0;
            emitter.once(PlayerEvents.PREPARED, () => {
              // 优先使用调用方从 play_progress 查到的集内起播位置（精确、不跨集）
              const directStart = pageParam.startPositionMs ?? 0;
              if (directStart > 0) {
                this.videoPlayerController.seek(directStart).catch(() => {});
                return;
              }
              // 回退：读 media_progress，但必须与当前季/集完全匹配，防止跨集乱 seek
              MediaProgressStore.get(this.currentMediaKey).then((saved) => {
                if (saved !== null && saved.positionMs > 0
                    && saved.seasonNumber === this.currentMediaSeason
                    && saved.episodeNumber === this.currentMediaEpisode) {
                  const dur = this.videoPlayerController.duration;
                  const isNearEnd = MediaProgressStore.isNearEnd(saved.positionMs, dur > 0 ? dur : saved.durationMs);
                  if (!isNearEnd) {
                    this.videoPlayerController.seek(saved.positionMs).catch(() => {});
                  } else {
                    // 进程被杀前已近结尾，清除残留进度避免详情页仍显示"继续播放"
                    MediaProgressStore.clear(this.currentMediaKey).catch(() => {});
                  }
                }
              }).catch(() => {});
            });
          } else {
            // ── 文件级入口：显示续播弹窗（原有逻辑不变）────────────────────
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
    if (this.mediaProgressTimerId >= 0) {
      clearInterval(this.mediaProgressTimerId);
      this.mediaProgressTimerId = -1;
    }
    // 媒体级进度：完播则清除，否则保存当前位置；结束后通知继续播放栏刷新
    if (this.currentMediaKey.length > 0) {
      const posMs = this.videoPlayerController.currentTime;
      const durMs = this.videoPlayerController.duration;
      console.info(`[PlayerPage][REFRESH] aboutToDisappear: currentMediaKey=${this.currentMediaKey} posMs=${posMs} durMs=${durMs}`);
      // duration 未就绪时跳过完播判断，避免 duration=0 误清除进度
      if (durMs > 0) {
        if (MediaProgressStore.isNearEnd(posMs, durMs)) {
          MediaProgressStore.clear(this.currentMediaKey).then(() => {
            console.info('[PlayerPage][REFRESH] clear 完成，emit MEDIA_PROGRESS_SAVED');
            emitter.emit(PlayerEvents.MEDIA_PROGRESS_SAVED);
          }).catch(() => {
            console.warn('[PlayerPage][REFRESH] clear 失败，仍 emit MEDIA_PROGRESS_SAVED');
            emitter.emit(PlayerEvents.MEDIA_PROGRESS_SAVED);
          });
        } else if (posMs > 0) {
          MediaProgressStore.save(
            this.currentMediaKey, posMs, durMs,
            this.currentMediaSeason, this.currentMediaEpisode
          ).then(() => {
            console.info('[PlayerPage][REFRESH] save 完成，emit MEDIA_PROGRESS_SAVED');
            emitter.emit(PlayerEvents.MEDIA_PROGRESS_SAVED);
          }).catch(() => {
            console.warn('[PlayerPage][REFRESH] save 失败，仍 emit MEDIA_PROGRESS_SAVED');
            emitter.emit(PlayerEvents.MEDIA_PROGRESS_SAVED);
          });
        } else {
          console.info('[PlayerPage][REFRESH] posMs=0，直接 emit MEDIA_PROGRESS_SAVED');
          emitter.emit(PlayerEvents.MEDIA_PROGRESS_SAVED);
        }
      } else {
        console.info('[PlayerPage][REFRESH] durMs=0，直接 emit MEDIA_PROGRESS_SAVED');
        emitter.emit(PlayerEvents.MEDIA_PROGRESS_SAVED);
      }
    } else {
      console.info('[PlayerPage][REFRESH] currentMediaKey 为空，跳过 emit');
    }
    this.videoPlayerController.saveProgressNow()
    this.videoPlayerController.release()
  }
}