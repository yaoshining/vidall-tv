import { VideoPlayer } from "../../components/core/player";
import { VideoDataType } from "../../components/core/player/Constants";
import { VideoData, PresetAudioTrack, PresetSubtitleTrack } from "../../components/core/player/VideoData";
import {
  VideoPlayerController,
  type PlayerBackend,
  type UnsupportedFormatFallback
} from "../../components/core/player/VideoPlayerController";
import { PlaybackContext, PlaybackContextItem, MediaLibraryContext } from "../../components/core/player/PlaybackContext";
import { FileSourceDatabase } from "../../db/files/FileSourceDatabase";
import { PlayProgressEntity } from "../../db/models/MediaEntity";
import { MediaProgressStore } from "../../db/MediaProgressStore";
import { millisecondsToTime } from "../../utils/TimeUtil";
import { PlayerEvents } from "../../components/core/player/Constants";
import { emitter } from "@kit.BasicServicesKit";
import { SubtitleSegment } from "../../components/core/player/SubtitleRenderer";
import { WebDAVClient, WebDAVConfig } from "../../lib/WebDAVClient";
import { FileSourceType, SMBSourceConfig, WebDAVSourceConfig } from "../../db/models/FileSourceEntity";
import { FfprobeUtil, FfprobeTrack } from "../../utils/FfprobeUtil";

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
  /**
   * 播放上下文（可选）。携带当季集列表及当前集索引，供播放器内连播/上下集跳转使用。
   * 由 SeasonDetailPage / SeriesDetailPage 在 playEpisode() 中构建并传入。
   */
  playbackContext?: PlaybackContext;
}

export interface ResolvedEpisodePlaybackSource {
  url: string;
  httpHeader?: Record<string, string>;
  durationHintMs?: number;
  presetAudioTracks?: PresetAudioTrack[];
  presetSubtitleTracks?: PresetSubtitleTrack[];
  startPositionMs?: number;
}

function buildPlayerEpisodeCode(seasonNumber: number, episodeNumber: number): string {
  const sn = seasonNumber > 0 ? seasonNumber : 0;
  const en = episodeNumber > 0 ? episodeNumber : 0;
  return `S${sn}:E${en}`;
}

function buildEpisodeSwitchPlayerTitle(
  currentParam: PlayerPageParam,
  episodeTitle: string,
  seasonNumber: number,
  episodeNumber: number
): string | undefined {
  const nextEpisodeTitle = episodeTitle.length > 0
    ? episodeTitle
    : (episodeNumber > 0 ? `第${episodeNumber}集` : currentParam.title);
  const currentTitle = (currentParam.title ?? '').trim();
  if (currentTitle.length === 0) {
    return nextEpisodeTitle;
  }
  const currentSeasonNumber = currentParam.seasonNumber ?? 0;
  const currentEpisodeNumber = currentParam.episodeNumber ?? 0;
  const currentCodeMarker = `-${buildPlayerEpisodeCode(currentSeasonNumber, currentEpisodeNumber)}-`;
  const currentCodeIndex = currentTitle.indexOf(currentCodeMarker);
  if (currentCodeIndex < 0) {
    return currentTitle;
  }
  const titlePrefix = currentTitle.substring(0, currentCodeIndex);
  const nextCode = buildPlayerEpisodeCode(seasonNumber, episodeNumber);
  return `${titlePrefix}-${nextCode}-${nextEpisodeTitle}`;
}

export function buildMediaLibraryEpisodeSwitchParam(
  currentParam: PlayerPageParam,
  playbackContext: PlaybackContext | undefined,
  selectedItem: PlaybackContextItem,
  resolvedSource: ResolvedEpisodePlaybackSource
): PlayerPageParam | null {
  if (playbackContext === undefined || playbackContext.contextType !== 'media_library') {
    return null;
  }
  const mediaLibraryContext = playbackContext as MediaLibraryContext;
  if (selectedItem.index < 0 || selectedItem.index >= mediaLibraryContext.items.length) {
    return null;
  }
  const seasonNumber = selectedItem.seasonNumber ?? currentParam.seasonNumber ?? 0;
  const episodeNumber = selectedItem.episodeNumber ?? currentParam.episodeNumber ?? 0;
  const seriesProviderId = currentParam.seriesProviderId ?? '';
  const mediaKey = (seriesProviderId.length > 0 && seasonNumber > 0 && episodeNumber > 0)
    ? MediaProgressStore.episodeKey(seriesProviderId, seasonNumber, episodeNumber)
    : undefined;
  const itemTitle = selectedItem.title.trim();
  const playerTitle = buildEpisodeSwitchPlayerTitle(currentParam, itemTitle, seasonNumber, episodeNumber);
  const nextParam: PlayerPageParam = {
    url: resolvedSource.url,
    httpHeader: resolvedSource.httpHeader,
    title: playerTitle,
    durationHintMs: resolvedSource.durationHintMs,
    videoId: selectedItem.videoId,
    seriesProviderId,
    seasonNumber,
    episodeNumber,
    preferredBackend: currentParam.preferredBackend,
    unsupportedFormatFallback: currentParam.unsupportedFormatFallback,
    presetAudioTracks: resolvedSource.presetAudioTracks,
    presetSubtitleTracks: resolvedSource.presetSubtitleTracks,
    mediaKey,
    startPositionMs: resolvedSource.startPositionMs,
    playbackContext: mediaLibraryContext
  };
  return nextParam;
}

