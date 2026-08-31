import { describe, it, expect } from '@ohos/hypium'
import {
  buildMediaLibraryEpisodeSwitchParam,
  commitMediaLibraryEpisodeSwitch,
  buildServerEpisodeSwitchParam,
  commitServerEpisodeSwitch,
  MediaProgressResumeAction,
  PlayerPage,
  PlayerPageParam,
  ResolvedEpisodePlaybackSource,
  ResolvedServerEpisodeSource,
  resolveMediaProgressResumeAction
} from '../main/ets/pages/player/index'
import {
  MediaLibraryContext,
  FileExplorerContext,
  PlaybackContext,
  PlaybackContextItem,
  ServerMediaLibraryContext,
  buildServerPlaybackItems
} from '../main/ets/components/core/player/PlaybackContext'
import { MediaItem, TvEpisodeEntity, MediaProgressEntry } from '../main/ets/db/models/MediaEntity'
import { VideoServerEpisode } from '../main/ets/lib/JellyfinClient'
import { VideoServerType } from '../main/ets/db/models/VideoServerEntity'
import { PlayerEvents } from '../main/ets/components/core/player/Constants'
import { emitter } from '@kit.BasicServicesKit'

function buildServerSwitchEpisode(id: string, episodeNumber: number): VideoServerEpisode {
  const episode: VideoServerEpisode = {
    id: id,
    episodeNumber: episodeNumber,
    seasonNumber: 1,
    title: `第${episodeNumber}集`,
    overview: '',
    stillUrl: '',
    durationMs: 1800000,
    rating: 0,
    positionMs: 0,
    lastPlayedDate: 0
  };
  return episode;
}

function buildServerSwitchContext(): ServerMediaLibraryContext {
  const episodes: VideoServerEpisode[] = [
    buildServerSwitchEpisode('server-ep-1', 1),
    buildServerSwitchEpisode('server-ep-2', 2)
  ]
  const buildResult = buildServerPlaybackItems(VideoServerType.JELLYFIN, 5, 'series-9', episodes, 'server-ep-1')
  return new ServerMediaLibraryContext(buildResult.items, buildResult.currentIndex)
}

function buildResolvedServerSwitchSource(url: string, playSessionId: string): ResolvedServerEpisodeSource {
  const source: ResolvedServerEpisodeSource = {
    url: url,
    playSessionId: playSessionId
  };
  return source;
}

interface PlayerPageAccessor {
  applyPlayerPageParam(pageParam: PlayerPageParam): void
  persistCurrentPlaybackState(): void
  resolveEpisodePlaybackSource(item: PlaybackContextItem): Promise<ResolvedEpisodePlaybackSource | null>
  handleEpisodeSelect(item: PlaybackContextItem): Promise<boolean>
  hideEpisodeAutoplayOverlay(): void
  resumePlaybackForParam(pageParam: PlayerPageParam): void
  currentMediaKey: string
  currentMediaSeason: number
  currentMediaEpisode: number
  currentPageParam?: PlayerPageParam
  episodeSwitching: boolean
  showEpisodeAutoplayOverlay?: boolean
  episodeAutoplayRemainingSeconds?: number
  episodeAutoplayNextTitle?: string
  showResumeDialog: boolean
  pendingSeekMs: number
  videoData?: PlayerPageVideoDataAccessor
  videoPlayerController: PlayerPageControllerAccessor
}

interface PlayerPageVideoDataAccessor {
  videoSrc: string
}

interface PlayerPageProgressContextAccessor {
  videoId: number
  seriesProviderId: string
  seasonNumber: number
  episodeNumber: number
  positionMs: number
  durationMs: number
  updatedAt: number
}

interface PlayerPageControllerAccessor {
  currentTime: number
  duration: number
  playbackContext?: MediaLibraryContext
  progressContext: PlayerPageProgressContextAccessor | null
  saveProgressNow(): void
  reloadSource(videoData: PlayerPageVideoDataAccessor, autoPlay: boolean): Promise<void>
  discardPreparedResumeAutoplayDecision(): void
  prepareResumeAutoplayDecision(shouldResumePlay: boolean, source: string): void
  rememberResumeAutoplayDecision(shouldResumePlay: boolean, source: string): void
}

interface PlayerPageControllerPlaybackAccessor extends PlayerPageControllerAccessor {
  play(): Promise<void>
}

interface BoundHandleEpisodeSelectMethod {
  bind(target: Object): (item: PlaybackContextItem) => Promise<boolean>
}

interface BoundRegisterPreparedResumeMethod {
  bind(target: Object): (pageParam: PlayerPageParam, token: number) => void
}

interface BoundResumePlaybackForParamMethod {
  bind(target: Object): (pageParam: PlayerPageParam) => void
}

class TestPlayerPageController implements PlayerPageControllerAccessor {
  currentTime: number = 120000
  duration: number = 1800000
  playbackContext?: MediaLibraryContext
  progressContext: PlayerPageProgressContextAccessor | null = null

  constructor(context: MediaLibraryContext) {
    this.playbackContext = context
  }

  saveProgressNow(): void {}

  async reloadSource(_videoData: PlayerPageVideoDataAccessor, _autoPlay: boolean): Promise<void> {}

  discardPreparedResumeAutoplayDecision(): void {}

  prepareResumeAutoplayDecision(_shouldResumePlay: boolean, _source: string): void {}

  rememberResumeAutoplayDecision(_shouldResumePlay: boolean, _source: string): void {}
}

interface EpisodeSelectNoOpSideEffectCalls {
  persistCurrentPlaybackState: number
  reloadSource: number
  resumePlaybackForParam: number
  saveProgressNow: number
  play: number
}

interface PlayerPageCurrentEpisodeHelperAccessor extends PlayerPageAccessor {
  isCurrentMediaLibraryEpisodeSelection?: (
    currentParam: PlayerPageParam,
    playbackContext: PlaybackContext | undefined,
    item: PlaybackContextItem
  ) => boolean
}

interface PreparedResumeCall {
  mediaKey: string
  seasonNumber: number
  episodeNumber: number
}

interface PlayerPagePreparedResumeBindingAccessor {
  handleEpisodeSelect: BoundHandleEpisodeSelectMethod
  registerPreparedResume: BoundRegisterPreparedResumeMethod
}

class SpyEpisodeSwitchController extends TestPlayerPageController {
  private calls: EpisodeSelectNoOpSideEffectCalls

  constructor(context: MediaLibraryContext, calls: EpisodeSelectNoOpSideEffectCalls) {
    super(context)
    this.calls = calls
  }

  saveProgressNow(): void {
    this.calls.saveProgressNow += 1
    this.calls.persistCurrentPlaybackState += 1
    throw new Error('当前集点击不应进入 persistCurrentPlaybackState')
  }

  async reloadSource(_videoData: PlayerPageVideoDataAccessor, _autoPlay: boolean): Promise<void> {
    this.calls.reloadSource += 1
    throw new Error('当前集点击不应进入 reloadSource')
  }

  play(): Promise<void> {
    this.calls.play += 1
    this.calls.resumePlaybackForParam += 1
    throw new Error('当前集点击不应进入 resumePlaybackForParam')
  }
}

