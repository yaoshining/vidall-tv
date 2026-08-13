/**
 * WebDAV 客户端纯工具函数（可单元测试）。
 * 拆分自 WebDAVClient.ets，无状态、无外部依赖。
 */

/**
 * 将 CURL TLS 错误码转换为用户友好的中文提示。
 * 返回 null 表示不是可识别的 TLS 错误。
 */
export function classifyTlsError(errorMsg: string): string | null {
  if (!errorMsg.startsWith('[CURL:')) {
    return null;
  }
  const bracketEnd = errorMsg.indexOf(']');
  if (bracketEnd < 0) {
    return null;
  }
  const codeStr = errorMsg.substring(6, bracketEnd);
  const code = parseInt(codeStr);
  if (code !== code) {
    return null;
  }
  if (code === 35) {
    return 'TLS 连接失败：握手错误，请检查服务器 TLS 配置';
  }
  if (code === 60) {
    return 'TLS 证书验证失败：证书可能已过期、域名不匹配或颁发机构不受信任';
  }
  if (code === 58) {
    return 'TLS 客户端证书错误';
  }
  if (code === 59) {
    return 'TLS 加密套件协商失败';
  }
  if (code === 77) {
    return 'TLS CA 证书文件异常';
  }
  if (code === 91) {
    return 'TLS 证书状态无效（OCSP 验证失败）';
  }
  return 'TLS 错误（CURL 错误码：' + code + '）';
}

/** 判断错误消息是否为 TLS 相关错误 */
export function isTlsError(errorMsg: string): boolean {
  return errorMsg.startsWith('[CURL:35]') ||
         errorMsg.startsWith('[CURL:58]') ||
         errorMsg.startsWith('[CURL:59]') ||
         errorMsg.startsWith('[CURL:60]') ||
         errorMsg.startsWith('[CURL:77]') ||
         errorMsg.startsWith('[CURL:91]') ||
         errorMsg.startsWith('TLS ') ||
         errorMsg.includes('[CURL:35]') ||
         errorMsg.includes('[CURL:60]');
}

/**
 * 将 tlsCertPolicy 配置值归一化。
 * 默认 allow_self_signed（家庭网络优先易用性）；仅显式传 'strict' 时才严格校验。
 */
export function normalizeTlsCertPolicy(policy?: string): string {
  return policy === 'strict' ? 'strict' : 'allow_self_signed';
}

/** 对审计日志中的 URL 进行脱敏处理（去除 Basic Auth 凭据） */
export function sanitizeUrlForAudit(rawUrl: string): string {
  return rawUrl.replace(/:\/\/([^:@]+):([^@]+)@/, '://***:***@');
}

/** 仅在存在有效凭据时向媒体请求附加 Authorization。 */
export function buildWebDavHttpHeader(authHeader: string): Record<string, string> {
  if (authHeader.length === 0) {
    return {};
  }
  const headers: Record<string, string> = { 'Authorization': authHeader };
  return headers;
}
