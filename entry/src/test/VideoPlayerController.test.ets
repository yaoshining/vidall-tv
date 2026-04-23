import { describe, it, expect } from '@ohos/hypium';
import { VideoPlayerController, PlayerBackend } from '../main/ets/components/core/player/VideoPlayerController';
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

interface TestXComponentContext {
}

class TestVideoPlayerController extends VideoPlayerController {
  async initPlayer(_videoData: VideoData, surfaceId: string): Promise<void> {
    this.surfaceId = surfaceId
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
  })
}
