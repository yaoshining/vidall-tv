/**
 * 平台身份（AuthProvider.login() 返回）
 *
 * platformUserId 是跨平台唯一的用户标识：
 * - 华为：unionID
 * - 微信：unionid
 */
export interface PlatformIdentity {
  /** 平台侧用户 ID：华为=unionID；微信=unionid */
  platformUserId: string;
  /** 显示昵称；provider 未返回资料时缺省 */
  displayName?: string;
  /** 头像 URI；provider 未返回资料时缺省 */
  avatarUri?: string;
  /** 平台侧 openID（华为=openID） */
  openID: string;
  /** 原始字段（authorizationCode、idToken 等），provider 自填 */
  raw: Map<string, string>;
}

/**
 * 认证 provider 抽象（可插拔）
 *
 * 新增平台只需实现该接口并注册到 AccountService.registerProvider()。
 * 按钮渲染由各 provider 自行提供 Builder（系统组件如 LoginWithHuaweiIDButton 无法泛化）。
 */
export interface AuthProvider {
  /** provider 标识：'huawei' | 'wechat' ... */
  providerId: string;
  /** 显示名：'华为账号' | '微信' */
  displayName: string;
  /** 拉起授权，返回平台身份 */
  login(): Promise<PlatformIdentity>;
  /** 退出授权（provider 侧清理，如有） */
  signOut(): Promise<void>;
}
