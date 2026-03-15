import { describe, it, expect } from '@ohos/hypium';
import {
  classifyTlsError,
  isTlsError,
  normalizeTlsCertPolicy,
  sanitizeUrlForAudit,
} from '../main/ets/lib/WebDAVClient';

export default function webDAVClientUtilsTest() {
  // ─── classifyTlsError ────────────────────────────────────────────────────

  describe('classifyTlsError', () => {
    it('CURL:35 → TLS 握手错误', 0, () => {
      const msg = classifyTlsError('[CURL:35] SSL connect error');
      expect(msg).assertContain('TLS 连接失败');
      expect(msg).assertContain('握手错误');
    });

    it('CURL:60 → TLS 证书验证失败', 0, () => {
      const msg = classifyTlsError('[CURL:60] SSL peer certificate or SSH remote key was not OK');
      expect(msg).assertContain('TLS 证书验证失败');
      expect(msg).assertContain('证书');
    });

    it('CURL:58 → TLS 客户端证书错误', 0, () => {
      const msg = classifyTlsError('[CURL:58] problem with the local SSL certificate');
      expect(msg).assertEqual('TLS 客户端证书错误');
    });

    it('CURL:59 → TLS 加密套件协商失败', 0, () => {
      const msg = classifyTlsError('[CURL:59] Couldn\'t connect to server');
      expect(msg).assertEqual('TLS 加密套件协商失败');
    });

    it('CURL:77 → TLS CA 证书文件异常', 0, () => {
      const msg = classifyTlsError('[CURL:77] error setting certificate file');
      expect(msg).assertEqual('TLS CA 证书文件异常');
    });

    it('CURL:91 → OCSP 验证失败', 0, () => {
      const msg = classifyTlsError('[CURL:91] OCSP failed');
      expect(msg).assertContain('OCSP');
    });

    it('未知 CURL 错误码 → 通用 TLS 错误', 0, () => {
      const msg = classifyTlsError('[CURL:999] some unknown error');
      expect(msg).assertContain('TLS 错误');
      expect(msg).assertContain('999');
    });

    it('非 CURL 前缀 → 返回 null', 0, () => {
      const msg = classifyTlsError('Connection refused');
      expect(msg).assertNull();
    });

    it('空字符串 → 返回 null', 0, () => {
      const msg = classifyTlsError('');
      expect(msg).assertNull();
    });

    it('[CURL: 前缀但无闭合括号 → 返回 null', 0, () => {
      const msg = classifyTlsError('[CURL:60 no closing bracket');
      expect(msg).assertNull();
    });
  });

  // ─── isTlsError ─────────────────────────────────────────────────────────

  describe('isTlsError', () => {
    it('[CURL:35] 前缀 → true', 0, () => {
      expect(isTlsError('[CURL:35] SSL connect error')).assertTrue();
    });

    it('[CURL:60] 前缀 → true', 0, () => {
      expect(isTlsError('[CURL:60] SSL peer certificate error')).assertTrue();
    });

    it('[CURL:58] 前缀 → true', 0, () => {
      expect(isTlsError('[CURL:58] local certificate')).assertTrue();
    });

    it('[CURL:59] 前缀 → true', 0, () => {
      expect(isTlsError('[CURL:59] cipher')).assertTrue();
    });

    it('[CURL:77] 前缀 → true', 0, () => {
      expect(isTlsError('[CURL:77] CA cert error')).assertTrue();
    });

    it('[CURL:91] 前缀 → true', 0, () => {
      expect(isTlsError('[CURL:91] OCSP error')).assertTrue();
    });

    it('TLS 前缀（已分类消息）→ true', 0, () => {
      expect(isTlsError('TLS 证书验证失败：证书可能已过期')).assertTrue();
    });

    it('包含 [CURL:60] 的中间字符串 → true', 0, () => {
      expect(isTlsError('native transport failed: [CURL:60] SSL error')).assertTrue();
    });

    it('普通网络错误 → false', 0, () => {
      expect(isTlsError('Connection refused')).assertFalse();
    });

    it('HTTP 4xx 错误 → false', 0, () => {
      expect(isTlsError('HTTP 401: Unauthorized')).assertFalse();
    });

    it('空字符串 → false', 0, () => {
      expect(isTlsError('')).assertFalse();
    });

    it('未知 CURL 错误码（非 TLS）→ false', 0, () => {
      expect(isTlsError('[CURL:7] Connection refused')).assertFalse();
    });
  });

  // ─── normalizeTlsCertPolicy ──────────────────────────────────────────────

  describe('normalizeTlsCertPolicy', () => {
    it('undefined → allow_self_signed（家庭网络默认）', 0, () => {
      expect(normalizeTlsCertPolicy(undefined)).assertEqual('allow_self_signed');
    });

    it('未传参 → allow_self_signed', 0, () => {
      expect(normalizeTlsCertPolicy()).assertEqual('allow_self_signed');
    });

    it("'strict' → strict", 0, () => {
      expect(normalizeTlsCertPolicy('strict')).assertEqual('strict');
    });

    it("'allow_self_signed' → allow_self_signed", 0, () => {
      expect(normalizeTlsCertPolicy('allow_self_signed')).assertEqual('allow_self_signed');
    });

    it('未知值 → allow_self_signed（降级宽松）', 0, () => {
      expect(normalizeTlsCertPolicy('unknown_value')).assertEqual('allow_self_signed');
    });
  });

  // ─── sanitizeUrlForAudit ─────────────────────────────────────────────────

  describe('sanitizeUrlForAudit', () => {
    it('含 Basic Auth 凭据的 URL → 凭据替换为 ***', 0, () => {
      const raw = 'https://user:password123@dav.example.com/dav';
      const result = sanitizeUrlForAudit(raw);
      expect(result).assertEqual('https://***:***@dav.example.com/dav');
      expect(result).assertContain('***:***');
    });

    it('不含凭据的 URL → 保持原样', 0, () => {
      const raw = 'https://dav.example.com/dav';
      const result = sanitizeUrlForAudit(raw);
      expect(result).assertEqual(raw);
    });

    it('含特殊字符密码的 URL → 凭据被脱敏', 0, () => {
      const raw = 'https://admin:P@$$w0rd@192.168.1.1:8080/dav';
      const result = sanitizeUrlForAudit(raw);
      expect(result).assertContain('***:***@');
      expect(result).assertContain('192.168.1.1:8080/dav');
    });
  });
}