class CountingEpisodeSwitchController extends TestPlayerPageController implements PlayerPageControllerPlaybackAccessor {
  private calls: EpisodeSelectNoOpSideEffectCalls
  lastVideoSrc: string = ''
  prepareResumeAutoplayDecisionCalls: string[] = []
  reloadObserver?: () => void

  constructor(context: MediaLibraryContext, calls: EpisodeSelectNoOpSideEffectCalls) {
    super(context)
    this.calls = calls
  }

  saveProgressNow(): void {
    this.calls.saveProgressNow += 1
    this.calls.persistCurrentPlaybackState += 1
  }

  async reloadSource(videoData: PlayerPageVideoDataAccessor, _autoPlay: boolean): Promise<void> {
    this.calls.reloadSource += 1
    this.lastVideoSrc = videoData.videoSrc
    if (this.reloadObserver !== undefined) {
      this.reloadObserver()
    }
  }

  prepareResumeAutoplayDecision(shouldResumePlay: boolean, source: string): void {
    this.prepareResumeAutoplayDecisionCalls.push(`${shouldResumePlay ? 'true' : 'false'}:${source}`)
  }

  play(): Promise<void> {
    this.calls.play += 1
    this.calls.resumePlaybackForParam += 1
    return Promise.resolve()
  }
}

class PreparedResumeIsolationController extends TestPlayerPageController implements PlayerPageControllerPlaybackAccessor {
  playCalls: number = 0

  play(): Promise<void> {
    this.playCalls += 1
    return Promise.resolve()
  }
}

class PreparedDecisionTrackingController extends TestPlayerPageController implements PlayerPageControllerPlaybackAccessor {
  decisionEvents: string[] = []

  discardPreparedResumeAutoplayDecision(): void {
    this.decisionEvents.push('discard')
  }

  prepareResumeAutoplayDecision(shouldResumePlay: boolean, source: string): void {
    this.decisionEvents.push(`prepare:${shouldResumePlay ? 'true' : 'false'}:${source}`)
  }

  play(): Promise<void> {
    return Promise.resolve()
  }
}

class EpisodeSwitchFailureCleanupController extends TestPlayerPageController implements PlayerPageControllerPlaybackAccessor {
  preparedDecisionActive: boolean = false
  preparedDecisionSource: string = ''

  discardPreparedResumeAutoplayDecision(): void {
    this.preparedDecisionActive = false
    this.preparedDecisionSource = ''
  }

  prepareResumeAutoplayDecision(shouldResumePlay: boolean, source: string): void {
    this.preparedDecisionActive = shouldResumePlay
    this.preparedDecisionSource = source
  }

  async reloadSource(_videoData: PlayerPageVideoDataAccessor, _autoPlay: boolean): Promise<void> {
    throw new Error('reload failed after prepare')
  }

  play(): Promise<void> {
    return Promise.resolve()
  }
}

interface ResumeDecisionControllerAccessor extends PlayerPageControllerPlaybackAccessor {
  seek(timeMs: number): Promise<void>
}

class ResumeDecisionController extends TestPlayerPageController implements ResumeDecisionControllerAccessor {
  seekCalls: number[] = []
  playCalls: number = 0
  resumeAutoplayDecisionEvents: string[] = []

  seek(timeMs: number): Promise<void> {
    this.seekCalls.push(timeMs)
    return Promise.resolve()
  }

  rememberResumeAutoplayDecision(shouldResumePlay: boolean, source: string): void {
    this.resumeAutoplayDecisionEvents.push(`remember:${shouldResumePlay ? 'true' : 'false'}:${source}`)
  }

  play(): Promise<void> {
    this.resumeAutoplayDecisionEvents.push('play')
    this.playCalls += 1
    return Promise.resolve()
  }
}

interface EpisodeSwitchResumeCall {
  mediaKey: string
  startPositionMs: number
  seasonAtCall: number
  episodeAtCall: number
}

class PreparedResumeListenerPage {
  pageParamToken: number = 0
  currentMediaSeason: number = 0
  currentMediaEpisode: number = 0
  showResumeDialog: boolean = false
  pendingSeekMs: number = -1
  savedPositionMs: number = 0
  totalDurationMs: number = 0
  videoPlayerController: PlayerPageControllerPlaybackAccessor
  resumeCalls: PreparedResumeCall[] = []
  private readonly registerPreparedResumeImpl: (pageParam: PlayerPageParam, token: number) => void

  constructor(context: MediaLibraryContext) {
    const page = buildPlayerPageAccessor() as Object as PlayerPagePreparedResumeBindingAccessor
    this.registerPreparedResumeImpl = page.registerPreparedResume.bind(this as Object)
    this.videoPlayerController = new PreparedResumeIsolationController(context)
  }

  registerPreparedResume(pageParam: PlayerPageParam, token: number): void {
    this.registerPreparedResumeImpl(pageParam, token)
  }

  resumePlaybackForParam(pageParam: PlayerPageParam): void {
    const call: PreparedResumeCall = {
      mediaKey: pageParam.mediaKey ?? '',
      seasonNumber: pageParam.seasonNumber ?? 0,
      episodeNumber: pageParam.episodeNumber ?? 0
    }
    this.resumeCalls.push(call)
  }
}

class EpisodeSwitchTokenPage {
  currentPageParam?: PlayerPageParam
  episodeSwitching: boolean = false
  showEpisodeAutoplayOverlay: boolean = false
  episodeAutoplayRemainingSeconds: number = 0
  episodeAutoplayNextTitle: string = ''
  showResumeDialog: boolean = false
  pendingSeekMs: number = -1
  currentMediaKey: string = ''
  currentMediaSeason: number = 0
  currentMediaEpisode: number = 0
  pageParamToken: number = 0
  videoData?: PlayerPageVideoDataAccessor
  videoPlayerController: PlayerPageControllerPlaybackAccessor
  observedResolveToken: number = -1
  private readonly handleEpisodeSelectImpl: (item: PlaybackContextItem) => Promise<boolean>
  private readonly resolvedSourceUrl: string

  constructor(context: MediaLibraryContext, resolvedSourceUrl: string) {
    const page = buildPlayerPageAccessor()
    const handleEpisodeSelect = page.handleEpisodeSelect as Object as BoundHandleEpisodeSelectMethod
    this.handleEpisodeSelectImpl = handleEpisodeSelect.bind(this as Object)
    this.videoPlayerController = new PreparedResumeIsolationController(context)
    this.resolvedSourceUrl = resolvedSourceUrl
  }

  handleEpisodeSelect(item: PlaybackContextItem): Promise<boolean> {
    return this.handleEpisodeSelectImpl(item)
  }

  hideEpisodeAutoplayOverlay(): void {
    this.showEpisodeAutoplayOverlay = false
    this.episodeAutoplayRemainingSeconds = 0
    this.episodeAutoplayNextTitle = ''
  }

  persistCurrentPlaybackState(): void {
    this.videoPlayerController.saveProgressNow()
  }

  async resolveEpisodePlaybackSource(_item: PlaybackContextItem): Promise<ResolvedEpisodePlaybackSource | null> {
    this.observedResolveToken = this.pageParamToken
    return buildResolvedSource(this.resolvedSourceUrl)
  }

