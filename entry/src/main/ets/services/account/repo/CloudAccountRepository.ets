import { cloudDatabase } from '@kit.CloudFoundationKit';
import { UserAccount } from '../../../db/models/UserAccount';
import { CLOUD_ZONE_NAME } from '../CloudAccountConfig';

/**
 * UserAccount 表的 Cloud DB 读写。
 *
 * 依赖：AGC 控制台已创建存储区 CLOUD_ZONE_NAME 与对象类型 UserAccount（见 tasks 1.2/1.3）。
 */
export class CloudAccountRepository {
  async upsert(account: UserAccount): Promise<number> {
    const zone = cloudDatabase.zone(CLOUD_ZONE_NAME);
    return zone.upsert(account);
  }

  async queryById(accountId: string): Promise<UserAccount | null> {
    const zone = cloudDatabase.zone(CLOUD_ZONE_NAME);
    const queryCondition = new cloudDatabase.DatabaseQuery(UserAccount);
    queryCondition.equalTo('accountId', accountId);
    const results: UserAccount[] = await zone.query(queryCondition);
    if (results.length === 0) {
      return null;
    }
    return results[0];
  }
}
