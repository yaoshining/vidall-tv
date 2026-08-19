import { VideoPlayer } from "../../components/core/player";
import { VideoDataType } from "../../components/core/player/Constants";
import { VideoData, PresetAudioTrack, PresetSubtitleTrack } from "../../components/core/player/VideoData";
import {
  VideoPlayerController,
  type PlayerBackend
} from "../../components/core/player/VideoPlayerController";
import { SubtitleCacheContext } from "../../subtitle/SubtitleDispatcher";
import { common } from "@kit.AbilityKit";
import { PlaybackContext, PlaybackContextItem, MediaLibraryContext, FileExplorerContext } from "../../components/core/player/PlaybackContext";
import { FileSourceDatabase } from "../../db/files/FileSourceDatabase";
import { PlayProgressEntity } from "../../db/models/MediaEntity";
import { MediaProgressStore } from "../../db/MediaProgressStore";
import { millisecondsToTime } from "../../utils/TimeUtil";
import { PlayerEvents } from "../../components/core/player/Constants";
import { emitter, BusinessError } from "@kit.BasicServicesKit";
import { SubtitleSegment } from "../../components/core/player/SubtitleRenderer";
import { EpisodePlaybackManager, EpisodePlaybackManagerState } from "../../components/core/player/EpisodePlaybackManager";
import { loadEpisodeAutoplaySettings } from "../../components/core/player/EpisodeAutoplayPreferences";
import { UmamiAnalyticsService } from "../../services/analytics/UmamiAnalyticsService";
import { defaultSourceAdapterService as sourceAdapter } from "../../services/sourceAdapter/SourceAdapterService";
import { PlaybackSourceIdentity } from "../../services/sourceAdapter/PlaybackSource";
import { normalizePlayerBackend } from "../../services/playback/PlaybackBackendTypes";
import {
  PlaybackProgressService,
  PlaybackProgressContext,
  PersistOutcome
} from "../../services/playbackProgress/PlaybackProgressService";
import { PlaybackResumeDecision } from "../../services/playbackProgress/PlaybackResumeDecision";
import { reportServerPlaybackStopped, reportServerPlaybackProgress } from "../../lib/ServerProgressReporter";

export interface PlayerPageParam {
  fileUrl?: string;
  url?: string;
  httpHeader?: Record<string, string>;
  title?: string;
  /** 视频时长提示（毫秒），用于 native 骨架阶段提供进度上限 */
  durationHintMs?: number;
  /** 预置音轨列表（可选），用于 EAC-3/AC-3 等 AVPlayer 无法探测的格式 */
  presetAudioTracks?: PresetAudioTrack[];
  /** 预置字幕轨列表（可选），来自 ffprobe 探测结果，供播放器后端字幕枚举 */
  presetSubtitleTracks?: PresetSubtitleTrack[];
  /** 视频 DB id（用于进度持久化） */
  videoId?: number;
  /** TMDB 剧集 ID，电影为空字符串 */
  seriesProviderId?: string;
  /** 季号，电影为 0 */
  seasonNumber?: number;
  /** 集号，电影为 0 */
  episodeNumber?: number;
  /** 可选：指定播放后端；native / ffmpeg 仅作为历史入参兼容并映射到 mpv */
  preferredBackend?: PlayerBackend | 'native' | 'ffmpeg';
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
  /**
   * 刮削得到的原始标题（英文，可选）。用于 OpenSubtitles 字幕搜索，
   * 优先于文件名解析，避免中文/混合标题问题。
   */
  scrapeOriginalTitle?: string;
  /**
   * TMDB ID（数字字符串，可选）。电影或剧集系列级别。
   * 用于 OpenSubtitles `tmdb_id` 精准匹配字幕。
   */
  tmdbId?: string;
  /**
   * IMDb ID（tt + 数字，可选）。电影或剧集系列级别。
   * 用于字幕搜索 `imdb_id` 精准匹配，优先于 tmdbId。
   */
  imdbId?: string;
  /**
   * 文件源类型（可选），如 'webdav'、'smb'。透传到 VideoData.fileSourceType，
   * 用于字幕本地缓存分桶策略中的 sourceType 字段。
   */
  fileSourceType?: string;
  /**
   * 文件源 ID（可选），对应数据库 FileSource.id 的字符串形式。
   * 透传到 VideoData.fileSourceId，用于字幕缓存分桶的 sourceId 字段。
   */
  fileSourceId?: string;
  /**
   * 影视服务器类型（可选），如 'jellyfin' / 'emby' / 'plex'。
   * 用于退出播放时将进度上报回服务器。
   */
  serverType?: string;
  /**
   * 影视服务器条目 ID（可选）。退出播放时随 serverType 上报进度。
   */
  serverItemId?: string;
  /**
   * 影视服务器配置 JSON（可选，凭据已解密）。用于上报进度时重建客户端。
   */
  serverConfigJson?: string;
  /**
   * 影视服务器播放会话 ID（可选）。Jellyfin/Emby 上报进度时关联同一会话。
   */
  serverPlaySessionId?: string;
}

