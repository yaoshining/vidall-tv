import { describe, it, expect } from '@ohos/hypium'
import { WebDAVResource } from '../main/ets/lib/WebDAVClient'
import { SmbFileInfo, SmbListDirectoryResult } from '../main/ets/lib/SMBClient'
import {
  createDirectorySelectorSourceDescriptor,
  DirectorySelectorLoadResult,
  DirectorySelectorRouteParams,
  SmbDirectorySelectorAdapter,
  WebDavDirectorySelectorAdapter
} from '../main/ets/pages/settings/directorySelector/DirectorySelectorAdapter'

class FakeWebDavClient {
  private readonly resources: WebDAVResource[]

  constructor(resources: WebDAVResource[]) {
    this.resources = resources
  }

  async listDirectory(_path: string): Promise<WebDAVResource[]> {
    return this.resources
  }
}

class FakeSmbClient {
  private readonly result: SmbListDirectoryResult

  constructor(result: SmbListDirectoryResult) {
    this.result = result
  }

  async listDirectory(_path: string): Promise<SmbListDirectoryResult> {
    return this.result
  }
}

function makeWebDavResource(name: string, href: string, isCollection: boolean): WebDAVResource {
  const resource: WebDAVResource = {
    href: href,
    displayName: name,
    isCollection: isCollection
  }
  return resource
}

function makeSmbFile(name: string, path: string, isDirectory: boolean): SmbFileInfo {
  const file: SmbFileInfo = {
    name: name,
    path: path,
    isDirectory: isDirectory,
    size: isDirectory ? 0 : 128,
    lastModifiedMs: 1
  }
  return file
}

export default function directorySelectorAdapterTest() {
  describe('DirectorySelectorAdapter', () => {
    it('WebDavDirectorySelectorAdapter 会过滤当前目录并映射文件夹路径', 0, async () => {
      const client = new FakeWebDavClient([
        makeWebDavResource('当前目录', '/dav/root', true),
        makeWebDavResource('Movies', '/dav/root/Movies', true),
        makeWebDavResource('cover.jpg', '/dav/root/cover.jpg', false)
      ])
      const adapter = new WebDavDirectorySelectorAdapter(
        (path: string): Promise<WebDAVResource[]> => client.listDirectory(path),
        'https://demo.local:8443/media'
      )

      const result: DirectorySelectorLoadResult = await adapter.load('/root')

      expect(result.entries.length).assertEqual(1)
      expect(result.entries[0].path).assertEqual('/root/Movies')
      expect(result.errorMessage === undefined).assertTrue()
    })

    it('SmbDirectorySelectorAdapter 遇到部分错误时仍保留可浏览目录', 0, async () => {
      const client = new FakeSmbClient({
        files: [
          makeSmbFile('Video', '/share/Video', true),
          makeSmbFile('cover.jpg', '/share/cover.jpg', false)
        ],
        error: '部分共享读取失败'
      })
      const adapter = new SmbDirectorySelectorAdapter(
        (path: string): Promise<SmbListDirectoryResult> => client.listDirectory(path),
        'nas.local:445'
      )

      const result: DirectorySelectorLoadResult = await adapter.load('/share')

      expect(result.entries.length).assertEqual(1)
      expect(result.entries[0].path).assertEqual('/share/Video')
      expect(result.errorMessage === undefined).assertTrue()
    })

    it('createDirectorySelectorSourceDescriptor 会保留 WebDAV 与 SMB 的根标签与兼容参数', 0, () => {
      const webDavParams: DirectorySelectorRouteParams = {
        sourceId: 7,
        protocolKey: 'webdav',
        baseUrl: 'https://demo.local:8443/media',
        username: 'tester',
        password: 'secret'
      }
      const smbParams: DirectorySelectorRouteParams = {
        sourceId: 9,
        protocolKey: 'smb',
        host: 'nas.local',
        username: 'tester',
        password: 'secret',
        port: 1445,
        domain: 'WORKGROUP'
      }

      const webDavDescriptor = createDirectorySelectorSourceDescriptor(webDavParams)
      const smbDescriptor = createDirectorySelectorSourceDescriptor(smbParams)

      if (webDavDescriptor === undefined || smbDescriptor === undefined) {
        expect(false).assertTrue()
        return
      }

      expect(webDavDescriptor.rootLabel).assertEqual('根目录')
      expect(webDavDescriptor.sourceId).assertEqual(7)
      expect(webDavDescriptor.endpointSummary).assertEqual('https://demo.local:8443/media')
      expect(smbDescriptor.rootLabel).assertEqual('共享列表')
      expect(smbDescriptor.sourceId).assertEqual(9)
      expect(smbDescriptor.endpointSummary).assertEqual('smb://nas.local:1445')
    })

    it('createDirectorySelectorSourceDescriptor 遇到缺失协议关键参数时会显式失败', 0, () => {
      const brokenParams: DirectorySelectorRouteParams = {
        sourceId: 10,
        protocolKey: 'webdav',
        username: 'tester',
        password: 'secret'
      }

      let thrownMessage = ''
      try {
        createDirectorySelectorSourceDescriptor(brokenParams)
      } catch (error) {
        thrownMessage = String(error)
      }

      expect(thrownMessage.includes('baseUrl')).assertTrue()
    })
  })
}
