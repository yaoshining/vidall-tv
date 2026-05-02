import { describe, it, expect } from '@ohos/hypium'
import {
  DirectorySelectorRouteParams,
  createDirectorySelectorRouteParams,
  createDirectorySelectorSourceDescriptor
} from '../main/ets/pages/settings/directorySelector/DirectorySelectorContainer'

/**
 * DirectorySelectorContainer Test
 * 
 * 测试路由参数解析与 Provider 初始化
 */

function createRawRouteParams(
  sourceId: number,
  protocol: string,
  username: string,
  password: string,
  baseUrl?: string,
  host?: string,
  port?: number,
  domain?: string
): Record<string, Object> {
  const params: Record<string, Object> = {}
  params['sourceId'] = sourceId
  params['protocol'] = protocol
  params['username'] = username
  params['password'] = password
  if (baseUrl !== undefined) {
    params['baseUrl'] = baseUrl
  }
  if (host !== undefined) {
    params['host'] = host
  }
  if (port !== undefined) {
    params['port'] = port
  }
  if (domain !== undefined) {
    params['domain'] = domain
  }
  return params
}

export default function DirectorySelectorContainerTest() {
  describe('DirectorySelectorContainer', () => {
    it('解析完整的 WebDAV 路由参数', 0, () => {
      const rawParams = createRawRouteParams(
        10,
        'webdav',
        'testuser',
        'testpass',
        'https://demo.local:8443/dav'
      )
      
      const parsed = createDirectorySelectorRouteParams(rawParams)
      
      expect(parsed !== undefined).assertTrue()
      if (parsed !== undefined) {
        expect(parsed.sourceId).assertEqual(10)
        expect(parsed.protocol).assertEqual('webdav')
        expect(parsed.username).assertEqual('testuser')
        expect(parsed.password).assertEqual('testpass')
        expect(parsed.protocolSpecific['baseUrl']).assertEqual('https://demo.local:8443/dav')
      }
    })

    it('解析完整的 SMB 路由参数', 0, () => {
      const rawParams = createRawRouteParams(
        20,
        'smb',
        'testuser',
        'testpass',
        undefined,
        'nas.local',
        1445,
        'WORKGROUP'
      )
      
      const parsed = createDirectorySelectorRouteParams(rawParams)
      
      expect(parsed !== undefined).assertTrue()
      if (parsed !== undefined) {
        expect(parsed.sourceId).assertEqual(20)
        expect(parsed.protocol).assertEqual('smb')
        expect(parsed.username).assertEqual('testuser')
        expect(parsed.password).assertEqual('testpass')
        expect(parsed.protocolSpecific['host']).assertEqual('nas.local')
        expect(parsed.protocolSpecific['port']).assertEqual(1445)
        expect(parsed.protocolSpecific['domain']).assertEqual('WORKGROUP')
      }
    })

    it('兼容旧格式（baseUrl推断为WebDAV）', 0, () => {
      const rawParams: Record<string, Object> = {}
      rawParams['sourceId'] = 30
      rawParams['baseUrl'] = 'https://old.server:8080/dav'
      rawParams['username'] = 'olduser'
      rawParams['password'] = 'oldpass'
      
      const parsed = createDirectorySelectorRouteParams(rawParams)
      
      expect(parsed !== undefined).assertTrue()
      if (parsed !== undefined) {
        expect(parsed.protocol).assertEqual('webdav')
        expect(parsed.protocolSpecific['baseUrl']).assertEqual('https://old.server:8080/dav')
      }
    })

    it('兼容旧格式（host推断为SMB）', 0, () => {
      const rawParams: Record<string, Object> = {}
      rawParams['sourceId'] = 40
      rawParams['host'] = 'old.nas.local'
      rawParams['port'] = 445
      rawParams['username'] = 'olduser'
      rawParams['password'] = 'oldpass'
      
      const parsed = createDirectorySelectorRouteParams(rawParams)
      
      expect(parsed !== undefined).assertTrue()
      if (parsed !== undefined) {
        expect(parsed.protocol).assertEqual('smb')
        expect(parsed.protocolSpecific['host']).assertEqual('old.nas.local')
        expect(parsed.protocolSpecific['port']).assertEqual(445)
      }
    })

    it('拒绝无效的 sourceId（0）', 0, () => {
      const rawParams = createRawRouteParams(
        0,
        'webdav',
        'testuser',
        'testpass',
        'https://demo.local:8443/dav'
      )
      
      const parsed = createDirectorySelectorRouteParams(rawParams)
      
      expect(parsed === undefined).assertTrue()
    })

    it('拒绝无效的 sourceId（负数）', 0, () => {
      const rawParams = createRawRouteParams(
        -1,
        'smb',
        'testuser',
        'testpass',
        undefined,
        'nas.local',
        445
      )
      
      const parsed = createDirectorySelectorRouteParams(rawParams)
      
      expect(parsed === undefined).assertTrue()
    })

    it('拒绝缺失协议关键参数（WebDAV无baseUrl）', 0, () => {
      // 不传 baseUrl，createRawRouteParams 的 baseUrl 参数留空
      const rawParams = createRawRouteParams(
        50,
        'webdav',
        'testuser',
        'testpass'
      )
      
      const parsed = createDirectorySelectorRouteParams(rawParams)
      
      // webdav 缺少 baseUrl 必须返回 undefined
      expect(parsed === undefined).assertTrue()
    })

    it('拒绝缺失协议关键参数（SMB无host）', 0, () => {
      // 不传 host，createRawRouteParams 的 host 参数留空
      const rawParams = createRawRouteParams(
        60,
        'smb',
        'testuser',
        'testpass'
      )
      
      const parsed = createDirectorySelectorRouteParams(rawParams)
      
      // smb 缺少 host 必须返回 undefined
      expect(parsed === undefined).assertTrue()
    })

    it('创建 WebDAV Provider 并初始化', 0, async () => {
      const routeParams: DirectorySelectorRouteParams = {
        sourceId: 70,
        protocol: 'webdav',
        username: 'testuser',
        password: 'testpass',
        protocolSpecific: {
          'baseUrl': 'https://demo.local:8443/dav',
          'tlsCertPolicy': 'allow_self_signed'
        }
      }
      
      const descriptor = await createDirectorySelectorSourceDescriptor(routeParams)
      
      expect(descriptor.sourceId).assertEqual(70)
      expect(descriptor.protocol).assertEqual('webdav')
      expect(descriptor.rootLabel).assertEqual('根目录')
      expect(descriptor.endpointSummary).assertEqual('demo.local:8443')
      expect(descriptor.provider.getProtocolKey()).assertEqual('webdav')
    })

    it('创建 SMB Provider 并初始化', 0, async () => {
      const routeParams: DirectorySelectorRouteParams = {
        sourceId: 80,
        protocol: 'smb',
        username: 'testuser',
        password: 'testpass',
        protocolSpecific: {
          'host': 'nas.local',
          'port': 1445,
          'domain': 'WORKGROUP',
          'shareName': ''
        }
      }
      
      const descriptor = await createDirectorySelectorSourceDescriptor(routeParams)
      
      expect(descriptor.sourceId).assertEqual(80)
      expect(descriptor.protocol).assertEqual('smb')
      expect(descriptor.rootLabel).assertEqual('共享列表')
      expect(descriptor.endpointSummary).assertEqual('nas.local:1445')
      expect(descriptor.provider.getProtocolKey()).assertEqual('smb')
    })

    it('拒绝不支持的协议类型', 0, async () => {
      const routeParams: DirectorySelectorRouteParams = {
        sourceId: 90,
        protocol: 'ftp' as 'webdav',
        username: 'testuser',
        password: 'testpass',
        protocolSpecific: {}
      }
      
      let thrownMessage = ''
      try {
        await createDirectorySelectorSourceDescriptor(routeParams)
      } catch (error) {
        thrownMessage = String(error)
      }
      
      expect(thrownMessage.includes('不支持的协议')).assertTrue()
    })
  })
}
