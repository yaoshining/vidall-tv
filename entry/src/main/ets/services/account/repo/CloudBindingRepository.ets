import { cloudDatabase } from '@kit.CloudFoundationKit';
import { AccountBinding } from '../../../db/models/AccountBinding';
import { CLOUD_ZONE_NAME } from '../CloudAccountConfig';

/**
 * AccountBinding 表的 Cloud DB 读写。
 *
 * 依赖：AGC 控制台已创建存储区 CLOUD_ZONE_NAME 与对象类型 AccountBinding（见 tasks 1.2/1.3）。
 * (platform, platformUserId) 使用确定性 bindingId，确保并发首次登录写入同一记录。
 */
export class CloudBindingRepository {
  async upsert(binding: AccountBinding): Promise<number> {
    const zone = cloudDatabase.zone(CLOUD_ZONE_NAME);
    return zone.upsert(binding);
  }

  async findByPlatformUser(platform: string, platformUserId: string): Promise<AccountBinding | null> {
    const zone = cloudDatabase.zone(CLOUD_ZONE_NAME);
    const queryCondition = new cloudDatabase.DatabaseQuery(AccountBinding);
    queryCondition.equalTo('platform', platform);
    queryCondition.equalTo('platformUserId', platformUserId);
    const results: AccountBinding[] = await zone.query(queryCondition);
    if (results.length === 0) {
      return null;
    }
    return results[0];
  }
}
