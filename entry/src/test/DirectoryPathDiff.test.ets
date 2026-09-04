import { describe, it, expect } from '@ohos/hypium'
import { computeDirectoryPathDiff, normalizeScrapeDirectoryPath } from '../main/ets/services/scrape/ScopedScrapeTypes'

export default function directoryPathDiffTest() {
  describe('computeDirectoryPathDiff', () => {
    it('纯新增：before 为空 after 有路径时返回全部 after 路径', 0, () => {
      const result: string[] = computeDirectoryPathDiff([], ['/a', '/b'])
      expect(result.length).assertEqual(2)
      expect(result.includes('/a')).assertTrue()
      expect(result.includes('/b')).assertTrue()
    })

    it('部分新增：before 有 /a after 有 /a 和 /b 时仅返回 /b', 0, () => {
      const result: string[] = computeDirectoryPathDiff(['/a'], ['/a', '/b'])
      expect(result.length).assertEqual(1)
      expect(result[0]).assertEqual('/b')
    })

    it('无变化：before 和 after 相同时返回空数组', 0, () => {
      const result: string[] = computeDirectoryPathDiff(['/a'], ['/a'])
      expect(result.length).assertEqual(0)
    })

    it('尾斜杠规范化：before 含 /media/ after 含 /media 时视为相同不返回', 0, () => {
      const result: string[] = computeDirectoryPathDiff(['/media/'], ['/media'])
      expect(result.length).assertEqual(0)
    })

    it('别名变化不影响结果：仅路径参与差集计算', 0, () => {
      // 对应 6.5：用户仅修改 customName（别名）时，目录路径集合不变，addedPaths 为空，不触发自动刮削
      const result: string[] = computeDirectoryPathDiff(['/movie'], ['/movie'])
      expect(result.length).assertEqual(0)
    })
  })

  describe('normalizeScrapeDirectoryPath', () => {
    it('去除尾斜杠', 0, () => {
      expect(normalizeScrapeDirectoryPath('/media/')).assertEqual('/media')
    })

    it('根目录返回 /', 0, () => {
      expect(normalizeScrapeDirectoryPath('/')).assertEqual('/')
    })

    it('空路径返回 /', 0, () => {
      expect(normalizeScrapeDirectoryPath('')).assertEqual('/')
    })

    it('补全前导斜杠', 0, () => {
      expect(normalizeScrapeDirectoryPath('media/movies')).assertEqual('/media/movies')
    })
  })
}
