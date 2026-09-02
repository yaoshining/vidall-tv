import { LoginWithHuaweiIDButton, loginComponentManager } from '@kit.AccountKit'
import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { AccountService } from '../../services/account/AccountService'
import { ERROR_AGC_NOT_INITIALIZED } from '../../services/account/AgcCloudAuthService'
import { HuaweiAuthProvider } from '../../services/account/providers/HuaweiAuthProvider'
import { AccountModel } from '../../stores/account/AccountModel'

@ComponentV2
export struct LoginDialog {
  @Local accountModel: AccountModel = AccountModel.getInstance()
  @Local private loginAttemptArmed: boolean = false

  aboutToAppear(): void {
    console.info('[LoginDialog] 登录弹层已挂载')
  }

  private prepareHuaweiLogin(): void {
    if (this.loginAttemptArmed || this.accountModel.isLogged) {
      return
    }
    const provider = AccountService.getInstance().getProvider('huawei')
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext
    if (!(provider instanceof HuaweiAuthProvider) || context === undefined) {
      this.accountModel.setLoginError('登录服务暂不可用，请稍后重试')
      return
    }
    provider.setAuthorizationContext(context)
    this.loginAttemptArmed = true
    void this.executeHuaweiLogin()
  }

  private async executeHuaweiLogin(): Promise<void> {
    try {
      await AccountService.getInstance().loginWith('huawei')
      this.loginAttemptArmed = false
    } catch (e) {
      this.loginAttemptArmed = false
      this.handleLoginError(e as Error)
      if (this.accountModel.loginDialogVisible) {
        this.prepareHuaweiLogin()
      }
    }
  }

  private handleLoginError(error: Error): void {
    const businessError = error as BusinessError
    console.warn(`[LoginDialog] 华为登录失败 code=${businessError.code ?? -1}`)
    if (businessError.code === 1001502012) {
      this.accountModel.setLoginError('已取消登录，你可以重新选择华为账号登录')
      return
    }
    if (businessError.code === ERROR_AGC_NOT_INITIALIZED) {
      this.accountModel.setLoginError('登录服务初始化失败，请重启应用后重试')
      return
    }
    this.accountModel.setLoginError('登录失败，请检查网络后重试')
  }

  private getHuaweiController(): loginComponentManager.LoginWithHuaweiIDButtonController {
    const provider = AccountService.getInstance().getProvider('huawei')
    if (provider instanceof HuaweiAuthProvider) {
      return provider.getController()
    }
    return new loginComponentManager.LoginWithHuaweiIDButtonController()
  }

  private getHuaweiButtonExtraStyle(): loginComponentManager.ExtraStyle {
    const normalStyle: loginComponentManager.ButtonStyle = new loginComponentManager.ButtonStyle()
      .backgroundColor('#CF0A2C')
      .fontColor(Color.White)
      .fontWeight(FontWeight.Bold)
    const focusedStyle: loginComponentManager.ButtonStyle = new loginComponentManager.ButtonStyle()
      .backgroundColor('#E42545')
      .fontColor(Color.White)
      .fontWeight(FontWeight.Bold)
      .outline({ width: 3, color: Color.White })
    const pressedStyle: loginComponentManager.ButtonStyle = new loginComponentManager.ButtonStyle()
      .backgroundColor('#A80724')
      .fontColor(Color.White)
      .fontWeight(FontWeight.Bold)
    const disabledStyle: loginComponentManager.ButtonStyle = new loginComponentManager.ButtonStyle()
      .backgroundColor('#6F2632')
      .fontColor('#BFBFBF')
      .opacity(0.7)
    const stateStyles: loginComponentManager.StateStyles = {
      normal: normalStyle,
      focused: focusedStyle,
      pressed: pressedStyle,
      disabled: disabledStyle
    }
    const extraStyle: loginComponentManager.ExtraStyle = {
      customButtonStateStyles: stateStyles
    }
    return extraStyle
  }

  build() {
    if (this.accountModel.loginDialogVisible) {
      Column() {
        Column() {
          Row() {
            Column() {
              Text('登录 VidAll')
                .fontSize(26)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
              Text('连接你的账号，解锁跨设备体验')
                .fontSize(14)
                .fontColor('#A8A8A8')
                .margin({ top: 6 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text('HUAWEI')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor('#CF0A2C')
              .letterSpacing(1.5)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)

          Text('选择登录方式')
            .width('100%')
            .fontSize(14)
            .fontColor('#D0D0D0')
            .margin({ top: 30, bottom: 12 })

          LoginWithHuaweiIDButton({
            params: {
              style: loginComponentManager.Style.BUTTON_CUSTOM,
              borderRadius: 10,
              loginType: loginComponentManager.LoginType.ID,
              supportDarkMode: true,
              customButtonParams: {
                fontColor: loginComponentManager.FontColor.WHITE,
                backgroundColor: '#CF0A2C'
              },
              extraStyle: this.getHuaweiButtonExtraStyle()
            },
            controller: this.getHuaweiController()
          })
            .width('100%')
            .height(56)
            .id('loginHuaweiBtn')
            .defaultFocus(true)
            .enabled(!this.accountModel.isLoggingIn)

          if (this.accountModel.loginErrorMessage.length > 0) {
            Text(this.accountModel.loginErrorMessage)
              .width('100%')
              .fontSize(13)
              .fontColor('#FF8A8A')
              .margin({ top: 12 })
          }

          Row() {
            Text('更多登录方式将在后续版本提供')
              .fontSize(12)
              .fontColor('#777777')
              .layoutWeight(1)
            Button('取消')
              .height(42)
              .fontSize(14)
              .fontColor('#E6E6E6')
              .backgroundColor('#3A3A3A')
              .borderRadius(8)
              .onClick(() => {
                this.accountModel.hideLoginDialog()
              })
          }
          .width('100%')
          .margin({ top: 24 })
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
      .onAppear(() => {
        this.prepareHuaweiLogin()
      })
      .onClick(() => {})
    }
  }
}
