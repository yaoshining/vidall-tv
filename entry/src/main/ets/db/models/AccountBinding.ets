import { cloudDatabase } from '@kit.CloudFoundationKit';

/**
 * 平台绑定关系（Cloud DB 对象类型 AccountBinding）
 *
 * 一个 App 账号可绑定多个平台；同一 (platform, platformUserId) 使用确定性 bindingId，确保并发写入收敛。
 * AGC 控制台需创建同名对象类型，主键 bindingId，并给 accountId / platform / platformUserId 建索引。
 */
export class AccountBinding extends cloudDatabase.DatabaseObject {
  /** 绑定关系 ID（UUID），主键 */
  bindingId: string = '';
  /** 所属 App 账号 ID（索引，反查 UserAccount） */
  accountId: string = '';
  /** 平台标识：'huawei' | 'wechat' ...（索引） */
  platform: string = '';
  /** 平台侧用户 ID：华为=unionID（索引） */
  platformUserId: string = '';
  /** 平台侧昵称（可能为空字符串） */
  platformDisplayName: string = '';
  /** 平台侧头像 URI（可能为空字符串） */
  platformAvatarUri: string = '';
  /** 首次绑定时间 */
  boundAt: Date = new Date(0);
  /** 最近更新时间 */
  updatedAt: Date = new Date(0);

  naturalbase_ClassName(): string {
    return 'AccountBinding';
  }
}