export interface ResolvedEpisodePlaybackSource {
  url: string;
  sourceIdentity: PlaybackSourceIdentity;
  httpHeader?: Record<string, string>;
  durationHintMs?: number;
  presetAudioTracks?: PresetAudioTrack[];
  presetSubtitleTracks?: PresetSubtitleTrack[];
  startPositionMs?: number;
}

export type MediaProgressResumeActionType = 'seek' | 'play' | 'clear_and_play';

export interface MediaProgressResumeAction {
  action: MediaProgressResumeActionType;
  positionMs?: number;
}

export type ResumeDiagnosticEventName = 'page_param_received' | 'saved_progress_resolved' | 'prepared_resume_decision';

export type ResumeDiagnosticAction = MediaProgressResumeActionType | 'dialog' | 'none';

export interface ResumeDiagnosticLogOptions {
  savedPositionMs?: number;
  resumeAction?: ResumeDiagnosticAction;
  resumePositionMs?: number;
}

export interface ResumeDiagnosticLogPayload {
  event: ResumeDiagnosticEventName;
  videoId: number;
  mediaKey: string;
  season: number;
  episode: number;
  startPositionMs: number;
  savedPositionMs: number;
  resumeAction: ResumeDiagnosticAction;
  resumePositionMs: number;
}

// 续播决策 pure functions 已在 Module 2 收口到 `PlaybackProgressService`。
// 这里 re-export 仅为了保持外部对 `PlayerPage` 顶层 export 符号的 import 兼容。
export {
  resolveSavedProgressResumeAction,
  resolveMediaProgressResumeAction,
  resolvePlayProgressResumeAction
} from "../../services/playbackProgress/PlaybackResumeDecision";

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
    scrapeOriginalTitle: currentParam.scrapeOriginalTitle,
    tmdbId: currentParam.tmdbId,
    imdbId: currentParam.imdbId,
    seasonNumber,
    episodeNumber,
    preferredBackend: currentParam.preferredBackend,
    presetAudioTracks: resolvedSource.presetAudioTracks,
    presetSubtitleTracks: resolvedSource.presetSubtitleTracks,
    fileSourceType: resolvedSource.sourceIdentity.sourceType,
    fileSourceId: resolvedSource.sourceIdentity.sourceId,
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

/**
 * 构建文件浏览器集切换参数，复用当前播放参数中的 httpHeader/preferredBackend 等字段。
 * videoPath 已是完整播放 URL（由 FileExplorerContext.build() 的 urlMapper 处理）。
 */
export function buildFileExplorerEpisodeSwitchParam(
  currentParam: PlayerPageParam,
  context: FileExplorerContext,
  selectedItem: PlaybackContextItem
): PlayerPageParam | null {
  if (selectedItem.index < 0 || selectedItem.index >= context.items.length) {
    return null;
  }
  const nextParam: PlayerPageParam = {
    url: selectedItem.videoPath,
    httpHeader: currentParam.httpHeader,
    title: selectedItem.title,
    preferredBackend: currentParam.preferredBackend,
    fileSourceType: currentParam.fileSourceType,
    fileSourceId: currentParam.fileSourceId,
    playbackContext: context
  };
  return nextParam;
}

