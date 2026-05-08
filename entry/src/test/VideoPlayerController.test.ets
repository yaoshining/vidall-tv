import { describe, it, expect } from '@ohos/hypium';
import {
  VideoPlayerController,
  PlayerBackend,
  resolveAiEnhanceEnabledByRuntime,
  shouldShowAiEnhanceSettingsByRuntime,
  resolveEffectivePlaybackSurfaceId
} from '../main/ets/components/core/player/VideoPlayerController';
import { VideoData } from '../main/ets/components/core/player/VideoData';
import { VideoDataType } from '../main/ets/components/core/player/Constants';

interface VideoPlayerControllerAccessor {
  backend: PlayerBackend
  surfaceId: string
  cachedIjkContext?: object
  cachedIjkComponentId: string
  cachedNativeContext?: object
  cachedNativeComponentId: string
  pendingReloadResolve?: () => void
  pendingReloadReject?: (error: Error) => void
  resolvePendingReload(): void
}

/** 用于访问 ijkVideoRatio 字段的 accessor 接口（Task 2.1/2.2 TDD 用） */
interface IjkVideoRatioAccessor {
  ijkVideoRatio: number
}

interface TestXComponentContext {
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
  })
}
