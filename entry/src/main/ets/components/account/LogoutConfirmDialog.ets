import { AccountService } from '../../services/account/AccountService'
import { AccountModel } from '../../stores/account/AccountModel'

@ComponentV2
export struct LogoutConfirmDialog {
  @Local accountModel: AccountModel = AccountModel.getInstance()
  @Local private isLoggingOut: boolean = false
  @Local private cancelFocused: boolean = false
  @Local private quitFocused: boolean = false

  private getDisplayName(): string {
    return this.accountModel.displayName.length > 0 ? this.accountModel.displayName : '当前用户'
  }

  private cancel(): void {
    if (this.isLoggingOut) {
      return
    }
    this.accountModel.hideLogoutConfirm()
  }

  private confirmLogout(): void {
    if (this.isLoggingOut) {
      return
    }
    this.isLoggingOut = true
    AccountService.getInstance().logout().then(() => {
      this.isLoggingOut = false
      this.accountModel.hideLogoutConfirm()
      this.showToast('已退出登录')
    }).catch(() => {
      this.isLoggingOut = false
      this.showToast('退出登录失败，请重试')
    })
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration: 2000 })
    } catch {
      console.warn(`[LogoutConfirmDialog] toast failed: ${message}`)
    }
  }

  build() {
    if (this.accountModel.logoutConfirmVisible) {
      Column() {
        Column() {
          Text('退出登录')
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)

          Text(`确定要退出当前账号（${this.getDisplayName()}）吗？退出后需要重新登录。`)
            .fontSize(15)
            .fontColor('#C8C8C8')
            .lineHeight(24)
            .margin({ top: 16 })

          Row({ space: 16 }) {
            Button('取消')
              .layoutWeight(1)
              .height(48)
              .fontSize(16)
              .fontColor('#E6E6E6')
              .backgroundColor(this.cancelFocused ? '#4A4A4A' : '#3A3A3A')
              .borderRadius(10)
              .border({ width: 2, color: this.cancelFocused ? Color.White : Color.Transparent })
              .defaultFocus(true)
              .focusable(true)
              .onFocus(() => { this.cancelFocused = true })
              .onBlur(() => { this.cancelFocused = false })
              .onClick(() => {
                this.cancel()
              })

            Button(this.isLoggingOut ? '退出中…' : '退出')
              .layoutWeight(1)
              .height(48)
              .fontSize(16)
              .fontColor(Color.White)
              .backgroundColor('#CF0A2C')
              .borderRadius(10)
              .border({ width: 2, color: this.quitFocused ? Color.White : Color.Transparent })
              .focusable(true)
              .enabled(!this.isLoggingOut)
              .onFocus(() => { this.quitFocused = true })
              .onBlur(() => { this.quitFocused = false })
              .onClick(() => {
                this.confirmLogout()
              })
          }
          .width('100%')
          .margin({ top: 28 })
        }
        .width(520)
        .padding({ top: 34, right: 38, bottom: 30, left: 38 })
        .backgroundColor('#242424')
        .borderRadius(18)
        .border({ width: 1, color: '#404040' })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('#B3000000')
      .onClick(() => {})
    }
  }
}
