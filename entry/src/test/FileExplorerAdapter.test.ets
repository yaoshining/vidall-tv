import { describe, it, expect } from '@ohos/hypium'
import { WebDAVResource } from '../main/ets/lib/WebDAVClient'
import { SmbFileInfo, SmbListDirectoryResult } from '../main/ets/lib/SMBClient'
import { FileExplorerLoadResult } from '../main/ets/components/core/file/FileExplorerController'
import {
  SmbFileExplorerAdapter,
  WebDavFileExplorerAdapter
} from '../main/ets/components/core/file/FileExplorerAdapter'

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

export default function fileExplorerAdapterTest() {
  describe('FileExplorerAdapter', () => {
    it('WebDavFileExplorerAdapter 会过滤当前目录自身并映射为统一资源', 0, async () => {
      const client = new FakeWebDavClient([
        makeWebDavResource('当前目录', '/dav/root', true),
        makeWebDavResource('Movies', '/dav/root/Movies', true),
        makeWebDavResource('cover.jpg', '/dav/root/cover.jpg', false)
      ])
      const adapter = new WebDavFileExplorerAdapter(client.listDirectory.bind(client))

      const result: FileExplorerLoadResult = await adapter.list('/root')

      expect(result.resources.length).assertEqual(2)
      expect(result.resources[0].name).assertEqual('Movies')
      expect(result.resources[0].path).assertEqual('/root/Movies')
      expect(result.resources[1].name).assertEqual('cover.jpg')
      expect(result.errorMessage === undefined).assertTrue()
    })

    it('SmbFileExplorerAdapter 会把客户端错误转成统一错误消息', 0, async () => {
      const client = new FakeSmbClient({
        files: [makeSmbFile('cover.jpg', '/share/cover.jpg', false)],
        error: '连接失败'
      })
      const adapter = new SmbFileExplorerAdapter(client.listDirectory.bind(client))

      const result: FileExplorerLoadResult = await adapter.list('/share')

      expect(result.resources.length).assertEqual(0)
      expect(result.errorMessage).assertEqual('连接失败')
    })
  })
}
