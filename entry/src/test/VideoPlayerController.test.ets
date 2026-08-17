import { describe, it, expect } from '@ohos/hypium';
import {
  VideoPlayerController,
  AudioTrackItem,
  PlayerBackend,
  resolveAiEnhanceEnabledByRuntime,
  shouldShowAiEnhanceSettingsByRuntime,
  resolveEffectivePlaybackSurfaceId,
  isHdrVideo
} from '../main/ets/components/core/player/VideoPlayerController';
import { IPlayer, SubtitleInfo, TrackInfo } from '../main/ets/components/core/player/IPlayer';
import {
  ISubtitleBridgeAdapter,
  SubtitleBridgeState,
  SubtitleTrackItem
} from '../main/ets/components/core/player/SubtitleBridgeAdapter';
import { PresetAudioTrack, VideoData } from '../main/ets/components/core/player/VideoData';
import { VideoDataType } from '../main/ets/components/core/player/Constants';
import { normalizeAudioCodec } from '../main/ets/services/audioRouting/AudioTrackRoutingService';

interface VideoPlayerControllerAccessor {
  backend: PlayerBackend
  surfaceId: string
  player?: IPlayer
  currentVideoData?: VideoData
  currentOriginalVideoSrc: string
  playbackSessionId: number
  consumedReadyResumeToken: string
  pendingResumeState: PendingResumeStateSnapshot | null
  pendingResumeAutoplayDecisionExplicit: boolean
  hasPendingResumeAutoplayDecisionExplicit: boolean
  pendingResumeAutoplayDecisionSource: string
  preparedResumeAutoplayDecisionExplicit: boolean
  hasPreparedResumeAutoplayDecisionExplicit: boolean
  preparedResumeAutoplayDecisionSource: string
  currentTime: number
  duration: number
  progress: number
  isPlaying: boolean
  isSeeking: boolean
  isLoading: boolean
  lastErrorMessage: string
  subtitleTracks: TrackInfo[]
  currentSubtitleTrack: number
  allSubtitleTracks: SubtitleTrackItem[]
  activeSubtitleIndex: number
  subtitleDelayMs: number
  audioTracks: AudioTrackItem[]
  activeAudioIndex: number
  pendingBackendResumeTimeMs: number
  pendingBackendResumePlay: boolean
  pendingMpvSurfaceId: string
  pendingMpvSurfaceWidth: number
  pendingMpvSurfaceHeight: number
  subtitleAdapter: ISubtitleBridgeAdapter
  pendingReloadResolve?: () => void
  pendingReloadReject?: (error: Error) => void
  pendingResumeAutoplayResultState: PendingResumeAutoplayResultStateSnapshot | null
  handlePlayerPlayEvent(sessionId: number): void
  fallbackAvPlayerToMpv(reason: string, detailMessage?: string): void
  handleTerminalPlayerError(message: string): void
  capturePendingResumeForFallback(source: string): void
  handlePlayerPaused(): void
  continuePendingReadyAfterSeek(): Promise<void>
  onPlayerReady(): Promise<void>
  resolvePendingReload(): void
  findInitialAudioTrackIndex(): number
  isAudioTrackPlayable(track: AudioTrackItem): boolean
}

interface PendingResumeStateSnapshot {
  positionMs: number
  shouldResumePlay: boolean
  autoplayDecisionSource: string
  autoplayDecisionOrigin: string
}

interface ResumeDiagnosticRecordSnapshot {
  event: string
  resumeSource: string
  captureBackend: PlayerBackend
  pendingResumeMs: number
  effectiveResumeMs: number
  autoResumePlay: boolean
  autoplayDecision: string
  queuedSeekMs: number
  autoplayDecisionSource: string
  autoplayDecisionOrigin: string
  autoplayExecutionResult: string
  durationMs: number
  filePath: string
}

interface PendingResumeAutoplayResultStateSnapshot {
  resumeSource: string
  captureBackend: PlayerBackend
  pendingResumeMs: number
  effectiveResumeMs: number
  shouldResumePlay: boolean
  autoplayDecision: string
  autoplayDecisionSource: string
  autoplayDecisionOrigin: string
}

class MockFallbackPlayer implements IPlayer {
  duration: number = 2_684_598
  currentTime: number = 500_762
  seekCalls: number[] = []
  playCallCount: number = 0

  init(_videoData: VideoData, _surfaceId: string): Promise<void> { return Promise.resolve() }
  play(): Promise<void> {
    this.playCallCount += 1
    return Promise.resolve()
  }
  pause(): Promise<void> { return Promise.resolve() }
  toggle(): Promise<void> { return Promise.resolve() }
  release(): Promise<void> { return Promise.resolve() }
  seek(timeMs: number): void {
    this.seekCalls.push(timeMs)
  }
  forward(_milliseconds: number): Promise<void> { return Promise.resolve() }
  backward(_milliseconds: number): Promise<void> { return Promise.resolve() }
  getTrackInfos(): Promise<TrackInfo[]> { return Promise.resolve([]) }
  selectTrack(_trackIndex: number): Promise<void> { return Promise.resolve() }
  setSubtitleDelay(_delayMs: number): void {}
  setPlaybackSpeed(_speed: number): void {}
  setPropertyString(_property: string, _value: string): void {}
  onReady(_callback: () => void): void {}
  onPlay(_callback: () => void): void {}
  onPaused(_callback: () => void): void {}
  onCompleted(_callback: () => void): void {}
  onStopped(_callback: () => void): void {}
  onTimeUpdate(_callback: (currentTime: number) => void): void {}
  onBuffering(_callback: (isBuffering: boolean) => void): void {}
  onError(_callback: (error: Error) => void): void {}
  onUnsupportedFormat(_callback: () => void): void {}
  onSeekDone(_callback: () => void): void {}
  onSubtitleUpdate(_callback: (info: SubtitleInfo) => void): void {}
}

class RecordingFallbackPlayer extends MockFallbackPlayer {
  readonly events: string[]
  private readonly audioTrackInfo: TrackInfo

  constructor(events: string[]) {
    super()
    this.events = events
    const audioTrackInfo: TrackInfo = {
      trackIndex: 0,
      trackType: 'audio',
      language: 'chi',
      mimeType: 'audio/mp4a-latm'
    }
    this.audioTrackInfo = audioTrackInfo
  }

  play(): Promise<void> {
    this.events.push('player:play')
    return super.play()
  }

  seek(timeMs: number): void {
    this.events.push(`player:seek:${timeMs}`)
    super.seek(timeMs)
  }

  getTrackInfos(): Promise<TrackInfo[]> {
    this.events.push('player:getTrackInfos')
    return Promise.resolve([this.audioTrackInfo])
  }

  selectTrack(trackIndex: number): Promise<void> {
    this.events.push(`player:selectTrack:${trackIndex}`)
    return Promise.resolve()
  }
}

class RejectingFallbackPlayer extends MockFallbackPlayer {
  play(): Promise<void> {
    this.playCallCount += 1
    return Promise.reject(new Error('mock play failed'))
  }
}

class PlayEventFallbackPlayer extends MockFallbackPlayer {
  private playCallback?: () => void

  onPlay(callback: () => void): void {
    this.playCallback = callback
  }

  triggerPlayEvent(): void {
    this.playCallback?.()
  }
}

class DelayedSeekCompleteFallbackPlayer extends PlayEventFallbackPlayer {
  private seekDoneCallback?: () => void

  onSeekDone(callback: () => void): void {
    this.seekDoneCallback = callback
  }

  triggerSeekDone(): void {
    this.seekDoneCallback?.()
  }
}

class RecordingSubtitleAdapter implements ISubtitleBridgeAdapter {
  private readonly events: string[]
  private state: SubtitleBridgeState

