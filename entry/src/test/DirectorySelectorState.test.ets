import { describe, it, expect } from '@ohos/hypium'
import { FileSourceDirectory } from '../main/ets/db/models/FileSourceEntity'
import { DirectorySelectorEntry } from '../main/ets/pages/settings/directorySelector/DirectorySelectorContainer'
import { DirectorySelectorState } from '../main/ets/pages/settings/directorySelector/DirectorySelectorState'
import { DirectoryEntry, DirectoryLoadResult } from '../main/ets/lib/DirectoryProvider'
import { MockDirectoryProvider } from './mocks/MockDirectoryProvider'

function makeEntry(name: string, path: string): DirectorySelectorEntry {
  const entry: DirectorySelectorEntry = {
    key: path,
    name: name,
    path: path
  }
  return entry
}

function makeDirectoryEntry(name: string, path: string, isDirectory: boolean): DirectoryEntry {
  const entry: DirectoryEntry = {
    key: path,
    name: name,
    path: path,
    isDirectory: isDirectory
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
      const mockProvider = new MockDirectoryProvider({
        mockEntries: [],
        protocolKey: 'mock',
        rootLabel: '根目录',
        endpointSummary: 'mock://root'
      })
      const state = new DirectorySelectorState(1, mockProvider)

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
      const mockProvider = new MockDirectoryProvider({
        mockEntries: [],
        protocolKey: 'mock',
        rootLabel: '根目录',
        endpointSummary: 'mock://root'
      })
      const state = new DirectorySelectorState(1, mockProvider)
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
      const mockEntries: DirectoryEntry[] = [
        makeDirectoryEntry('Movies', '/Movies', true)
      ]
      const mockProvider = new MockDirectoryProvider({
        mockEntries: mockEntries,
        protocolKey: 'mock',
        rootLabel: '根目录',
        endpointSummary: 'mock://root'
      })
      const state = new DirectorySelectorState(1, mockProvider)

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
      const mockProvider = new MockDirectoryProvider({
        mockEntries: [],
        shouldFailList: true,
        errorMessage: '目录加载失败',
        protocolKey: 'mock',
        rootLabel: '根目录',
        endpointSummary: 'mock://root'
      })
      const state = new DirectorySelectorState(1, mockProvider)
      state.currentPath = '/Retry'

      await state.loadCurrentDirectory()
      expect(state.errorMessage).assertEqual('目录加载失败')
      expect(state.currentPath).assertEqual('/Retry')

      // Switch to success mode with empty entries
      mockProvider.updateMockConfig({
        shouldFailList: false,
        mockEntries: []
      })
      
      await state.retryCurrentDirectory()
      expect(state.errorMessage).assertEqual('此目录下没有文件夹')
      expect(state.currentPath).assertEqual('/Retry')

      // Switch to success mode with entries
      mockProvider.updateMockConfig({
        mockEntries: [
          makeDirectoryEntry('Recovered', '/Retry/Recovered', true)
        ]
      })
      
      await state.retryCurrentDirectory()
      expect(state.errorMessage).assertEqual('')
      expect(state.directories.length).assertEqual(1)
      expect(state.directories[0].path).assertEqual('/Retry/Recovered')
      expect(state.currentPath).assertEqual('/Retry')
    })
  })
}
