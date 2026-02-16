import { describe, it, expect } from '@ohos/hypium'
import { SettingsController } from '../main/ets/pages/settings/SettingsController'
import SettingType from '../main/ets/pages/settings/SettingType'

export default function SettingsControllerTest() {
  describe('SettingsController 堆栈系统测试', () => {

    it('初始状态应该为 HOME，堆栈为空', () => {
      const controller = new SettingsController()
      expect(controller.type).assertEqual(SettingType.HOME)
      expect(controller.canGoBack()).assertEqual(false)
    })

    it('pushType 应该将当前类型压入堆栈并切换到新类型', () => {
      const controller = new SettingsController()
      controller.pushType(SettingType.FILE_SOURCE)

      expect(controller.type).assertEqual(SettingType.FILE_SOURCE)
      expect(controller.canGoBack()).assertEqual(true)
    })

    it('popType 应该返回到上一个类型', () => {
      const controller = new SettingsController()
      controller.pushType(SettingType.FILE_SOURCE)
      controller.pushType(SettingType.VIDEO_SERVER)

      const result = controller.popType()

      expect(result).assertEqual(true)
      expect(controller.type).assertEqual(SettingType.FILE_SOURCE)
      expect(controller.canGoBack()).assertEqual(true)
    })

    it('多次 popType 应该正确回溯历史', () => {
      const controller = new SettingsController()
      controller.pushType(SettingType.FILE_SOURCE)
      controller.pushType(SettingType.VIDEO_SERVER)
      controller.pushType(SettingType.RESOURCE_LIBRARY)

      controller.popType() // 回到 VIDEO_SERVER
      expect(controller.type).assertEqual(SettingType.VIDEO_SERVER)

      controller.popType() // 回到 FILE_SOURCE
      expect(controller.type).assertEqual(SettingType.FILE_SOURCE)

      controller.popType() // 回到 HOME
      expect(controller.type).assertEqual(SettingType.HOME)

      // 堆栈应该为空
      expect(controller.canGoBack()).assertEqual(false)
    })

    it('在根菜单时 popType 应该返回 false', () => {
      const controller = new SettingsController()
      const result = controller.popType()

      expect(result).assertEqual(false)
      expect(controller.type).assertEqual(SettingType.HOME)
    })

    it('clearStack 应该清空堆栈但不改变当前类型', () => {
      const controller = new SettingsController()
      controller.pushType(SettingType.FILE_SOURCE)
      controller.pushType(SettingType.VIDEO_SERVER)

      controller.clearStack()

      expect(controller.type).assertEqual(SettingType.VIDEO_SERVER)
      expect(controller.canGoBack()).assertEqual(false)
    })

    it('reset 应该清空堆栈并设置初始类型', () => {
      const controller = new SettingsController()
      controller.pushType(SettingType.FILE_SOURCE)
      controller.pushType(SettingType.VIDEO_SERVER)

      controller.reset(SettingType.RESOURCE_LIBRARY)

      expect(controller.type).assertEqual(SettingType.RESOURCE_LIBRARY)
      expect(controller.canGoBack()).assertEqual(false)
    })

    it('reset 不传参数应该重置到 HOME', () => {
      const controller = new SettingsController()
      controller.pushType(SettingType.FILE_SOURCE)

      controller.reset()

      expect(controller.type).assertEqual(SettingType.HOME)
      expect(controller.canGoBack()).assertEqual(false)
    })

    it('复杂导航场景测试', () => {
      const controller = new SettingsController()

      // HOME -> FILE_SOURCE -> VIDEO_SERVER
      controller.pushType(SettingType.FILE_SOURCE)
      controller.pushType(SettingType.VIDEO_SERVER)
      expect(controller.type).assertEqual(SettingType.VIDEO_SERVER)

      // 回到 FILE_SOURCE
      controller.popType()
      expect(controller.type).assertEqual(SettingType.FILE_SOURCE)

      // 从 FILE_SOURCE -> RESOURCE_LIBRARY
      controller.pushType(SettingType.RESOURCE_LIBRARY)
      expect(controller.type).assertEqual(SettingType.RESOURCE_LIBRARY)

      // 堆栈应该是: [HOME, FILE_SOURCE]
      controller.popType()
      expect(controller.type).assertEqual(SettingType.FILE_SOURCE)

      controller.popType()
      expect(controller.type).assertEqual(SettingType.HOME)

      expect(controller.canGoBack()).assertEqual(false)
    })
  })
}