  constructor(events: string[]) {
    this.events = events
    const subtitleTracks: TrackInfo[] = []
    const allSubtitleTracks: SubtitleTrackItem[] = []
    const state: SubtitleBridgeState = {
      subtitleTracks,
      allSubtitleTracks,
      activeSubtitleIndex: -1,
      currentSubtitleTrack: -1,
      currentSubtitleText: '',
      subtitleDelayMs: 0,
      hasExternalActive: false
    }
    this.state = state
  }

  async init(_player: IPlayer, _videoData?: VideoData): Promise<void> {
    this.events.push('subtitle:init')
    const internalSubtitleTracks: SubtitleTrackItem[] = [{
      kind: 'internal',
      displayName: '中文',
      internalIndex: 0,
      language: 'chi'
    }]
    const nextState: SubtitleBridgeState = {
      subtitleTracks: [],
      allSubtitleTracks: internalSubtitleTracks,
      activeSubtitleIndex: 0,
      currentSubtitleTrack: 0,
      currentSubtitleText: '',
      subtitleDelayMs: 0,
      hasExternalActive: false
    }
    this.state = nextState
  }

  onTimeUpdate(_currentTimeMs: number): void {}

  onSubtitleUpdate(_info: SubtitleInfo): void {}

  onEmbeddedTimedText(_text: string): void {}

  async switchTrack(_allIndex: number): Promise<void> {
    return Promise.resolve()
  }

  adjustDelay(_deltaMs: number): void {}

  onSeekSync(): void {
    this.events.push('subtitle:onSeekSync')
  }

  getState(): SubtitleBridgeState {
    return this.state
  }

  release(): void {}

  async addLocalSubtitle(_localPath: string): Promise<void> {
    return Promise.resolve()
  }
}

class TestVideoPlayerController extends VideoPlayerController {
  async initPlayer(_videoData: VideoData, surfaceId: string): Promise<void> {
    this.surfaceId = surfaceId
  }

  saveProgressNow(): void {}
}

class SurfaceInitVideoPlayerController extends TestVideoPlayerController {
  initializedVideoData?: VideoData

  async initPlayer(videoData: VideoData, surfaceId: string): Promise<void> {
    this.initializedVideoData = videoData
    await super.initPlayer(videoData, surfaceId)
  }
}

class DiagnosticVideoPlayerController extends TestVideoPlayerController {
  readonly resumeLogs: ResumeDiagnosticRecordSnapshot[] = []

  protected override emitResumeDiagnosticRecord(recordText: string): void {
    const logPrefix = '[resume] '
    const payloadText = recordText.startsWith(logPrefix)
      ? recordText.substring(logPrefix.length)
      : recordText
    const parsed = JSON.parse(payloadText) as ResumeDiagnosticRecordSnapshot
    this.resumeLogs.push(parsed)
  }
}

class InitPlayerDiagnosticVideoPlayerController extends VideoPlayerController {
  readonly resumeLogs: ResumeDiagnosticRecordSnapshot[] = []
  private readonly injectedPlayer: PlayEventFallbackPlayer

  constructor(player: PlayEventFallbackPlayer) {
    super()
    this.injectedPlayer = player
  }

  protected override createAvPlayerAdapter(): IPlayer {
    return this.injectedPlayer
  }

  protected override createAdapterForBackend(_backend: PlayerBackend): IPlayer | undefined {
    return this.injectedPlayer
  }

  protected override emitResumeDiagnosticRecord(recordText: string): void {
    const logPrefix = '[resume] '
    const payloadText = recordText.startsWith(logPrefix)
      ? recordText.substring(logPrefix.length)
      : recordText
    const parsed = JSON.parse(payloadText) as ResumeDiagnosticRecordSnapshot
    this.resumeLogs.push(parsed)
  }

  saveProgressNow(): void {}
}

class InitPlayerDelayedSeekFallbackController extends VideoPlayerController {
  private readonly injectedPlayer: DelayedSeekCompleteFallbackPlayer

  constructor(player: DelayedSeekCompleteFallbackPlayer) {
    super()
    this.injectedPlayer = player
  }

  protected override createAvPlayerAdapter(): IPlayer {
    return this.injectedPlayer
  }

  protected override createAdapterForBackend(_backend: PlayerBackend): IPlayer | undefined {
    return this.injectedPlayer
  }

  saveProgressNow(): void {}
}

class ControlledResumeSeekFallbackController extends InitPlayerDelayedSeekFallbackController {
  private pendingResumeSeekFallbackTimerId: number = 0
  private pendingResumeSeekFallbackCallback?: () => void

  protected override scheduleResumeSeekAutoplayFallbackTimeout(callback: () => void): number {
    this.pendingResumeSeekFallbackTimerId += 1
    this.pendingResumeSeekFallbackCallback = callback
    return this.pendingResumeSeekFallbackTimerId
  }

  protected override clearResumeSeekAutoplayFallbackTimeout(timerId: number): void {
    if (timerId === this.pendingResumeSeekFallbackTimerId) {
      this.pendingResumeSeekFallbackCallback = undefined
    }
  }

  triggerResumeSeekAutoplayFallback(): void {
    const callback = this.pendingResumeSeekFallbackCallback
    this.pendingResumeSeekFallbackCallback = undefined
    callback?.()
  }
}

class ReloadPreparedLifecycleController extends VideoPlayerController {
  preparedStateSeenInReload: boolean = false
  preparedSourceSeenInReload: string = ''
  pendingStateSeenAfterInit: boolean = false
  pendingSourceSeenAfterInit: string = ''
  playCallCount: number = 0
  private readonly injectedPlayer: MockFallbackPlayer = new MockFallbackPlayer()

  protected override createAvPlayerAdapter(): IPlayer {
    return this.injectedPlayer
  }

  protected override createAdapterForBackend(_backend: PlayerBackend): IPlayer | undefined {
    return this.injectedPlayer
  }

  async initPlayer(videoData: VideoData, surfaceId: string): Promise<void> {
    const beforeAccessor = accessController(this)
    this.preparedStateSeenInReload = beforeAccessor.hasPreparedResumeAutoplayDecisionExplicit
    this.preparedSourceSeenInReload = beforeAccessor.preparedResumeAutoplayDecisionSource
    super.initPlayer(videoData, surfaceId).catch(() => {})
    const afterAccessor = accessController(this)
    this.pendingStateSeenAfterInit = afterAccessor.hasPendingResumeAutoplayDecisionExplicit
    this.pendingSourceSeenAfterInit = afterAccessor.pendingResumeAutoplayDecisionSource
    afterAccessor.resolvePendingReload()
  }

  play(): Promise<void> {
    this.playCallCount += 1
    return Promise.resolve()
  }

  saveProgressNow(): void {}
}

class ReloadPreparedEarlyFailureController extends VideoPlayerController {
  saveProgressNow(): void {}
}

class ReloadPreparedPendingFailureController extends VideoPlayerController {
  pendingStateSeenBeforeFailure: boolean = false
  pendingSourceSeenBeforeFailure: string = ''

  async initPlayer(videoData: VideoData, surfaceId: string): Promise<void> {
    super.initPlayer(videoData, surfaceId).catch(() => {})
    const accessor = accessController(this)
    this.pendingStateSeenBeforeFailure = accessor.hasPendingResumeAutoplayDecisionExplicit
    this.pendingSourceSeenBeforeFailure = accessor.pendingResumeAutoplayDecisionSource
    throw new Error('init failed after pending decision')
  }

  saveProgressNow(): void {}
}

function buildVideoData(name: string): VideoData {
  return {
    type: VideoDataType.FILE_URI,
    videoSrc: `file:///${name}.mp4`,
    name
  }
}

