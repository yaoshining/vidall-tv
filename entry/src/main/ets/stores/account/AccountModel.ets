import { AppStorageV2 } from '@kit.ArkUI'
import { AppPreferences, LoginStateRecord } from '../../utils/AppPreferences'

@ObservedV2
export class AccountModel {
  private static readonly STORAGE_KEY: string = 'VidAllAccountModel'

  @Trace isLogged: boolean = false
  @Trace accountId: string = ''
  @Trace providerId: string = ''
  @Trace displayName: string = ''
  @Trace avatarUri: string = ''
  @Trace loginDialogVisible: boolean = false
  @Trace logoutConfirmVisible: boolean = false
  @Trace isLoggingIn: boolean = false
  @Trace loginErrorMessage: string = ''

  constructor() {
  }

  static getInstance(): AccountModel {
    const model = AppStorageV2.connect<AccountModel>(
      AccountModel,
      AccountModel.STORAGE_KEY,
      () => new AccountModel()
    )
    if (model === undefined) {
      throw new Error('无法初始化全局账号状态')
    }
    return model
  }

  async restore(): Promise<void> {
    const state: LoginStateRecord | null = await AppPreferences.getLoginState()
    if (state === null) {
      this.clear()
      return
    }
    this.applyLoggedInState(state)
  }

  applyLoggedInState(state: LoginStateRecord): void {
    this.accountId = state.accountId
    this.providerId = state.providerId
    this.displayName = state.displayName
    this.avatarUri = state.avatarUri
    this.isLogged = true
    this.isLoggingIn = false
    this.loginErrorMessage = ''
    this.loginDialogVisible = false
  }

  clear(): void {
    this.isLogged = false
    this.accountId = ''
    this.providerId = ''
    this.displayName = ''
    this.avatarUri = ''
    this.isLoggingIn = false
    this.loginErrorMessage = ''
    this.loginDialogVisible = false
    this.logoutConfirmVisible = false
  }

  showLoginDialog(): void {
    if (this.isLogged) {
      return
    }
    this.loginErrorMessage = ''
    this.loginDialogVisible = true
    console.info(`[AccountModel] 登录弹层状态=${this.loginDialogVisible}`)
  }

  hideLoginDialog(): void {
    this.loginDialogVisible = false
    this.isLoggingIn = false
    this.loginErrorMessage = ''
  }

  showLogoutConfirm(): void {
    if (!this.isLogged) {
      return
    }
    this.logoutConfirmVisible = true
  }

  hideLogoutConfirm(): void {
    this.logoutConfirmVisible = false
  }

  beginLogin(): void {
    this.isLoggingIn = true
    this.loginErrorMessage = ''
  }

  finishLogin(): void {
    this.isLoggingIn = false
  }

  setLoginError(message: string): void {
    this.isLoggingIn = false
    this.loginErrorMessage = message
  }
}
