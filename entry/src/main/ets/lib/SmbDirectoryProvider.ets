/**
 * SmbDirectoryProvider
 * 
 * SMB 协议的 DirectoryProvider 实现
 * 基于 SMBClient 提供目录浏览能力
 */

import { SMBClient, SMBClientConfig, SmbFileInfo, SmbListDirectoryResult } from '../lib/SMBClient'
import { SMBSourceConfig } from '../db/models/FileSourceEntity'
import { getFileExplorerErrorMessage } from '../components/core/file/FileExplorerAdapter'
import {
  DirectoryProvider,
  DirectoryProviderConfig,
  DirectoryEntry,
  DirectoryLoadResult
} from '../lib/DirectoryProvider'

/**
 * SMB Directory Provider 实现
 */
export class SmbDirectoryProvider implements DirectoryProvider {
  private smbClient?: SMBClient
  private endpointSummary: string = ''
  private config?: DirectoryProviderConfig

  /**
   * 初始化 SMB 提供者
   */
  async initWithConfig(config: DirectoryProviderConfig): Promise<void> {
    this.config = config
    
    // 从 protocolSpecific 中提取 SMB 配置
    const smbConfig = this.extractSmbConfig(config)
    
    // 创建 SMB 客户端
    this.smbClient = new SMBClient(smbConfig)
    
    // 构建端点摘要
    this.endpointSummary = `${smbConfig.host}:${smbConfig.port}`
  }

  /**
   * 清理资源
   */
  async cleanup(): Promise<void> {
    this.smbClient = undefined
    this.config = undefined
  }

  /**
   * 列出目录
   */
  async listDirectory(path: string): Promise<DirectoryLoadResult> {
    if (this.smbClient === undefined) {
      const errorResult: DirectoryLoadResult = {
        entries: [],
        errorMessage: 'SMB 客户端未初始化'
      }
      return errorResult
    }

    try {
      const result: SmbListDirectoryResult = await this.smbClient.listDirectory(path)
      
      // 只保留目录
      const directories = result.files.filter((file: SmbFileInfo) => file.isDirectory)
      
      // 转换为 DirectoryEntry
      const entries: DirectoryEntry[] = directories.map((file: SmbFileInfo) => {
        const entry: DirectoryEntry = {
          key: file.path,
          name: file.name,
          path: file.path,
          isDirectory: true
        }
        return entry
      })

      // 检查错误
      const errorMessage = result.error !== undefined && result.error.length > 0 && entries.length === 0
        ? result.error
        : undefined

      const loadResult: DirectoryLoadResult = {
        entries: entries,
        errorMessage: errorMessage
      }
      return loadResult
    } catch (error) {
      const errorResult: DirectoryLoadResult = {
        entries: [],
        errorMessage: getFileExplorerErrorMessage(error)
      }
      return errorResult
    }
  }

  /**
   * 获取显示名称
   */
  async getDisplayName(path: string): Promise<string> {
    if (path === '' || path === '/') {
      return this.getRootLabel()
    }
    const parts = path.split('/').filter((part: string) => part.length > 0)
    return parts.length > 0 ? parts[parts.length - 1] : this.getRootLabel()
  }

  /**
   * 格式化路径用于导航
   * SMB 路径使用 encodeURIComponent 编码
   */
  formatPathForNavigation(path: string): string {
    return encodeURIComponent(path)
  }

  /**
   * 解析导航路径
   */
  parseNavigationPath(navPath: string): string {
    return decodeURIComponent(navPath)
  }

  /**
   * 判断错误是否可重试
   * SMB 特定错误映射
   */
  isRetryable(error: Error): boolean {
    const errorMessage = error.message.toLowerCase()
    
    // 网络相关错误可重试
    const retryableKeywords = [
      'timeout',
      'network',
      'connection',
      'ETIMEDOUT',
      'ECONNREFUSED',
      'ECONNRESET',
      'temporarily unavailable'
    ]
    
    const isRetryable = retryableKeywords.some((keyword: string) => 
      errorMessage.includes(keyword.toLowerCase())
    )
    
    return isRetryable
  }

  /**
   * 获取协议标识
   */
  getProtocolKey(): string {
    return 'smb'
  }

  /**
   * 获取根路径标签
   */
  getRootLabel(): string {
    return '共享列表'
  }

  /**
   * 获取端点摘要
   */
  getEndpointSummary(): string {
    return this.endpointSummary
  }

  /**
   * 从通用配置中提取 SMB 特定配置
   */
  private extractSmbConfig(config: DirectoryProviderConfig): SMBClientConfig {
    const protocolSpecific = config.protocolSpecific ?? {}
    
    const host = this.readStringFromRecord(protocolSpecific, 'host', '')
    const port = this.readNumberFromRecord(protocolSpecific, 'port', 445)
    const domain = this.readStringFromRecord(protocolSpecific, 'domain', '')
    const shareName = this.readStringFromRecord(protocolSpecific, 'shareName', '')
    
    const smbConfig: SMBClientConfig = {
      host: host,
      port: port,
      username: config.username,
      password: config.password,
      domain: domain,
      shareName: shareName.length > 0 ? shareName : undefined
    }
    return smbConfig
  }

  /**
   * 从 Record 中读取字符串值
   */
  private readStringFromRecord(record: Record<string, Object>, key: string, defaultValue: string): string {
    const value = record[key]
    return typeof value === 'string' ? value : defaultValue
  }

  /**
   * 从 Record 中读取数字值
   */
  private readNumberFromRecord(record: Record<string, Object>, key: string, defaultValue: number): number {
    const value = record[key]
    return typeof value === 'number' ? value : defaultValue
  }
}

/**
 * 从 SMBSourceConfig 创建 DirectoryProviderConfig
 */
export function createSmbProviderConfig(sourceId: number, smbConfig: SMBSourceConfig): DirectoryProviderConfig {
  const protocolSpecific: Record<string, Object> = {}
  protocolSpecific['host'] = smbConfig.host
  protocolSpecific['port'] = smbConfig.port ?? 445
  protocolSpecific['domain'] = smbConfig.domain ?? ''
  protocolSpecific['shareName'] = ''

  const config: DirectoryProviderConfig = {
    protocol: 'smb',
    sourceId: sourceId,
    username: smbConfig.username,
    password: smbConfig.password,
    protocolSpecific: protocolSpecific
  }
  return config
}
