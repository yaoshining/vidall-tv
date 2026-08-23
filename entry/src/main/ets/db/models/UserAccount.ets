import { cloudDatabase } from '@kit.CloudFoundationKit';

/**
 * 账号主体（Cloud DB 对象类型 UserAccount）
 *
 * 一个 App 账号对应一行，可绑定多个平台身份（见 AccountBinding）。
 * AGC 控制台需创建同名对象类型并配置主键 accountId、其余字段为可空。
 */
export class UserAccount extends cloudDatabase.DatabaseObject {
  /** 本 App 内账号 ID（UUID），主键 */
  accountId: string = '';
  /** 显示昵称（首登录取华为昵称，可能为空字符串） */
  displayName: string = '';
  /** 头像 URI（可能为空字符串） */
  avatarUri: string = '';
  /** 创建时间 */
  createdAt: Date = new Date(0);
  /** 最近更新时间 */
  updatedAt: Date = new Date(0);

  naturalbase_ClassName(): string {
    return 'UserAccount';
  }
}
