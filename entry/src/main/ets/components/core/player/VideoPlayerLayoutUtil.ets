import { AspectRatioMode } from './VideoPlayerController'

export class IjkPlayerLayoutConfig {
  width: Length = '100%'
  height?: Length
  aspectRatio?: number
  renderFit?: RenderFit
  clipViewport: boolean = false
  xComponentBackgroundColor: ResourceColor = Color.Black
  outerStackBackgroundColor: ResourceColor = Color.Black
}

export function resolveRenderFitForAspectRatioMode(mode: AspectRatioMode): RenderFit {
  if (mode === AspectRatioMode.FILL) {
    return RenderFit.RESIZE_COVER
  }
  if (mode === AspectRatioMode.STRETCH) {
    return RenderFit.RESIZE_FILL
  }
  return RenderFit.RESIZE_CONTAIN
}

function applyFillCoverLayout(
  config: IjkPlayerLayoutConfig,
  videoRatio: number,
  viewportWidth: number,
  viewportHeight: number
): void {
  if (videoRatio <= 0 || viewportWidth <= 0 || viewportHeight <= 0) {
    config.height = '100%'
    config.renderFit = RenderFit.RESIZE_CONTAIN
    return
  }

  config.clipViewport = true
  const viewportRatio = viewportWidth / viewportHeight
  if (videoRatio >= viewportRatio) {
    config.width = viewportHeight * videoRatio
    config.height = viewportHeight
    return
  }
  config.width = viewportWidth
  config.height = viewportWidth / videoRatio
}

export function resolveIjkPlayerLayoutConfig(
  mode: AspectRatioMode,
  videoRatio: number,
  viewportWidth: number = 0,
  viewportHeight: number = 0
) {
  const config: IjkPlayerLayoutConfig = new IjkPlayerLayoutConfig()
  if (mode === AspectRatioMode.FIT && videoRatio > 0) {
    config.aspectRatio = videoRatio
    return config
  }

  if (mode === AspectRatioMode.FILL) {
    applyFillCoverLayout(config, videoRatio, viewportWidth, viewportHeight)
    return config
  }

  config.height = '100%'
  config.renderFit = resolveRenderFitForAspectRatioMode(mode)
  return config
}
