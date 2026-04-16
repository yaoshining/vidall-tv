import { describe, it, expect } from '@ohos/hypium';
import { ValidationUtil } from '../main/ets/utils/ValidationUtil';

export default function ValidationUtilTest() {

  // ─── validateUrl ────────────────────────────────────────────────────────────

  describe('ValidationUtil.validateUrl', () => {

    // Happy path

    it('有效 IPv4 地址应通过验证', 0, () => {
      const result = ValidationUtil.validateUrl('192.168.1.100');
      expect(result.valid).assertTrue();
    });

    it('带端口的有效 IPv4 地址应通过验证', 0, () => {
      const result = ValidationUtil.validateUrl('192.168.1.100:5005');
      expect(result.valid).assertTrue();
    });

    it('有效域名应通过验证', 0, () => {
      const result = ValidationUtil.validateUrl('nas.example.com');
      expect(result.valid).assertTrue();
    });

    it('带端口的有效域名应通过验证', 0, () => {
      const result = ValidationUtil.validateUrl('nas.example.com:443');
      expect(result.valid).assertTrue();
    });

    it('多级子域名应通过验证', 0, () => {
      const result = ValidationUtil.validateUrl('storage.home.local');
      expect(result.valid).assertTrue();
    });

    // 负向

    it('空字符串应返回无效', 0, () => {
      const result = ValidationUtil.validateUrl('');
      expect(result.valid).assertFalse();
      expect(result.message.length > 0).assertTrue();
    });

    it('纯空格应返回无效', 0, () => {
      const result = ValidationUtil.validateUrl('   ');
      expect(result.valid).assertFalse();
    });

    it('包含 http:// 前缀应返回无效', 0, () => {
      const result = ValidationUtil.validateUrl('http://192.168.1.1');
      expect(result.valid).assertFalse();
    });

    it('包含 https:// 前缀应返回无效', 0, () => {
      const result = ValidationUtil.validateUrl('https://nas.example.com');
      expect(result.valid).assertFalse();
    });

    it('包含路径的地址应返回无效', 0, () => {
      const result = ValidationUtil.validateUrl('192.168.1.1/dav');
      expect(result.valid).assertFalse();
    });

    it('无点的单词（如 localhost）应返回无效', 0, () => {
      const result = ValidationUtil.validateUrl('localhost');
      expect(result.valid).assertFalse();
    });
  });

  // ─── validatePort ──────────────────────────────────────────────────────────

  describe('ValidationUtil.validatePort', () => {

    it('端口 1（最小有效值）应通过验证', 0, () => {
      expect(ValidationUtil.validatePort(1).valid).assertTrue();
    });

    it('端口 65535（最大有效值）应通过验证', 0, () => {
      expect(ValidationUtil.validatePort(65535).valid).assertTrue();
    });

    it('常用端口 80 应通过验证', 0, () => {
      expect(ValidationUtil.validatePort(80).valid).assertTrue();
    });

    it('端口 0 应返回无效', 0, () => {
      const result = ValidationUtil.validatePort(0);
      expect(result.valid).assertFalse();
    });

    it('端口 65536（超出范围）应返回无效', 0, () => {
      const result = ValidationUtil.validatePort(65536);
      expect(result.valid).assertFalse();
    });

    it('负数端口应返回无效', 0, () => {
      const result = ValidationUtil.validatePort(-1);
      expect(result.valid).assertFalse();
    });
  });

  // ─── validateNotEmpty ──────────────────────────────────────────────────────

  describe('ValidationUtil.validateNotEmpty', () => {

    it('非空字符串应通过验证', 0, () => {
      expect(ValidationUtil.validateNotEmpty('admin', '用户名').valid).assertTrue();
    });

    it('单字符字符串应通过验证', 0, () => {
      expect(ValidationUtil.validateNotEmpty('a', '字段').valid).assertTrue();
    });

    it('空字符串应返回无效并包含字段名', 0, () => {
      const result = ValidationUtil.validateNotEmpty('', '用户名');
      expect(result.valid).assertFalse();
      expect(result.message.includes('用户名')).assertTrue();
    });

    it('纯空格应返回无效', 0, () => {
      const result = ValidationUtil.validateNotEmpty('   ', '密码');
      expect(result.valid).assertFalse();
    });
  });
}
