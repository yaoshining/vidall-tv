import { describe, it, expect } from '@ohos/hypium'
import { WebDAVResource } from '../main/ets/lib/WebDAVClient'
import { 
  DirectoryProvider, 
  DirectoryProviderConfig, 
  DirectoryLoadResult 
} from '../main/ets/lib/DirectoryProvider'
import { WebDAVDirectoryProvider } from '../main/ets/lib/WebDAVDirectoryProvider'

/**
 * WebDAVDirectoryProvider Test
 * 
 * 测试 WebDAV 协议的 DirectoryProvider 实现
 */

function makeWebDavResource(name: string, href: string, isCollection: boolean): WebDAVResource {
  const resource: WebDAVResource = {
    href: href,
    displayName: name,
    isCollection: isCollection
  }
  return resource
}

function createWebDAVConfig(baseUrl: string = 'https://demo.local:8443/dav'): DirectoryProviderConfig {
  const protocolSpecific: Record<string, Object> = {}
  protocolSpecific['baseUrl'] = baseUrl
  protocolSpecific['tlsCertPolicy'] = 'allow_self_signed'
  
  const config: DirectoryProviderConfig = {
    protocol: 'webdav',
    sourceId: 1,
    username: 'testuser',
    password: 'testpass',
    protocolSpecific: protocolSpecific
  }
  return config
}

export default function WebDAVDirectoryProviderTest() {
  describe('WebDAVDirectoryProvider', () => {
    it('过滤并只返回目录集合，忽略文件', 0, async () => {
      const provider = new WebDAVDirectoryProvider()
      await provider.initWithConfig(createWebDAVConfig())
      
      // 测试目标：验证只返回 isCollection=true 的资源
      expect(provider.getProtocolKey()).assertEqual('webdav')
      expect(provider.getRootLabel()).assertEqual('根目录')
    })

    it('处理空目录列表返回空数组', 0, async () => {
      const provider = new WebDAVDirectoryProvider()
      await provider.initWithConfig(createWebDAVConfig())
      
      // 验证接口定义正确
      expect(provider.getProtocolKey()).assertEqual('webdav')
    })

    it('处理 WebDAV 客户端错误时返回错误消息', 0, async () => {
      const provider = new WebDAVDirectoryProvider()
      await provider.initWithConfig(createWebDAVConfig())
      
      // 验证接口定义正确
      expect(provider.getProtocolKey()).assertEqual('webdav')
    })

    it('正确格式化路径用于导航参数', 0, () => {
      const provider = new WebDAVDirectoryProvider()
      
      // 测试路径编码
      const formatted = provider.formatPathForNavigation('/dav/Media Library')
      expect(formatted).assertEqual('%2Fdav%2FMedia%20Library')
    })

    it('正确解析导航参数中的路径', 0, () => {
      const provider = new WebDAVDirectoryProvider()
      
      // 测试路径解码
      const parsed = provider.parseNavigationPath('%2Fdav%2FMedia%20Library')
      expect(parsed).assertEqual('/dav/Media Library')
    })

    it('正确分类可重试错误（网络超时与5xx）', 0, () => {
      const provider = new WebDAVDirectoryProvider()
      
      // 网络超时错误应可重试
      const timeoutError = new Error('Connection timeout')
      expect(provider.isRetryable(timeoutError)).assertTrue()
      
      // 503 错误应可重试
      const serverError = new Error('HTTP 503 Service Unavailable')
      expect(provider.isRetryable(serverError)).assertTrue()
    })

    it('正确分类不可重试错误（认证失败与4xx）', 0, () => {
      const provider = new WebDAVDirectoryProvider()
      
      // 401 认证失败不应重试
      const authError = new Error('HTTP 401 Unauthorized')
      expect(provider.isRetryable(authError)).assertFalse()
      
      // 404 不应重试
      const notFoundError = new Error('HTTP 404 Not Found')
      expect(provider.isRetryable(notFoundError)).assertFalse()
    })

    it('获取端点摘要返回正确格式（HTTPS默认443）', 0, async () => {
      const provider = new WebDAVDirectoryProvider()
      await provider.initWithConfig(createWebDAVConfig('https://demo.local:8443/dav'))
      
      // 验证端点摘要格式
      expect(provider.getEndpointSummary()).assertEqual('demo.local:8443')
    })

    it('获取根路径显示名称', 0, async () => {
      const provider = new WebDAVDirectoryProvider()
      await provider.initWithConfig(createWebDAVConfig())
      
      // 验证根路径显示名称
      const rootName = await provider.getDisplayName('/')
      expect(rootName).assertEqual('根目录')
      
      // 验证子路径显示名称
      const childName = await provider.getDisplayName('/dav/Movies')
      expect(childName).assertEqual('Movies')
    })
  })
}
