import { describe, it, expect } from '@ohos/hypium'
import { AspectRatioMode } from '../main/ets/components/core/player/VideoPlayerController'
import { IjkXComponentLayoutModifier } from '../main/ets/components/core/player/VideoPlayer'

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

function applyModifier(mode: AspectRatioMode, ratio: number): XComponentAttributeSpy {
  const modifier = new IjkXComponentLayoutModifier(mode, ratio)
  const spy = new XComponentAttributeSpy()
  modifier.applyNormalAttribute?.(spy as Object as XComponentAttribute)
  return spy
}

export default function videoPlayerLayoutTest() {
  describe('VideoPlayer 3.4 layout contract', () => {
    it('FIT 且 ratio > 0 时在内层 XComponent 上使用 width + aspectRatio，且不设置 height / renderFit', 0, () => {
      const spy = applyModifier(AspectRatioMode.FIT, 1.7778)

      expect(spy.hasCall('width:100%')).assertTrue()
      expect(spy.hasCall('aspectRatio:1.7778')).assertTrue()
      expect(spy.hasCall('height:')).assertFalse()
      expect(spy.hasCall('renderFit:')).assertFalse()
      expect(spy.hasCall('backgroundColor')).assertTrue()
    })

    it('FIT 且 ratio 未知时显式回退为 width + height + renderFit', 0, () => {
      const spy = applyModifier(AspectRatioMode.FIT, 0)

      expect(spy.hasCall('width:100%')).assertTrue()
      expect(spy.hasCall('height:100%')).assertTrue()
      expect(spy.hasCall(`renderFit:${RenderFit.RESIZE_CONTAIN}`)).assertTrue()
      expect(spy.hasCall('aspectRatio:')).assertFalse()
    })

    it('FILL / STRETCH 时保持原有 renderFit 分支，不使用 aspectRatio', 0, () => {
      const fillSpy = applyModifier(AspectRatioMode.FILL, 1.7778)
      const stretchSpy = applyModifier(AspectRatioMode.STRETCH, 1.7778)

      expect(fillSpy.hasCall('height:100%')).assertTrue()
      expect(fillSpy.hasCall(`renderFit:${RenderFit.RESIZE_COVER}`)).assertTrue()
      expect(fillSpy.hasCall('aspectRatio:')).assertFalse()

      expect(stretchSpy.hasCall('height:100%')).assertTrue()
      expect(stretchSpy.hasCall(`renderFit:${RenderFit.RESIZE_FILL}`)).assertTrue()
      expect(stretchSpy.hasCall('aspectRatio:')).assertFalse()
    })
  })
}
