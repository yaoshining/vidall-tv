import { describe, it, expect } from '@ohos/hypium'
import { AspectRatioMode } from '../main/ets/components/core/player/VideoPlayerController'
import { resolveIjkPlayerLayoutConfig } from '../main/ets/components/core/player/VideoPlayerLayoutUtil'

class XComponentAttributeSpy {
  calls: string[] = []

  width(value: string): XComponentAttributeSpy {
    this.calls.push(`width:${value}`)
    return this
  }

  height(value: string): XComponentAttributeSpy {
    this.calls.push(`height:${value}`)
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

function applyLayout(mode: AspectRatioMode, ratio: number): XComponentAttributeSpy {
  const config = resolveIjkPlayerLayoutConfig(mode, ratio)
  const spy = new XComponentAttributeSpy()
  spy.width(config.width)
  if (config.height !== undefined) {
    spy.height(config.height)
  }
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
    it('FIT 且 ratio > 0 时在内层 XComponent 上使用 width + aspectRatio，且不设置 height / renderFit', 0, () => {
      const spy = applyLayout(AspectRatioMode.FIT, 1.7778)

      expect(spy.hasCall('width:100%')).assertTrue()
      expect(spy.hasCall('aspectRatio:1.7778')).assertTrue()
      expect(spy.hasCall('height:')).assertFalse()
      expect(spy.hasCall('renderFit:')).assertFalse()
      expect(spy.hasCall('backgroundColor')).assertTrue()
    })

    it('FIT 且 ratio 未知时显式回退为 width + height + renderFit', 0, () => {
      const spy = applyLayout(AspectRatioMode.FIT, 0)

      expect(spy.hasCall('width:100%')).assertTrue()
      expect(spy.hasCall('height:100%')).assertTrue()
      expect(spy.hasCall(`renderFit:${RenderFit.RESIZE_CONTAIN}`)).assertTrue()
      expect(spy.hasCall('aspectRatio:')).assertFalse()
    })

    it('FILL / STRETCH 时保持原有 renderFit 分支，不使用 aspectRatio', 0, () => {
      const fillSpy = applyLayout(AspectRatioMode.FILL, 1.7778)
      const stretchSpy = applyLayout(AspectRatioMode.STRETCH, 1.7778)

      expect(fillSpy.hasCall('height:100%')).assertTrue()
      expect(fillSpy.hasCall(`renderFit:${RenderFit.RESIZE_COVER}`)).assertTrue()
      expect(fillSpy.hasCall('aspectRatio:')).assertFalse()

      expect(stretchSpy.hasCall('height:100%')).assertTrue()
      expect(stretchSpy.hasCall(`renderFit:${RenderFit.RESIZE_FILL}`)).assertTrue()
      expect(stretchSpy.hasCall('aspectRatio:')).assertFalse()
    })

    it('ijkplayer 外层 Stack 显式使用 Color.Black', 0, () => {
      const config = resolveIjkPlayerLayoutConfig(AspectRatioMode.FIT, 1.7778)

      expect(config.outerStackBackgroundColor).assertEqual(Color.Black)
    })
  })
}