  buildVideoDataFromParam(pageParam: PlayerPageParam): PlayerPageVideoDataAccessor | undefined {
    const url = pageParam.url ?? ''
    if (url.length === 0) {
      return undefined
    }
    const videoData: PlayerPageVideoDataAccessor = {
      videoSrc: url
    }
    return videoData
  }

  buildProgressContext(pageParam: PlayerPageParam): PlayerPageProgressContextAccessor {
    const progressContext: PlayerPageProgressContextAccessor = {
      videoId: pageParam.videoId ?? 0,
      seriesProviderId: pageParam.seriesProviderId ?? '',
      seasonNumber: pageParam.seasonNumber ?? 0,
      episodeNumber: pageParam.episodeNumber ?? 0,
      positionMs: 0,
      durationMs: 0,
      updatedAt: 0
    }
    return progressContext
  }

  resumePlaybackForParam(_pageParam: PlayerPageParam): void {
    this.videoPlayerController.play().catch(() => {})
  }
}

class EpisodeSwitchPreparedDecisionInvalidationPage {
  currentPageParam?: PlayerPageParam
  episodeSwitching: boolean = false
  showEpisodeAutoplayOverlay: boolean = false
  episodeAutoplayRemainingSeconds: number = 0
  episodeAutoplayNextTitle: string = ''
  showResumeDialog: boolean = false
  pendingSeekMs: number = -1
  currentMediaKey: string = ''
  currentMediaSeason: number = 0
  currentMediaEpisode: number = 0
  pageParamToken: number = 0
  videoData?: PlayerPageVideoDataAccessor
  videoPlayerController: PlayerPageControllerPlaybackAccessor
  private readonly handleEpisodeSelectImpl: (item: PlaybackContextItem) => Promise<boolean>

  constructor(context: MediaLibraryContext) {
    const page = buildPlayerPageAccessor()
    const handleEpisodeSelect = page.handleEpisodeSelect as Object as BoundHandleEpisodeSelectMethod
    this.handleEpisodeSelectImpl = handleEpisodeSelect.bind(this as Object)
    this.videoPlayerController = new PreparedDecisionTrackingController(context)
  }

  handleEpisodeSelect(item: PlaybackContextItem): Promise<boolean> {
    return this.handleEpisodeSelectImpl(item)
  }

  hideEpisodeAutoplayOverlay(): void {
    this.showEpisodeAutoplayOverlay = false
    this.episodeAutoplayRemainingSeconds = 0
    this.episodeAutoplayNextTitle = ''
  }

  persistCurrentPlaybackState(): void {
    this.videoPlayerController.saveProgressNow()
  }

  async resolveEpisodePlaybackSource(_item: PlaybackContextItem): Promise<ResolvedEpisodePlaybackSource | null> {
    return null
  }

  buildVideoDataFromParam(pageParam: PlayerPageParam): PlayerPageVideoDataAccessor | undefined {
    const url = pageParam.url ?? ''
    if (url.length === 0) {
      return undefined
    }
    const videoData: PlayerPageVideoDataAccessor = {
      videoSrc: url
    }
    return videoData
  }

  buildProgressContext(pageParam: PlayerPageParam): PlayerPageProgressContextAccessor {
    const progressContext: PlayerPageProgressContextAccessor = {
      videoId: pageParam.videoId ?? 0,
      seriesProviderId: pageParam.seriesProviderId ?? '',
      seasonNumber: pageParam.seasonNumber ?? 0,
      episodeNumber: pageParam.episodeNumber ?? 0,
      positionMs: 0,
      durationMs: 0,
      updatedAt: 0
    }
    return progressContext
  }

  resumePlaybackForParam(_pageParam: PlayerPageParam): void {}
}

class ResumeDecisionPage {
  currentMediaSeason: number = 0
  currentMediaEpisode: number = 0
  videoPlayerController: ResumeDecisionControllerAccessor
  private readonly resumePlaybackForParamImpl: (pageParam: PlayerPageParam) => void

  constructor(context: MediaLibraryContext) {
    const page = buildPlayerPageAccessor()
    const resumePlaybackForParam = page.resumePlaybackForParam as Object as BoundResumePlaybackForParamMethod
    this.resumePlaybackForParamImpl = resumePlaybackForParam.bind(this as Object)
    this.videoPlayerController = new ResumeDecisionController(context)
  }

  resumePlaybackForParam(pageParam: PlayerPageParam): void {
    this.resumePlaybackForParamImpl(pageParam)
  }

  emitResumeDiagnosticLog(
    _event: string,
    _pageParam: PlayerPageParam,
    _options?: Object
  ): void {}
}

class TestEpisodeSwitchPage {
  currentPageParam?: PlayerPageParam
  episodeSwitching: boolean = false
  showEpisodeAutoplayOverlay: boolean = false
  episodeAutoplayRemainingSeconds: number = 0
  episodeAutoplayNextTitle: string = ''
  showResumeDialog: boolean = false
  pendingSeekMs: number = -1
  currentMediaKey: string = ''
  currentMediaSeason: number = 0
  currentMediaEpisode: number = 0
  pageParamToken: number = 0
  videoData?: PlayerPageVideoDataAccessor
  videoPlayerController: PlayerPageControllerPlaybackAccessor
  private readonly handleEpisodeSelectImpl: (item: PlaybackContextItem) => Promise<boolean>
  private readonly resolvedSourceUrl: string

  constructor(context: MediaLibraryContext, calls: EpisodeSelectNoOpSideEffectCalls, resolvedSourceUrl: string) {
    const page = buildPlayerPageAccessor()
    const handleEpisodeSelect = page.handleEpisodeSelect as Object as BoundHandleEpisodeSelectMethod
    this.handleEpisodeSelectImpl = handleEpisodeSelect.bind(this as Object)
    this.videoPlayerController = new CountingEpisodeSwitchController(context, calls)
    this.resolvedSourceUrl = resolvedSourceUrl
  }

  handleEpisodeSelect(item: PlaybackContextItem): Promise<boolean> {
    return this.handleEpisodeSelectImpl(item)
  }

  hideEpisodeAutoplayOverlay(): void {
    this.showEpisodeAutoplayOverlay = false
    this.episodeAutoplayRemainingSeconds = 0
    this.episodeAutoplayNextTitle = ''
  }

  persistCurrentPlaybackState(): void {
    this.videoPlayerController.saveProgressNow()
  }

  async resolveEpisodePlaybackSource(_item: PlaybackContextItem): Promise<ResolvedEpisodePlaybackSource | null> {
    return buildResolvedSource(this.resolvedSourceUrl)
  }

  buildVideoDataFromParam(pageParam: PlayerPageParam): PlayerPageVideoDataAccessor | undefined {
    const url = pageParam.url ?? ''
    if (url.length === 0) {
      return undefined
    }
    const videoData: PlayerPageVideoDataAccessor = {
      videoSrc: url
    }
    return videoData
  }

