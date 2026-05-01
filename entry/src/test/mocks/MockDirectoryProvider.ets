/**
 * MockDirectoryProvider
 * 
 * 测试用的 DirectoryProvider mock 实现
 * 支持配置化的响应行为，用于单元测试
 */

import {
  DirectoryProvider,
  DirectoryProviderConfig,
  DirectoryEntry,
  DirectoryLoadResult
} from "../../main/ets/lib/DirectoryProvider"

/**
 * Mock 配置接口
 */
export interface MockDirectoryProviderConfig {
  /** mock 响应的目录列表 */
  mockEntries?: DirectoryEntry[]
  
  /** 是否模拟初始化失败 */
  shouldFailInit?: boolean
  
  /** 是否模拟列表加载失败 */
  shouldFailList?: boolean
  
  /** 错误消息 */
  errorMessage?: string
  
  /** 协议标识 */
  protocolKey?: string
  
  /** 根路径标签 */
  rootLabel?: string
  
  /** 端点摘要 */
  endpointSummary?: string
}

/**
 * MockDirectoryProvider 实现
 */
export class MockDirectoryProvider implements DirectoryProvider {
  private config: DirectoryProviderConfig | null = null
  private mockConfig: MockDirectoryProviderConfig
  
  constructor(mockConfig: MockDirectoryProviderConfig = {}) {
    this.mockConfig = mockConfig
  }
  
  async initWithConfig(config: DirectoryProviderConfig): Promise<void> {
    if (this.mockConfig.shouldFailInit) {
      throw new Error(this.mockConfig.errorMessage ?? 'Mock init failed')
    }
    this.config = config
  }
  
  async cleanup(): Promise<void> {
    this.config = null
  }
  
  async listDirectory(path: string): Promise<DirectoryLoadResult> {
    if (this.mockConfig.shouldFailList) {
      const result: DirectoryLoadResult = {
        entries: [],
        errorMessage: this.mockConfig.errorMessage ?? 'Mock list failed'
      }
      return result
    }
    
    const result: DirectoryLoadResult = {
      entries: this.mockConfig.mockEntries ?? []
    }
    return result
  }
  
  async getDisplayName(path: string): Promise<string> {
    if (path === '' || path === '/') {
      return this.getRootLabel()
    }
    const parts = path.split('/').filter((p: string) => p.length > 0)
    return parts.length > 0 ? parts[parts.length - 1] : this.getRootLabel()
  }
  
  formatPathForNavigation(path: string): string {
    return encodeURIComponent(path)
  }
  
  parseNavigationPath(navPath: string): string {
    return decodeURIComponent(navPath)
  }
  
  isRetryable(error: Error): boolean {
    return error.message.includes('timeout') || error.message.includes('network')
  }
  
  getProtocolKey(): string {
    return this.mockConfig.protocolKey ?? 'mock'
  }
  
  getRootLabel(): string {
    return this.mockConfig.rootLabel ?? 'Mock Root'
  }
  
  getEndpointSummary(): string {
    return this.mockConfig.endpointSummary ?? 'mock://test'
  }
}
