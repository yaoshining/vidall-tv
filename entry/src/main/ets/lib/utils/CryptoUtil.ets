import cryptoFramework from '@ohos.security.cryptoFramework';
import buffer from '@ohos.buffer';

/**
 * 加密工具类
 * 使用 AES-256-GCM 模式加密敏感数据
 */
export class CryptoUtil {
  // 使用应用 bundleName 作为密钥派生的基础
  private static readonly APP_SECRET = "com.yao.vidalltv";
  private static readonly SALT = "vidall_tv_salt_2024";
  private static readonly KEY_SIZE = 32; // 256 bits
  private static readonly IV_SIZE = 12; // GCM 推荐 12 字节
  private static readonly TAG_SIZE = 16; // GCM 认证标签 16 字节

  /**
   * 派生 AES 密钥
   * 使用 PBKDF2 从应用密钥派生 32 字节密钥
   */
  private static async deriveKey(): Promise<Uint8Array> {
    try {
      // 组合密钥材料
      const keyMaterial = CryptoUtil.APP_SECRET + CryptoUtil.SALT;
      const keyData = buffer.from(keyMaterial, 'utf-8').buffer;

      // 创建 PBKDF2 参数
      const pbkdf2Spec: cryptoFramework.PBKDF2Spec = {
        algName: 'PBKDF2',
        password: new Uint8Array(keyData),
        salt: new Uint8Array(buffer.from(CryptoUtil.SALT, 'utf-8').buffer),
        iterations: 10000,
        keySize: CryptoUtil.KEY_SIZE * 8 // 转换为 bits
      };

      // 生成密钥
      const kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
      const derivedKey = await kdf.generateSecret(pbkdf2Spec);
      return new Uint8Array(derivedKey.data);
    } catch (error) {
      console.error('CryptoUtil: Failed to derive key', JSON.stringify(error));
      throw new Error('密钥派生失败');
    }
  }

  /**
   * 加密字符串
   * @param plaintext 明文字符串
   * @returns 加密后的字符串，格式：iv:ciphertext:authTag (Base64编码)
   */
  static async encrypt(plaintext: string): Promise<string> {
    try {
      // 派生密钥
      const keyData = await CryptoUtil.deriveKey();

      // 生成随机 IV
      const iv = cryptoFramework.createRandom().generateRandomSync(CryptoUtil.IV_SIZE).data;

      // 创建对称密钥
      const keyBlob: cryptoFramework.DataBlob = {
        data: keyData
      };
      const symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256');
      const symKey = await symKeyGenerator.convertKey(keyBlob);

      // 创建加密器
      const cipher = cryptoFramework.createCipher('AES256|GCM|PKCS7');
      const gcmParams: cryptoFramework.GcmParamsSpec = {
        iv: { data: iv },
        aad: { data: new Uint8Array(0) },
        authTag: { data: new Uint8Array(CryptoUtil.TAG_SIZE) },
        algName: 'GcmParamsSpec'
      };

      await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, gcmParams);

      // 加密数据
      const plaintextData = buffer.from(plaintext, 'utf-8').buffer;
      const encryptData = await cipher.doFinal({ data: new Uint8Array(plaintextData) });

      // 提取密文和认证标签
      const ciphertext = new Uint8Array(encryptData.data.buffer, 0, encryptData.data.length - CryptoUtil.TAG_SIZE);
      const authTag = new Uint8Array(encryptData.data.buffer, encryptData.data.length - CryptoUtil.TAG_SIZE, CryptoUtil.TAG_SIZE);

      // 转换为 Base64 并组合
      const ivBase64 = buffer.from(iv.buffer).toString('base64');
      const ciphertextBase64 = buffer.from(ciphertext.buffer).toString('base64');
      const authTagBase64 = buffer.from(authTag.buffer).toString('base64');

      return `${ivBase64}:${ciphertextBase64}:${authTagBase64}`;
    } catch (error) {
      console.error('CryptoUtil: Encryption failed', JSON.stringify(error));
      throw new Error('加密失败');
    }
  }

  /**
   * 解密字符串
   * @param encrypted 加密字符串，格式：iv:ciphertext:authTag (Base64编码)
   * @returns 解密后的明文字符串
   */
  static async decrypt(encrypted: string): Promise<string> {
    try {
      // 解析加密字符串
      const parts = encrypted.split(':');
      if (parts.length !== 3) {
        throw new Error('加密数据格式错误');
      }

      const iv = new Uint8Array(buffer.from(parts[0], 'base64').buffer);
      const ciphertext = new Uint8Array(buffer.from(parts[1], 'base64').buffer);
      const authTag = new Uint8Array(buffer.from(parts[2], 'base64').buffer);

      // 派生密钥
      const keyData = await CryptoUtil.deriveKey();

      // 创建对称密钥
      const keyBlob: cryptoFramework.DataBlob = {
        data: keyData
      };
      const symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256');
      const symKey = await symKeyGenerator.convertKey(keyBlob);

      // 创建解密器
      const decipher = cryptoFramework.createCipher('AES256|GCM|PKCS7');
      const gcmParams: cryptoFramework.GcmParamsSpec = {
        iv: { data: iv },
        aad: { data: new Uint8Array(0) },
        authTag: { data: authTag },
        algName: 'GcmParamsSpec'
      };

      await decipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, gcmParams);

      // 组合密文和认证标签
      const encryptedData = new Uint8Array(ciphertext.length + authTag.length);
      encryptedData.set(ciphertext, 0);
      encryptedData.set(authTag, ciphertext.length);

      // 解密数据
      const decryptData = await decipher.doFinal({ data: encryptedData });

      // 转换为字符串
      return buffer.from(decryptData.data.buffer).toString('utf-8');
    } catch (error) {
      console.error('CryptoUtil: Decryption failed', JSON.stringify(error));
      throw new Error('解密失败');
    }
  }
}