@ComponentV2
export struct PlayerPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  private videoPlayerController = new VideoPlayerController()
  private videoData?: VideoData
  private currentPageParam?: PlayerPageParam
  private pageParamToken: number = 0
  private episodeSwitching: boolean = false
  private readonly episodePlaybackManager = new EpisodePlaybackManager()
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
  /** 自动下一集轮询定时器 ID，-1 表示未启动 */
  private episodeAutoplayTimerId: number = -1;
  /** 文件不存在时待 pop 的 videoId（-1 表示无） */
  private fileNotFoundVideoId: number = -1;
  /**
   * Module 2 收口后的续播 + 持久化 façade。
   * 延迟初始化：第一次访问 `this.progressService` 时创建，确保 `this.videoPlayerController` /
   * `this.currentMediaKey` 等 page state 已就绪。
   */
  private progressService?: PlaybackProgressService = undefined;
  @Local showEpisodeAutoplayOverlay: boolean = false
  @Local episodeAutoplayRemainingSeconds: number = 0
  @Local episodeAutoplayNextTitle: string = ''

  /**
   * 懒构造 service。
   *
   * 因为 page 字段都在 `this` 上且 `currentMediaKey` 在切换时会被修改，
   * 用 `getContext: () => ({...})` 回调让 service 每次实时读取最新值。
   */
  private getProgressService(): PlaybackProgressService {
    if (this.progressService === undefined) {
      this.progressService = new PlaybackProgressService({
        controller: this.videoPlayerController,
        getContext: (): PlaybackProgressContext => {
          return {
            mediaKey: this.currentMediaKey,
            season: this.currentMediaSeason,
            episode: this.currentMediaEpisode
          };
        },
        onResumeDialog: (posMs: number): void => {
          this.pendingSeekMs = posMs;
          this.showResumeDialog = true;
        }
      });
    }
    return this.progressService;
  }

  aboutToAppear(): void {
    if (UmamiAnalyticsService.isInitialized()) {
      UmamiAnalyticsService.getInstance().trackPageView('/player');
    }
    // 注入字幕缓存上下文（filesDir 由 UIAbilityContext 获取）
    try {
      const hostCtx = this.getUIContext().getHostContext()
      if (hostCtx) {
        const subtitleCacheCtx: SubtitleCacheContext = {
          filesDir: hostCtx.filesDir,
          sourceType: '',
          sourceId: ''
        };
        this.videoPlayerController.setSubtitleCacheContext(subtitleCacheCtx);
      }
    } catch {
      // 获取 context 失败时，步骤 4 缓存查询将跳过
    }
  }

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
    const backendLabel = (rawBackend === 'avplayer' && proto === 'SMB')
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
    // 服务器媒体续播：把起始位置传给控制器，让控制器在 mpv 自动播放前先 seek，
    // 避免「先从头播放再 seek」的二次播放。文件源续播仍走 decidePlayResume。
    if (pageParam.serverItemId !== undefined && pageParam.serverItemId.length > 0 &&
        pageParam.startPositionMs !== undefined && pageParam.startPositionMs > 0) {
      nextVideoData.seekTime = pageParam.startPositionMs;
    }
    if (pageParam.presetAudioTracks && pageParam.presetAudioTracks.length > 0) {
      nextVideoData.presetAudioTracks = pageParam.presetAudioTracks;
    }
    if (pageParam.presetSubtitleTracks && pageParam.presetSubtitleTracks.length > 0) {
      nextVideoData.presetSubtitleTracks = pageParam.presetSubtitleTracks;
    }
    if (pageParam.scrapeOriginalTitle) {
      nextVideoData.scrapeOriginalTitle = pageParam.scrapeOriginalTitle;
    }
    if (pageParam.tmdbId) {
      nextVideoData.tmdbId = pageParam.tmdbId;
    } else if (pageParam.seriesProviderId && pageParam.seriesProviderId.length > 0) {
      // TV series: seriesProviderId IS the TMDB series ID, reuse for subtitle search
      nextVideoData.tmdbId = pageParam.seriesProviderId;
    }
    if (pageParam.imdbId) {
      nextVideoData.imdbId = pageParam.imdbId;
    }
    if (pageParam.seasonNumber !== undefined && pageParam.seasonNumber > 0) {
      nextVideoData.seasonNumber = pageParam.seasonNumber;
    }
    if (pageParam.episodeNumber !== undefined && pageParam.episodeNumber > 0) {
      nextVideoData.episodeNumber = pageParam.episodeNumber;
    }
    if (pageParam.fileSourceType) {
      nextVideoData.fileSourceType = pageParam.fileSourceType;
    }
    if (pageParam.fileSourceId) {
      nextVideoData.fileSourceId = pageParam.fileSourceId;
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

  private emitResumeDiagnosticLog(
    event: ResumeDiagnosticEventName,
    pageParam: PlayerPageParam,
    options?: ResumeDiagnosticLogOptions
  ): void {
    const payload: ResumeDiagnosticLogPayload = {
      event,
      videoId: pageParam.videoId ?? 0,
      mediaKey: pageParam.mediaKey ?? '',
      season: pageParam.seasonNumber ?? 0,
      episode: pageParam.episodeNumber ?? 0,
      startPositionMs: pageParam.startPositionMs ?? 0,
      savedPositionMs: options?.savedPositionMs ?? 0,
      resumeAction: options?.resumeAction ?? 'none',
      resumePositionMs: options?.resumePositionMs ?? 0
    };
    console.info(`[PlayerPage][RESUME] ${JSON.stringify(payload)}`);
  }

  private resumePlaybackForParam(pageParam: PlayerPageParam): void {
    const mediaKey = pageParam.mediaKey ?? '';
    if (mediaKey.length === 0) {
      this.emitResumeDiagnosticLog('prepared_resume_decision', pageParam, {
        resumeAction: 'play'
      });
      this.videoPlayerController.rememberResumeAutoplayDecision(true, 'prepared_resume_play');
      this.videoPlayerController.play().catch(() => {});
      return;
    }
    const directStart = pageParam.startPositionMs ?? 0;
    // 直接走 pageStartPosition 决策，跳过 DB 读。
    if (directStart > 0) {
      this.emitResumeDiagnosticLog('saved_progress_resolved', pageParam, {
        savedPositionMs: directStart,
        resumeAction: 'seek',
        resumePositionMs: directStart
      });
      this.emitResumeDiagnosticLog('prepared_resume_decision', pageParam, {
        savedPositionMs: directStart,
        resumeAction: 'seek',
        resumePositionMs: directStart
      });
      this.videoPlayerController.seek(directStart, 'prepared_resume_seek').catch(() => {});
      return;
    }
    // 走 service 决策媒体级续播（含 DB 读 + near-end 判定）。
    this.getProgressService().decideMediaResume({
      mediaKey,
      pageStartPositionMs: directStart,
      currentDurationMs: this.videoPlayerController.duration,
      currentSeason: this.currentMediaSeason,
      currentEpisode: this.currentMediaEpisode
    }).then((decision) => {
      const savedPositionMs = decision.positionMs ?? 0;
      this.emitResumeDiagnosticLog('saved_progress_resolved', pageParam, {
        savedPositionMs,
        resumeAction: decision.action === 'dialog' ? 'dialog' : decision.action,
        resumePositionMs: savedPositionMs
      });
      this.emitResumeDiagnosticLog('prepared_resume_decision', pageParam, {
        savedPositionMs,
        resumeAction: decision.action === 'dialog' ? 'dialog' : decision.action,
        resumePositionMs: savedPositionMs
      });
      this.applyMediaResumeDecision(decision);
    }).catch(() => {
      this.emitResumeDiagnosticLog('saved_progress_resolved', pageParam, {
        resumeAction: 'play'
      });
      this.emitResumeDiagnosticLog('prepared_resume_decision', pageParam, {
        resumeAction: 'play'
      });
      this.videoPlayerController.rememberResumeAutoplayDecision(true, 'prepared_resume_play');
      this.videoPlayerController.play().catch(() => {});
    });
  }

  /**
   * 把 `decideMediaResume` 返回的决策落到 player 上。
   *
   * 与原 `PlayerPage.resumePlaybackForParam` 中内联分支等价。
   */
  private applyMediaResumeDecision(decision: PlaybackResumeDecision): void {
    if (decision.action === 'seek' && decision.positionMs !== undefined && decision.positionMs > 0) {
      this.videoPlayerController.seek(decision.positionMs, 'prepared_resume_seek').catch(() => {});
      return;
    }
    if (decision.action === 'clear_and_play') {
      if (decision.mediaKey !== undefined && decision.mediaKey.length > 0) {
        MediaProgressStore.clear(decision.mediaKey).catch(() => {});
      }
      this.videoPlayerController.rememberResumeAutoplayDecision(true, 'prepared_resume_play');
      this.videoPlayerController.play().catch(() => {});
      return;
    }
    // action === 'play'
    this.videoPlayerController.rememberResumeAutoplayDecision(true, 'prepared_resume_play');
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
      // 服务器媒体（无 mediaKey / videoId）且带续播位置：起始位置已通过 VideoData.seekTime
      // 传给控制器，onPlayerReady 会在 mpv 自动播放前先 seek，这里不再重复 seek（避免二次播放）。
      const directStartMs = pageParam.startPositionMs ?? 0;
      if (videoId <= 0 && directStartMs > 0) {
        return;
      }
      // 服务器媒体无续播位置（videoId<=0 且 startPositionMs==0）：
      // 交给 VideoPlayer 的自动播放，避免这里再 play() 一次造成双播。
      if (videoId <= 0) {
        return;
      }
      // 走 service 决策视频级续播。`onResumeDialog` 回调已通过 service 配置注入，
      // 会负责设置 pendingSeekMs / showResumeDialog / savedPositionMs / totalDurationMs。
      this.getProgressService().decidePlayResume({
        videoId,
        currentDurationMs: this.videoPlayerController.duration,
        pageStartPositionMs: pageParam.startPositionMs ?? 0
      }).then((decision) => {
        if (token !== this.pageParamToken) {
          return;
        }
        const savedPositionMs = decision.positionMs ?? 0;
        // `dialog` 决策：service 已通过 onResumeDialog 设置了 pendingSeekMs / showResumeDialog。
        // 这里再补 savedPositionMs / totalDurationMs 两个 page 状态字段（用于 UI 显示）。
        if (decision.action === 'dialog' && decision.positionMs !== undefined) {
          this.savedPositionMs = decision.positionMs;
          this.totalDurationMs = this.videoPlayerController.duration > 0
            ? this.videoPlayerController.duration
            : 0;
        }
        if (decision.action === 'clear_and_play') {
          // 与原行为一致：把 buildProgressContext 用作 play_progress 清理回写。
          const progressContext = this.buildProgressContext(pageParam);
          progressContext.durationMs = this.videoPlayerController.duration > 0
            ? this.videoPlayerController.duration
            : 0;
          progressContext.updatedAt = Date.now();
          FileSourceDatabase.getInstance().upsertPlayProgress(progressContext).catch(() => {});
        }
        this.emitResumeDiagnosticLog('saved_progress_resolved', pageParam, {
          savedPositionMs,
          resumeAction: decision.action === 'dialog' ? 'dialog' : decision.action,
          resumePositionMs: savedPositionMs
        });
        this.emitResumeDiagnosticLog('prepared_resume_decision', pageParam, {
          savedPositionMs,
          resumeAction: decision.action === 'dialog' ? 'dialog' : decision.action,
          resumePositionMs: savedPositionMs
        });
        if (decision.action !== 'dialog') {
          this.videoPlayerController.play().catch(() => {});
        }
      }).catch(() => {
        this.emitResumeDiagnosticLog('saved_progress_resolved', pageParam, {
          resumeAction: 'play'
        });
        this.emitResumeDiagnosticLog('prepared_resume_decision', pageParam, {
          resumeAction: 'play'
        });
        this.videoPlayerController.play().catch(() => {});
      });
    });
  }

  private applyPlayerPageParam(pageParam: PlayerPageParam): void {
    this.currentPageParam = pageParam;
    this.emitResumeDiagnosticLog('page_param_received', pageParam);
    this.pageParamToken += 1;
    const token = this.pageParamToken;
    this.videoPlayerController.discardPreparedResumeAutoplayDecision();
    if (pageParam.preferredBackend) {
      this.videoPlayerController.backend = normalizePlayerBackend(pageParam.preferredBackend);
    }
    this.videoData = this.buildVideoDataFromParam(pageParam);
    this.videoPlayerController.progressContext = null;
    this.currentMediaKey = '';
    this.currentMediaSeason = 0;
    this.currentMediaEpisode = 0;
    this.currentMediaKey = pageParam.mediaKey ?? '';
    this.currentMediaSeason = pageParam.seasonNumber ?? 0;
    this.currentMediaEpisode = pageParam.episodeNumber ?? 0;
    if (this.currentMediaKey.length > 0) {
      this.videoPlayerController.prepareResumeAutoplayDecision(true, 'page_param_prepared_resume');
    }
    this.showResumeDialog = false;
    this.pendingSeekMs = -1;
    this.hideEpisodeAutoplayOverlay();
    this.episodePlaybackManager.clear();
    if (pageParam.videoId !== undefined && pageParam.videoId > 0) {
      this.videoPlayerController.progressContext = this.buildProgressContext(pageParam);
      this.registerPreparedResume(pageParam, token);
    } else if (pageParam.serverItemId !== undefined && pageParam.serverItemId.length > 0) {
      // 服务器媒体：无 mediaKey/videoId，仍注册 prepared 续播以应用 startPositionMs。
      // 不调 prepareResumeAutoplayDecision，避免「先从头自动播放、再 seek 续播」的双播；
      // seek(..., 'prepared_resume_seek') 内部会在 seek 完成后自动恢复播放。
      this.registerPreparedResume(pageParam, token);
    }
    this.videoPlayerController.playbackContext = pageParam.playbackContext;
  }

  private persistCurrentPlaybackState(): void {
    // 切集前 fire-and-forget 持久化：play_progress 立即写，media_progress 异步落盘。
    this.getProgressService().persistNow().catch(() => {});
  }

  private async resolveEpisodePlaybackSource(item: PlaybackContextItem): Promise<ResolvedEpisodePlaybackSource | null> {
    // 第一阶段：协议拼装与已落库元数据已收口到 SourceAdapterService。
    // 页面层负责映射切集所需字段，并保留稳定的播放源标识。
    const resolved = await sourceAdapter.resolveEpisode({
      sourceId: item.sourceId,
      filePath: item.videoPath,
      videoId: item.videoId
    });
    if (resolved === null) {
      return null;
    }
    const resolvedSource: ResolvedEpisodePlaybackSource = {
      url: resolved.url,
      sourceIdentity: resolved.sourceIdentity
    };
    if (Object.keys(resolved.httpHeader).length > 0) {
      resolvedSource.httpHeader = resolved.httpHeader;
    }
    if (resolved.durationHintMs !== undefined) {
      resolvedSource.durationHintMs = resolved.durationHintMs;
    }
    if (resolved.presetAudioTracks !== undefined) {
      resolvedSource.presetAudioTracks = resolved.presetAudioTracks;
    }
    if (resolved.presetSubtitleTracks !== undefined) {
      resolvedSource.presetSubtitleTracks = resolved.presetSubtitleTracks;
    }
    if (resolved.startPositionMs !== undefined) {
      resolvedSource.startPositionMs = resolved.startPositionMs;
    }
    return resolvedSource;
  }

  private async handleEpisodeSelect(item: PlaybackContextItem): Promise<boolean> {
    const currentParam = this.currentPageParam;
    if (currentParam === undefined || this.episodeSwitching) {
      return false;
    }
    if (this.episodePlaybackManager !== undefined) {
      this.episodePlaybackManager.cancelCurrentEpisode();
    }
    this.hideEpisodeAutoplayOverlay();
    const playbackContext = this.videoPlayerController.playbackContext;
    if (playbackContext !== undefined && playbackContext.contextType === 'media_library') {
      const mediaLibraryContext = playbackContext as MediaLibraryContext;
      if (item.index === mediaLibraryContext.currentIndex) {
        return true;
      }
    }
    if (playbackContext !== undefined && playbackContext.contextType === 'file_explorer') {
      if (item.index === playbackContext.currentIndex) {
        return true;
      }
    }
    this.episodeSwitching = true;
    const previousProgressContext = this.videoPlayerController.progressContext;
    const previousPageParamToken = this.pageParamToken;
    const previousVideoData = this.videoData;
    const previousMediaKey = this.currentMediaKey;
    const previousMediaSeason = this.currentMediaSeason;
    const previousMediaEpisode = this.currentMediaEpisode;
    this.pageParamToken += 1;
    this.videoPlayerController.discardPreparedResumeAutoplayDecision();
    let keepNextPageParamToken = false;
    try {
      let nextParam: PlayerPageParam | null = null;
      if (playbackContext !== undefined && playbackContext.contextType === 'file_explorer') {
        const fileExplorerContext = playbackContext as FileExplorerContext;
        nextParam = buildFileExplorerEpisodeSwitchParam(currentParam, fileExplorerContext, item);
      } else {
        const resolvedSource = await this.resolveEpisodePlaybackSource(item);
        if (resolvedSource === null) {
          return false;
        }
        nextParam = buildMediaLibraryEpisodeSwitchParam(
          currentParam,
          playbackContext,
          item,
          resolvedSource
        );
      }
      if (nextParam === null) {
        return false;
      }
      const nextVideoData = this.buildVideoDataFromParam(nextParam);
      if (nextVideoData === undefined) {
        return false;
      }
      this.videoPlayerController.prepareResumeAutoplayDecision(true, 'episode_switch_prepared_resume');
      this.persistCurrentPlaybackState();
      this.videoPlayerController.progressContext = nextParam.videoId !== undefined && nextParam.videoId > 0
        ? this.buildProgressContext(nextParam)
        : null;
      // 后端切换会重建 XComponent；先更新页面源，避免 onLoad 用旧集再次初始化播放器。
      this.currentPageParam = nextParam;
      this.videoData = nextVideoData;
      this.currentMediaKey = nextParam.mediaKey ?? '';
      this.currentMediaSeason = nextParam.seasonNumber ?? 0;
      this.currentMediaEpisode = nextParam.episodeNumber ?? 0;
      await this.videoPlayerController.reloadSource(nextVideoData, false);
      if (playbackContext !== undefined && playbackContext.contextType === 'file_explorer') {
        const fileExplorerContext = playbackContext as FileExplorerContext;
        fileExplorerContext.jumpTo(item.index);
      } else {
        if (commitMediaLibraryEpisodeSwitch(playbackContext, item) === null) {
          this.videoPlayerController.progressContext = previousProgressContext;
          return false;
        }
      }
      this.showResumeDialog = false;
      this.pendingSeekMs = -1;
      keepNextPageParamToken = true;
      this.resumePlaybackForParam(nextParam);
      return true;
    } catch {
      this.videoPlayerController.discardPreparedResumeAutoplayDecision();
      this.videoPlayerController.progressContext = previousProgressContext;
      return false;
    } finally {
      if (!keepNextPageParamToken) {
        this.currentPageParam = currentParam;
        this.videoData = previousVideoData;
        this.currentMediaKey = previousMediaKey;
        this.currentMediaSeason = previousMediaSeason;
        this.currentMediaEpisode = previousMediaEpisode;
        this.pageParamToken = previousPageParamToken;
      }
      this.episodeSwitching = false;
    }
  }

  private hideEpisodeAutoplayOverlay(): void {
    this.showEpisodeAutoplayOverlay = false
    this.episodeAutoplayRemainingSeconds = 0
    this.episodeAutoplayNextTitle = ''
  }

  private applyEpisodeAutoplayOverlayState(state: EpisodePlaybackManagerState): void {
    if (!state.visible || state.nextItem === null) {
      this.hideEpisodeAutoplayOverlay()
      return
    }
    this.showEpisodeAutoplayOverlay = true
    this.episodeAutoplayRemainingSeconds = state.remainingSeconds
    this.episodeAutoplayNextTitle = state.nextItem.title
  }

  private cancelEpisodeAutoplayCountdown(): boolean {
    if (!this.showEpisodeAutoplayOverlay) {
      return false
    }
    this.episodePlaybackManager.cancelCurrentEpisode()
    this.hideEpisodeAutoplayOverlay()
    return true
  }

  private loadEpisodeAutoplayPreferences(): void {
    loadEpisodeAutoplaySettings().then((settings) => {
      this.videoPlayerController.episodeAutoplayEnabled = settings.enabled
      this.videoPlayerController.episodeAutoplayCountdownSeconds = settings.countdownSeconds
    }).catch(() => {})
  }

  private showEpisodeAutoplayFailureToast(): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: '自动播放下一集失败' })
    } catch (_) {}
  }

  private triggerEpisodeAutoplay(nextItem: PlaybackContextItem): void {
    if (this.episodeSwitching) {
      return
    }
    this.handleEpisodeSelect(nextItem).then((didSwitch: boolean) => {
      if (!didSwitch) {
        this.episodePlaybackManager.markAutoplayFailed()
        this.hideEpisodeAutoplayOverlay()
        this.showEpisodeAutoplayFailureToast()
      }
    }).catch(() => {
      this.episodePlaybackManager.markAutoplayFailed()
      this.hideEpisodeAutoplayOverlay()
      this.showEpisodeAutoplayFailureToast()
    })
  }

  private syncEpisodeAutoplayState(): void {
    this.episodePlaybackManager.updateSettings(
      this.videoPlayerController.episodeAutoplayEnabled,
      this.videoPlayerController.episodeAutoplayCountdownSeconds
    )
    const state = this.episodePlaybackManager.sync(
      this.videoPlayerController.playbackContext,
      this.videoPlayerController.currentTime,
      this.videoPlayerController.duration,
      Date.now(),
      this.videoPlayerController.isPlaying
    )
    this.applyEpisodeAutoplayOverlayState(state)
    if (state.shouldPlayNext && state.nextItem !== null) {
      this.triggerEpisodeAutoplay(state.nextItem)
    }
  }

  @Builder
  private EpisodeAutoplayOverlay() {
    if (this.showEpisodeAutoplayOverlay) {
      Row({ space: 18 }) {
        Column({ space: 4 }) {
          Text(`即将播放下一集 · ${this.episodeAutoplayRemainingSeconds}s`)
            .fontSize(24)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Medium)
          Text(this.episodeAutoplayNextTitle.length > 0 ? this.episodeAutoplayNextTitle : '下一集')
            .fontSize(18)
            .fontColor('#D7DCE7')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)

        Button('取消')
          .fontSize(16)
          .fontColor(Color.White)
          .backgroundColor('rgba(255, 255, 255, 0.18)')
          .borderRadius(20)
          .padding({ left: 18, right: 18, top: 10, bottom: 10 })
          .onClick(() => {
            this.cancelEpisodeAutoplayCountdown()
          })
      }
      .padding({ left: 22, right: 22, top: 18, bottom: 18 })
      .backgroundColor('rgba(0, 0, 0, 0.78)')
      .borderRadius(20)
      .shadow({ radius: 12, color: '#55000000', offsetX: 0, offsetY: 4 })
      .alignRules({
        bottom: { anchor: '__container__', align: VerticalAlign.Bottom },
        middle: { anchor: '__container__', align: HorizontalAlign.Center }
      })
      .margin({ bottom: 160 })
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
                this.videoPlayerController.seek(this.pendingSeekMs, 'resume_dialog_seek');
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
        this.EpisodeAutoplayOverlay()

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
        this.getProgressService().persistNow().catch(() => {});
        this.reportServerPeriodicProgress();
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
        this.getProgressService().persistNow().catch(() => {});
        this.reportServerPeriodicProgress();
      }, 10000);
      this.episodeAutoplayTimerId = setInterval(() => {
        this.syncEpisodeAutoplayState()
      }, 500);

      let pageParam = context.pathInfo.param as PlayerPageParam
      if (pageParam) {
        this.applyPlayerPageParam(pageParam);
      }
      this.loadEpisodeAutoplayPreferences();
    })
    .onBackPressed(() => {
      if (this.cancelEpisodeAutoplayCountdown()) {
        return true
      }
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

  /**
   * 周期性把影视服务器播放进度上报回服务器（不结束会话）。
   * 仅在服务器媒体（serverItemId/serverType 存在）时生效。
   */
  private reportServerPeriodicProgress(): void {
    const param = this.currentPageParam
    if (!param || !param.serverItemId || !param.serverType) {
      return
    }
    const configJson = param.serverConfigJson ?? ''
    if (configJson.length === 0) {
      return
    }
    const posMs = this.videoPlayerController.currentTime
    const durMs = this.videoPlayerController.duration
    if (posMs <= 0) {
      return
    }
    const playSessionId = param.serverPlaySessionId ?? ''
    reportServerPlaybackProgress(param.serverType, configJson, param.serverItemId, playSessionId, posMs, durMs)
      .catch((e: BusinessError) => {
        console.warn('[PlayerPage] 周期性上报服务器进度失败', e.message ?? String(e))
      })
  }

  /**
   * 退出播放器时，把影视服务器的播放进度上报回服务器。
   * 返回是否已上报（用于决定是否 emit 刷新事件）。
   */
  private reportServerProgress(posMs: number, durMs: number): Promise<boolean> {
    const param = this.currentPageParam
    if (!param || !param.serverItemId || !param.serverType) {
      return Promise.resolve(false)
    }
    const configJson = param.serverConfigJson ?? ''
    if (configJson.length === 0) {
      return Promise.resolve(false)
    }
    const playSessionId = param.serverPlaySessionId ?? ''
    try {
      return reportServerPlaybackStopped(param.serverType, configJson, param.serverItemId, playSessionId, posMs, durMs)
        .then(() => true)
        .catch((e: BusinessError) => {
          console.warn('[PlayerPage] 上报服务器进度失败', e.message ?? String(e))
          return false
        })
    } catch (e) {
      const err = e as BusinessError
      console.warn('[PlayerPage] 上报服务器进度异常', err.message ?? String(e))
      return Promise.resolve(false)
    }
  }

  aboutToDisappear(): void {
    emitter.off(PlayerEvents.APP_BACKGROUND.eventId)
    emitter.off(PlayerEvents.FILE_INACCESSIBLE.eventId)
    if (this.mediaProgressTimerId >= 0) {
      clearInterval(this.mediaProgressTimerId);
      this.mediaProgressTimerId = -1;
    }
    if (this.episodeAutoplayTimerId >= 0) {
      clearInterval(this.episodeAutoplayTimerId);
      this.episodeAutoplayTimerId = -1;
    }
    // 媒体级进度：完播则清除，否则保存当前位置；结束后通知继续播放栏刷新。
    // 委托给 PlaybackProgressService.persistNow() 编排，
    // page 端只负责根据 outcome 决定是否 emit MEDIA_PROGRESS_SAVED。
    const posMs = this.videoPlayerController.currentTime;
    const durMs = this.videoPlayerController.duration;
    console.info(`[PlayerPage][REFRESH] aboutToDisappear: currentMediaKey=${this.currentMediaKey} posMs=${posMs} durMs=${durMs}`);
    this.getProgressService().persistNow().then((outcome: PersistOutcome) => {
      // 与原行为一致：clear / save / posMs=0 路径都 emit，让首页「继续播放」刷新。
      // durMs=0 / mediaKey 为空 路径不 emit（无可写目标或 durMs 未就绪）。
      if (outcome === 'cleared' || outcome === 'saved' || outcome === 'noop_position_zero') {
        console.info(`[PlayerPage][REFRESH] outcome=${outcome}，emit MEDIA_PROGRESS_SAVED`);
        emitter.emit(PlayerEvents.MEDIA_PROGRESS_SAVED);
      } else {
        console.info(`[PlayerPage][REFRESH] outcome=${outcome}，跳过 emit`);
      }
    }).catch(() => {
      // service 异常时仍 emit，保持与原"save 失败仍 emit"路径兼容。
      console.warn('[PlayerPage][REFRESH] persistNow 失败，仍 emit MEDIA_PROGRESS_SAVED');
      emitter.emit(PlayerEvents.MEDIA_PROGRESS_SAVED);
    });
    this.reportServerProgress(posMs, durMs).then((reported: boolean) => {
      if (reported) {
        // 服务器媒体：上报完成后通知首页刷新「继续观看」进度
        emitter.emit(PlayerEvents.MEDIA_PROGRESS_SAVED);
      }
    });
    this.videoPlayerController.saveProgressNow()
    this.videoPlayerController.release()
  }
}
