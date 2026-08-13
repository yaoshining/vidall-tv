import { describe, it, expect } from '@ohos/hypium'
import { AspectRatioMode } from '../main/ets/components/core/player/VideoPlayerController'
import { resolveRenderFitForAspectRatioMode } from '../main/ets/components/core/player/VideoPlayerLayoutUtil'

export default function videoPlayerLayoutTest() {
  describe('VideoPlayer layout contract', () => {
    it('maps each aspect ratio mode to its generic RenderFit', 0, () => {
      expect(resolveRenderFitForAspectRatioMode(AspectRatioMode.FIT)).assertEqual(RenderFit.RESIZE_CONTAIN)
      expect(resolveRenderFitForAspectRatioMode(AspectRatioMode.FILL)).assertEqual(RenderFit.RESIZE_COVER)
      expect(resolveRenderFitForAspectRatioMode(AspectRatioMode.STRETCH)).assertEqual(RenderFit.RESIZE_FILL)
    })
  })
}
