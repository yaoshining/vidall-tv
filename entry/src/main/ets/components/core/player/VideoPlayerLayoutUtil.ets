import { AspectRatioMode } from './VideoPlayerController'

export function resolveRenderFitForAspectRatioMode(mode: AspectRatioMode): RenderFit {
  if (mode === AspectRatioMode.FILL) {
    return RenderFit.RESIZE_COVER
  }
  if (mode === AspectRatioMode.STRETCH) {
    return RenderFit.RESIZE_FILL
  }
  return RenderFit.RESIZE_CONTAIN
}
