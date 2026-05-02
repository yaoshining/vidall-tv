/**
 * DirectoryProvider Interface
 * 
 * 统一的目录提供者接口，定义协议无关的目录浏览能力
 * 所有协议实现（SMB、WebDAV、FTP等）必须实现此接口
 */

/**
 * 目录提供者配置接口
 * 包含初始化连接所需的通用参数
 */
export interface DirectoryProviderConfig {
  /** 协议类型标识 (smb, webdav, ftp 等) */
  protocol: string
  
  /** 数据源唯一标识 */
  sourceId: number
  
  /** 用户名 */
  username: string
  
  /** 密码 */
  password: string
  
  /** 协议特定配置（各协议自行扩展） */
  protocolSpecific?: Record<string, Object>
}

/**
 * 目录项接口
 * 表示目录浏览中的单个条目
 */
export interface DirectoryEntry {
  /** 唯一标识（通常为完整路径） */
  key: string
  
  /** 显示名称 */
  name: string
  
  /** 完整路径 */
  path: string
  
  /** 是否为目录 */
  isDirectory: boolean
}

/**
 * 目录加载结果
 */
export interface DirectoryLoadResult {
  /** 目录条目列表 */
  entries: DirectoryEntry[]
  
  /** 错误消息（如有） */
  errorMessage?: string
}

/**
 * DirectoryProvider 接口
 * 
 * 定义协议无关的目录浏览能力，确保所有协议实现行为一致
 */
export interface DirectoryProvider {
  /**
   * 初始化提供者
   * @param config 配置参数
   * @returns Promise<void> 初始化完成
   * @throws Error 如果配置无效或连接失败
   */
  initWithConfig(config: DirectoryProviderConfig): Promise<void>
  
  /**
   * 清理资源
   * 释放连接、清理缓存等
   * @returns Promise<void> 清理完成
   */
  cleanup(): Promise<void>
  
  /**
   * 列出指定路径下的目录
   * @param path 目录路径
   * @returns Promise<DirectoryLoadResult> 目录条目列表及可能的错误消息
   */
  listDirectory(path: string): Promise<DirectoryLoadResult>
  
  /**
   * 获取路径的显示名称
   * @param path 路径
   * @returns Promise<string> 显示名称
   */
  getDisplayName(path: string): Promise<string>
  
  /**
   * 格式化路径用于导航参数
   * 将内部路径格式转换为 URL 安全的导航参数格式
   * @param path 内部路径
   * @returns string URL 安全的导航路径
   */
  formatPathForNavigation(path: string): string
  
  /**
   * 解析导航参数中的路径
   * 将 URL 参数格式的路径还原为内部路径格式
   * @param navPath 导航路径参数
   * @returns string 内部路径
   */
  parseNavigationPath(navPath: string): string
  
  /**
   * 判断错误是否可重试
   * 区分瞬时错误（网络超时）和致命错误（认证失败）
   * @param error 错误对象
   * @returns boolean true 表示可重试（瞬时错误），false 表示致命错误
   */
  isRetryable(error: Error): boolean
  
  /**
   * 获取协议标识
   * @returns string 协议键（smb, webdav 等）
   */
  getProtocolKey(): string
  
  /**
   * 获取根路径标签
   * @returns string 根路径显示标签（如 "共享列表"、"根目录"）
   */
  getRootLabel(): string
  
  /**
   * 获取端点摘要
   * @returns string 端点描述（如 "192.168.1.100:445"）
   */
  getEndpointSummary(): string
}
