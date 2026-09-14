import buffer from '@ohos.buffer';
import relationalStore from '@ohos.data.relationalStore';
import { CryptoUtil } from '../../utils/CryptoUtil';
import { CREDENTIAL_FAILURE } from '../../utils/CredentialConfig';

export interface CredentialCodec {
  encrypt(value: string, scope: string): Promise<string>;
  decrypt(value: string, scope: string): Promise<string>;
}

class SystemCredentialCodec implements CredentialCodec {
  encrypt(value: string, scope: string): Promise<string> { return CryptoUtil.encrypt(value, scope); }
  decrypt(value: string, scope: string): Promise<string> { return CryptoUtil.decrypt(value, scope); }
}

/** 两个 DAO 共用同一策略。测试可注入独立别名，生产始终使用系统 codec。 */
export class CredentialStorage {
  private codec: CredentialCodec;
  constructor(codec: CredentialCodec = new SystemCredentialCodec()) { this.codec = codec; }

  /** 只保留本应用已定义的完整密文格式；v2:example 等普通密码仍可使用。 */
  private isStoredCiphertext(value: string): boolean {
    const parts = value.split(':');
    if (parts.length === 3 && parts[0] === 'v2') {
      // 12 字节 nonce；至少 1 字节内部格式前缀和 16 字节认证标签。
      return this.base64Length(parts[1]) === 12 && this.base64Length(parts[2]) >= 17;
    }
    if (parts.length === 2) {
      const ciphertextLength = this.base64Length(parts[1]);
      return this.base64Length(parts[0]) === 16 && ciphertextLength > 0 && ciphertextLength % 16 === 0;
    }
    return false;
  }

  private base64Length(value: string): number {
    try {
      const decoded = buffer.from(value, 'base64');
      return decoded.toString('base64') === value ? decoded.length : -1;
    } catch (e) { return -1; }
  }

  private parse(json: string): Record<string, Object> {
    const input = JSON.parse(json) as Record<string, Object>;
    const output: Record<string, Object> = {};
    for (const key of Object.keys(input)) {
      if (key !== CREDENTIAL_FAILURE) { output[key] = input[key]; }
    }
    return output;
  }

  async read(store: relationalStore.RdbStore, table: string, id: number,
    raw: string, keys: string[]): Promise<string> {
    const plain = this.parse(raw);
    const migrated = JSON.parse(raw) as Record<string, Object>;
    const failures: string[] = [];
    let needsMigration = false;
    for (const key of keys) {
      const value = plain[key];
      if (value === undefined || value === '') { continue; }
      try {
        if (typeof value !== 'string') { throw new Error('格式错误'); }
        plain[key] = await this.codec.decrypt(value, table + ':' + key);
        if (!value.startsWith('v2:')) { needsMigration = true; }
      } catch (e) {
        plain[key] = '';
        failures.push(key);
      }
    }
    if (failures.length > 0) { plain[CREDENTIAL_FAILURE] = failures; }
    // 任一字段失败则整行不迁移，保证部分失败也不改变原始数据。
    if (needsMigration && failures.length === 0) {
      try {
        for (const key of keys) {
          const old = migrated[key];
          if (typeof old === 'string' && old !== '' && !old.startsWith('v2:')) {
            migrated[key] = await this.codec.encrypt(plain[key] as string, table + ':' + key);
          }
        }
        const predicates = this.compare(table, id, raw);
        await store.update({ config_json: JSON.stringify(migrated) }, predicates);
      } catch (e) {
        // 加密或数据库失败保留原值；下一次读取重试。成功解密的值仍可使用。
        console.warn('CredentialStorage: migration deferred');
      }
    }
    return JSON.stringify(plain);
  }

  async raw(store: relationalStore.RdbStore, table: string, id: number): Promise<string> {
    const predicates = new relationalStore.RdbPredicates(table);
    predicates.equalTo('id', id);
    const rs = await store.query(predicates, ['config_json']);
    try {
      if (!rs.goToFirstRow()) { throw new Error('数据源已不存在，请重新加载'); }
      return rs.getString(0);
    } finally { rs.close(); }
  }

  compare(table: string, id: number, raw: string): relationalStore.RdbPredicates {
    const predicates = new relationalStore.RdbPredicates(table);
    predicates.equalTo('id', id).and().equalTo('config_json', raw);
    return predicates;
  }

  async write(json: string, table: string, keys: string[], raw?: string): Promise<string> {
    const config = this.parse(json);
    const previous = JSON.parse(raw ?? '{}') as Record<string, Object>;
    for (const key of keys) {
      const value = config[key];
      if (value !== undefined && typeof value !== 'string') { throw new Error('凭据格式错误'); }
      // 空值/省略一律保留已有凭据，包括读取后密钥恢复的情况。
      // 编辑界面不会因失败字段显示为空而擦除原值；替换必须输入非空新凭据。
      const old = previous[key];
      if ((value === undefined || value === '') && old !== undefined && old !== '') {
        config[key] = old;
        if (typeof old === 'string' && !old.startsWith('v2:')) {
          let recovered: string;
          try { recovered = await this.codec.decrypt(old, table + ':' + key); }
          catch (e) { continue; }
          config[key] = await this.codec.encrypt(recovered, table + ':' + key);
        }
        continue;
      }
      if (typeof value === 'string' && value !== '') {
        // DAO 接收明文编辑数据；直接传入加密备份必须拒绝，不能二次加密。
        if (this.isStoredCiphertext(value)) {
          throw new Error('不能将设备密文作为新凭据导入，请重新输入');
        }
        config[key] = await this.codec.encrypt(value, table + ':' + key);
      }
    }
    return JSON.stringify(config);
  }
}
