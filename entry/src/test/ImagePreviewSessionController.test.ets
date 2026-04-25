import { describe, it, expect } from '@ohos/hypium'
import { DialogHandle, ImagePreviewSessionController } from '../main/ets/components/core/file/ImagePreviewSessionController'

class FakeDialogHandle implements DialogHandle {
  openCount: number = 0
  closeCount: number = 0

  open(): void {
    this.openCount += 1
  }

  close(): void {
    this.closeCount += 1
  }
}

export default function imagePreviewSessionControllerTest() {
  describe('ImagePreviewSessionController', () => {
    it('打开新预览前会先关闭旧弹窗', 0, () => {
      const controller = new ImagePreviewSessionController()
      const firstDialog = new FakeDialogHandle()
      const secondDialog = new FakeDialogHandle()

      controller.openDialog(firstDialog)
      controller.openDialog(secondDialog)

      expect(firstDialog.openCount).assertEqual(1)
      expect(firstDialog.closeCount).assertEqual(1)
      expect(secondDialog.openCount).assertEqual(1)
      expect(secondDialog.closeCount).assertEqual(0)
    })

    it('handleBack 会关闭当前预览并返回已消费', 0, () => {
      const controller = new ImagePreviewSessionController()
      const dialog = new FakeDialogHandle()

      controller.openDialog(dialog)
      expect(controller.handleBack()).assertTrue()
      expect(dialog.closeCount).assertEqual(1)
      expect(controller.handleBack()).assertFalse()
    })
  })
}
