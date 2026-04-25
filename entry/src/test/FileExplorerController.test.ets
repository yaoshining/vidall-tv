import { describe, it, expect } from '@ohos/hypium'
import { WebDAVResource } from '../main/ets/lib/WebDAVClient'
import { SmbFileInfo } from '../main/ets/lib/SMBClient'
import {
  compareFileExplorerNames,
  FileExplorerController,
  FileExplorerControllerParam,
  FileExplorerResource,
  createFileExplorerResourceFromSmb,
  createFileExplorerResourceFromWebDav
} from '../main/ets/components/core/file/FileExplorerController'

function makeWebDavResource(name: string, isCollection: boolean, lastModified?: string): WebDAVResource {
  const resource: WebDAVResource = {
    href: '/root/' + name,
    displayName: name,
    isCollection: isCollection,
    lastModified: lastModified,
    size: isCollection ? undefined : 128
  }
  return resource
}

function makeSmbFileInfo(name: string, path: string, isDirectory: boolean, lastModifiedMs: number): SmbFileInfo {
  const file: SmbFileInfo = {
    name: name,
    path: path,
    isDirectory: isDirectory,
    size: isDirectory ? 0 : 256,
    lastModifiedMs: lastModifiedMs
  }
  return file
}

export default function fileExplorerControllerTest() {
  describe('FileExplorerResource mapping', () => {
    it('会把 WebDAV 资源转换为统一模型并解析隐藏标记与完整路径', 0, () => {
      const resource: FileExplorerResource = createFileExplorerResourceFromWebDav(
        '/影视',
        makeWebDavResource('.cover.jpg', false, 'Wed, 26 Apr 2026 10:30:00 GMT')
      )

      expect(resource.name).assertEqual('.cover.jpg')
      expect(resource.path).assertEqual('/影视/.cover.jpg')
      expect(resource.isDirectory).assertFalse()
      expect(resource.isHidden).assertTrue()
      expect(resource.lastModifiedMs !== undefined).assertTrue()
    })

    it('会把 SMB 资源转换为统一模型并保留毫秒时间戳', 0, () => {
      const resource: FileExplorerResource = createFileExplorerResourceFromSmb(
        makeSmbFileInfo('Episode01.mkv', '/share/TV/Episode01.mkv', false, 1714000000123)
      )

      expect(resource.name).assertEqual('Episode01.mkv')
      expect(resource.path).assertEqual('/share/TV/Episode01.mkv')
      expect(resource.isDirectory).assertFalse()
      expect(resource.isHidden).assertFalse()
      expect(resource.lastModifiedMs).assertEqual(1714000000123)
    })
  })

  describe('FileExplorerController unified resources', () => {
    it('会按统一模型过滤隐藏文件并保持目录优先排序', 0, () => {
      const controller = new FileExplorerController({
        resources: [
          createFileExplorerResourceFromSmb(makeSmbFileInfo('video.mkv', '/share/video.mkv', false, 10)),
          createFileExplorerResourceFromSmb(makeSmbFileInfo('.hidden', '/share/.hidden', false, 11)),
          createFileExplorerResourceFromSmb(makeSmbFileInfo('Season 1', '/share/Season 1', true, 9))
        ],
        currentPath: '/'
      })

      expect(controller.sortedResources.length).assertEqual(2)
      expect(controller.sortedResources[0].name).assertEqual('Season 1')
      expect(controller.sortedResources[1].name).assertEqual('video.mkv')

      controller.showHiddenFiles = true
      expect(controller.sortedResources.length).assertEqual(3)
    })

    it('按名称排序时会把中文季序号按自然顺序排列', 0, () => {
      const names: string[] = ['第一季', '第七季', '第三季', '第二季', '第五季', '第六季', '第四季']
      names.sort((a: string, b: string): number => compareFileExplorerNames(a, b))
      expect(names[0]).assertEqual('第一季')
      expect(names[1]).assertEqual('第二季')
      expect(names[2]).assertEqual('第三季')
      expect(names[3]).assertEqual('第四季')
      expect(names[4]).assertEqual('第五季')
      expect(names[5]).assertEqual('第六季')
      expect(names[6]).assertEqual('第七季')

      const controller = new FileExplorerController({
        resources: [
          createFileExplorerResourceFromSmb(makeSmbFileInfo('第五季', '/share/第五季', true, 5)),
          createFileExplorerResourceFromSmb(makeSmbFileInfo('第四季', '/share/第四季', true, 4)),
          createFileExplorerResourceFromSmb(makeSmbFileInfo('第七季', '/share/第七季', true, 7)),
          createFileExplorerResourceFromSmb(makeSmbFileInfo('第三季', '/share/第三季', true, 3)),
          createFileExplorerResourceFromSmb(makeSmbFileInfo('第一季', '/share/第一季', true, 1)),
          createFileExplorerResourceFromSmb(makeSmbFileInfo('第二季', '/share/第二季', true, 2)),
          createFileExplorerResourceFromSmb(makeSmbFileInfo('第六季', '/share/第六季', true, 6))
        ],
        currentPath: '/'
      })

      expect(controller.sortedResources[0].name).assertEqual('第一季')
      expect(controller.sortedResources[1].name).assertEqual('第二季')
      expect(controller.sortedResources[2].name).assertEqual('第三季')
      expect(controller.sortedResources[3].name).assertEqual('第四季')
      expect(controller.sortedResources[4].name).assertEqual('第五季')
      expect(controller.sortedResources[5].name).assertEqual('第六季')
      expect(controller.sortedResources[6].name).assertEqual('第七季')
    })

    it('handleBack 在非根目录时回到上一级，在根目录时交给外层处理', 0, () => {
      const folderChanges: string[] = []
      let backCalls = 0
      const controller = new FileExplorerController({
        resources: [],
        currentPath: '/电影/华语',
        onFolderChange: (path: string): void => {
          folderChanges.push(path)
        },
        onBack: (): boolean => {
          backCalls += 1
          return true
        }
      })

      controller.handleBack()
      expect(folderChanges.length).assertEqual(1)
      expect(folderChanges[0]).assertEqual('/电影')
      expect(backCalls).assertEqual(0)

      controller.currentPath = '/'
      controller.handleBack()
      expect(backCalls).assertEqual(1)
    })

    it('配置了 rootPath 时回退到文件源根目录就交给外层关闭', 0, () => {
      const folderChanges: string[] = []
      let backCalls = 0
      const resources: FileExplorerResource[] = []
      const params: FileExplorerControllerParam = {
        resources: resources,
        currentPath: '/share/library/season1',
        rootPath: '/share/library',
        onFolderChange: (path: string): void => {
          folderChanges.push(path)
        },
        onBack: (): boolean => {
          backCalls += 1
          return true
        }
      }
      const controller = new FileExplorerController(params)

      controller.handleBack()
      expect(folderChanges.length).assertEqual(1)
      expect(folderChanges[0]).assertEqual('/share/library')
      expect(backCalls).assertEqual(0)

      controller.currentPath = '/share/library'
      controller.handleBack()
      expect(backCalls).assertEqual(1)
    })

    it('配置了 rootPath 时面包屑根项使用文件源根目录', 0, () => {
      const resources: FileExplorerResource[] = []
      const params: FileExplorerControllerParam = {
        resources: resources,
        currentPath: '/share/library/season1',
        rootPath: '/share/library'
      }
      const controller = new FileExplorerController(params)

      expect(controller.pathItems.length).assertEqual(2)
      expect(controller.pathItems[0].name).assertEqual('根目录')
      expect(controller.pathItems[0].path).assertEqual('/share/library')
      expect(controller.pathItems[1].path).assertEqual('/share/library/season1')
    })

    it('rootPath 仅在完整路径段匹配时才视为当前根目录前缀', 0, () => {
      const resources: FileExplorerResource[] = []
      const params: FileExplorerControllerParam = {
        resources: resources,
        currentPath: '/share/library2',
        rootPath: '/share/library'
      }
      const controller = new FileExplorerController(params)

      expect(controller.pathItems.length).assertEqual(2)
      expect(controller.pathItems[0].path).assertEqual('/share/library')
      expect(controller.pathItems[1].name).assertEqual('library2')
      expect(controller.pathItems[1].path).assertEqual('/share/library2')
    })
  })
}
