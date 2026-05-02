import { describe, it, expect } from '@ohos/hypium'
import { FileExplorerContext } from '../main/ets/components/core/player/PlaybackContext'
import { FileExplorerResource } from '../main/ets/components/core/file/FileExplorerController'

function makeResource(name: string, path: string, isDirectory: boolean = false): FileExplorerResource {
  const r: FileExplorerResource = {
    key: path,
    name,
    path,
    isDirectory,
    isHidden: false,
    sourceType: 'webdav'
  }
  return r
}

export default function FileExplorerContextTest() {
  describe('FileExplorerContext', () => {
    describe('build()', () => {
      it('过滤目录，仅保留视频文件', 0, () => {
        const resources: FileExplorerResource[] = [
          makeResource('folder', '/folder', true),
          makeResource('movie.mp4', '/movie.mp4'),
          makeResource('doc.pdf', '/doc.pdf'),
          makeResource('show.mkv', '/show.mkv')
        ]
        const ctx = FileExplorerContext.build(resources, '/movie.mp4')
        expect(ctx.items.length).assertEqual(2)
        expect(ctx.items[0].title).assertEqual('movie.mp4')
        expect(ctx.items[1].title).assertEqual('show.mkv')
      })

      it('定位当前视频的 currentIndex', 0, () => {
        const resources: FileExplorerResource[] = [
          makeResource('a.mp4', '/a.mp4'),
          makeResource('b.mkv', '/b.mkv'),
          makeResource('c.avi', '/c.avi')
        ]
        const ctx = FileExplorerContext.build(resources, '/b.mkv')
        expect(ctx.currentIndex).assertEqual(1)
      })

      it('currentVideoPath 无匹配时 currentIndex 默认为 0', 0, () => {
        const resources: FileExplorerResource[] = [
          makeResource('a.mp4', '/a.mp4'),
          makeResource('b.mkv', '/b.mkv')
        ]
        const ctx = FileExplorerContext.build(resources, '/not_exist.mp4')
        expect(ctx.currentIndex).assertEqual(0)
      })

      it('urlMapper 转换视频路径', 0, () => {
        const resources: FileExplorerResource[] = [
          makeResource('movie.mp4', '/nas/movie.mp4')
        ]
        const ctx = FileExplorerContext.build(
          resources,
          '/nas/movie.mp4',
          (p: string): string => 'http://server:8080' + p
        )
        expect(ctx.items[0].videoPath).assertEqual('http://server:8080/nas/movie.mp4')
      })

      it('支持所有 SUPPORTED_VIDEO_EXTENSIONS', 0, () => {
        const extensions: string[] = ['.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.ts', '.m2ts']
        const resources: FileExplorerResource[] = extensions.map((ext: string) => {
          const r: FileExplorerResource = makeResource('file' + ext, '/file' + ext)
          return r
        })
        const ctx = FileExplorerContext.build(resources, '/file.mp4')
        expect(ctx.items.length).assertEqual(extensions.length)
      })

      it('资源列表为空时返回空上下文', 0, () => {
        const ctx = FileExplorerContext.build([], '/any.mp4')
        expect(ctx.items.length).assertEqual(0)
        expect(ctx.currentIndex).assertEqual(0)
      })
    })

    describe('jumpTo()', () => {
      it('有效 index 返回对应 item 并更新 currentIndex', 0, () => {
        const resources: FileExplorerResource[] = [
          makeResource('a.mp4', '/a.mp4'),
          makeResource('b.mp4', '/b.mp4'),
          makeResource('c.mp4', '/c.mp4')
        ]
        const ctx = FileExplorerContext.build(resources, '/a.mp4')
        const item = ctx.jumpTo(2)
        expect(item !== null).assertTrue()
        expect(item!.title).assertEqual('c.mp4')
        expect(ctx.currentIndex).assertEqual(2)
      })

      it('index 越界返回 null，currentIndex 不变', 0, () => {
        const resources: FileExplorerResource[] = [
          makeResource('a.mp4', '/a.mp4')
        ]
        const ctx = FileExplorerContext.build(resources, '/a.mp4')
        const result = ctx.jumpTo(5)
        expect(result).assertNull()
        expect(ctx.currentIndex).assertEqual(0)
      })

      it('负 index 返回 null', 0, () => {
        const resources: FileExplorerResource[] = [
          makeResource('a.mp4', '/a.mp4')
        ]
        const ctx = FileExplorerContext.build(resources, '/a.mp4')
        const result = ctx.jumpTo(-1)
        expect(result).assertNull()
        expect(ctx.currentIndex).assertEqual(0)
      })
    })

    describe('jumpToNext()', () => {
      it('有下一集时返回下一集并更新 currentIndex', 0, () => {
        const resources: FileExplorerResource[] = [
          makeResource('a.mp4', '/a.mp4'),
          makeResource('b.mp4', '/b.mp4')
        ]
        const ctx = FileExplorerContext.build(resources, '/a.mp4')
        const next = ctx.jumpToNext()
        expect(next !== null).assertTrue()
        expect(next!.title).assertEqual('b.mp4')
        expect(ctx.currentIndex).assertEqual(1)
      })

      it('已是最后一集时返回 null', 0, () => {
        const resources: FileExplorerResource[] = [
          makeResource('a.mp4', '/a.mp4'),
          makeResource('b.mp4', '/b.mp4')
        ]
        const ctx = FileExplorerContext.build(resources, '/b.mp4')
        const next = ctx.jumpToNext()
        expect(next).assertNull()
        expect(ctx.currentIndex).assertEqual(1)
      })
    })

    describe('jumpToPrev()', () => {
      it('有上一集时返回上一集并更新 currentIndex', 0, () => {
        const resources: FileExplorerResource[] = [
          makeResource('a.mp4', '/a.mp4'),
          makeResource('b.mp4', '/b.mp4')
        ]
        const ctx = FileExplorerContext.build(resources, '/b.mp4')
        const prev = ctx.jumpToPrev()
        expect(prev !== null).assertTrue()
        expect(prev!.title).assertEqual('a.mp4')
        expect(ctx.currentIndex).assertEqual(0)
      })

      it('已是第一集时返回 null', 0, () => {
        const resources: FileExplorerResource[] = [
          makeResource('a.mp4', '/a.mp4'),
          makeResource('b.mp4', '/b.mp4')
        ]
        const ctx = FileExplorerContext.build(resources, '/a.mp4')
        const prev = ctx.jumpToPrev()
        expect(prev).assertNull()
        expect(ctx.currentIndex).assertEqual(0)
      })
    })

    describe('hasNext / hasPrev', () => {
      it('中间位置 hasNext=true, hasPrev=true', 0, () => {
        const resources: FileExplorerResource[] = [
          makeResource('a.mp4', '/a.mp4'),
          makeResource('b.mp4', '/b.mp4'),
          makeResource('c.mp4', '/c.mp4')
        ]
        const ctx = FileExplorerContext.build(resources, '/b.mp4')
        expect(ctx.hasNext).assertTrue()
        expect(ctx.hasPrev).assertTrue()
      })

      it('只有一个视频时 hasNext=false, hasPrev=false', 0, () => {
        const resources: FileExplorerResource[] = [
          makeResource('a.mp4', '/a.mp4')
        ]
        const ctx = FileExplorerContext.build(resources, '/a.mp4')
        expect(ctx.hasNext).assertFalse()
        expect(ctx.hasPrev).assertFalse()
      })
    })
  })
}
