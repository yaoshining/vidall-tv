import { AuthProvider, PlatformIdentity } from './AuthProvider';
import { CloudAccountRepository } from './repo/CloudAccountRepository';
import { CloudBindingRepository } from './repo/CloudBindingRepository';
import { UserAccount } from '../../db/models/UserAccount';
import { AccountBinding } from '../../db/models/AccountBinding';
import { AppPreferences } from '../../utils/AppPreferences';
import { AgcCloudAuthService } from './AgcCloudAuthService';
import { AccountModel } from '../../stores/account/AccountModel';
import { LoginStateRecord } from '../../utils/AppPreferences';

/**
 * 账号服务（单例）
 *
 * 职责：
 * - 维护可插拔的 AuthProvider 注册表（registerProvider）
 * - loginWith(providerId)：provider 拉起授权 → 按 (platform, platformUserId) find-or-create
 *   AccountBinding + UserAccount → 写 Cloud DB → 写本地登录态
 * - logout()：provider.signOut() → 清本地登录态（Cloud DB 记录保留）
 *
 * 一账号多绑定：同一 UserAccount 可关联多条 AccountBinding（不同 platform）；
 * (platform, platformUserId) 使用确定性主键，保证并发首次登录收敛到同一账号。
 */
export class AccountService {
  private static instance: AccountService | null = null;
  private providers: Map<string, AuthProvider> = new Map<string, AuthProvider>();
  private accountRepo: CloudAccountRepository = new CloudAccountRepository();
  private bindingRepo: CloudBindingRepository = new CloudBindingRepository();

  private constructor() {}

  static getInstance(): AccountService {
    if (AccountService.instance === null) {
      AccountService.instance = new AccountService();
    }
    return AccountService.instance;
  }

  /** 注册 provider，UI 未登录态会渲染已注册 provider 的登录按钮 */
  registerProvider(provider: AuthProvider): void {
    this.providers.set(provider.providerId, provider);
  }

  /** 获取已注册 provider（未注册返回 undefined） */
  getProvider(providerId: string): AuthProvider | undefined {
    return this.providers.get(providerId);
  }

  /**
   * 使用指定 provider 登录。
   * 流程：provider.login() → find-or-create binding + account → upsert Cloud DB → 写本地态。
   * 失败（用户取消、授权失败、Cloud DB 写入失败）时抛出，不写本地态。
   */
  async loginWith(providerId: string): Promise<void> {
    const provider = this.providers.get(providerId);
    if (!provider) {
      throw new Error(`未注册的 provider: ${providerId}`);
    }

    const identity: PlatformIdentity = await provider.login();
    await AgcCloudAuthService.getInstance().authenticateHuaweiAccount();

    // 1. 按 (platform, platformUserId) find-or-create 绑定
    const existingBinding = await this.bindingRepo.findByPlatformUser(
      provider.providerId,
      identity.platformUserId
    );
    let binding: AccountBinding;
    let accountId: string;
    if (existingBinding !== null) {
      binding = existingBinding;
      accountId = existingBinding.accountId;
      if (identity.displayName !== undefined && identity.displayName.length > 0) {
        binding.platformDisplayName = identity.displayName;
      }
      if (identity.avatarUri !== undefined && identity.avatarUri.length > 0) {
        binding.platformAvatarUri = identity.avatarUri;
      }
      binding.updatedAt = new Date();
    } else {
      // Cloud DB 无复合唯一索引；确定性主键使并发首次登录写入同一账号与绑定。
      accountId = `${provider.providerId}:${identity.platformUserId}`;
      binding = new AccountBinding();
      binding.bindingId = accountId;
      binding.accountId = accountId;
      binding.platform = provider.providerId;
      binding.platformUserId = identity.platformUserId;
      binding.platformDisplayName = identity.displayName ?? '';
      binding.platformAvatarUri = identity.avatarUri ?? '';
      binding.boundAt = new Date();
      binding.updatedAt = binding.boundAt;
    }

    // 2. 按 accountId find-or-create 账号主体
    const existingAccount = await this.accountRepo.queryById(accountId);
    let account: UserAccount;
    if (existingAccount !== null) {
      account = existingAccount;
      if (identity.displayName !== undefined && identity.displayName.length > 0) {
        account.displayName = identity.displayName;
      }
      if (identity.avatarUri !== undefined && identity.avatarUri.length > 0) {
        account.avatarUri = identity.avatarUri;
      }
      account.updatedAt = new Date();
    } else {
      account = new UserAccount();
      account.accountId = accountId;
      account.displayName = identity.displayName ?? '';
      account.avatarUri = identity.avatarUri ?? '';
      account.createdAt = new Date();
      account.updatedAt = account.createdAt;
    }

    // 3. 写 Cloud DB（先账号后绑定，绑定引用账号 ID）
    await this.accountRepo.upsert(account);
    await this.bindingRepo.upsert(binding);

    // 4. 写本地登录态
    const loginTime: number = Date.now();
    await AppPreferences.setLoginState(
      accountId,
      provider.providerId,
      account.displayName,
      account.avatarUri,
      loginTime
    );
    const loginState: LoginStateRecord = {
      accountId: accountId,
      providerId: provider.providerId,
      displayName: account.displayName,
      avatarUri: account.avatarUri,
      loginTime: loginTime,
      isLogged: true
    };
    AccountModel.getInstance().applyLoggedInState(loginState);
  }

  /**
   * 退出登录：清理 provider 与 AGC 会话，并始终清除本地登录态。
   * Cloud DB 的 UserAccount / AccountBinding 记录保留（便于再登录命中 + 历史）。
   */
  async logout(): Promise<void> {
    try {
      const providerId = await AppPreferences.getCurrentProviderId();
      if (providerId.length > 0) {
        const provider = this.providers.get(providerId);
        if (provider) {
          await provider.signOut();
        }
      }
      await AgcCloudAuthService.getInstance().signOut();
    } finally {
      await AppPreferences.clearLoginState();
      AccountModel.getInstance().clear();
    }
  }
}
