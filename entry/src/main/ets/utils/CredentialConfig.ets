/** 仅包含失败字段名，绝不包含密文或明文。随配置传递，避免被误当成匿名连接。 */
export const CREDENTIAL_FAILURE = '_credentialReadFailures';
export const CREDENTIAL_RECOVERY_MESSAGE = '凭据无法读取，原数据已保留。请重试加载，或重新输入失败字段后保存；跨设备恢复需要重新输入。';

export function parseCredentialConfig(json: string): Object {
  const config = JSON.parse(json) as Record<string, Object>;
  if (config[CREDENTIAL_FAILURE]) { throw new Error(CREDENTIAL_RECOVERY_MESSAGE); }
  return config;
}