  buildProgressContext(pageParam: PlayerPageParam): PlayerPageProgressContextAccessor {
    const progressContext: PlayerPageProgressContextAccessor = {
      videoId: pageParam.videoId ?? 0,
      seriesProviderId: pageParam.seriesProviderId ?? '',
      seasonNumber: pageParam.seasonNumber ?? 0,
      episodeNumber: pageParam.episodeNumber ?? 0,
      positionMs: 0,
      durationMs: 0,
      updatedAt: 0
    }
    return progressContext
  }

  resumePlaybackForParam(_pageParam: PlayerPageParam): void {
    this.videoPlayerController.play().catch(() => {})
  }
}

class ResumeDecisionEpisodeSwitchPage extends TestEpisodeSwitchPage {
  resumeCalls: EpisodeSwitchResumeCall[] = []
  private readonly resolvedStartPositionMs: number

  constructor(
    context: MediaLibraryContext,
    calls: EpisodeSelectNoOpSideEffectCalls,
    resolvedSourceUrl: string,
    resolvedStartPositionMs: number
  ) {
    super(context, calls, resolvedSourceUrl)
    this.resolvedStartPositionMs = resolvedStartPositionMs
  }

  async resolveEpisodePlaybackSource(item: PlaybackContextItem): Promise<ResolvedEpisodePlaybackSource | null> {
    const resolvedSource = await super.resolveEpisodePlaybackSource(item)
    if (resolvedSource === null) {
      return null
    }
    const nextResolvedSource: ResolvedEpisodePlaybackSource = {
      url: resolvedSource.url,
      sourceIdentity: resolvedSource.sourceIdentity,
      httpHeader: resolvedSource.httpHeader,
      durationHintMs: resolvedSource.durationHintMs,
      presetAudioTracks: resolvedSource.presetAudioTracks,
      presetSubtitleTracks: resolvedSource.presetSubtitleTracks,
      startPositionMs: this.resolvedStartPositionMs
    }
    return nextResolvedSource
  }

  resumePlaybackForParam(pageParam: PlayerPageParam): void {
    const call: EpisodeSwitchResumeCall = {
      mediaKey: pageParam.mediaKey ?? '',
      startPositionMs: pageParam.startPositionMs ?? 0,
      seasonAtCall: this.currentMediaSeason,
      episodeAtCall: this.currentMediaEpisode
    }
    this.resumeCalls.push(call)
  }
}

class EpisodeSwitchFailureCleanupPage extends TestEpisodeSwitchPage {
  constructor(context: MediaLibraryContext, resolvedSourceUrl: string) {
    const calls: EpisodeSelectNoOpSideEffectCalls = {
      persistCurrentPlaybackState: 0,
      reloadSource: 0,
      resumePlaybackForParam: 0,
      saveProgressNow: 0,
      play: 0
    }
    super(context, calls, resolvedSourceUrl)
    this.videoPlayerController = new EpisodeSwitchFailureCleanupController(context)
  }
}

function buildSelectedEpisode(index: number): PlaybackContextItem {
  return {
    index,
    title: `第${index + 1}集`,
    videoPath: `/series/s01e0${index + 1}.mkv`,
    videoId: 100 + index,
    sourceId: 200 + index,
    seasonNumber: 1,
    episodeNumber: index + 1,
    durationMs: 1800000
  }
}

function buildResolvedSource(url: string): ResolvedEpisodePlaybackSource {
  const httpHeader = {} as Record<string, string>
  httpHeader.Authorization = 'Basic token'
  const resolvedSource: ResolvedEpisodePlaybackSource = {
    url,
    sourceIdentity: {
      sourceType: 'webdav',
      sourceId: '200'
    },
    httpHeader,
    durationHintMs: 1800000
  }
  return resolvedSource
}

function buildPlayerPageAccessor(): PlayerPageAccessor {
  return new PlayerPage() as Object as PlayerPageAccessor
}

function buildEpisodeSwitchContext(currentIndex: number = 0): MediaLibraryContext {
  const context = new MediaLibraryContext()
  context.items = [buildSelectedEpisode(0), buildSelectedEpisode(1), buildSelectedEpisode(2)]
  context.currentIndex = currentIndex
  return context
}

function buildEpisodeSwitchParam(context: MediaLibraryContext): PlayerPageParam {
  const pageParam: PlayerPageParam = {
    url: 'https://example.com/current.mkv',
    title: '长夜余火 第一季-S1:E1-启程',
    seriesProviderId: 'tmdb-9527',
    seasonNumber: 1,
    episodeNumber: 1,
    playbackContext: context
  }
  return pageParam
}

function buildEpisodeSwitchController(context: MediaLibraryContext): PlayerPageControllerAccessor {
  return new TestPlayerPageController(context)
}