export function commitMediaLibraryEpisodeSwitch(
  playbackContext: PlaybackContext | undefined,
  selectedItem: PlaybackContextItem
): PlaybackContextItem | null {
  if (playbackContext === undefined || playbackContext.contextType !== 'media_library') {
    return null;
  }
  const mediaLibraryContext = playbackContext as MediaLibraryContext;
  return mediaLibraryContext.jumpTo(selectedItem.index);
}

@ComponentV2
export struct PlayerPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  private videoPlayerController = new VideoPlayerController()
  private videoData?: VideoData
  private currentPageParam?: PlayerPageParam
  private pageParamToken: number = 0
  private episodeSwitching: boolean = false
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
  /** 文件不存在时待 pop 的 videoId（-1 表示无） */
  private fileNotFoundVideoId: number = -1;

  /** 合并字幕行中各 Segment 的文本 */
  private mergeSubtitleLineText(line: SubtitleSegment[]): string {
    let merged = ''
    for (let i = 0; i < line.length; i++) {
      merged += line[i].text
    }
    return merged
  }

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

  private buildVideoDataFromParam(pageParam: PlayerPageParam): VideoData | undefined {
    let nextVideoData: VideoData | undefined = undefined;
    if (pageParam.url) {
      nextVideoData = {
        type: VideoDataType.URL,
        videoSrc: pageParam.url
      };
    } else if (pageParam.fileUrl) {
      nextVideoData = {
        type: VideoDataType.FILE_URI,
        videoSrc: pageParam.fileUrl
      };
    }
    if (nextVideoData === undefined) {
      return undefined;
    }
    nextVideoData.httpHeader = pageParam.httpHeader;
    nextVideoData.name = pageParam.title;
    if (pageParam.durationHintMs !== undefined && pageParam.durationHintMs > 0) {
      nextVideoData.durationHintMs = pageParam.durationHintMs;
    }
    if (pageParam.presetAudioTracks && pageParam.presetAudioTracks.length > 0) {
      nextVideoData.presetAudioTracks = pageParam.presetAudioTracks;
    }
    if (pageParam.presetSubtitleTracks && pageParam.presetSubtitleTracks.length > 0) {
      nextVideoData.presetSubtitleTracks = pageParam.presetSubtitleTracks;
    }
    return nextVideoData;
  }

  private buildProgressContext(pageParam: PlayerPageParam): PlayProgressEntity {
    const ctx: PlayProgressEntity = {
      videoId: pageParam.videoId ?? 0,
      seriesProviderId: pageParam.seriesProviderId ?? '',
      seasonNumber: pageParam.seasonNumber ?? 0,
      episodeNumber: pageParam.episodeNumber ?? 0,
      positionMs: 0,
      durationMs: 0,
      updatedAt: 0
    };
    return ctx;
  }

  private resumePlaybackForParam(pageParam: PlayerPageParam): void {
    const mediaKey = pageParam.mediaKey ?? '';
    if (mediaKey.length > 0) {
      const directStart = pageParam.startPositionMs ?? 0;
      if (directStart > 0) {
        this.videoPlayerController.seek(directStart).catch(() => {});
        return;
      }
      MediaProgressStore.get(mediaKey).then((saved) => {
        if (saved !== null && saved.positionMs > 0
            && saved.seasonNumber === this.currentMediaSeason
            && saved.episodeNumber === this.currentMediaEpisode) {
          const dur = this.videoPlayerController.duration;
          const isNearEnd = MediaProgressStore.isNearEnd(saved.positionMs, dur > 0 ? dur : saved.durationMs);
          if (!isNearEnd) {
            this.videoPlayerController.seek(saved.positionMs).catch(() => {});
          } else {
            MediaProgressStore.clear(mediaKey).catch(() => {});
          }
        } else {
          this.videoPlayerController.play().catch(() => {});
        }
      }).catch(() => {
        this.videoPlayerController.play().catch(() => {});
      });
      return;
    }
    this.videoPlayerController.play().catch(() => {});
  }

  private registerPreparedResume(pageParam: PlayerPageParam, token: number): void {
    emitter.once(PlayerEvents.PREPARED, () => {
      if (token !== this.pageParamToken) {
        return;
      }
      const mediaKey = pageParam.mediaKey ?? '';
      if (mediaKey.length > 0) {
        this.resumePlaybackForParam(pageParam);
        return;
      }
      const videoId = pageParam.videoId ?? 0;
      FileSourceDatabase.getInstance().getPlayProgress(videoId).then((saved) => {
        if (token !== this.pageParamToken) {
          return;
        }
        if (saved !== null && saved.positionMs > 0) {
          const dur = this.videoPlayerController.duration;
          const isWatched = dur > 0 && saved.positionMs >= dur * 0.95;
          this.savedPositionMs = saved.positionMs;
          this.totalDurationMs = dur > 0 ? dur : saved.durationMs;
          if (isWatched) {
            this.pendingSeekMs = 0;
          } else {
            this.pendingSeekMs = saved.positionMs;
          }
          this.showResumeDialog = true;
        }
      }).catch(() => {});
    });
  }

  private applyPlayerPageParam(pageParam: PlayerPageParam): void {
    this.currentPageParam = pageParam;
    this.pageParamToken += 1;
    const token = this.pageParamToken;
    if (pageParam.preferredBackend) {
      this.videoPlayerController.backend = pageParam.preferredBackend === 'ffmpeg'
        ? 'ijkplayer'
        : pageParam.preferredBackend;
    }
    if (pageParam.unsupportedFormatFallback) {
      this.videoPlayerController.setUnsupportedFormatFallback(pageParam.unsupportedFormatFallback);
    }
    this.videoData = this.buildVideoDataFromParam(pageParam);
    this.videoPlayerController.progressContext = null;
    this.currentMediaKey = '';
    this.currentMediaSeason = 0;
    this.currentMediaEpisode = 0;
    this.currentMediaKey = pageParam.mediaKey ?? '';
    this.currentMediaSeason = pageParam.seasonNumber ?? 0;
    this.currentMediaEpisode = pageParam.episodeNumber ?? 0;
    this.showResumeDialog = false;
    this.pendingSeekMs = -1;
    if (pageParam.videoId !== undefined && pageParam.videoId > 0) {
      this.videoPlayerController.progressContext = this.buildProgressContext(pageParam);
      this.registerPreparedResume(pageParam, token);
    }
    this.videoPlayerController.playbackContext = pageParam.playbackContext;
  }

  private persistCurrentPlaybackState(): void {
    this.videoPlayerController.saveProgressNow();
    if (this.currentMediaKey.length === 0) {
      return;
    }
    const posMs = this.videoPlayerController.currentTime;
    const durMs = this.videoPlayerController.duration;
    if (durMs <= 0) {
      return;
    }
    if (MediaProgressStore.isNearEnd(posMs, durMs)) {
      MediaProgressStore.clear(this.currentMediaKey).catch(() => {});
      return;
    }
    if (posMs > 0) {
      MediaProgressStore.save(
        this.currentMediaKey,
        posMs,
        durMs,
        this.currentMediaSeason,
        this.currentMediaEpisode
      ).catch(() => {});
    }
  }

  private async resolveEpisodePlaybackSource(item: PlaybackContextItem): Promise<ResolvedEpisodePlaybackSource | null> {
    if (item.sourceId === undefined || item.sourceId <= 0) {
      return null;
    }
    const db = FileSourceDatabase.getInstance();
    const fileSource = await db.getFileSourceById(item.sourceId);
    if (fileSource === null) {
      return null;
    }
    let url = '';
    let httpHeader: Record<string, string> | undefined = undefined;
    if (fileSource.type === FileSourceType.SMB) {
      const smbConfig = JSON.parse(fileSource.configJson) as SMBSourceConfig;
      const port = smbConfig.port ?? 445;
      const user = encodeURIComponent(smbConfig.username);
      const pass = encodeURIComponent(smbConfig.password);
      const encodedPath = item.videoPath.split('/').map((seg: string): string => {
        if (seg.length === 0) {
          return '';
        }
        let decoded = seg;
        try {
          decoded = decodeURIComponent(seg);
        } catch {
          decoded = seg;
        }
        return encodeURIComponent(decoded);
      }).join('/');
      url = `smb://${user}:${pass}@${smbConfig.host}:${port}${encodedPath}`;
    } else if (fileSource.type === FileSourceType.WEBDAV) {
      const config = JSON.parse(fileSource.configJson) as WebDAVSourceConfig;
      const protocol = config.protocol ?? 'http';
      const host = config.url ?? '';
      const port = config.port ?? (protocol === 'https' ? 443 : 80);
      const rootPath = (config.rootPath ?? '').replace(/\/$/, '');
      const baseUrl = `${protocol}://${host}:${port}${rootPath}`;
      const webdavConfig: WebDAVConfig = {
        baseUrl,
        username: config.username ?? '',
        password: config.password ?? '',
        timeout: 30000
      };
      const client = new WebDAVClient(webdavConfig);
      url = client.getFullUrl(item.videoPath);
      const authHeader = client.getAuthHeaderPublic();
      if (authHeader.length > 0) {
        httpHeader = { 'Authorization': authHeader };
      }
    } else {
      return null;
    }

    const videoEntity = await db.getVideoByPath(item.videoPath);
    let durationHintMs = item.durationMs ?? 0;
    let presetAudioTracks: PresetAudioTrack[] | undefined = undefined;
    let presetSubtitleTracks: PresetSubtitleTrack[] | undefined = undefined;
    if (videoEntity !== null) {
      durationHintMs = videoEntity.durationMs ?? durationHintMs;
      if (videoEntity.audioTracksJson !== undefined && videoEntity.audioTracksJson !== null &&
          videoEntity.audioTracksJson.length > 0) {
        const audioTracks = JSON.parse(videoEntity.audioTracksJson) as FfprobeTrack[];
        const mappedAudioTracks = FfprobeUtil.toPresetAudioTracks(audioTracks);
        if (mappedAudioTracks.length > 0) {
          presetAudioTracks = mappedAudioTracks;
        }
      }
      if (videoEntity.subtitleTracksJson !== undefined && videoEntity.subtitleTracksJson !== null &&
          videoEntity.subtitleTracksJson.length > 0) {
        const subtitleTracks = JSON.parse(videoEntity.subtitleTracksJson) as FfprobeTrack[];
        const mappedSubtitleTracks = FfprobeUtil.toPresetSubtitleTracks(subtitleTracks);
        if (mappedSubtitleTracks.length > 0) {
          presetSubtitleTracks = mappedSubtitleTracks;
        }
      }
    }

    let startPositionMs = 0;
    const progressVideoId = item.videoId ?? videoEntity?.id ?? 0;
    if (progressVideoId > 0) {
      const savedProgress = await db.getPlayProgress(progressVideoId);
      if (savedProgress !== null && savedProgress.positionMs > 0) {
        const isWatched = savedProgress.durationMs > 0
          && savedProgress.positionMs >= savedProgress.durationMs * 0.95;
        if (!isWatched) {
          startPositionMs = savedProgress.positionMs;
        }
      }
    }
    const resolvedSource: ResolvedEpisodePlaybackSource = {
      url,
      httpHeader,
      durationHintMs: durationHintMs > 0 ? durationHintMs : undefined,
      presetAudioTracks,
      presetSubtitleTracks,
      startPositionMs: startPositionMs > 0 ? startPositionMs : undefined
    };
    return resolvedSource;
  }

  private isCurrentMediaLibraryEpisodeSelection(
    currentParam: PlayerPageParam,
    playbackContext: PlaybackContext | undefined,
    item: PlaybackContextItem
  ): boolean {
    if (playbackContext === undefined || playbackContext.contextType !== 'media_library') {
      return false;
    }
    const mediaLibraryContext = playbackContext as MediaLibraryContext;
    if (item.index === mediaLibraryContext.currentIndex) {
      return true;
    }
    const currentSeasonNumber = currentParam.seasonNumber ?? 0;
    const currentEpisodeNumber = currentParam.episodeNumber ?? 0;
    if (currentSeasonNumber <= 0 || currentEpisodeNumber <= 0) {
      return false;
    }
    const selectedSeasonNumber = item.seasonNumber ?? currentSeasonNumber;
    const selectedEpisodeNumber = item.episodeNumber ?? 0;
    return selectedSeasonNumber === currentSeasonNumber && selectedEpisodeNumber === currentEpisodeNumber;
  }

  private async handleEpisodeSelect(item: PlaybackContextItem): Promise<boolean> {
    const currentParam = this.currentPageParam;
    if (currentParam === undefined || this.episodeSwitching) {
      return false;
    }
    const playbackContext = this.videoPlayerController.playbackContext;
    if (this.isCurrentMediaLibraryEpisodeSelection(currentParam, playbackContext, item)) {
      return true;
    }
    this.episodeSwitching = true;
    const previousProgressContext = this.videoPlayerController.progressContext;
    try {
      const resolvedSource = await this.resolveEpisodePlaybackSource(item);
      if (resolvedSource === null) {
        return false;
      }
      const nextParam = buildMediaLibraryEpisodeSwitchParam(
        currentParam,
        playbackContext,
        item,
        resolvedSource
      );
      if (nextParam === null) {
        return false;
      }
      const nextVideoData = this.buildVideoDataFromParam(nextParam);
      if (nextVideoData === undefined) {
        return false;
      }
      this.persistCurrentPlaybackState();
      this.videoPlayerController.progressContext = nextParam.videoId !== undefined && nextParam.videoId > 0
        ? this.buildProgressContext(nextParam)
        : null;
      await this.videoPlayerController.reloadSource(nextVideoData, false);
      if (commitMediaLibraryEpisodeSwitch(playbackContext, item) === null) {
        this.videoPlayerController.progressContext = previousProgressContext;
        return false;
      }
      this.currentPageParam = nextParam;
      this.videoData = nextVideoData;
      this.currentMediaKey = nextParam.mediaKey ?? '';
      this.currentMediaSeason = nextParam.seasonNumber ?? 0;
      this.currentMediaEpisode = nextParam.episodeNumber ?? 0;
      this.showResumeDialog = false;
      this.pendingSeekMs = -1;
      this.resumePlaybackForParam(nextParam);
      return true;
    } catch {
      this.videoPlayerController.progressContext = previousProgressContext;
      return false;
    } finally {
      this.episodeSwitching = false;
    }
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
            onEpisodeSelect: (item: PlaybackContextItem) => this.handleEpisodeSelect(item),
            autoPlay: true
          })
            .width('100%')
            .height('100%')
            .alignRules({
              center: { anchor: '__container__', align: VerticalAlign.Center },
              middle: { anchor: '__container__', align: HorizontalAlign.Center }
            })
        }

        // 字幕覆盖层：独立于 VideoPlayer 的 Stack/XComponent 渲染层，
        // 避免 GPU 合成器把 XComponent Surface 与 ArkUI 覆盖层视为同一 Surface
        // 导致 renderFit 矩阵变换连同字幕一起扭曲的问题（PR #146 修复）
        Row() {
          if (this.videoPlayerController.parsedSubtitle !== null &&
              this.videoPlayerController.parsedSubtitle.lines.length > 0) {
            Column({ space: 6 }) {
              ForEach(
                this.videoPlayerController.parsedSubtitle.lines,
                (line: SubtitleSegment[], lineIndex: number) => {
                  Text(this.mergeSubtitleLineText(line))
                    .fontSize(30)
                    .lineHeight(34)
                    .fontColor(Color.White)
                    .fontWeight(FontWeight.Normal)
                    .textAlign(TextAlign.Center)
                    .textShadow({ radius: 3, offsetX: 3, offsetY: 3, color: Color.Black })
                },
                (line: SubtitleSegment[], index: number) =>
                  `line-${index}-${this.videoPlayerController.subtitleUpdateCounter}`
              )
            }
            .padding({ left: 20, right: 20, top: 8, bottom: 8 })
          }
        }
        .width('100%')
        .height('100%')
        .position({ x: 0, y: 0 })
        .padding({ left: 40, right: 40, bottom: 80 })
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Bottom)
        .hitTestBehavior(HitTestMode.Transparent)
        .alignRules({
          center: { anchor: '__container__', align: VerticalAlign.Center },
          middle: { anchor: '__container__', align: HorizontalAlign.Center }
        })

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
      // 订阅文件不存在事件：记录 videoId 并自动退出播放页
      emitter.on(PlayerEvents.FILE_INACCESSIBLE, (event: emitter.EventData) => {
        const data = event.data as Record<string, number>;
        this.fileNotFoundVideoId = data?.['videoId'] ?? -1;
        const popResult: Record<string, Object> = {
          'fileNotFound': true as Object,
          'videoId': (this.fileNotFoundVideoId as Object)
        };
        this.pageStack.pop(popResult);
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
        this.applyPlayerPageParam(pageParam);
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
    emitter.off(PlayerEvents.FILE_INACCESSIBLE.eventId)
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
