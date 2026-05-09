import { describe, it, expect } from '@ohos/hypium'
import { AspectRatioMode } from '../main/ets/components/core/player/VideoPlayerController'
import { resolveIjkPlayerLayoutConfig, resolveRenderFitForAspectRatioMode } from '../main/ets/components/core/player/VideoPlayerLayoutUtil'

class XComponentAttributeSpy {
  calls: string[] = []

  width(value: Length | undefined): XComponentAttributeSpy {
    if (value !== undefined) {
      this.calls.push(`width:${value}`)
    }
    return this
  }

  height(value: Length | undefined): XComponentAttributeSpy {
    if (value !== undefined) {
      this.calls.push(`height:${value}`)
    }
    return this
  }

  aspectRatio(value: number): XComponentAttributeSpy {
    this.calls.push(`aspectRatio:${value}`)
    return this
  }

  renderFit(value: RenderFit): XComponentAttributeSpy {
    this.calls.push(`renderFit:${value}`)
    return this
  }

  backgroundColor(_value: ResourceColor): XComponentAttributeSpy {
    this.calls.push('backgroundColor')
    return this
  }

  hasCall(prefix: string): boolean {
    for (let i = 0; i < this.calls.length; i++) {
      if (this.calls[i].startsWith(prefix)) {
        return true
      }
    }
    return false
  }
}

function applyLayout(mode: AspectRatioMode, videoRatio: number, viewportWidth: number, viewportHeight: number): XComponentAttributeSpy {
  const config = resolveIjkPlayerLayoutConfig(mode, videoRatio, viewportWidth, viewportHeight)
  const spy = new XComponentAttributeSpy()
  spy.width(config.width)
  spy.height(config.height)
  if (config.aspectRatio !== undefined) {
    spy.aspectRatio(config.aspectRatio)
  }
  if (config.renderFit !== undefined) {
    spy.renderFit(config.renderFit)
  }
  spy.backgroundColor(config.xComponentBackgroundColor)
  return spy
}

export default function videoPlayerLayoutTest() {
  describe('VideoPlayer 3.4 layout contract', () => {
    it('AspectRatioMode 到 RenderFit 的映射由单一导出函数提供', 0, () => {
      expect(resolveRenderFitForAspectRatioMode(AspectRatioMode.FIT)).assertEqual(RenderFit.RESIZE_CONTAIN)
      expect(resolveRenderFitForAspectRatioMode(AspectRatioMode.FILL)).assertEqual(RenderFit.RESIZE_COVER)
      expect(resolveRenderFitForAspectRatioMode(AspectRatioMode.STRETCH)).assertEqual(RenderFit.RESIZE_FILL)
    })

    it('FIT 且 ratio > 0 时在内层 XComponent 上使用 width + aspectRatio，且不设置 height / renderFit', 0, () => {
      const spy = applyLayout(AspectRatioMode.FIT, 1.7778, 1920, 1080)
      const config = resolveIjkPlayerLayoutConfig(AspectRatioMode.FIT, 1.7778, 1920, 1080)

      expect(spy.hasCall('width:100%')).assertTrue()
      expect(spy.hasCall('aspectRatio:1.7778')).assertTrue()
      expect(spy.hasCall('height:')).assertFalse()
      expect(spy.hasCall('renderFit:')).assertFalse()
      expect(config.clipViewport).assertFalse()
      expect(spy.hasCall('backgroundColor')).assertTrue()
    })

    it('FIT 且 ratio 未知时显式回退为 width + height + renderFit', 0, () => {
      const spy = applyLayout(AspectRatioMode.FIT, 0, 1920, 1080)
      const config = resolveIjkPlayerLayoutConfig(AspectRatioMode.FIT, 0, 1920, 1080)

      expect(spy.hasCall('width:100%')).assertTrue()
      expect(spy.hasCall('height:100%')).assertTrue()
      expect(spy.hasCall(`renderFit:${RenderFit.RESIZE_CONTAIN}`)).assertTrue()
      expect(spy.hasCall('aspectRatio:')).assertFalse()
      expect(config.clipViewport).assertFalse()
    })

    it('FILL 在窄视频场景走显式 cover 尺寸 + clip 路径，不再依赖 renderFit', 0, () => {
      const expectedHeight = 1920 / 1.3333
      const fillSpy = applyLayout(AspectRatioMode.FILL, 1.3333, 1920, 1080)
      const config = resolveIjkPlayerLayoutConfig(AspectRatioMode.FILL, 1.3333, 1920, 1080)

      expect(fillSpy.hasCall('width:1920')).assertTrue()
      expect(fillSpy.hasCall(`height:${expectedHeight}`)).assertTrue()
      expect(fillSpy.hasCall('aspectRatio:')).assertFalse()
      expect(fillSpy.hasCall('renderFit:')).assertFalse()
      expect(config.clipViewport).assertTrue()
    })

    it('FILL 在宽视频场景走显式 cover 尺寸 + clip 路径，不再依赖 renderFit', 0, () => {
      const fillSpy = applyLayout(AspectRatioMode.FILL, 2.39, 1920, 1080)
      const config = resolveIjkPlayerLayoutConfig(AspectRatioMode.FILL, 2.39, 1920, 1080)

      expect(fillSpy.hasCall('width:2581.2')).assertTrue()
      expect(fillSpy.hasCall('height:1080')).assertTrue()
      expect(fillSpy.hasCall('aspectRatio:')).assertFalse()
      expect(fillSpy.hasCall('renderFit:')).assertFalse()
      expect(config.clipViewport).assertTrue()
    })

    it('STRETCH 保持明确的 width + height + renderFit 拉伸路径，且不启用 clip', 0, () => {
      const stretchSpy = applyLayout(AspectRatioMode.STRETCH, 1.7778, 1920, 1080)
      const config = resolveIjkPlayerLayoutConfig(AspectRatioMode.STRETCH, 1.7778, 1920, 1080)

      expect(stretchSpy.hasCall('height:100%')).assertTrue()
      expect(stretchSpy.hasCall('width:100%')).assertTrue()
      expect(stretchSpy.hasCall(`renderFit:${RenderFit.RESIZE_FILL}`)).assertTrue()
      expect(stretchSpy.hasCall('aspectRatio:')).assertFalse()
      expect(config.clipViewport).assertFalse()
    })

    it('ijkplayer 外层 Stack 显式使用 Color.Black', 0, () => {
      const config = resolveIjkPlayerLayoutConfig(AspectRatioMode.FIT, 1.7778, 1920, 1080)

      expect(config.outerStackBackgroundColor).assertEqual(Color.Black)
    })
  })
}
