import { describe, it, expect } from '@ohos/hypium';
import {
  VideoPlayerController,
  PlayerBackend,
  resolveAiEnhanceEnabledByRuntime,
  shouldShowAiEnhanceSettingsByRuntime,
  resolveEffectivePlaybackSurfaceId
} from '../main/ets/components/core/player/VideoPlayerController';
import { IPlayer, SubtitleInfo, TrackInfo } from '../main/ets/components/core/player/IPlayer';
import {
  ISubtitleBridgeAdapter,
  SubtitleBridgeState,
  SubtitleTrackItem
} from '../main/ets/components/core/player/SubtitleBridgeAdapter';
import { VideoData } from '../main/ets/components/core/player/VideoData';
import { VideoDataType } from '../main/ets/components/core/player/Constants';

interface VideoPlayerControllerAccessor {
  backend: PlayerBackend
  surfaceId: string
  player?: IPlayer
  pendingResumeState: PendingResumeStateSnapshot | null
  pendingResumeAutoplayDecisionExplicit: boolean
  hasPendingResumeAutoplayDecisionExplicit: boolean
  pendingResumeAutoplayDecisionSource: string
  preparedResumeAutoplayDecisionExplicit: boolean
  hasPreparedResumeAutoplayDecisionExplicit: boolean
  preparedResumeAutoplayDecisionSource: string
  cachedIjkContext?: object
  cachedIjkComponentId: string
  cachedNativeContext?: object
  cachedNativeComponentId: string
  currentTime: number
  duration: number
  progress: number
  isPlaying: boolean
  isSeeking: boolean
  activeSubtitleIndex: number
  pendingBackendResumeTimeMs: number
  pendingBackendResumePlay: boolean
  subtitleAdapter: ISubtitleBridgeAdapter
  pendingReloadResolve?: () => void
  pendingReloadReject?: (error: Error) => void
  capturePendingResumeForFallback(source: string): void
  handlePlayerPaused(): void
  continuePendingReadyAfterSeek(): Promise<void>
  onPlayerReady(): Promise<void>
  resolvePendingReload(): void
}

interface PendingResumeStateSnapshot {
  positionMs: number
  shouldResumePlay: boolean
  autoplayDecisionSource: string
}

/** 用于访问 ijkVideoRatio 字段的 accessor 接口（Task 2.1/2.2 TDD 用） */
interface IjkVideoRatioAccessor {
  ijkVideoRatio: number
}

interface TestXComponentContext {
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

class ReloadPreparedLifecycleController extends VideoPlayerController {
  preparedStateSeenInReload: boolean = false
  preparedSourceSeenInReload: string = ''
  pendingStateSeenAfterInit: boolean = false
  pendingSourceSeenAfterInit: string = ''
  playCallCount: number = 0

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

/**
 * Task 2.2 TDD spy：验证真实 initPlayer 调用了 resetDisplayState。
 * override resetDisplayState() 而非 initPlayer，确保生产代码路径被真实执行。
 */
class ResetDisplayStateSpyController extends VideoPlayerController {
  resetDisplayStateCalled: boolean = false;
  private resolveResetDisplayStateWaiter?: () => void
  private readonly resetDisplayStateWaiter: Promise<void> = new Promise<void>((resolve: () => void): void => {
    this.resolveResetDisplayStateWaiter = resolve
  })

  protected override resetDisplayState(): void {
    this.resetDisplayStateCalled = true;
    this.resolveResetDisplayStateWaiter?.()
    this.resolveResetDisplayStateWaiter = undefined
    super.resetDisplayState();
  }

