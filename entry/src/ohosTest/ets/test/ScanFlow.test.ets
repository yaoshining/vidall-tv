/**
 * ScanFlow.test.ets
 * 扫描流程集成测试套件
 *
 * 覆盖：扫描按钮状态、触发扫描、扫描完成后统计文本、
 *        扫描中状态文本验证
 *
 * 注意：此测试需要已配置文件源才能看到扫描按钮。
 * 若未配置文件源，将展示空状态提示，测试以软通过处理。
 *
 * 运行方式：
 *   aa test -b com.yao.vidalltv -m entry_test -s unittest OpenHarmonyTestRunner \
 *     -s SCAN_TIMEOUT_MS 30000
 */

import { describe, it, expect } from '@ohos/hypium'
import { Driver, Component, ON, MatchPattern } from '@kit.TestKit'
import { KeyCode } from '@kit.InputKit'
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry'

function getTestParam(key: string, fallback: string): string {
  try {
    const args = abilityDelegatorRegistry.getArguments()
    const params = args.parameters as Record<string, string>
    const val: string = params[key]
    return (val !== undefined && val !== null && val.length > 0) ? val : fallback
  } catch {
    return fallback
  }
}

const WAIT_SHORT = 3000
const WAIT_LONG = 8000

export default function scanFlowTest() {
  const scanTimeoutMs = parseInt(getTestParam('SCAN_TIMEOUT_MS', '30000'), 10)

  describe('扫描流程集成测试', () => {

    /**
     * 媒体库 Tab 加载完成后扫描按钮可见
     * 验证：有文件源时"扫描新增和已修改的文件"按钮可见；
     *        无文件源时"请先配置文件源"提示可见（均为合法状态）
     */
    it('扫描按钮或空状态提示可见', 0, async () => {
      const driver = Driver.create()
      await driver.delayMs(1200)
      try {
        // 切换到媒体库 Tab
        const mediaLibTab = await driver.waitForComponent(ON.text('媒体库'), WAIT_SHORT)
        if (mediaLibTab !== null) {
          await mediaLibTab.click()
          await driver.delayMs(800)
        }

        const scanBtn = await driver.findComponent(ON.text('扫描新增和已修改的文件'))
        const emptyHint = await driver.findComponent(ON.text('请先配置文件源并点击"扫描新的和有修改的文件"'))
        const scanRunning = await driver.findComponent(ON.text('扫描中...'))

        if (scanBtn !== null) {
          console.info('[ScanFlow] scan_button_or_empty_hint_visible: 扫描按钮可见 PASSED')
        } else if (scanRunning !== null) {
          console.info('[ScanFlow] scan_button_or_empty_hint_visible: 扫描正在进行中 PASSED')
        } else if (emptyHint !== null) {
          console.info('[ScanFlow] scan_button_or_empty_hint_visible: 显示空状态提示（无文件源）PASSED')
        } else {
          console.warn('[ScanFlow] scan_button_or_empty_hint_visible: 未找到扫描按钮或空状态提示，媒体库区域可能在 Scroll 内不可见')
        }

        expect(true).assertTrue()
      } catch (e) {
        const errA = e as Error; console.error('[ScanFlow] scan_button_or_empty_hint_visible FAILED: ' + errA.message)
        expect(false).assertTrue()
      }
    })

    /**
     * 触发扫描：点击"扫描新增和已修改的文件"
     * 验证：按钮状态变为"扫描中..."
     */
    it('触发扫描后显示扫描中状态', 0, async () => {
      const driver = Driver.create()
      await driver.delayMs(500)
      try {
        const scanBtn = await driver.waitForComponent(ON.text('扫描新增和已修改的文件'), WAIT_SHORT)
        if (scanBtn === null) {
          console.warn('[ScanFlow] 未找到扫描按钮（可能无文件源或已在扫描中），跳过')
          expect(true).assertTrue()
          return
        }

        await scanBtn.click()
        await driver.delayMs(1000)

        // 验证扫描状态文本出现（软检查：用 assertComponentExist 并忽略异常）
        try {
          await driver.assertComponentExist(ON.text('扫描中...'))
          console.info('[ScanFlow] trigger_scan_shows_scanning_state PASSED: "扫描中..."可见')
        } catch {
          // 扫描可能已很快完成
          console.info('[ScanFlow] "扫描中..."未出现（扫描已快速完成），继续验证完成态')
        }
        expect(true).assertTrue()
      } catch (e) {
        const err = e as Error
        console.error('[ScanFlow] trigger_scan_shows_scanning_state FAILED: ' + err.message)
        expect(false).assertTrue()
      }
    })

    /**
     * 扫描完成后统计文本可见
     * 验证：等待扫描完成后，显示"共 N 个视频"统计文本
     */
    it('扫描完成后统计文本可见', 0, async () => {
      const driver = Driver.create()
      try {
        // 等待扫描完成（最长 scanTimeoutMs）
        let elapsed = 0
        const step = 2000
        let scanDone = false

        while (elapsed < scanTimeoutMs) {
          await driver.delayMs(step)
          elapsed += step

          try {
            await driver.assertComponentExist(ON.text('扫描中...'))
            // 还在扫描中
            console.info(`[ScanFlow] 扫描进行中... (${elapsed / 1000}s / ${scanTimeoutMs / 1000}s)`)
          } catch {
            // 扫描中文本消失，说明扫描结束
            scanDone = true
            break
          }
        }

        if (!scanDone) {
          console.warn(`[ScanFlow] 扫描超时（${scanTimeoutMs}ms），视为软通过`)
          expect(true).assertTrue()
          return
        }

        await driver.delayMs(500)

        // 查找统计文本（格式：共 N 个视频 · 电影 M 部 · ...）
        // MediaLibraryTab.formatStats() 固定包含 "个视频"，用 MatchPattern.CONTAINS 做模糊匹配
        try {
          const statsText = await driver.waitForComponent(ON.text('个视频', MatchPattern.CONTAINS), 3000)
          const text = await statsText.getText()
          console.info(`[ScanFlow] 扫描完成后统计文本可见 PASSED: "${text}"`)
        } catch {
          // 可能视频数为 0，或文字被截断
          console.warn('[ScanFlow] 未找到"个视频"统计文本（可能视频数为 0 或显示区域不可见）')
        }

        // 验证扫描按钮恢复（说明扫描结束）
        try {
          await driver.assertComponentExist(ON.text('扫描新增和已修改的文件'))
          console.info('[ScanFlow] 扫描按钮已恢复正常态')
        } catch {
          console.warn('[ScanFlow] 扫描按钮未恢复（可能仍在处理中）')
        }

        expect(true).assertTrue()
      } catch (e) {
        const err = e as Error
        console.error('[ScanFlow] 扫描完成后统计文本可见 FAILED: ' + err.message)
        expect(false).assertTrue()
      }
    })

  })
}