function buildVideoDataWithPresetAudio(name: string): VideoData {
  const videoData = buildVideoData(name)
  const presetAudioTracks: PresetAudioTrack[] = [{
    trackIndex: 0,
    displayName: '中文 (AAC)',
    language: 'chi',
    mimeType: 'audio/mp4a-latm'
  }]
  videoData.presetAudioTracks = presetAudioTracks
  return videoData
}

function accessController(controller: VideoPlayerController): VideoPlayerControllerAccessor {
  return controller as Object as VideoPlayerControllerAccessor
}

async function flushMicrotasks(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

function resetTrackStateForSimulatedNewSession(accessor: VideoPlayerControllerAccessor): void {
  accessor.subtitleTracks = []
  accessor.currentSubtitleTrack = -1
  accessor.allSubtitleTracks = []
  accessor.activeSubtitleIndex = -1
  accessor.subtitleDelayMs = 0
  accessor.audioTracks = []
  accessor.activeAudioIndex = -1
}

function findResumeLog(
  controller: DiagnosticVideoPlayerController | InitPlayerDiagnosticVideoPlayerController,
  event: string
): ResumeDiagnosticRecordSnapshot | null {
  for (let index = controller.resumeLogs.length - 1; index >= 0; index -= 1) {
    const record = controller.resumeLogs[index]
    if (record.event === event) {
      return record
    }
  }
  return null
}

export default function videoPlayerControllerTest() {
  describe('VideoPlayerController review regressions', () => {
    it('XComponent 首次挂载使用组件传入的播放源', 0, async () => {
      const controller = new SurfaceInitVideoPlayerController()
      const initialVideoData = buildVideoData('initial-surface-source')

      await controller.initPlayerForSurface(initialVideoData, 'surface-initial')

      expect(controller.initializedVideoData).assertEqual(initialVideoData)
      expect(controller.surfaceId).assertEqual('surface-initial')
    })

    it('XComponent 重建忽略组件旧源并恢复控制器当前原始源', 0, async () => {
      const controller = new SurfaceInitVideoPlayerController()
      const accessor = accessController(controller)
      const staleVideoData = buildVideoData('episode-one')
      const activeVideoData = buildVideoData('episode-two')
      activeVideoData.videoSrc = 'http://127.0.0.1:34559/episode-two.mp4'
      accessor.currentVideoData = activeVideoData
      accessor.currentOriginalVideoSrc = 'smb://server/share/episode-two.mkv'

      await controller.initPlayerForSurface(staleVideoData, 'surface-recreated')

      expect(controller.initializedVideoData).assertEqual(activeVideoData)
      expect(activeVideoData.videoSrc).assertEqual('smb://server/share/episode-two.mkv')
      expect(controller.surfaceId).assertEqual('surface-recreated')
    })

    it('MPV player 尚未创建时会缓存最新 surface 参数', 0, async () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      accessor.backend = 'mpv'
      accessor.player = undefined

      await controller.setMpvSurface('surface-before-player', 1920, 1080)

      expect(accessor.pendingMpvSurfaceId).assertEqual('surface-before-player')
      expect(accessor.pendingMpvSurfaceWidth).assertEqual(1920)
      expect(accessor.pendingMpvSurfaceHeight).assertEqual(1080)
    })

    it('fallback 后端尚未切成 MPV 时也会缓存 surface 参数', 0, async () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      accessor.backend = 'avplayer'
      accessor.player = undefined

      await controller.setMpvSurface('surface-during-fallback', 1280, 720)

      expect(accessor.pendingMpvSurfaceId).assertEqual('surface-during-fallback')
      expect(accessor.pendingMpvSurfaceWidth).assertEqual(1280)
      expect(accessor.pendingMpvSurfaceHeight).assertEqual(720)
    })

    it('reloadSource 再次触发时会先拒绝上一个待完成回调', 0, async () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      accessor.backend = 'avplayer'
      accessor.surfaceId = 'surface-review'
      let rejectedMessage = ''
      accessor.pendingReloadResolve = (): void => {}
      accessor.pendingReloadReject = (error: Error): void => {
        rejectedMessage = error.message
      }

      const secondReload = controller.reloadSource(buildVideoData('second'), false)
      await flushMicrotasks()

      accessor.resolvePendingReload()
      await secondReload

      expect(rejectedMessage).assertEqual('reload superseded')
    })

    it('运行时探测失败时会强制关闭画质增强请求', 0, () => {
      expect(resolveAiEnhanceEnabledByRuntime(false, true)).assertFalse()
      expect(resolveAiEnhanceEnabledByRuntime(false, false)).assertFalse()
      expect(resolveAiEnhanceEnabledByRuntime(true, true)).assertTrue()
    })

    it('仅在 avplayer 且运行时支持时显示画质增强设置', 0, () => {
      expect(shouldShowAiEnhanceSettingsByRuntime(true, 'avplayer')).assertTrue()
      expect(shouldShowAiEnhanceSettingsByRuntime(false, 'avplayer')).assertFalse()
      expect(shouldShowAiEnhanceSettingsByRuntime(true, 'mpv')).assertFalse()
    })

    it('HDR 视频不显示画质增强设置', 0, () => {
      expect(shouldShowAiEnhanceSettingsByRuntime(true, 'avplayer', true)).assertFalse()
      expect(shouldShowAiEnhanceSettingsByRuntime(true, 'avplayer', false)).assertTrue()
      expect(shouldShowAiEnhanceSettingsByRuntime(true, 'mpv', true)).assertFalse()
    })

    it('isHdrVideo 正确判定 HDR 类型', 0, () => {
      expect(isHdrVideo('HDR10')).assertTrue()
      expect(isHdrVideo('HLG')).assertTrue()
      expect(isHdrVideo('DOLBY_VISION')).assertTrue()
      expect(isHdrVideo('SDR')).assertFalse()
      expect(isHdrVideo('')).assertFalse()
      expect(isHdrVideo(undefined)).assertFalse()
    })

    it('VPE 未提供输入 surface 时回退到基础播放 surface', 0, () => {
      expect(resolveEffectivePlaybackSurfaceId('display-surface', '')).assertEqual('display-surface')
      expect(resolveEffectivePlaybackSurfaceId('display-surface', 'vpe-input-surface')).assertEqual('vpe-input-surface')
    })

    it('AVPlayer fallback 到 MPV 会切换后端并保留续播位置与自动续播意图', 0, () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      accessor.backend = 'avplayer'
      accessor.player = new MockFallbackPlayer()
      accessor.currentTime = 501626
      accessor.duration = 2684598
      accessor.progress = 0
      accessor.isPlaying = false
      accessor.isSeeking = true
      accessor.pendingBackendResumeTimeMs = -1
      accessor.pendingBackendResumePlay = false

      accessor.fallbackAvPlayerToMpv('test_fallback')

      expect(accessor.backend).assertEqual('mpv')
      expect(accessor.pendingBackendResumeTimeMs).assertEqual(501626)
      expect(accessor.pendingBackendResumePlay).assertTrue()
      expect(accessor.currentTime).assertEqual(501626)
    })

    it('MPV 终端错误会停止加载和播放并保留可展示错误', 0, () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      accessor.backend = 'mpv'
      accessor.isLoading = true
      accessor.isPlaying = true

      accessor.handleTerminalPlayerError('MPV decoder failed')

      expect(accessor.backend).assertEqual('mpv')
      expect(accessor.isLoading).assertFalse()
      expect(accessor.isPlaying).assertFalse()
      expect(accessor.lastErrorMessage).assertEqual('MPV decoder failed')
    })

    it('reloadSource 自动播放路径会写入 prepared decision，并在 initPlayer 启动时转正消费', 0, async () => {
      const controller = new ReloadPreparedLifecycleController()
      const accessor = accessController(controller)
      accessor.surfaceId = 'surface-review'

      await controller.reloadSource(buildVideoData('reload-autoplay'), true)

      expect(controller.preparedStateSeenInReload).assertTrue()
      expect(controller.preparedSourceSeenInReload).assertEqual('reload_source_autoplay')
      expect(controller.pendingStateSeenAfterInit).assertTrue()
      expect(controller.pendingSourceSeenAfterInit).assertEqual('reload_source_autoplay')
      expect(accessor.hasPreparedResumeAutoplayDecisionExplicit).assertFalse()
      expect(accessor.preparedResumeAutoplayDecisionSource).assertEqual('')
      expect(accessor.hasPendingResumeAutoplayDecisionExplicit).assertTrue()
      expect(accessor.pendingResumeAutoplayDecisionSource).assertEqual('reload_source_autoplay')
      expect(controller.playCallCount).assertEqual(1)
    })

    it('reloadSource 自动播放路径前置校验失败时会清理旧 prepared decision', 0, async () => {
      const controller = new ReloadPreparedEarlyFailureController()
      const accessor = accessController(controller)
      accessor.surfaceId = ''
      controller.prepareResumeAutoplayDecision(false, 'stale_prepared')

      let rejectedMessage = ''
      try {
        await controller.reloadSource(buildVideoData('reload-autoplay-early-failure'), true)
      } catch (error) {
        rejectedMessage = (error as Error).message
      }

      expect(rejectedMessage).assertEqual('reloadSource requires surfaceId')
      expect(accessor.hasPreparedResumeAutoplayDecisionExplicit).assertFalse()
      expect(accessor.preparedResumeAutoplayDecisionSource).assertEqual('')
    })

    it('reloadSource 在 prepared 已转成 pending 后失败时会同时清理 prepared 与 pending decision', 0, async () => {
      const controller = new ReloadPreparedPendingFailureController()
      const accessor = accessController(controller)
      accessor.surfaceId = 'surface-review'
      controller.prepareResumeAutoplayDecision(true, 'episode_switch_prepared_resume')

      let rejectedMessage = ''
      try {
        await controller.reloadSource(buildVideoData('reload-pending-failure'), false)
      } catch (error) {
        rejectedMessage = (error as Error).message
      }

      expect(controller.pendingStateSeenBeforeFailure).assertTrue()
      expect(controller.pendingSourceSeenBeforeFailure).assertEqual('episode_switch_prepared_resume')
      expect(rejectedMessage).assertEqual('init failed after pending decision')
      expect(accessor.hasPreparedResumeAutoplayDecisionExplicit).assertFalse()
      expect(accessor.preparedResumeAutoplayDecisionSource).assertEqual('')
      expect(accessor.hasPendingResumeAutoplayDecisionExplicit).assertFalse()
      expect(accessor.pendingResumeAutoplayDecisionSource).assertEqual('')
    })

    it('公共 seek 入口会为新会话初始化链路记录显式自动续播决策来源', 0, async () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      const player = new MockFallbackPlayer()
      accessor.player = player
      accessor.currentTime = 3200
      accessor.duration = 9000
      accessor.isPlaying = false
      accessor.isSeeking = false

      await controller.seek(3200, 'prepared_resume_seek')

      expect(player.seekCalls.length).assertEqual(1)
      expect(player.seekCalls[0]).assertEqual(3200)
      expect(accessor.hasPendingResumeAutoplayDecisionExplicit).assertTrue()
      expect(accessor.pendingResumeAutoplayDecisionExplicit).assertTrue()
      expect(accessor.pendingResumeAutoplayDecisionSource).assertEqual('prepared_resume_seek')
    })

    it('prepared resume seek 超时兜底会恢复一次播放且晚到 seekDone 不会重复 play', 0, async () => {
      const player = new DelayedSeekCompleteFallbackPlayer()
      const controller = new ControlledResumeSeekFallbackController(player)

      await controller.initPlayer(buildVideoDataWithPresetAudio('resume-seek-timeout-fallback'), 'surface-timeout-fallback')
      await controller.seek(245000, 'prepared_resume_seek')

      expect(player.seekCalls.length).assertEqual(1)
      expect(player.playCallCount).assertEqual(0)
      controller.triggerResumeSeekAutoplayFallback()
      await flushMicrotasks()

      expect(player.playCallCount).assertEqual(1)

      player.triggerSeekDone()
      await flushMicrotasks()

      expect(player.playCallCount).assertEqual(1)
    })

    it('prepared resume seek 超时兜底前若发生显式 pause 不会误恢复播放', 0, async () => {
      const player = new DelayedSeekCompleteFallbackPlayer()
      const controller = new ControlledResumeSeekFallbackController(player)

      await controller.initPlayer(buildVideoDataWithPresetAudio('resume-seek-timeout-pause'), 'surface-timeout-pause')
      await controller.seek(245000, 'prepared_resume_seek')

      await controller.pause()
      controller.triggerResumeSeekAutoplayFallback()
      await flushMicrotasks()

      expect(player.playCallCount).assertEqual(0)
    })

    it('prepared resume seek 显式 pause 后晚到 seekDone 主路径不会误恢复播放', 0, async () => {
      const player = new DelayedSeekCompleteFallbackPlayer()
      const controller = new ControlledResumeSeekFallbackController(player)

      await controller.initPlayer(buildVideoDataWithPresetAudio('resume-seek-late-seekdone-pause'), 'surface-late-seekdone-pause')
      await controller.seek(245000, 'prepared_resume_seek')

      await controller.pause()
      controller.triggerResumeSeekAutoplayFallback()
      await flushMicrotasks()
      player.triggerSeekDone()
      await flushMicrotasks()

      expect(player.playCallCount).assertEqual(0)
    })

    it('普通 seek 未带 autoplayDecisionSource 时超时后不会触发 fallback play', 0, async () => {
      const player = new DelayedSeekCompleteFallbackPlayer()
      const controller = new ControlledResumeSeekFallbackController(player)

      await controller.initPlayer(buildVideoDataWithPresetAudio('plain-seek-no-fallback-play'), 'surface-no-fallback-play')
      await controller.seek(245000)
      controller.triggerResumeSeekAutoplayFallback()
      await flushMicrotasks()

      expect(player.playCallCount).assertEqual(0)
    })

    it('reloadSource 自动播放会记录显式恢复决策建立日志', 0, async () => {
      const controller = new DiagnosticVideoPlayerController()
      const accessor = accessController(controller)
      accessor.backend = 'avplayer'
      accessor.surfaceId = 'surface-review'

      const reloadTask = controller.reloadSource(buildVideoData('reload-diagnostic'), true)
      await flushMicrotasks()
      accessor.resolvePendingReload()
      await reloadTask

      const decisionLog = findResumeLog(controller, 'resume_decision_established')
      expect(decisionLog !== null).assertTrue()
      if (decisionLog !== null) {
        expect(decisionLog.autoplayDecisionSource).assertEqual('reload_source_autoplay')
        expect(decisionLog.autoplayDecisionOrigin).assertEqual('explicit')
      }
    })

    it('fallback capture 会在 seekDone 到 onPlay 窗口内保留显式自动播放决策', 0, async () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      const player = new MockFallbackPlayer()
      accessor.player = player
      accessor.currentTime = 3200
      accessor.duration = 9000
      accessor.isPlaying = false
      accessor.isSeeking = false

      await controller.seek(3200, 'prepared_resume_seek')
      expect(accessor.hasPendingResumeAutoplayDecisionExplicit).assertTrue()
      accessor.isSeeking = false
      accessor.capturePendingResumeForFallback('test_fallback')

      expect(accessor.pendingResumeState?.autoplayDecisionSource ?? '').assertEqual('prepared_resume_seek')
      expect(accessor.pendingBackendResumePlay).assertTrue()
    })

    it('fallback capture 日志会区分显式恢复决策来源', 0, async () => {
      const controller = new DiagnosticVideoPlayerController()
      const accessor = accessController(controller)
      const player = new MockFallbackPlayer()
      accessor.player = player
      accessor.currentTime = 3200
      accessor.duration = 9000
      accessor.isPlaying = false
      accessor.isSeeking = false

      await controller.seek(3200, 'prepared_resume_seek')
      accessor.isSeeking = false
      accessor.capturePendingResumeForFallback('test_fallback')

      const captureLog = findResumeLog(controller, 'resume_pending_capture')
      expect(captureLog !== null).assertTrue()
      if (captureLog !== null) {
        expect(captureLog.autoplayDecisionSource).assertEqual('prepared_resume_seek')
        expect(captureLog.autoplayDecisionOrigin).assertEqual('explicit')
      }
    })

    it('fallback capture 日志会标记瞬时状态兜底来源', 0, async () => {
      const controller = new DiagnosticVideoPlayerController()
      const accessor = accessController(controller)
      accessor.currentTime = 1800
      accessor.duration = 9000
      accessor.isPlaying = false
      accessor.isSeeking = false

      accessor.capturePendingResumeForFallback('test_fallback')

      const captureLog = findResumeLog(controller, 'resume_pending_capture')
      expect(captureLog !== null).assertTrue()
      if (captureLog !== null) {
        expect(captureLog.autoplayDecisionSource).assertEqual('transient_player_state')
        expect(captureLog.autoplayDecisionOrigin).assertEqual('transient')
      }
    })

    it('MPV onReady 时会消费 fallback 保留的续播点并执行 seek', 0, async () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      const player = new MockFallbackPlayer()
      accessor.backend = 'mpv'
      accessor.player = player
      accessor.currentTime = 0
      accessor.duration = player.duration
      accessor.progress = 0
      accessor.isPlaying = false
      accessor.isSeeking = false
      accessor.pendingBackendResumeTimeMs = 501626
      accessor.pendingBackendResumePlay = true

      await accessor.onPlayerReady()

      expect(player.seekCalls.length).assertEqual(1)
      expect(player.seekCalls[0]).assertEqual(501626)
      expect(accessor.pendingBackendResumeTimeMs).assertEqual(-1)
      expect(accessor.pendingBackendResumePlay).assertFalse()
      expect(accessor.currentTime).assertEqual(501626)
      expect(player.playCallCount).assertEqual(0)
    })

    it('fallback pending-resume 场景 onPlayerReady 会先进入 seek 再延后轨道初始化', 0, async () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      const events: string[] = []
      const player = new RecordingFallbackPlayer(events)
      const subtitleAdapter = new RecordingSubtitleAdapter(events)
      accessor.backend = 'mpv'
      accessor.player = player
      accessor.subtitleAdapter = subtitleAdapter
      accessor.currentTime = 0
      accessor.duration = player.duration
      accessor.progress = 0
      accessor.isPlaying = false
      accessor.isSeeking = false
      accessor.pendingBackendResumeTimeMs = 501626
      accessor.pendingBackendResumePlay = true

      await accessor.onPlayerReady()

      expect(events.length).assertEqual(2)
      expect(events[0]).assertEqual('subtitle:onSeekSync')
      expect(events[1]).assertEqual('player:seek:501626')
    })

    it('fallback pending-resume 场景 seek 完成后才补偿轨道初始化并只恢复一次播放', 0, async () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      const events: string[] = []
      const player = new RecordingFallbackPlayer(events)
      const subtitleAdapter = new RecordingSubtitleAdapter(events)
      accessor.backend = 'mpv'
      accessor.player = player
      accessor.subtitleAdapter = subtitleAdapter
      accessor.currentVideoData = buildVideoData('fallback-pending-resume')
      accessor.currentTime = 0
      accessor.duration = player.duration
      accessor.progress = 0
      accessor.isPlaying = false
      accessor.isSeeking = false
      accessor.pendingBackendResumeTimeMs = 501626
      accessor.pendingBackendResumePlay = true

      await accessor.onPlayerReady()
      await accessor.continuePendingReadyAfterSeek()

      expect(events.length).assertEqual(6)
      expect(events[0]).assertEqual('subtitle:onSeekSync')
      expect(events[1]).assertEqual('player:seek:501626')
      expect(events[2]).assertEqual('subtitle:init')
      expect(events[3]).assertEqual('player:getTrackInfos')
      expect(events[4]).assertEqual('player:selectTrack:0')
      expect(events[5]).assertEqual('player:play')
      expect(accessor.activeSubtitleIndex).assertEqual(0)
      expect(player.playCallCount).assertEqual(1)
    })

    it('fallback pending-resume 场景会记录消费与自动播放结果日志', 0, async () => {
      const controller = new DiagnosticVideoPlayerController()
      const accessor = accessController(controller)
      const events: string[] = []
      const player = new RecordingFallbackPlayer(events)
      const subtitleAdapter = new RecordingSubtitleAdapter(events)
      accessor.backend = 'mpv'
      accessor.player = player
      accessor.subtitleAdapter = subtitleAdapter
      accessor.currentTime = 0
      accessor.duration = player.duration
      accessor.progress = 0
      accessor.isPlaying = false
      accessor.isSeeking = false
      accessor.pendingBackendResumeTimeMs = 501626
      accessor.pendingBackendResumePlay = true

      await accessor.onPlayerReady()
      await accessor.continuePendingReadyAfterSeek()

      const consumeLog = findResumeLog(controller, 'resume_pending_consume')
      expect(consumeLog !== null).assertTrue()
      if (consumeLog !== null) {
        expect(consumeLog.autoplayDecisionSource).assertEqual('compat_override')
      }
      const resultLog = findResumeLog(controller, 'resume_autoplay_result')
      expect(resultLog !== null).assertTrue()
      if (resultLog !== null) {
        expect(resultLog.autoplayExecutionResult).assertEqual('play_requested')
      }
    })

    it('fallback pending-resume 保持暂停时会记录 paused 结果日志', 0, async () => {
      const controller = new DiagnosticVideoPlayerController()
      const accessor = accessController(controller)
      const events: string[] = []
      const player = new RecordingFallbackPlayer(events)
      const subtitleAdapter = new RecordingSubtitleAdapter(events)
      accessor.backend = 'mpv'
      accessor.player = player
      accessor.subtitleAdapter = subtitleAdapter
      accessor.currentTime = 0
      accessor.duration = player.duration
      accessor.progress = 0
      accessor.isPlaying = false
      accessor.isSeeking = false
      accessor.pendingBackendResumeTimeMs = 501626
      accessor.pendingBackendResumePlay = false

      await accessor.onPlayerReady()
      await accessor.continuePendingReadyAfterSeek()

      const resultLog = findResumeLog(controller, 'resume_autoplay_result')
      expect(resultLog !== null).assertTrue()
      if (resultLog !== null) {
        expect(resultLog.autoplayExecutionResult).assertEqual('paused')
      }
    })

    it('选集切换续播在 unsupported fallback 后会恢复位置并自动播放', 0, async () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      const currentPlayer = new MockFallbackPlayer()
      currentPlayer.currentTime = 245000
      accessor.backend = 'avplayer'
      accessor.player = currentPlayer
      accessor.currentTime = 245000
      accessor.duration = 900000
      accessor.progress = 0
      accessor.isPlaying = false
      accessor.isSeeking = false

      controller.prepareResumeAutoplayDecision(true, 'episode_switch_prepared_resume')
      await controller.seek(245000, 'prepared_resume_seek')
      accessor.isSeeking = false
      accessor.capturePendingResumeForFallback('avplayer_unsupported_format')

      expect(accessor.pendingResumeState?.positionMs ?? 0).assertEqual(245000)
      expect(accessor.pendingResumeState?.autoplayDecisionSource ?? '').assertEqual('prepared_resume_seek')
      expect(accessor.pendingResumeState?.shouldResumePlay ?? false).assertTrue()

      const fallbackEvents: string[] = []
      const fallbackPlayer = new RecordingFallbackPlayer(fallbackEvents)
      const fallbackSubtitleAdapter = new RecordingSubtitleAdapter(fallbackEvents)
      accessor.backend = 'mpv'
      accessor.player = fallbackPlayer
      accessor.subtitleAdapter = fallbackSubtitleAdapter
      accessor.currentVideoData = buildVideoData('episode-fallback')
      accessor.currentTime = 0
      accessor.duration = fallbackPlayer.duration
      accessor.progress = 0
      accessor.isPlaying = false
      accessor.isSeeking = false

      await accessor.onPlayerReady()
      await accessor.continuePendingReadyAfterSeek()

      expect(fallbackPlayer.seekCalls.length).assertEqual(1)
      expect(fallbackPlayer.seekCalls[0]).assertEqual(245000)
      expect(fallbackPlayer.playCallCount).assertEqual(1)
      expect(fallbackEvents.length).assertEqual(6)
      expect(fallbackEvents[5]).assertEqual('player:play')
    })

    it('选集切换后的显式暂停决策在 unsupported fallback 后仍保持暂停', 0, async () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      const currentPlayer = new MockFallbackPlayer()
      currentPlayer.currentTime = 245000
      accessor.backend = 'avplayer'
      accessor.player = currentPlayer
      accessor.currentTime = 245000
      accessor.duration = 900000
      accessor.progress = 0
      accessor.isPlaying = false
      accessor.isSeeking = false

      controller.rememberResumeAutoplayDecision(false, 'episode_switch_pause_resume')
      accessor.capturePendingResumeForFallback('avplayer_unsupported_format')

      expect(accessor.pendingResumeState?.positionMs ?? 0).assertEqual(245000)
      expect(accessor.pendingResumeState?.autoplayDecisionSource ?? '').assertEqual('episode_switch_pause_resume')
      expect(accessor.pendingResumeState?.shouldResumePlay ?? true).assertFalse()

      const fallbackEvents: string[] = []
      const fallbackPlayer = new RecordingFallbackPlayer(fallbackEvents)
      const fallbackSubtitleAdapter = new RecordingSubtitleAdapter(fallbackEvents)
      accessor.backend = 'mpv'
      accessor.player = fallbackPlayer
      accessor.subtitleAdapter = fallbackSubtitleAdapter
      accessor.currentVideoData = buildVideoData('episode-pause-fallback')
      accessor.currentTime = 0
      accessor.duration = fallbackPlayer.duration
      accessor.progress = 0
      accessor.isPlaying = false
      accessor.isSeeking = false

      await accessor.onPlayerReady()
      await accessor.continuePendingReadyAfterSeek()

      expect(fallbackPlayer.seekCalls.length).assertEqual(1)
      expect(fallbackPlayer.seekCalls[0]).assertEqual(245000)
      expect(fallbackPlayer.playCallCount).assertEqual(0)
      expect(fallbackEvents.length).assertEqual(5)
      expect(fallbackEvents[4]).assertEqual('player:selectTrack:0')
    })

    it('play 在已有恢复上下文时会记录 play_requested 结果日志', 0, async () => {
      const controller = new DiagnosticVideoPlayerController()
      const accessor = accessController(controller)
      const player = new MockFallbackPlayer()
      const pendingResultState: PendingResumeAutoplayResultStateSnapshot = {
        resumeSource: 'seek_done_resume',
        captureBackend: 'mpv',
        pendingResumeMs: 3200,
        effectiveResumeMs: 3200,
        shouldResumePlay: true,
        autoplayDecision: 'play',
        autoplayDecisionSource: 'prepared_resume_seek',
        autoplayDecisionOrigin: 'explicit'
      }
      accessor.player = player
      accessor.pendingResumeAutoplayResultState = pendingResultState

      await controller.play()

      const resultLog = findResumeLog(controller, 'resume_autoplay_result')
      expect(resultLog !== null).assertTrue()
      if (resultLog !== null) {
        expect(resultLog.autoplayExecutionResult).assertEqual('play_requested')
        expect(resultLog.autoplayDecision).assertEqual('play')
      }
    })

    it('play 在记录 play_requested 前会先刷新 duration 日志字段', 0, async () => {
      const controller = new DiagnosticVideoPlayerController()
      const accessor = accessController(controller)
      const player = new MockFallbackPlayer()
      const pendingResultState: PendingResumeAutoplayResultStateSnapshot = {
        resumeSource: 'seek_done_resume',
        captureBackend: 'mpv',
        pendingResumeMs: 3200,
        effectiveResumeMs: 3200,
        shouldResumePlay: true,
        autoplayDecision: 'play',
        autoplayDecisionSource: 'prepared_resume_seek',
        autoplayDecisionOrigin: 'explicit'
      }
      player.duration = 654321
      accessor.player = player
      accessor.duration = 0
      accessor.pendingResumeAutoplayResultState = pendingResultState

      await controller.play()

      const resultLog = findResumeLog(controller, 'resume_autoplay_result')
      expect(resultLog !== null).assertTrue()
      if (resultLog !== null) {
        expect(resultLog.autoplayExecutionResult).assertEqual('play_requested')
        expect(resultLog.durationMs).assertEqual(654321)
      }
    })

    it('resume 日志仅保留本地文件协议，不暴露敏感路径信息', 0, async () => {
      const controller = new DiagnosticVideoPlayerController()
      const accessor = accessController(controller)
      const player = new MockFallbackPlayer()
      const pendingResultState: PendingResumeAutoplayResultStateSnapshot = {
        resumeSource: 'seek_done_resume',
        captureBackend: 'mpv',
        pendingResumeMs: 3200,
        effectiveResumeMs: 3200,
        shouldResumePlay: true,
        autoplayDecision: 'play',
        autoplayDecisionSource: 'prepared_resume_seek',
        autoplayDecisionOrigin: 'explicit'
      }
      const videoData: VideoData = {
        type: VideoDataType.FILE_URI,
        videoSrc: 'file:///Users/demo/Movies/Secret/episode01.mp4?token=abc',
        name: 'episode01'
      }
      accessor.player = player
      accessor.currentVideoData = videoData
      accessor.pendingResumeAutoplayResultState = pendingResultState

      await controller.play()

      const resultLog = findResumeLog(controller, 'resume_autoplay_result')
      expect(resultLog !== null).assertTrue()
      if (resultLog !== null) {
        expect(resultLog.filePath).assertEqual('file://***')
      }
    })

    it('resume 日志仅保留 SMB 协议，不暴露主机与共享路径信息', 0, async () => {
      const controller = new DiagnosticVideoPlayerController()
      const accessor = accessController(controller)
      const player = new MockFallbackPlayer()
      const pendingResultState: PendingResumeAutoplayResultStateSnapshot = {
        resumeSource: 'seek_done_resume',
        captureBackend: 'mpv',
        pendingResumeMs: 3200,
        effectiveResumeMs: 3200,
        shouldResumePlay: true,
        autoplayDecision: 'play',
        autoplayDecisionSource: 'prepared_resume_seek',
        autoplayDecisionOrigin: 'explicit'
      }
      const videoData: VideoData = {
        type: VideoDataType.URL,
        videoSrc: 'smb://user:pass@192.168.1.9/media-share/Shows/episode01.mkv?token=abc',
        name: 'episode01'
      }
      accessor.player = player
      accessor.currentVideoData = videoData
      accessor.pendingResumeAutoplayResultState = pendingResultState

      await controller.play()

      const resultLog = findResumeLog(controller, 'resume_autoplay_result')
      expect(resultLog !== null).assertTrue()
      if (resultLog !== null) {
        expect(resultLog.filePath).assertEqual('smb://***')
      }
    })

    it('play -> onPlay 在已有恢复上下文时会记录 play_started 结果日志', 0, async () => {
      const player = new PlayEventFallbackPlayer()
      const controller = new InitPlayerDiagnosticVideoPlayerController(player)
      const accessor = accessController(controller)
      const pendingResultState: PendingResumeAutoplayResultStateSnapshot = {
        resumeSource: 'seek_done_resume',
        captureBackend: 'mpv',
        pendingResumeMs: 3200,
        effectiveResumeMs: 3200,
        shouldResumePlay: true,
        autoplayDecision: 'play',
        autoplayDecisionSource: 'prepared_resume_seek',
        autoplayDecisionOrigin: 'explicit'
      }
      await controller.initPlayer(buildVideoDataWithPresetAudio('task-3-1-play-started'), 'surface-play-started')
      expect(accessor.player === player).assertTrue()
      accessor.pendingResumeAutoplayResultState = pendingResultState

      await controller.play()
      expect(player.playCallCount).assertEqual(1)
      const requestedLog = findResumeLog(controller, 'resume_autoplay_result')
      expect(requestedLog !== null).assertTrue()
      if (requestedLog !== null) {
        expect(requestedLog.autoplayExecutionResult).assertEqual('play_requested')
      }
      player.triggerPlayEvent()

      const resultLog = findResumeLog(controller, 'resume_autoplay_result')
      expect(resultLog !== null).assertTrue()
      if (resultLog !== null) {
        expect(resultLog.autoplayExecutionResult).assertEqual('play_started')
      }
    })

    it('play 在无播放器实例时会记录 play_no_player 结果日志', 0, async () => {
      const controller = new DiagnosticVideoPlayerController()
      const accessor = accessController(controller)
      const pendingResultState: PendingResumeAutoplayResultStateSnapshot = {
        resumeSource: 'seek_done_resume',
        captureBackend: 'mpv',
        pendingResumeMs: 3200,
        effectiveResumeMs: 3200,
        shouldResumePlay: true,
        autoplayDecision: 'play',
        autoplayDecisionSource: 'prepared_resume_seek',
        autoplayDecisionOrigin: 'explicit'
      }
      accessor.pendingResumeAutoplayResultState = pendingResultState

      await controller.play()

      const resultLog = findResumeLog(controller, 'resume_autoplay_result')
      expect(resultLog !== null).assertTrue()
      if (resultLog !== null) {
        expect(resultLog.autoplayExecutionResult).assertEqual('play_no_player')
      }
    })

    it('play 在底层播放器拒绝时会记录 play_failed 结果日志', 0, async () => {
      const controller = new DiagnosticVideoPlayerController()
      const accessor = accessController(controller)
      const player = new RejectingFallbackPlayer()
      const pendingResultState: PendingResumeAutoplayResultStateSnapshot = {
        resumeSource: 'seek_done_resume',
        captureBackend: 'mpv',
        pendingResumeMs: 3200,
        effectiveResumeMs: 3200,
        shouldResumePlay: true,
        autoplayDecision: 'play',
        autoplayDecisionSource: 'prepared_resume_seek',
        autoplayDecisionOrigin: 'explicit'
      }
      accessor.player = player
      accessor.pendingResumeAutoplayResultState = pendingResultState

      await controller.play()

      const resultLog = findResumeLog(controller, 'resume_autoplay_result')
      expect(resultLog !== null).assertTrue()
      if (resultLog !== null) {
        expect(resultLog.autoplayExecutionResult).assertEqual('play_failed')
      }
    })

    it('fallback pending-resume 场景重复 onPlayerReady 不会重复消费恢复逻辑', 0, async () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      const events: string[] = []
      const player = new RecordingFallbackPlayer(events)
      const subtitleAdapter = new RecordingSubtitleAdapter(events)
      accessor.backend = 'mpv'
      accessor.player = player
      accessor.subtitleAdapter = subtitleAdapter
      accessor.currentTime = 0
      accessor.duration = player.duration
      accessor.progress = 0
      accessor.isPlaying = false
      accessor.isSeeking = false
      accessor.pendingBackendResumeTimeMs = 501626
      accessor.pendingBackendResumePlay = true

      await accessor.onPlayerReady()
      await accessor.onPlayerReady()

      expect(events.length).assertEqual(2)
      expect(events[0]).assertEqual('subtitle:onSeekSync')
      expect(events[1]).assertEqual('player:seek:501626')
      expect(player.seekCalls.length).assertEqual(1)
      expect(player.playCallCount).assertEqual(0)
    })

    it('fallback 切换后新后端首次 onPlayerReady 仍会消费 pending resume', 0, async () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      const initialEvents: string[] = []
      const initialPlayer = new RecordingFallbackPlayer(initialEvents)
      const initialSubtitleAdapter = new RecordingSubtitleAdapter(initialEvents)
      accessor.backend = 'avplayer'
      accessor.player = initialPlayer
      accessor.subtitleAdapter = initialSubtitleAdapter
      accessor.currentTime = 0
      accessor.duration = initialPlayer.duration
      accessor.progress = 0
      accessor.isPlaying = false
      accessor.isSeeking = false

      await accessor.onPlayerReady()

      const fallbackEvents: string[] = []
      const fallbackPlayer = new RecordingFallbackPlayer(fallbackEvents)
      const fallbackSubtitleAdapter = new RecordingSubtitleAdapter(fallbackEvents)
      accessor.backend = 'mpv'
      accessor.player = fallbackPlayer
      accessor.subtitleAdapter = fallbackSubtitleAdapter
      accessor.currentTime = 0
      accessor.duration = fallbackPlayer.duration
      accessor.progress = 0
      accessor.isPlaying = false
      accessor.isSeeking = false
      accessor.pendingBackendResumeTimeMs = 501626
      accessor.pendingBackendResumePlay = true

      await accessor.onPlayerReady()

      expect(fallbackEvents.length).assertEqual(2)
      expect(fallbackEvents[0]).assertEqual('subtitle:onSeekSync')
      expect(fallbackEvents[1]).assertEqual('player:seek:501626')
      expect(fallbackPlayer.seekCalls.length).assertEqual(1)
      expect(accessor.pendingBackendResumeTimeMs).assertEqual(-1)
    })

    it('同 backend 的后续新媒体会话不会被旧 ready token 阻断 pending resume', 0, async () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      const firstSessionEvents: string[] = []
      const firstSessionPlayer = new RecordingFallbackPlayer(firstSessionEvents)
      const firstSessionSubtitleAdapter = new RecordingSubtitleAdapter(firstSessionEvents)
      accessor.backend = 'mpv'
      accessor.player = firstSessionPlayer
      accessor.subtitleAdapter = firstSessionSubtitleAdapter
      accessor.playbackSessionId = 1
      accessor.currentVideoData = buildVideoData('same-backend-resume')
      accessor.currentTime = 0
      accessor.duration = firstSessionPlayer.duration
      accessor.progress = 0
      accessor.isPlaying = false
      accessor.isSeeking = false
      accessor.pendingBackendResumeTimeMs = 501626
      accessor.pendingBackendResumePlay = true

      await accessor.onPlayerReady()
      await accessor.continuePendingReadyAfterSeek()

      expect(accessor.consumedReadyResumeToken).assertEqual('1:mpv')
      expect(firstSessionPlayer.seekCalls.length).assertEqual(1)
      expect(firstSessionPlayer.playCallCount).assertEqual(1)

      const secondSessionEvents: string[] = []
      const secondSessionPlayer = new RecordingFallbackPlayer(secondSessionEvents)
      const secondSessionSubtitleAdapter = new RecordingSubtitleAdapter(secondSessionEvents)
      accessor.player = secondSessionPlayer
      accessor.subtitleAdapter = secondSessionSubtitleAdapter
      // 该用例手工切换“新会话”以验证 ready token 作用域，需同步清理 initPlayer()
      // 会重置的轨道相关状态，避免前一会话残留污染第二次 ready 验证。
      resetTrackStateForSimulatedNewSession(accessor)
      accessor.playbackSessionId = 2
      accessor.currentTime = 0
      accessor.duration = secondSessionPlayer.duration
      accessor.progress = 0
      accessor.isPlaying = false
      accessor.isSeeking = false
      accessor.pendingBackendResumeTimeMs = 28123
      accessor.pendingBackendResumePlay = true

      await accessor.onPlayerReady()
      await accessor.continuePendingReadyAfterSeek()

      expect(accessor.consumedReadyResumeToken).assertEqual('2:mpv')
      expect(secondSessionEvents.length).assertEqual(6)
      expect(secondSessionEvents[0]).assertEqual('subtitle:onSeekSync')
      expect(secondSessionEvents[1]).assertEqual('player:seek:28123')
      expect(secondSessionEvents[2]).assertEqual('subtitle:init')
      expect(secondSessionEvents[3]).assertEqual('player:getTrackInfos')
      expect(secondSessionEvents[4]).assertEqual('player:selectTrack:0')
      expect(secondSessionEvents[5]).assertEqual('player:play')
      expect(secondSessionPlayer.seekCalls.length).assertEqual(1)
      expect(secondSessionPlayer.playCallCount).assertEqual(1)
    })

  })

  // ─────────────────────────────────────────────────────────────────────────
  // codec-aware 音轨候选选择器（#214 修复）
  // ─────────────────────────────────────────────────────────────────────────
  describe('findInitialAudioTrackIndex - codec-aware 音轨选择', () => {
    it('4.0 探测失败回退 preset 时将 AAC MIME 归一化', 0, () => {
      expect(normalizeAudioCodec('audio/mp4a-latm')).assertEqual('aac')
    })

    it('4.1 可播偏好命中：偏好轨 codec 可播放时直接返回 0', 0, () => {
      const ctrl = new TestVideoPlayerController()
      const accessor = accessController(ctrl)
      const aacTrack: AudioTrackItem = {
        trackIndex: 0, displayName: '中文 (AAC)', language: 'chi', codecName: 'aac'
      }
      const eac3Track: AudioTrackItem = {
        trackIndex: 1, displayName: '日语 (E-AC-3)', language: 'jpn', codecName: 'eac3'
      }
      accessor.audioTracks = [aacTrack, eac3Track]
      const result = accessor.findInitialAudioTrackIndex()
      expect(result).assertEqual(0)
    })

    it('4.2 同语言可播放降级：偏好轨 eac3 不可播，同语言 aac 轨优先', 0, () => {
      const ctrl = new TestVideoPlayerController()
      const accessor = accessController(ctrl)
      const eac3Chi: AudioTrackItem = {
        trackIndex: 0, displayName: '中文 (E-AC-3)', language: 'chi', codecName: 'eac3'
      }
      const aacChi: AudioTrackItem = {
        trackIndex: 1, displayName: '中文 (AAC)', language: 'chi', codecName: 'aac'
      }
      const aacEng: AudioTrackItem = {
        trackIndex: 2, displayName: '英语 (AAC)', language: 'eng', codecName: 'aac'
      }
      accessor.audioTracks = [eac3Chi, aacChi, aacEng]
      const result = accessor.findInitialAudioTrackIndex()
      expect(result).assertEqual(1)
    })

    it('4.3 任意可播放降级：偏好轨 eac3 不可播、无同语言候选时选择第一个可播放轨', 0, () => {
      const ctrl = new TestVideoPlayerController()
      const accessor = accessController(ctrl)
      const eac3Chi: AudioTrackItem = {
        trackIndex: 0, displayName: '中文 (E-AC-3)', language: 'chi', codecName: 'eac3'
      }
      const eac3Jpn: AudioTrackItem = {
        trackIndex: 1, displayName: '日语 (E-AC-3)', language: 'jpn', codecName: 'eac3'
      }
      const aacEng: AudioTrackItem = {
        trackIndex: 2, displayName: '英语 (AAC)', language: 'eng', codecName: 'aac'
      }
      accessor.audioTracks = [eac3Chi, eac3Jpn, aacEng]
      const result = accessor.findInitialAudioTrackIndex()
      expect(result).assertEqual(2)
    })

    it('4.4 全部不可播放：所有轨道 codec 不支持时返回 0，沿用现有降级策略', 0, () => {
      const ctrl = new TestVideoPlayerController()
      const accessor = accessController(ctrl)
      const eac3Chi: AudioTrackItem = {
        trackIndex: 0, displayName: '中文 (E-AC-3)', language: 'chi', codecName: 'eac3'
      }
      const ac3Eng: AudioTrackItem = {
        trackIndex: 1, displayName: '英语 (AC-3)', language: 'eng', codecName: 'ac3'
      }
      accessor.audioTracks = [eac3Chi, ac3Eng]
      const result = accessor.findInitialAudioTrackIndex()
      expect(result).assertEqual(0)
    })

    it('4.5 mimeType=audio/ac-3 路径：无 codecName 时通过归一化 mimeType 判定为不可播放并降级', 0, () => {
      // 验证 getTrackInfos() 路径下 mimeType="audio/ac-3"（含短横线）能被正确识别为不可播放
      const ctrl = new TestVideoPlayerController()
      const accessor = accessController(ctrl)
      const ac3Track: AudioTrackItem = {
        trackIndex: 0, displayName: 'AC-3', language: 'chi', mimeType: 'audio/ac-3'
        // codecName 故意不设置，模拟 getTrackInfos() 只有 mimeType 的情况
      }
      const aacTrack: AudioTrackItem = {
        trackIndex: 1, displayName: 'AAC', language: 'chi', codecName: 'aac'
      }
      accessor.audioTracks = [ac3Track, aacTrack]
      const result = accessor.findInitialAudioTrackIndex()
      // audio/ac-3 归一化后为 "ac3"，命中黑名单，应降级到 index=1 的 AAC 轨
      expect(result).assertEqual(1)
    })

    it('4.6 AVPlayer AAC MIME：同语言 E-AC-3 与 audio/mp4a-latm 并存时选择 AAC', 0, () => {
      const ctrl = new TestVideoPlayerController()
      const accessor = accessController(ctrl)
      const eac3Track: AudioTrackItem = {
        trackIndex: 1, displayName: '中文 (E-AC-3)', language: 'chi', mimeType: 'audio/eac3'
      }
      const aacTrack: AudioTrackItem = {
        trackIndex: 2, displayName: '中文 (AAC)', language: 'chi', mimeType: 'audio/mp4a-latm'
      }
      accessor.audioTracks = [eac3Track, aacTrack]
      const result = accessor.findInitialAudioTrackIndex()
      expect(result).assertEqual(1)
    })

  })
}
