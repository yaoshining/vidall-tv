import cryptoFramework from '@ohos.security.cryptoFramework';
import buffer from '@ohos.buffer';

/**
 * 仅用于读取旧版本密文。禁止添加旧格式写入能力。
 */
export class LegacyCredentialReader {
  // 使用应用 bundleName 作为密钥派生的基础
  private static readonly APP_SECRET = "com.yao.vidalltv";
  private static readonly SALT = "vidall_tv_salt_2024";

  /**
   * 派生 AES 密钥
   * 使用 SHA-256 从应用密钥派生 32 字节密钥
   */
  private static async deriveKey(): Promise<Uint8Array> {
    try {
      // 组合密钥材料
      const keyMaterial = LegacyCredentialReader.APP_SECRET + LegacyCredentialReader.SALT;
      const keyData = buffer.from(keyMaterial, 'utf-8');

      // 使用 SHA-256 生成 32 字节密钥
      const md = cryptoFramework.createMd('SHA256');
      await md.update({ data: new Uint8Array(keyData.buffer) });
      const digest = await md.digest();

      return new Uint8Array(digest.data);
    } catch (error) {
      throw new Error('密钥派生失败');
    }
  }

  /**
   * 解密字符串
   * @param encrypted 加密字符串，格式：iv:ciphertext (Base64编码)
   * @returns 解密后的明文字符串
   */
  static async decrypt(encrypted: string): Promise<string> {
    try {
      // 解析加密字符串
      const parts = encrypted.split(':');
      if (parts.length !== 2) {
        throw new Error('加密数据格式错误');
      }

      const iv = new Uint8Array(buffer.from(parts[0], 'base64').buffer);
      const ciphertext = new Uint8Array(buffer.from(parts[1], 'base64').buffer);
      if (iv.length !== 16 || ciphertext.length === 0 || ciphertext.length % 16 !== 0 ||
        buffer.from(iv).toString('base64') !== parts[0] ||
        buffer.from(ciphertext).toString('base64') !== parts[1]) { throw new Error('旧凭据格式错误'); }

      // 派生密钥
      const keyData = await LegacyCredentialReader.deriveKey();

      // 创建对称密钥
      const keyBlob: cryptoFramework.DataBlob = {
        data: keyData
      };
      const symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256');
      const symKey = await symKeyGenerator.convertKey(keyBlob);

      // 创建解密器（使用 CBC 模式 + PKCS7 填充）
      const decipher = cryptoFramework.createCipher('AES256|CBC|PKCS7');
      const ivParams: cryptoFramework.IvParamsSpec = {
        algName: 'IvParamsSpec',
        iv: { data: iv }
      };

      await decipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, ivParams);

      // 解密数据
      const decryptData = await decipher.doFinal({ data: ciphertext });

      // 转换为字符串
      return buffer.from(decryptData.data.buffer).toString('utf-8');
    } catch (error) {
      throw new Error('解密失败');
    }
  }
}