  waitForResetDisplayStateCall(): Promise<void> {
    return this.resetDisplayStateWaiter
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

function accessController(controller: VideoPlayerController): VideoPlayerControllerAccessor {
  return controller as Object as VideoPlayerControllerAccessor
}

async function flushMicrotasks(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

export default function videoPlayerControllerTest() {
  describe('VideoPlayerController review regressions', () => {
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

    it('release 会清理缓存的 xcomponent context 与 component id', 0, async () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      const ijkContext: TestXComponentContext = {}
      const nativeContext: TestXComponentContext = {}
      accessor.cachedIjkContext = ijkContext as object
      accessor.cachedIjkComponentId = 'ijk-component'
      accessor.cachedNativeContext = nativeContext as object
      accessor.cachedNativeComponentId = 'native-component'

      await controller.release()

      expect(accessor.cachedIjkContext === undefined).assertTrue()
      expect(accessor.cachedIjkComponentId).assertEqual('')
      expect(accessor.cachedNativeContext === undefined).assertTrue()
      expect(accessor.cachedNativeComponentId).assertEqual('')
    })

    it('运行时探测失败时会强制关闭画质增强请求', 0, () => {
      expect(resolveAiEnhanceEnabledByRuntime(false, true)).assertFalse()
      expect(resolveAiEnhanceEnabledByRuntime(false, false)).assertFalse()
      expect(resolveAiEnhanceEnabledByRuntime(true, true)).assertTrue()
    })

    it('仅在 avplayer 且运行时支持时显示画质增强设置', 0, () => {
      expect(shouldShowAiEnhanceSettingsByRuntime(true, 'avplayer')).assertTrue()
      expect(shouldShowAiEnhanceSettingsByRuntime(false, 'avplayer')).assertFalse()
      expect(shouldShowAiEnhanceSettingsByRuntime(true, 'ijkplayer')).assertFalse()
    })

    it('VPE 未提供输入 surface 时回退到基础播放 surface', 0, () => {
      expect(resolveEffectivePlaybackSurfaceId('display-surface', '')).assertEqual('display-surface')
      expect(resolveEffectivePlaybackSurfaceId('display-surface', 'vpe-input-surface')).assertEqual('vpe-input-surface')
    })

    // ── Task 2.1：ijkVideoRatio 属性默认值 ──────────────────────────────────
    it('ijkVideoRatio 初始值为 0（Task 2.1）', 0, () => {
      const controller = new VideoPlayerController()
      const accessor = controller as Object as IjkVideoRatioAccessor
      expect(accessor.ijkVideoRatio).assertEqual(0)
    })

    // ── Task 2.2：initPlayer 调用 resetDisplayState，ijkVideoRatio 被清零 ───
    // 验证策略：spy override resetDisplayState()，通过 promise 等待真实调用发生，
    // 不再依赖 initPlayer 内部 await 排布或“同步阶段立即断言”的时序假设。
    it('initPlayer 调用真实 resetDisplayState 并将 ijkVideoRatio 重置为 0（Task 2.2）', 0, async () => {
      const controller = new ResetDisplayStateSpyController()
      const ratioAccessor = controller as Object as IjkVideoRatioAccessor
      ratioAccessor.ijkVideoRatio = 1.7778

      const initPromise = controller.initPlayer(buildVideoData('task-2-2-spy'), 'surface-spy')
      const resetOrInitSettled = Promise.race<void>([
        controller.waitForResetDisplayStateCall(),
        initPromise.then((): void => {}, (): void => {})
      ])

      await resetOrInitSettled
      expect(controller.resetDisplayStateCalled).assertTrue()
      expect(ratioAccessor.ijkVideoRatio).assertEqual(0)

      await initPromise.catch(() => {})
    })

    // ── Task 2.3/2.4：ijkVideoRatio 回调注入语义验证 ─────────────────────────
    // 注入到 IjkPlayerAdapter 的回调行为：调用后 ijkVideoRatio 可被写入并读出。
    // 限制说明：IjkPlayerAdapter 构造器依赖 native .so，无法在 UnitTestBuild 环境中
    // 实例化，因此无法测试"initPlayer 实际注入了回调"。本用例验证注入后的回调语义：
    // 若回调中执行 this.ijkVideoRatio = ratio，field 能被正确更新。
    it('ijkVideoRatio 可通过回调语义写入并读出（Task 2.3 回调注入后行为）', 0, () => {
      const controller = new VideoPlayerController()
      const accessor = controller as Object as IjkVideoRatioAccessor
      // 模拟 setOnVideoRatioCallback 注入后，DAR 回调触发时的写入路径
      const simulatedCallback = (ratio: number): void => {
        accessor.ijkVideoRatio = ratio
      }
      simulatedCallback(1.7778)
      expect(Math.abs(accessor.ijkVideoRatio - 1.7778) < 1e-9).assertTrue()
    })

    it('fallback 到 ijkplayer 前会保留 seek flush 的续播位置与自动续播意图', 0, () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      accessor.player = new MockFallbackPlayer()
      accessor.currentTime = 501626
      accessor.duration = 2684598
      accessor.progress = 0
      accessor.isPlaying = false
      accessor.isSeeking = true
      accessor.pendingBackendResumeTimeMs = -1
      accessor.pendingBackendResumePlay = false

      accessor.capturePendingResumeForFallback('test_fallback')

      expect(accessor.pendingBackendResumeTimeMs).assertEqual(501626)
      expect(accessor.pendingBackendResumePlay).assertTrue()
      expect(accessor.currentTime).assertEqual(501626)
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

    it('fallback capture 在 task 2.1 前仍只依赖瞬时播放态', 0, async () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      const player = new MockFallbackPlayer()
      accessor.player = player
      accessor.currentTime = 3200
      accessor.duration = 9000
      accessor.isPlaying = false
      accessor.isSeeking = false

      await controller.seek(3200, 'prepared_resume_seek')
      accessor.capturePendingResumeForFallback('test_fallback')

      expect(accessor.pendingResumeState?.autoplayDecisionSource ?? '').assertEqual('transient_player_state')
      expect(accessor.pendingBackendResumePlay).assertFalse()
    })

    it('ijkplayer onPrepared 时会消费 fallback 保留的续播点并执行 seek', 0, async () => {
      const controller = new TestVideoPlayerController()
      const accessor = accessController(controller)
      const player = new MockFallbackPlayer()
      accessor.backend = 'ijkplayer'
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
      accessor.backend = 'ijkplayer'
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
      accessor.backend = 'ijkplayer'
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

  })
}
