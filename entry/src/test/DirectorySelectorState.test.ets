import { describe, it, expect } from '@ohos/hypium'
import { FileSourceDirectory } from '../main/ets/db/models/FileSourceEntity'
import {
  DirectorySelectorEntry,
  DirectorySelectorLoadResult,
  DirectorySelectorSourceAdapter
} from '../main/ets/pages/settings/directorySelector/DirectorySelectorAdapter'
import { DirectorySelectorState } from '../main/ets/pages/settings/directorySelector/DirectorySelectorState'

class FakeDirectorySelectorAdapter implements DirectorySelectorSourceAdapter {
  readonly protocolKey: string = 'mock'
  readonly rootLabel: string = '根目录'
  readonly endpointSummary: string = 'mock://root'
  private readonly entriesByPath: Map<string, DirectorySelectorLoadResult>
  private readonly sequenceResultsByPath: Map<string, DirectorySelectorLoadResult[]>
  private readonly loadCountByPath: Map<string, number> = new Map()

  constructor(
    entriesByPath: Map<string, DirectorySelectorLoadResult>,
    sequenceResultsByPath: Map<string, DirectorySelectorLoadResult[]> = new Map()
  ) {
    this.entriesByPath = entriesByPath
    this.sequenceResultsByPath = sequenceResultsByPath
  }

  async load(path: string): Promise<DirectorySelectorLoadResult> {
    const loadCount = (this.loadCountByPath.get(path) ?? 0) + 1
    this.loadCountByPath.set(path, loadCount)
    const sequenceResults = this.sequenceResultsByPath.get(path)
    if (sequenceResults !== undefined && sequenceResults.length > 0) {
      const sequenceIndex = loadCount - 1
      if (sequenceIndex < sequenceResults.length) {
        return sequenceResults[sequenceIndex]
      }
      return sequenceResults[sequenceResults.length - 1]
    }
    const result = this.entriesByPath.get(path)
    if (result !== undefined) {
      return result
    }
    const emptyResult: DirectorySelectorLoadResult = {
      entries: []
    }
    return emptyResult
  }

  getLoadCount(path: string): number {
    return this.loadCountByPath.get(path) ?? 0
  }
}

function makeEntry(name: string, path: string): DirectorySelectorEntry {
  const entry: DirectorySelectorEntry = {
    key: path,
    name: name,
    path: path
  }
  return entry
}

function makeDirectory(path: string, customName?: string): FileSourceDirectory {
  const directory: FileSourceDirectory = {
    sourceId: 1,
    directoryPath: path,
    customName: customName
  }
  return directory
}

export default function directorySelectorStateTest() {
  describe('DirectorySelectorState', () => {
    it('会把根路径标记识别为全部文件夹并可恢复之前的选择', 0, () => {
      const state = new DirectorySelectorState(1, new FakeDirectorySelectorAdapter(new Map<string, DirectorySelectorLoadResult>()))

      state.hydrateSelectedDirectories([
        makeDirectory('/', ''),
        makeDirectory('/Movies', '电影')
      ])
      expect(state.isAllSelected).assertFalse()

      state.hydrateSelectedDirectories([makeDirectory('/', '')])
      expect(state.isAllSelected).assertTrue()

      state.hydrateSelectedDirectories([makeDirectory('/Movies', '电影')])
      state.toggleSelectAll()
      expect(state.isAllSelected).assertTrue()
      expect(state.selectedMap.has('/')).assertTrue()
      expect(state.selectedMap.has(' /')).assertFalse()

      state.toggleSelectAll()
      expect(state.isAllSelected).assertFalse()
      expect(state.selectedMap.get('/Movies')).assertEqual('电影')
    })

    it('勾选目录时会弹出命名态并在二次勾选时恢复上次别名', 0, () => {
      const state = new DirectorySelectorState(1, new FakeDirectorySelectorAdapter(new Map<string, DirectorySelectorLoadResult>()))
      const movieEntry = makeEntry('Movies', '/Movies')

      state.toggleDirectorySelection(movieEntry)
      expect(state.showNameDialog).assertTrue()
      expect(state.pendingPath).assertEqual('/Movies')

      state.inputCustomName = '电影库'
      state.confirmPendingSelection()
      expect(state.selectedMap.get('/Movies')).assertEqual('电影库')

      state.toggleDirectorySelection(movieEntry)
      expect(state.selectedMap.has('/Movies')).assertFalse()

      state.toggleDirectorySelection(movieEntry)
      expect(state.inputCustomName).assertEqual('电影库')
      state.inputCustomName = ''
      state.confirmPendingSelection()
      expect(state.selectedMap.get('/Movies')).assertEqual('Movies')
    })

    it('会根据路径历史生成面包屑并在返回根目录时交给外层处理', 0, async () => {
      const entriesByPath: Map<string, DirectorySelectorLoadResult> = new Map<string, DirectorySelectorLoadResult>([
        ['/', { entries: [makeEntry('Movies', '/Movies')] }],
        ['/Movies', { entries: [makeEntry('Action', '/Movies/Action')] }]
      ])
      const state = new DirectorySelectorState(1, new FakeDirectorySelectorAdapter(entriesByPath))

      await state.loadCurrentDirectory()
      state.enterDirectory(makeEntry('Movies', '/Movies'))
      await state.loadCurrentDirectory()

      expect(state.currentPath).assertEqual('/Movies')
      expect(state.getBreadcrumbs().length).assertEqual(2)
      expect(state.getBreadcrumbs()[0].name).assertEqual('根目录')
      expect(state.handleBack()).assertTrue()
      expect(state.currentPath).assertEqual('/')
      expect(state.handleBack()).assertFalse()
    })

    it('错误态和空态都可以重试当前目录并重新触发加载', 0, async () => {
      const sequenceResultsByPath: Map<string, DirectorySelectorLoadResult[]> = new Map<string, DirectorySelectorLoadResult[]>([
        ['/Retry', [
          { entries: [], errorMessage: '目录加载失败' },
          { entries: [] },
          { entries: [makeEntry('Recovered', '/Retry/Recovered')] }
        ]]
      ])
      const adapter = new FakeDirectorySelectorAdapter(new Map<string, DirectorySelectorLoadResult>(), sequenceResultsByPath)
      const state = new DirectorySelectorState(1, adapter)
      state.currentPath = '/Retry'

      await state.loadCurrentDirectory()
      expect(adapter.getLoadCount('/Retry')).assertEqual(1)
      expect(state.errorMessage).assertEqual('目录加载失败')
      expect(state.currentPath).assertEqual('/Retry')

      await state.retryCurrentDirectory()
      expect(adapter.getLoadCount('/Retry')).assertEqual(2)
      expect(state.errorMessage).assertEqual('此目录下没有文件夹')
      expect(state.currentPath).assertEqual('/Retry')

      await state.retryCurrentDirectory()
      expect(adapter.getLoadCount('/Retry')).assertEqual(3)
      expect(state.errorMessage).assertEqual('')
      expect(state.directories.length).assertEqual(1)
      expect(state.directories[0].path).assertEqual('/Retry/Recovered')
      expect(state.currentPath).assertEqual('/Retry')
    })
  })
}
