/**
 * 验证结果接口
 */
export interface ValidationResult {
  valid: boolean;
  message: string;
}

/**
 * 验证工具类
 * 提供各种输入验证功能
 */
export class ValidationUtil {
  /**
   * 验证 URL 格式
   * @param url URL 字符串（服务器地址，可以包含端口，但不包含路径）
   * @returns 验证结果和错误消息
   */
  static validateUrl(url: string): ValidationResult {
    // 检查是否为空
    if (!url || url.trim().length === 0) {
      const result: ValidationResult = {
        valid: false,
        message: '服务器地址不能为空'
      };
      return result;
    }

    // 去除可能的协议前缀（用户误输入的情况）
    let urlToValidate = url.trim();
    if (urlToValidate.startsWith('http://') || urlToValidate.startsWith('https://')) {
      const result: ValidationResult = {
        valid: false,
        message: '请不要包含协议前缀（http:// 或 https://），请在协议下拉框中选择'
      };
      return result;
    }

    // 检查是否包含路径（不应该包含）
    if (urlToValidate.includes('/')) {
      const result: ValidationResult = {
        valid: false,
        message: '服务器地址不应包含路径，请将路径填写在"路径"字段中'
      };
      return result;
    }

    // 验证 IP 地址格式（IPv4，可以包含端口）
    const ipPattern = /^(\d{1,3}\.){3}\d{1,3}(:\d+)?$/;
    // 验证域名格式（可以包含端口）
    const domainPattern = /^[\w\-]+(\.[\w\-]+)+(:\d+)?$/;

    if (!ipPattern.test(urlToValidate) && !domainPattern.test(urlToValidate)) {
      const result: ValidationResult = {
        valid: false,
        message: '请输入有效的服务器地址，例如：192.168.1.100:5445 或 nas.example.com'
      };
      return result;
    }

    const result: ValidationResult = {
      valid: true,
      message: ''
    };
    return result;
  }

  /**
   * 验证端口号
   * @param port 端口号
   * @returns 验证结果和错误消息
   */
  static validatePort(port: number): ValidationResult {
    if (port < 1 || port > 65535) {
      const result: ValidationResult = {
        valid: false,
        message: '端口号必须在 1-65535 之间'
      };
      return result;
    }

    const result: ValidationResult = {
      valid: true,
      message: ''
    };
    return result;
  }

  /**
   * 验证字段非空
   * @param value 字段值
   * @param fieldName 字段名称
   * @returns 验证结果和错误消息
   */
  static validateNotEmpty(value: string, fieldName: string): ValidationResult {
    if (!value || value.trim().length === 0) {
      const result: ValidationResult = {
        valid: false,
        message: `${fieldName}不能为空`
      };
      return result;
    }

    const result: ValidationResult = {
      valid: true,
      message: ''
    };
    return result;
  }
}





