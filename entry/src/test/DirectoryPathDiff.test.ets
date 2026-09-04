import { describe, it, expect } from '@ohos/hypium'
import { computeDirectoryPathDiff, computeRemovedDirectoryPaths, normalizeScrapeDirectoryPath } from '../main/ets/services/scrape/ScopedScrapeTypes'

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

  describe('computeRemovedDirectoryPaths', () => {
    it('纯移除：after 为空时返回全部 before 原始路径', 0, () => {
      const result: string[] = computeRemovedDirectoryPaths(['/a', '/b'], [])
      expect(result.length).assertEqual(2)
      expect(result.includes('/a')).assertTrue()
      expect(result.includes('/b')).assertTrue()
    })

    it('部分移除：返回被移除目录的原始路径（非规范化值）', 0, () => {
      const result: string[] = computeRemovedDirectoryPaths(['/a', '/b'], ['/a'])
      expect(result.length).assertEqual(1)
      expect(result[0]).assertEqual('/b')
    })

    it('无移除：before 与 after 一致时返回空数组', 0, () => {
      const result: string[] = computeRemovedDirectoryPaths(['/a'], ['/a'])
      expect(result.length).assertEqual(0)
    })

    it('尾斜杠规范化：before 含 /media/ after 含 /media 时视为相同不被判定为移除', 0, () => {
      // 对应用户把 `/media/` 改成 `/media`：同一目录的不同写法不应触发媒体清理
      const result: string[] = computeRemovedDirectoryPaths(['/media/'], ['/media'])
      expect(result.length).assertEqual(0)
    })

    it('移除返回原始存储值：/media/ 保持原样以便按 directory_path 精确匹配删除', 0, () => {
      const result: string[] = computeRemovedDirectoryPaths(['/media/'], ['/other'])
      expect(result.length).assertEqual(1)
      expect(result[0]).assertEqual('/media/')
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
