import { huks } from '@kit.UniversalKeystoreKit';
import cryptoFramework from '@ohos.security.cryptoFramework';
import buffer from '@ohos.buffer';
import { LegacyCredentialReader } from './LegacyCredentialReader';

/** 密钥材料只在 HUKS 内生成和使用；别名不是密钥。删除数据源不删除共享密钥。 */
export class CredentialCipher {
  private alias: string;
  private creating: Promise<void> | null = null;

  constructor(alias: string) { this.alias = alias; }

  private properties(purpose: number): huks.HuksParam[] {
    return [
      { tag: huks.HuksTag.HUKS_TAG_AUTH_STORAGE_LEVEL, value: huks.HuksAuthStorageLevel.HUKS_AUTH_STORAGE_LEVEL_DE },
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM }
    ];
  }

  private storageOptions(): huks.HuksOptions {
    return { properties: [
      { tag: huks.HuksTag.HUKS_TAG_AUTH_STORAGE_LEVEL, value: huks.HuksAuthStorageLevel.HUKS_AUTH_STORAGE_LEVEL_DE }
    ] };
  }

  private async createIfMissing(): Promise<void> {
    if (!await huks.hasKeyItem(this.alias, this.storageOptions())) {
      await huks.generateKeyItem(this.alias, { properties: this.properties(
        huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT) });
    }
  }

  private async ensureKey(): Promise<void> {
    if (this.creating === null) { this.creating = this.createIfMissing(); }
    try { await this.creating; } finally { this.creating = null; }
  }

  private async crypt(data: Uint8Array, nonce: Uint8Array, scope: string,
    encrypt: boolean, tag?: Uint8Array): Promise<Uint8Array> {
    const properties = this.properties(encrypt ? huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT :
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT);
    properties.push({ tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce });
    properties.push({ tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA,
      value: new Uint8Array(buffer.from('vidall:v2:' + scope, 'utf-8').buffer) });
    if (tag !== undefined) { properties.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: tag }); }
    const session = await huks.initSession(this.alias, { properties });
    try {
      const result = await huks.finishSession(session.handle, { properties, inData: data });
      if (result.outData === undefined) { throw new Error('凭据加解密失败'); }
      return result.outData;
    } catch (e) {
      try { await huks.abortSession(session.handle, { properties: [] }); } catch (e) { }
      throw new Error('凭据加解密失败');
    }
  }

  async encrypt(value: string, scope: string): Promise<string> {
    try {
      await this.ensureKey();
      const nonce = cryptoFramework.createRandom().generateRandomSync(12).data;
      const out = await this.crypt(new Uint8Array(buffer.from('1' + value, 'utf-8').buffer), nonce, scope, true);
      return 'v2:' + buffer.from(nonce).toString('base64') + ':' + buffer.from(out).toString('base64');
    } catch (e) { throw new Error('凭据保护失败，请重试；原数据未修改'); }
  }

  async decrypt(value: string, scope: string): Promise<string> {
    try {
      if (!value.startsWith('v2:')) { return await LegacyCredentialReader.decrypt(value); }
      const parts = value.split(':');
      if (parts.length !== 3) { throw new Error('格式错误'); }
      const nonce = this.decode(parts[1]);
      const encrypted = this.decode(parts[2]);
      if (nonce.length !== 12 || encrypted.length < 16) { throw new Error('格式错误'); }
      // 读取绝不创建或替换密钥；恢复到其他设备时显式失败，原密文仍保留。
      if (!await huks.hasKeyItem(this.alias, this.storageOptions())) { throw new Error('密钥缺失'); }
      const out = await this.crypt(encrypted.slice(0, -16), nonce, scope, false, encrypted.slice(-16));
      const decoded = buffer.from(out).toString('utf-8');
      if (!decoded.startsWith('1')) { throw new Error('凭据内容格式错误'); }
      return decoded.slice(1);
    } catch (e) { throw new Error('凭据无法读取，请重试或在设置中重新输入；原凭据已保留'); }
  }

  private decode(value: string): Uint8Array {
    const bytes = new Uint8Array(buffer.from(value, 'base64').buffer);
    if (buffer.from(bytes).toString('base64') !== value) { throw new Error('格式错误'); }
    return bytes;
  }
}

export class CryptoUtil {
  private static cipher: CredentialCipher = new CredentialCipher('vidall.credentials.aesgcm.v2');
  static encrypt(value: string, scope: string = ''): Promise<string> {
    return CryptoUtil.cipher.encrypt(value, scope);
  }
  static decrypt(value: string, scope: string = ''): Promise<string> {
    return CryptoUtil.cipher.decrypt(value, scope);
  }
}
