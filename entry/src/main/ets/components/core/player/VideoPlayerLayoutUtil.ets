import { AspectRatioMode } from './VideoPlayerController'

class IjkPlayerLayoutConfig {
  width: string = '100%'
  height?: string
  aspectRatio?: number
  renderFit?: RenderFit
  xComponentBackgroundColor: ResourceColor = Color.Black
  outerStackBackgroundColor: ResourceColor = Color.Black
}

function resolveRenderFitForAspectRatioMode(mode: AspectRatioMode): RenderFit {
  if (mode === AspectRatioMode.FILL) {
    return RenderFit.RESIZE_COVER
  }
  if (mode === AspectRatioMode.STRETCH) {
    return RenderFit.RESIZE_FILL
  }
  return RenderFit.RESIZE_CONTAIN
}

export function resolveIjkPlayerLayoutConfig(mode: AspectRatioMode, ratio: number) {
  const config: IjkPlayerLayoutConfig = new IjkPlayerLayoutConfig()
  if (mode === AspectRatioMode.FIT && ratio > 0) {
    config.aspectRatio = ratio
    return config
  }

  config.height = '100%'
  config.renderFit = resolveRenderFitForAspectRatioMode(mode)
  return config
}
