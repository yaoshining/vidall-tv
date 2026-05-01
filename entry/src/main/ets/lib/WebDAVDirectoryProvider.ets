/**
 * WebDAVDirectoryProvider
 * 
 * WebDAV 协议的 DirectoryProvider 实现
 * 基于 WebDAVClient 提供目录浏览能力
 */

import url from '@ohos.url'
import { WebDAVClient, WebDAVConfig, WebDAVResource } from '../lib/WebDAVClient'
import { WebDAVSourceConfig } from '../db/models/FileSourceEntity'
import { getFileExplorerErrorMessage } from '../components/core/file/FileExplorerAdapter'
import {
  DirectoryProvider,
  DirectoryProviderConfig,
  DirectoryEntry,
  DirectoryLoadResult
} from '../lib/DirectoryProvider'

/**
 * WebDAV Directory Provider 实现
 */
export class WebDAVDirectoryProvider implements DirectoryProvider {
  private webdavClient?: WebDAVClient
  private endpointSummary: string = ''
  private config?: DirectoryProviderConfig
  private currentPath: string = '/'

  /**
   * 初始化 WebDAV 提供者
   */
  async initWithConfig(config: DirectoryProviderConfig): Promise<void> {
    this.config = config
    
    // 从 protocolSpecific 中提取 WebDAV 配置
    const webdavConfig = this.extractWebDAVConfig(config)
    
    // 创建 WebDAV 客户端
    this.webdavClient = new WebDAVClient(webdavConfig)
    
    // 构建端点摘要
    const parsedUrl = new url.URL(webdavConfig.baseUrl)
    this.endpointSummary = `${parsedUrl.hostname}:${parsedUrl.port || (parsedUrl.protocol === 'https:' ? '443' : '80')}`
  }

  /**
   * 清理资源
   */
  async cleanup(): Promise<void> {
    this.webdavClient = undefined
    this.config = undefined
  }

  /**
   * 列出目录
   */
  async listDirectory(path: string): Promise<DirectoryLoadResult> {
    if (this.webdavClient === undefined) {
      const errorResult: DirectoryLoadResult = {
        entries: [],
        errorMessage: 'WebDAV 客户端未初始化'
      }
      return errorResult
    }

    try {
      this.currentPath = path
      const resources: WebDAVResource[] = await this.webdavClient.listDirectory(path)
      
      // 只保留目录（isCollection）
      const collections = resources
        .filter((resource: WebDAVResource) => resource.isCollection)
        // 跳过第一个（当前目录本身）
        .slice(1)
      
      // 转换为 DirectoryEntry
      const entries: DirectoryEntry[] = collections.map((resource: WebDAVResource) => {
        const childPath = this.joinPath(path, resource.displayName)
        const entry: DirectoryEntry = {
          key: childPath,
          name: resource.displayName,
          path: childPath,
          isDirectory: true
        }
        return entry
      })

      const loadResult: DirectoryLoadResult = {
        entries: entries
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
   * WebDAV 路径使用 encodeURIComponent 编码
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
   * WebDAV 特定错误映射
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
      '502',
      '503',
      '504',
      'temporarily unavailable',
      'service unavailable'
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
    return 'webdav'
  }

  /**
   * 获取根路径标签
   */
  getRootLabel(): string {
    return '根目录'
  }

  /**
   * 获取端点摘要
   */
  getEndpointSummary(): string {
    return this.endpointSummary
  }

  /**
   * 从通用配置中提取 WebDAV 特定配置
   */
  private extractWebDAVConfig(config: DirectoryProviderConfig): WebDAVConfig {
    const protocolSpecific = config.protocolSpecific ?? {}
    
    const baseUrl = this.readStringFromRecord(protocolSpecific, 'baseUrl', '')
    const tlsCertPolicy = this.readStringFromRecord(protocolSpecific, 'tlsCertPolicy', 'allow_self_signed')
    
    const webdavConfig: WebDAVConfig = {
      baseUrl: baseUrl,
      username: config.username,
      password: config.password,
      tlsCertPolicy: tlsCertPolicy === 'strict' ? 'strict' : 'allow_self_signed'
    }
    return webdavConfig
  }

  /**
   * 从 Record 中读取字符串值
   */
  private readStringFromRecord(record: Record<string, Object>, key: string, defaultValue: string): string {
    const value = record[key]
    return typeof value === 'string' ? value : defaultValue
  }

  /**
   * 拼接路径
   */
  private joinPath(parentPath: string, childName: string): string {
    if (parentPath === '/') {
      return '/' + childName
    }
    return parentPath.endsWith('/') ? parentPath + childName : parentPath + '/' + childName
  }
}

/**
 * 从 WebDAVSourceConfig 创建 DirectoryProviderConfig
 */
export function createWebDAVProviderConfig(sourceId: number, webdavConfig: WebDAVSourceConfig): DirectoryProviderConfig {
  // 构建 baseUrl
  let serverAddress = webdavConfig.url
  let port = webdavConfig.port
  if (serverAddress.includes(':')) {
    const parts = serverAddress.split(':')
    serverAddress = parts[0]
    const portInUrl = parseInt(parts[1], 10)
    if (!Number.isNaN(portInUrl)) {
      port = portInUrl
    }
  }
  let baseUrl = `${webdavConfig.protocol}://${serverAddress}:${port}`
  const normalizedPath = webdavConfig.rootPath.trim().length > 0 ? webdavConfig.rootPath.trim() : '/'
  if (normalizedPath !== '/') {
    baseUrl += normalizedPath.startsWith('/') ? normalizedPath : '/' + normalizedPath
  }

  const protocolSpecific: Record<string, Object> = {}
  protocolSpecific['baseUrl'] = baseUrl
  protocolSpecific['tlsCertPolicy'] = webdavConfig.tlsCertPolicy ?? 'allow_self_signed'

  const config: DirectoryProviderConfig = {
    protocol: 'webdav',
    sourceId: sourceId,
    username: webdavConfig.username,
    password: webdavConfig.password,
    protocolSpecific: protocolSpecific
  }
  return config
}
