import cryptoFramework from '@ohos.security.cryptoFramework';
import buffer from '@ohos.buffer';

/**
 * 加密工具类
 * 使用 AES-256-CBC 模式加密敏感数据
 */
export class CryptoUtil {
  // 使用应用 bundleName 作为密钥派生的基础
  private static readonly APP_SECRET = "com.yao.vidalltv";
  private static readonly SALT = "vidall_tv_salt_2024";
  private static readonly KEY_SIZE = 32; // 256 bits
  private static readonly IV_SIZE = 16; // CBC 需要 16 字节 IV

  /**
   * 派生 AES 密钥
   * 使用 SHA-256 从应用密钥派生 32 字节密钥
   */
  private static async deriveKey(): Promise<Uint8Array> {
    try {
      // 组合密钥材料
      const keyMaterial = CryptoUtil.APP_SECRET + CryptoUtil.SALT;
      const keyData = buffer.from(keyMaterial, 'utf-8');

      // 使用 SHA-256 生成 32 字节密钥
      const md = cryptoFramework.createMd('SHA256');
      await md.update({ data: new Uint8Array(keyData.buffer) });
      const digest = await md.digest();

      return new Uint8Array(digest.data);
    } catch (error) {
      console.error('CryptoUtil: Failed to derive key', JSON.stringify(error));
      throw new Error('密钥派生失败');
    }
  }

  /**
   * 加密字符串
   * @param plaintext 明文字符串
   * @returns 加密后的字符串，格式：iv:ciphertext (Base64编码)
   */
  static async encrypt(plaintext: string): Promise<string> {
    try {
      console.info('CryptoUtil: Starting encryption...');

      // 派生密钥
      console.info('CryptoUtil: Deriving key...');
      const keyData = await CryptoUtil.deriveKey();
      console.info('CryptoUtil: Key derived, length:', keyData.length);

      // 生成随机 IV
      console.info('CryptoUtil: Generating random IV...');
      const iv = cryptoFramework.createRandom().generateRandomSync(CryptoUtil.IV_SIZE).data;
      console.info('CryptoUtil: IV generated, length:', iv.length);

      // 创建对称密钥
      console.info('CryptoUtil: Creating symmetric key...');
      const keyBlob: cryptoFramework.DataBlob = {
        data: keyData
      };
      const symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256');
      const symKey = await symKeyGenerator.convertKey(keyBlob);
      console.info('CryptoUtil: Symmetric key created');

      // 创建加密器（使用 CBC 模式 + PKCS7 填充）
      console.info('CryptoUtil: Creating cipher...');
      const cipher = cryptoFramework.createCipher('AES256|CBC|PKCS7');
      const ivParams: cryptoFramework.IvParamsSpec = {
        algName: 'IvParamsSpec',
        iv: { data: iv }
      };

      console.info('CryptoUtil: Initializing cipher...');
      await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, ivParams);
      console.info('CryptoUtil: Cipher initialized');

      // 加密数据
      console.info('CryptoUtil: Encrypting data...');
      const plaintextData = buffer.from(plaintext, 'utf-8').buffer;
      const encryptData = await cipher.doFinal({ data: new Uint8Array(plaintextData) });
      console.info('CryptoUtil: Data encrypted');

      // 转换为 Base64 并组合
      const ivBase64 = buffer.from(iv.buffer).toString('base64');
      const ciphertextBase64 = buffer.from(encryptData.data.buffer).toString('base64');

      console.info('CryptoUtil: Encryption completed successfully');
      return `${ivBase64}:${ciphertextBase64}`;
    } catch (error) {
      console.error('CryptoUtil: Encryption failed', JSON.stringify(error));
      throw new Error('加密失败: ' + JSON.stringify(error));
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

      // 派生密钥
      const keyData = await CryptoUtil.deriveKey();

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
      console.error('CryptoUtil: Decryption failed', JSON.stringify(error));
      throw new Error('解密失败');
    }
  }
}

