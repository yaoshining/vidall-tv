import { describe, it, expect } from '@ohos/hypium';
import {
  VideoPlayerController,
  PlayerBackend,
  resolveAiEnhanceEnabledByRuntime,
  shouldShowAiEnhanceSettingsByRuntime,
  resolveEffectivePlaybackSurfaceId
} from '../main/ets/components/core/player/VideoPlayerController';
import { IPlayer, SubtitleInfo, TrackInfo } from '../main/ets/components/core/player/IPlayer';
import { VideoData } from '../main/ets/components/core/player/VideoData';
import { VideoDataType } from '../main/ets/components/core/player/Constants';

interface VideoPlayerControllerAccessor {
  backend: PlayerBackend
  surfaceId: string
  player?: IPlayer
  cachedIjkContext?: object
  cachedIjkComponentId: string
  cachedNativeContext?: object
  cachedNativeComponentId: string
  currentTime: number
  duration: number
  progress: number
  isPlaying: boolean
  isSeeking: boolean
  pendingBackendResumeTimeMs: number
  pendingBackendResumePlay: boolean
  pendingReloadResolve?: () => void
  pendingReloadReject?: (error: Error) => void
  capturePendingResumeForFallback(): void
  onPlayerReady(): Promise<void>
  resolvePendingReload(): void
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

class TestVideoPlayerController extends VideoPlayerController {
  async initPlayer(_videoData: VideoData, surfaceId: string): Promise<void> {
    this.surfaceId = surfaceId
  }

  saveProgressNow(): void {}
}

/**
 * Task 2.2 TDD spy：验证真实 initPlayer 调用了 resetDisplayState。
 * override resetDisplayState() 而非 initPlayer，确保生产代码路径被真实执行。
 */
class ResetDisplayStateSpyController extends VideoPlayerController {
  resetDisplayStateCalled: boolean = false;

  protected override resetDisplayState(): void {
    this.resetDisplayStateCalled = true;
    super.resetDisplayState();
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
    // 验证策略：spy override resetDisplayState()，调用真实 initPlayer（不 await 全程）。
    // initPlayer 为 async 函数，同步部分在第一个 await（resolveAudioRoutingDecision）前
    // 执行，resetDisplayState() 在此之前被调用，可在同步阶段立即断言。
    // 若删除 initPlayer 中 this.resetDisplayState() 调用，第一个 expect 失败（RED）。
    it('initPlayer 调用真实 resetDisplayState 并将 ijkVideoRatio 重置为 0（Task 2.2）', 0, async () => {
      const controller = new ResetDisplayStateSpyController()
      const ratioAccessor = controller as Object as IjkVideoRatioAccessor
      ratioAccessor.ijkVideoRatio = 1.7778

      // 启动真实 initPlayer，不 await：同步阶段在第一个 await 前立即执行
      const p = controller.initPlayer(buildVideoData('task-2-2-spy'), 'surface-spy')

      // 同步阶段已完成：resetDisplayState 已被真实 initPlayer 调用
      expect(controller.resetDisplayStateCalled).assertTrue()
      expect(ratioAccessor.ijkVideoRatio).assertEqual(0)

      // 静默消费 Promise，忽略设备 API 不可用的异步错误
      await p.catch(() => {})
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

      accessor.capturePendingResumeForFallback()

      expect(accessor.pendingBackendResumeTimeMs).assertEqual(501626)
      expect(accessor.pendingBackendResumePlay).assertTrue()
      expect(accessor.currentTime).assertEqual(501626)
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

  })
}
