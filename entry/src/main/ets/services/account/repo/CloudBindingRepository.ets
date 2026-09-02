import { BusinessError } from '@kit.BasicServicesKit';
import { cloudDatabase } from '@kit.CloudFoundationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AccountBinding } from '../../../db/models/AccountBinding';
import { CLOUD_ZONE_NAME } from '../CloudAccountConfig';

const LOG_DOMAIN: number = 0x0000;
const TAG: string = 'CloudBindingRepo';

class CloudBindingRepositoryError extends Error implements BusinessError {
  code: number;

  constructor(code: number, message: string) {
    super(message);
    this.name = 'CloudBindingRepositoryError';
    this.code = code;
  }
}

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
    try {
      const results: AccountBinding[] = await zone.query(queryCondition);
      if (results.length === 0) {
        return null;
      }
      return results[0];
    } catch (e) {
      const error = e as BusinessError;
      hilog.error(LOG_DOMAIN, TAG, '查询 AccountBinding 失败 code=%{public}d message=%{public}s',
        error.code ?? -1, error.message ?? 'Cloud DB 查询失败');
      throw new CloudBindingRepositoryError(error.code ?? -1, error.message ?? 'Cloud DB 查询失败');
    }
  }
}