export default function playerPageTest() {
  describe('PlayerPage episode switching', () => {
    it('初次进入播放器时会用 pageParam 初始化媒体级进度标识', 0, () => {
      const page = buildPlayerPageAccessor()
      const pageParam: PlayerPageParam = {
        url: 'https://example.com/s01e03.mkv',
        title: '第3集',
        mediaKey: 'media_progress_episode_tmdb_tmdb-9527_s1_e3',
        seasonNumber: 1,
        episodeNumber: 3
      }

      page.applyPlayerPageParam(pageParam)

      expect(page.currentMediaKey).assertEqual('media_progress_episode_tmdb_tmdb-9527_s1_e3')
      expect(page.currentMediaSeason).assertEqual(1)
      expect(page.currentMediaEpisode).assertEqual(3)
    })

    it('初次进入播放器且存在 mediaKey 时不会因空 key 跳过媒体级进度保存链路', 0, () => {
      const page = buildPlayerPageAccessor()
      const mediaKey = 'media_progress_episode_tmdb_tmdb-9527_s1_e3'
      page.applyPlayerPageParam({
        url: 'https://example.com/s01e03.mkv',
        title: '第3集',
        mediaKey,
        seasonNumber: 1,
        episodeNumber: 3
      })

      expect(page.currentMediaKey.length > 0).assertTrue()
      expect(page.currentMediaKey).assertEqual(mediaKey)
    })

    it('page_param_prepared_resume 会先清理旧 prepared decision，再为当前媒体建立新 decision', 0, () => {
      const page = buildPlayerPageAccessor()
      const controller = new PreparedDecisionTrackingController(new MediaLibraryContext())
      page.videoPlayerController = controller

      page.applyPlayerPageParam({
        url: 'https://example.com/s01e03.mkv',
        title: '第3集',
        mediaKey: 'media_progress_episode_tmdb_tmdb-9527_s1_e3',
        seasonNumber: 1,
        episodeNumber: 3
      })

      expect(controller.decisionEvents.length).assertEqual(2)
      expect(controller.decisionEvents[0]).assertEqual('discard')
      expect(controller.decisionEvents[1]).assertEqual('prepare:true:page_param_prepared_resume')
    })

    it('新 pageParam 覆盖旧 prepared resume 场景时不会保留旧 decision', 0, () => {
      const page = buildPlayerPageAccessor()
      const controller = new PreparedDecisionTrackingController(new MediaLibraryContext())
      page.videoPlayerController = controller

      page.applyPlayerPageParam({
        url: 'https://example.com/s01e03.mkv',
        title: '第3集',
        mediaKey: 'media_progress_episode_tmdb_tmdb-9527_s1_e3',
        seasonNumber: 1,
        episodeNumber: 3
      })
      page.applyPlayerPageParam({
        url: 'https://example.com/movie.mkv',
        title: '电影'
      })

      expect(controller.decisionEvents.length).assertEqual(3)
      expect(controller.decisionEvents[0]).assertEqual('discard')
      expect(controller.decisionEvents[1]).assertEqual('prepare:true:page_param_prepared_resume')
      expect(controller.decisionEvents[2]).assertEqual('discard')
    })

    it('媒体库选集会生成新的播放参数，并在提交后让 currentIndex 与所选播放源对齐', 0, () => {
      const context = new MediaLibraryContext()
      context.items = [buildSelectedEpisode(0), buildSelectedEpisode(1), buildSelectedEpisode(2)]
      context.currentIndex = 0

      const currentParam: PlayerPageParam = {
        url: 'https://example.com/current.mkv',
        title: '当前播放',
        seriesProviderId: 'tmdb-9527',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: context
      }

      const nextParam = buildMediaLibraryEpisodeSwitchParam(
        currentParam,
        context,
        context.items[2],
        buildResolvedSource('https://example.com/s01e03.mkv')
      )

      expect(nextParam !== null).assertTrue()
      expect(context.currentIndex).assertEqual(0)
      if (nextParam !== null) {
        expect(nextParam.url).assertEqual('https://example.com/s01e03.mkv')
        expect(nextParam.videoId).assertEqual(102)
        expect(nextParam.seasonNumber).assertEqual(1)
        expect(nextParam.episodeNumber).assertEqual(3)
        expect(nextParam.fileSourceType).assertEqual('webdav')
        expect(nextParam.fileSourceId).assertEqual('200')
        expect(nextParam.mediaKey).assertEqual('media_progress_episode_tmdb_tmdb-9527_s1_e3')
        expect(nextParam.playbackContext?.currentIndex).assertEqual(0)
      }

      const committedItem = commitMediaLibraryEpisodeSwitch(context, context.items[2])
      expect(committedItem !== null).assertTrue()
      expect(context.currentIndex).assertEqual(2)
    })

    it('媒体库切集生成的新参数仍可更新媒体级进度标识', 0, () => {
      const page = buildPlayerPageAccessor()
      const context = new MediaLibraryContext()
      context.items = [buildSelectedEpisode(0), buildSelectedEpisode(1), buildSelectedEpisode(2)]
      context.currentIndex = 0

      const currentParam: PlayerPageParam = {
        url: 'https://example.com/current.mkv',
        title: '当前播放',
        seriesProviderId: 'tmdb-9527',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: context
      }

      const nextParam = buildMediaLibraryEpisodeSwitchParam(
        currentParam,
        context,
        context.items[1],
        buildResolvedSource('https://example.com/s01e02.mkv')
      )

      expect(nextParam !== null).assertTrue()
      if (nextParam !== null) {
        page.applyPlayerPageParam(nextParam)
        expect(page.currentMediaKey).assertEqual('media_progress_episode_tmdb_tmdb-9527_s1_e2')
        expect(page.currentMediaSeason).assertEqual(1)
        expect(page.currentMediaEpisode).assertEqual(2)
      }
    })

    it('非 media_library 场景不会生成播放器切源参数', 0, () => {
      const fileExplorerContext = new FileExplorerContext()
      fileExplorerContext.items = [buildSelectedEpisode(0), buildSelectedEpisode(1)]
      fileExplorerContext.currentIndex = 0

      const currentParam: PlayerPageParam = {
        url: 'https://example.com/current.mkv',
        title: '当前播放',
        seriesProviderId: 'tmdb-9527',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: fileExplorerContext
      }

      const nextParam = buildMediaLibraryEpisodeSwitchParam(
        currentParam,
        fileExplorerContext,
        fileExplorerContext.items[1],
        buildResolvedSource('https://example.com/s01e02.mkv')
      )

      expect(nextParam === null).assertTrue()
      expect(fileExplorerContext.currentIndex).assertEqual(0)
    })

    it('媒体库切集后标题保持详情页的完整格式', 0, () => {
      const fakeItems: MediaItem[] = [
        {
          id: 101, sourceId: 201, directoryPath: '/tv', scannedAt: 0,
          filePath: '/series/s01e01.mkv', fileName: 's01e01.mkv', seasonNumber: 1, episodeNumber: 1,
          title: '长夜余火'
        },
        {
          id: 102, sourceId: 202, directoryPath: '/tv', scannedAt: 0,
          filePath: '/series/s01e02.mkv', fileName: 's01e02.mkv', seasonNumber: 1, episodeNumber: 2,
          title: '长夜余火'
        }
      ]
      const episodeEntities: TvEpisodeEntity[] = [
        {
          seriesId: 7, provider: 'tmdb', providerId: 'ep-1',
          seasonNumber: 1, episodeNumber: 1, scrapedAt: 0,
          title: '启程'
        },
        {
          seriesId: 7, provider: 'tmdb', providerId: 'ep-2',
          seasonNumber: 1, episodeNumber: 2, scrapedAt: 0,
          title: '突围'
        }
      ]
      const buildResult = MediaLibraryContext.buildItems(fakeItems, 1, '/series/s01e01.mkv', episodeEntities)
      const context = new MediaLibraryContext()
      context.items = buildResult.items
      context.currentIndex = buildResult.currentIndex

      const currentParam: PlayerPageParam = {
        url: 'https://example.com/current.mkv',
        title: '长夜余火 第一季-S1:E1-启程',
        seriesProviderId: 'tmdb-9527',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: context
      }

      const nextParam = buildMediaLibraryEpisodeSwitchParam(
        currentParam,
        context,
        context.items[1],
        buildResolvedSource('https://example.com/s01e02.mkv')
      )

      expect(context.items[1].title).assertEqual('突围')
      expect(nextParam !== null).assertTrue()
      if (nextParam !== null) {
        expect(nextParam.title).assertEqual('长夜余火 第一季-S1:E2-突围')
        expect(nextParam.title === '突围').assertFalse()
        expect(nextParam.url).assertEqual('https://example.com/s01e02.mkv')
      }
    })

    it('媒体库切集后缺少集标题时仍保持完整标题格式并回退为第X集', 0, () => {
      const fakeItems: MediaItem[] = [
        {
          id: 101, sourceId: 201, directoryPath: '/tv', scannedAt: 0,
          filePath: '/series/s01e01.mkv', fileName: 's01e01.mkv', seasonNumber: 1, episodeNumber: 1,
          title: '长夜余火'
        },
        {
          id: 102, sourceId: 202, directoryPath: '/tv', scannedAt: 0,
          filePath: '/series/s01e02.mkv', fileName: 's01e02.mkv', seasonNumber: 1, episodeNumber: 2,
          title: '长夜余火'
        }
      ]
      const buildResult = MediaLibraryContext.buildItems(fakeItems, 1, '/series/s01e01.mkv')
      const context = new MediaLibraryContext()
      context.items = buildResult.items
      context.currentIndex = buildResult.currentIndex

      const currentParam: PlayerPageParam = {
        url: 'https://example.com/current.mkv',
        title: '长夜余火 第一季-S1:E1-启程',
        seriesProviderId: 'tmdb-9527',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: context
      }

      const nextParam = buildMediaLibraryEpisodeSwitchParam(
        currentParam,
        context,
        context.items[1],
        buildResolvedSource('https://example.com/s01e02.mkv')
      )

      expect(context.items[1].title).assertEqual('第2集')
      expect(nextParam !== null).assertTrue()
      if (nextParam !== null) {
        expect(nextParam.title).assertEqual('长夜余火 第一季-S1:E2-第2集')
        expect(nextParam.title === '第2集').assertFalse()
        expect(nextParam.url).assertEqual('https://example.com/s01e02.mkv')
      }
    })

    it('媒体库切集后当前标题缺少季集编码时使用新集标题', 0, () => {
      const fakeItems: MediaItem[] = [
        {
          id: 101, sourceId: 201, directoryPath: '/tv', scannedAt: 0,
          filePath: '/series/s01e01.mkv', fileName: 's01e01.mkv', seasonNumber: 1, episodeNumber: 1,
          title: '长夜余火'
        },
        {
          id: 102, sourceId: 202, directoryPath: '/tv', scannedAt: 0,
          filePath: '/series/s01e02.mkv', fileName: 's01e02.mkv', seasonNumber: 1, episodeNumber: 2,
          title: '长夜余火'
        }
      ]
      const episodeEntities: TvEpisodeEntity[] = [
        {
          seriesId: 7, provider: 'tmdb', providerId: 'ep-1',
          seasonNumber: 1, episodeNumber: 1, scrapedAt: 0,
          title: '启程'
        },
        {
          seriesId: 7, provider: 'tmdb', providerId: 'ep-2',
          seasonNumber: 1, episodeNumber: 2, scrapedAt: 0,
          title: '突围'
        }
      ]
      const buildResult = MediaLibraryContext.buildItems(fakeItems, 1, '/series/s01e01.mkv', episodeEntities)
      const context = new MediaLibraryContext()
      context.items = buildResult.items
      context.currentIndex = buildResult.currentIndex

      const currentParam: PlayerPageParam = {
        url: 'https://example.com/current.mkv',
        title: '长夜余火 第一季',
        seriesProviderId: 'tmdb-9527',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: context
      }

      const nextParam = buildMediaLibraryEpisodeSwitchParam(
        currentParam,
        context,
        context.items[1],
        buildResolvedSource('https://example.com/s01e02.mkv')
      )

      expect(context.items[1].title).assertEqual('突围')
      expect(nextParam !== null).assertTrue()
      if (nextParam !== null) {
        expect(nextParam.title).assertEqual('突围')
        expect(nextParam.title === '长夜余火 第一季').assertFalse()
        expect(nextParam.url).assertEqual('https://example.com/s01e02.mkv')
      }
    })

    it('播放器内点击当前集数时只关闭弹层且不触发切集链路', 0, async () => {
      const context = buildEpisodeSwitchContext(0)
      // 若误入 resolveEpisodePlaybackSource，sourceId <= 0 会导致 handleEpisodeSelect 返回 false
      context.items[0].sourceId = 0
      const calls: EpisodeSelectNoOpSideEffectCalls = {
        persistCurrentPlaybackState: 0,
        reloadSource: 0,
        resumePlaybackForParam: 0,
        saveProgressNow: 0,
        play: 0
      }
      const page = buildPlayerPageAccessor()
      page.videoPlayerController = new SpyEpisodeSwitchController(context, calls)
      page.currentPageParam = {
        url: 'https://example.com/current.mkv',
        title: '长夜余火 第一季-S1:E1-启程',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: context
      }

      const didSwitch = await page.handleEpisodeSelect(context.items[0])

      expect(didSwitch).assertTrue()
      expect(context.currentIndex).assertEqual(0)
      expect(page.currentPageParam?.episodeNumber ?? 0).assertEqual(1)
      expect(page.videoPlayerController.progressContext === null).assertTrue()
      expect(calls.persistCurrentPlaybackState).assertEqual(0)
      expect(calls.reloadSource).assertEqual(0)
      expect(calls.resumePlaybackForParam).assertEqual(0)
      expect(calls.saveProgressNow).assertEqual(0)
      expect(calls.play).assertEqual(0)
    })

    it('index 不同但季集元数据相同且资源不同时仍会继续切换', 0, async () => {
      const context = buildEpisodeSwitchContext(0)
      context.items[1].seasonNumber = 1
      context.items[1].episodeNumber = 1
      context.items[1].title = '启程-B'
      context.items[1].videoPath = '/series/s01e01-alt.mkv'
      context.items[1].videoId = 301
      const calls: EpisodeSelectNoOpSideEffectCalls = {
        persistCurrentPlaybackState: 0,
        reloadSource: 0,
        resumePlaybackForParam: 0,
        saveProgressNow: 0,
        play: 0
      }
      const page = new TestEpisodeSwitchPage(context, calls, 'https://example.com/s01e01-alt.mkv')
      const controller = page.videoPlayerController as Object as CountingEpisodeSwitchController
      page.currentPageParam = {
        url: 'https://example.com/current.mkv',
        title: '长夜余火 第一季-S1:E1-启程',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: context
      }

      const didSwitch = await page.handleEpisodeSelect(context.items[1])

      expect(didSwitch).assertTrue()
      expect(context.currentIndex).assertEqual(1)
      expect(controller.lastVideoSrc).assertEqual('https://example.com/s01e01-alt.mkv')
      expect(page.currentPageParam?.url ?? '').assertEqual('https://example.com/s01e01-alt.mkv')
      expect(page.currentPageParam?.videoId ?? 0).assertEqual(301)
      expect(page.currentPageParam?.episodeNumber ?? 0).assertEqual(1)
      expect(calls.persistCurrentPlaybackState).assertEqual(1)
      expect(calls.reloadSource).assertEqual(1)
      expect(calls.resumePlaybackForParam).assertEqual(1)
      expect(calls.saveProgressNow).assertEqual(1)
      expect(calls.play).assertEqual(1)
    })

    it('旧 pageParam 的 PREPARED 一次性监听在 token 失效后不会续播', 0, () => {
      emitter.off(PlayerEvents.PREPARED.eventId)
      const context = buildEpisodeSwitchContext(0)
      const page = new PreparedResumeListenerPage(context)
      page.pageParamToken = 2
      page.registerPreparedResume({
        url: 'https://example.com/current.mkv',
        title: '长夜余火 第一季-S1:E1-启程',
        mediaKey: 'media_progress_episode_tmdb_tmdb-9527_s1_e1',
        seriesProviderId: 'tmdb-9527',
        seasonNumber: 1,
        episodeNumber: 1,
        videoId: 101,
        playbackContext: context
      }, 1)

      emitter.emit(PlayerEvents.PREPARED)
      expect(page.resumeCalls.length).assertEqual(0)
      emitter.off(PlayerEvents.PREPARED.eventId)
    })

    it('pageParamToken 失效且切集解析失败时会先丢弃旧 prepared decision，避免泄漏到后续媒体', 0, async () => {
      const context = buildEpisodeSwitchContext(0)
      const page = new EpisodeSwitchPreparedDecisionInvalidationPage(context)
      const controller = page.videoPlayerController as PreparedDecisionTrackingController
      page.currentPageParam = buildEpisodeSwitchParam(context)
      page.pageParamToken = 5

      const didSwitch = await page.handleEpisodeSelect(context.items[1])

      expect(didSwitch).assertFalse()
      expect(controller.decisionEvents.length).assertEqual(1)
      expect(controller.decisionEvents[0]).assertEqual('discard')
    })

    it('媒体级进度接近完播时会改为清理进度后继续播放', 0, () => {
      const mediaKey = 'media_progress_episode_tmdb_tmdb-9527_s1_e7'
      const nearEndEntry = new MediaProgressEntry(
        mediaKey, 1720000, 1800000, 1, 1, 7
      )
      const action = resolveMediaProgressResumeAction(
        nearEndEntry,
        1800000,
        1,
        7
      )

      expect(action.action).assertEqual('clear_and_play')
      expect(action.positionMs ?? 0).assertEqual(0)
    })

    it('重新进入同季同集且存在有效进度时会生成 seek 决策', 0, () => {
      const savedEntry = new MediaProgressEntry(
        'media_progress_episode_tmdb_tmdb-9527_s1_e7', 420000, 1800000, 1, 1, 7
      )
      const action = resolveMediaProgressResumeAction(
        savedEntry,
        1800000,
        1,
        7
      )

      expect(action.action).assertEqual('seek')
      expect(action.positionMs ?? 0).assertEqual(420000)
    })

    it('重新进入同一视频但没有有效进度时会直接播放', 0, () => {
      const noProgressEntry = new MediaProgressEntry(
        'media_progress_episode_tmdb_tmdb-9527_s1_e7', 0, 1800000, 1, 1, 7
      )
      const action = resolveMediaProgressResumeAction(
        noProgressEntry,
        1800000,
        1,
        7
      )

      expect(action.action).assertEqual('play')
      expect(action.positionMs ?? 0).assertEqual(0)
    })

    it('重新进入不同季或不同集时不会错误复用旧进度', 0, () => {
      const savedEntry = new MediaProgressEntry(
        'media_progress_episode_tmdb_tmdb-9527_s1_e7', 420000, 1800000, 1, 1, 7
      )
      const actionForDifferentSeason = resolveMediaProgressResumeAction(
        savedEntry,
        1800000,
        2,
        7
      )
      const actionForDifferentEpisode = resolveMediaProgressResumeAction(
        savedEntry,
        1800000,
        1,
        8
      )

      expect(actionForDifferentSeason.action).assertEqual('play')
      expect(actionForDifferentSeason.positionMs ?? 0).assertEqual(0)
      expect(actionForDifferentEpisode.action).assertEqual('play')
      expect(actionForDifferentEpisode.positionMs ?? 0).assertEqual(0)
    })

    it('resumePlaybackForParam 会优先 seek 选集切换传入的新媒体 startPositionMs', 0, async () => {
      const context = buildEpisodeSwitchContext(1)
      const page = new ResumeDecisionPage(context)
      const controller = page.videoPlayerController as ResumeDecisionController
      const pageParam: PlayerPageParam = {
        url: 'https://example.com/s01e02.mkv',
        title: '长夜余火 第一季-S1:E2-突围',
        mediaKey: 'media_progress_episode_tmdb_tmdb-9527_s1_e2',
        seasonNumber: 1,
        episodeNumber: 2,
        startPositionMs: 245000
      }

      page.resumePlaybackForParam(pageParam)

      expect(controller.seekCalls.length).assertEqual(1)
      expect(controller.seekCalls[0]).assertEqual(245000)
      expect(controller.playCalls).assertEqual(0)
    })

    it('resumePlaybackForParam 直接播放路径会显式记录当前会话的自动续播决策', 0, async () => {
      const context = buildEpisodeSwitchContext(0)
      const page = new ResumeDecisionPage(context)
      const controller = page.videoPlayerController as ResumeDecisionController
      const pageParam: PlayerPageParam = {
        url: 'https://example.com/movie.mkv',
        title: '独行月球',
        videoId: 9527
      }

      page.resumePlaybackForParam(pageParam)

      expect(controller.resumeAutoplayDecisionEvents.length).assertEqual(2)
      expect(controller.resumeAutoplayDecisionEvents[0]).assertEqual('remember:true:prepared_resume_play')
      expect(controller.resumeAutoplayDecisionEvents[1]).assertEqual('play')
    })

    it('handleEpisodeSelect 会把新媒体续播参数与新季集标识一起传给 reload 后的续播决策', 0, async () => {
      const context = buildEpisodeSwitchContext(0)
      const calls: EpisodeSelectNoOpSideEffectCalls = {
        persistCurrentPlaybackState: 0,
        reloadSource: 0,
        resumePlaybackForParam: 0,
        saveProgressNow: 0,
        play: 0
      }
      const page = new ResumeDecisionEpisodeSwitchPage(
        context,
        calls,
        'https://example.com/s01e02.mkv',
        245000
      )
      page.currentPageParam = buildEpisodeSwitchParam(context)

      const didSwitch = await page.handleEpisodeSelect(context.items[1])

      expect(didSwitch).assertTrue()
      expect(calls.reloadSource).assertEqual(1)
      const controller = page.videoPlayerController as CountingEpisodeSwitchController
      expect(controller.prepareResumeAutoplayDecisionCalls.length).assertEqual(1)
      expect(controller.prepareResumeAutoplayDecisionCalls[0]).assertEqual('true:episode_switch_prepared_resume')
      expect(page.resumeCalls.length).assertEqual(1)
      expect(page.resumeCalls[0].mediaKey).assertEqual('media_progress_episode_tmdb_tmdb-9527_s1_e2')
      expect(page.resumeCalls[0].startPositionMs).assertEqual(245000)
      expect(page.resumeCalls[0].seasonAtCall).assertEqual(1)
      expect(page.resumeCalls[0].episodeAtCall).assertEqual(2)
      expect(page.currentPageParam?.episodeNumber ?? 0).assertEqual(2)
    })

    it('handleEpisodeSelect 在 reload 前更新页面播放源，避免重建组件重新初始化旧集', 0, async () => {
      const context = buildEpisodeSwitchContext(0)
      const calls: EpisodeSelectNoOpSideEffectCalls = {
        persistCurrentPlaybackState: 0,
        reloadSource: 0,
        resumePlaybackForParam: 0,
        saveProgressNow: 0,
        play: 0
      }
      const page = new ResumeDecisionEpisodeSwitchPage(
        context,
        calls,
        'https://example.com/s01e02.mkv',
        0
      )
      page.currentPageParam = buildEpisodeSwitchParam(context)
      page.videoData = { videoSrc: 'https://example.com/s01e01.mkv' }
      const controller = page.videoPlayerController as CountingEpisodeSwitchController
      let pageSourceDuringReload: string = ''
      let pageEpisodeDuringReload: number = 0
      controller.reloadObserver = (): void => {
        pageSourceDuringReload = page.videoData?.videoSrc ?? ''
        pageEpisodeDuringReload = page.currentPageParam?.episodeNumber ?? 0
      }

      const didSwitch = await page.handleEpisodeSelect(context.items[1])

      expect(didSwitch).assertTrue()
      expect(pageSourceDuringReload).assertEqual('https://example.com/s01e02.mkv')
      expect(pageEpisodeDuringReload).assertEqual(2)
    })

    it('handleEpisodeSelect 在 prepare 后 reload 失败时会清理新 prepared decision', 0, async () => {
      const context = buildEpisodeSwitchContext(0)
      const page = new EpisodeSwitchFailureCleanupPage(context, 'https://example.com/s01e02.mkv')
      const controller = page.videoPlayerController as EpisodeSwitchFailureCleanupController
      const previousProgressContext: PlayerPageProgressContextAccessor = {
        videoId: 101,
        seriesProviderId: 'tmdb-9527',
        seasonNumber: 1,
        episodeNumber: 1,
        positionMs: 120000,
        durationMs: 1800000,
        updatedAt: 1
      }
      page.currentPageParam = buildEpisodeSwitchParam(context)
      page.videoData = { videoSrc: 'https://example.com/s01e01.mkv' }
      page.currentMediaKey = 'media_progress_episode_tmdb_tmdb-9527_s1_e1'
      page.currentMediaSeason = 1
      page.currentMediaEpisode = 1
      controller.progressContext = previousProgressContext

      const didSwitch = await page.handleEpisodeSelect(context.items[1])

      expect(didSwitch).assertFalse()
      expect(controller.preparedDecisionActive).assertFalse()
      expect(controller.preparedDecisionSource).assertEqual('')
      expect(controller.progressContext?.episodeNumber ?? 0).assertEqual(1)
      expect(page.currentPageParam?.episodeNumber ?? 0).assertEqual(1)
      expect(page.videoData?.videoSrc ?? '').assertEqual('https://example.com/s01e01.mkv')
      expect(page.currentMediaKey).assertEqual('media_progress_episode_tmdb_tmdb-9527_s1_e1')
      expect(page.currentMediaSeason).assertEqual(1)
      expect(page.currentMediaEpisode).assertEqual(1)
    })

    it('handleEpisodeSelect 会在解析新播放源前推进 pageParamToken', 0, async () => {
      const context = buildEpisodeSwitchContext(0)
      const page = new EpisodeSwitchTokenPage(context, 'https://example.com/s01e02.mkv')
      page.pageParamToken = 7
      page.currentPageParam = {
        url: 'https://example.com/current.mkv',
        title: '长夜余火 第一季-S1:E1-启程',
        seriesProviderId: 'tmdb-9527',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: context
      }

      const didSwitch = await page.handleEpisodeSelect(context.items[1])

      expect(didSwitch).assertTrue()
      expect(page.observedResolveToken).assertEqual(8)
      expect(page.pageParamToken).assertEqual(8)
      expect(page.currentPageParam?.episodeNumber ?? 0).assertEqual(2)
    })

    it('当前集短路判断保持在 handleEpisodeSelect 内，不额外新增 helper', 0, () => {
      const page = buildPlayerPageAccessor() as Object as PlayerPageCurrentEpisodeHelperAccessor

      expect(page.isCurrentMediaLibraryEpisodeSelection === undefined).assertTrue()
    })

    it('服务器切集生成携带服务器元数据与播放会话的新参数', 0, () => {
      const context = buildServerSwitchContext()
      const currentParam: PlayerPageParam = {
        url: 'https://jellyfin.local/stream/server-ep-1',
        title: '测试剧集 第一季-S1:E1-第1集',
        serverType: 'jellyfin',
        serverItemId: 'server-ep-1',
        serverId: 5,
        serverPlaySessionId: 'session-old',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: context
      }

      const nextParam = buildServerEpisodeSwitchParam(
        currentParam,
        context,
        context.items[1],
        buildResolvedServerSwitchSource('https://jellyfin.local/stream/server-ep-2', 'session-new')
      )

      expect(nextParam !== null).assertTrue()
      if (nextParam !== null) {
        expect(nextParam.url).assertEqual('https://jellyfin.local/stream/server-ep-2')
        expect(nextParam.serverType ?? '').assertEqual('jellyfin')
        expect(nextParam.serverItemId ?? '').assertEqual('server-ep-2')
        expect(nextParam.serverId ?? 0).assertEqual(5)
        expect(nextParam.serverPlaySessionId ?? '').assertEqual('session-new')
        expect(nextParam.title).assertEqual('测试剧集 第一季-S1:E2-第2集')
        expect(nextParam.seasonNumber ?? 0).assertEqual(1)
        expect(nextParam.episodeNumber ?? 0).assertEqual(2)
        expect(nextParam.durationHintMs ?? 0).assertEqual(1800000)
        expect(nextParam.playbackContext === context).assertTrue()
      }
    })

    it('非 server_media_library 上下文构建服务器切集参数返回 null', 0, () => {
      const mediaContext = new MediaLibraryContext()
      const currentParam: PlayerPageParam = {
        url: 'https://example.com/current.mkv',
        title: '本地剧集',
        playbackContext: mediaContext
      }
      const item: PlaybackContextItem = {
        index: 0,
        title: '第1集',
        videoPath: '/series/s01e01.mkv',
        videoId: 101,
        sourceId: 201,
        seasonNumber: 1,
        episodeNumber: 1,
        durationMs: 1800000
      }

      const nextParam = buildServerEpisodeSwitchParam(
        currentParam,
        mediaContext,
        item,
        buildResolvedServerSwitchSource('https://example.com/s01e01.mkv', 'session-x')
      )

      expect(nextParam).assertNull()
    })

    it('服务器切集索引越界返回 null，commit 正常更新上下文索引', 0, () => {
      const context = buildServerSwitchContext()
      const currentParam: PlayerPageParam = {
        url: 'https://jellyfin.local/stream/server-ep-1',
        title: '测试剧集 第一季-S1:E1-第1集',
        serverType: 'jellyfin',
        serverItemId: 'server-ep-1',
        serverId: 5,
        playbackContext: context
      }
      const outOfRangeItem: PlaybackContextItem = {
        index: 9,
        title: '越界集',
        videoPath: 'server-ep-9',
        videoId: 0,
        sourceId: 0,
        seasonNumber: 1,
        episodeNumber: 9,
        durationMs: 0
      }

      const outOfRangeParam = buildServerEpisodeSwitchParam(
        currentParam,
        context,
        outOfRangeItem,
        buildResolvedServerSwitchSource('https://jellyfin.local/stream/server-ep-9', 'session-x')
      )
      expect(outOfRangeParam).assertNull()
      expect(commitServerEpisodeSwitch(context, outOfRangeItem)).assertNull()
      expect(context.currentIndex).assertEqual(0)

      const committed = commitServerEpisodeSwitch(context, context.items[1])
      expect(committed !== null).assertTrue()
      expect(context.currentIndex).assertEqual(1)
    })
  })
}
