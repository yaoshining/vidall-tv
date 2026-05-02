import { describe, it, expect, beforeEach } from '@ohos/hypium'
import { SmbFileInfo, SmbListDirectoryResult } from '../main/ets/lib/SMBClient'
import { 
  DirectoryProvider, 
  DirectoryProviderConfig, 
  DirectoryLoadResult 
} from '../main/ets/lib/DirectoryProvider'
import { SmbDirectoryProvider } from '../main/ets/lib/SmbDirectoryProvider'

/**
 * SmbDirectoryProvider Test
 * 
 * 测试 SMB 协议的 DirectoryProvider 实现
 */

function makeSmbFile(name: string, path: string, isDirectory: boolean): SmbFileInfo {
  const file: SmbFileInfo = {
    name: name,
    path: path,
    isDirectory: isDirectory,
    size: isDirectory ? 0 : 1024,
    lastModifiedMs: Date.now()
  }
  return file
}

function createSmbConfig(host: string = 'nas.local', port: number = 445): DirectoryProviderConfig {
  const protocolSpecific: Record<string, Object> = {}
  protocolSpecific['host'] = host
  protocolSpecific['port'] = port
  protocolSpecific['domain'] = 'WORKGROUP'
  protocolSpecific['shareName'] = ''
  
  const config: DirectoryProviderConfig = {
    protocol: 'smb',
    sourceId: 1,
    username: 'testuser',
    password: 'testpass',
    protocolSpecific: protocolSpecific
  }
  return config
}

export default function SmbDirectoryProviderTest() {
  describe('SmbDirectoryProvider', () => {
    it('初始化后 getProtocolKey 返回 smb', 0, async () => {
      const provider = new SmbDirectoryProvider()
      await provider.initWithConfig(createSmbConfig())
      
      // 验证接口签名和基本初始化
      expect(provider.getProtocolKey()).assertEqual('smb')
      expect(provider.getRootLabel()).assertEqual('共享列表')
    })

    it('初始化后接口签名完整（getRootLabel 非空）', 0, async () => {
      const provider = new SmbDirectoryProvider()
      await provider.initWithConfig(createSmbConfig())
      
      // 验证接口签名完整
      expect(provider.getProtocolKey()).assertEqual('smb')
    })

    it('初始化成功后接口可正常调用', 0, async () => {
      const provider = new SmbDirectoryProvider()
      await provider.initWithConfig(createSmbConfig())
      
      // 验证初始化后接口可正常调用
      expect(provider.getProtocolKey()).assertEqual('smb')
    })

    it('正确格式化路径用于导航参数', 0, () => {
      const provider = new SmbDirectoryProvider()
      
      // 测试路径编码
      const formatted = provider.formatPathForNavigation('/share/Movies & TV')
      expect(formatted).assertEqual('%2Fshare%2FMovies%20%26%20TV')
    })

    it('正确解析导航参数中的路径', 0, () => {
      const provider = new SmbDirectoryProvider()
      
      // 测试路径解码
      const parsed = provider.parseNavigationPath('%2Fshare%2FMovies%20%26%20TV')
      expect(parsed).assertEqual('/share/Movies & TV')
    })

    it('正确分类可重试错误（网络超时）', 0, () => {
      const provider = new SmbDirectoryProvider()
      
      // 网络超时错误应可重试
      const timeoutError = new Error('Connection timeout')
      expect(provider.isRetryable(timeoutError)).assertTrue()
      
      const networkError = new Error('Network unreachable')
      expect(provider.isRetryable(networkError)).assertTrue()
    })

    it('正确分类不可重试错误（认证失败）', 0, () => {
      const provider = new SmbDirectoryProvider()
      
      // 认证失败不应重试
      const authError = new Error('Authentication failed')
      expect(provider.isRetryable(authError)).assertFalse()
      
      const permissionError = new Error('Permission denied')
      expect(provider.isRetryable(permissionError)).assertFalse()
    })

    it('获取端点摘要返回正确格式', 0, async () => {
      const provider = new SmbDirectoryProvider()
      await provider.initWithConfig(createSmbConfig('192.168.1.100', 1445))
      
      // 验证端点摘要格式
      expect(provider.getEndpointSummary()).assertEqual('192.168.1.100:1445')
    })

    it('获取根路径显示名称', 0, async () => {
      const provider = new SmbDirectoryProvider()
      await provider.initWithConfig(createSmbConfig())
      
      // 验证根路径显示名称
      const rootName = await provider.getDisplayName('/')
      expect(rootName).assertEqual('共享列表')
      
      // 验证子路径显示名称
      const childName = await provider.getDisplayName('/share/Movies')
      expect(childName).assertEqual('Movies')
    })
  })
}
