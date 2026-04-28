import { FileSourceDirectory } from "../../../db/models/FileSourceEntity"
import { DirectorySelectorEntry, DirectorySelectorSourceAdapter, EmptyDirectorySelectorSourceAdapter } from "./DirectorySelectorAdapter"

export interface DirectorySelectorBreadcrumbItem {
  name: string
  path: string
}

@ObservedV2
export class DirectorySelectorState {
  @Trace directories: DirectorySelectorEntry[] = []
  @Trace isLoading: boolean = false
  @Trace errorMessage: string = ''
  @Trace currentPath: string = '/'
  @Trace selectedMap: Map<string, string> = new Map()
  @Trace isAllSelected: boolean = false
  @Trace showNameDialog: boolean = false
  @Trace pendingPath: string = ''
  @Trace pendingDefaultName: string = ''
  @Trace inputCustomName: string = ''
  @Trace rootLabel: string = '根目录'
  @Trace endpointSummary: string = ''
  @Trace protocolKey: string = 'empty'

  sourceId: number = 0
  private adapter: DirectorySelectorSourceAdapter = new EmptyDirectorySelectorSourceAdapter()
  private pathHistory: string[] = ['/']
  private previousSelectedMap: Map<string, string> = new Map()
  private uncheckedMap: Map<string, string> = new Map()
  private directoryLoadSeq: number = 0

  constructor(sourceId: number = 0, adapter: DirectorySelectorSourceAdapter = new EmptyDirectorySelectorSourceAdapter()) {
    this.configure(sourceId, adapter)
  }

  configure(sourceId: number, adapter: DirectorySelectorSourceAdapter): void {
    this.sourceId = sourceId
    this.adapter = adapter
    this.rootLabel = adapter.rootLabel
    this.endpointSummary = adapter.endpointSummary
    this.protocolKey = adapter.protocolKey
    this.directories = []
    this.isLoading = false
    this.errorMessage = ''
    this.currentPath = '/'
    this.selectedMap = new Map()
    this.isAllSelected = false
    this.showNameDialog = false
    this.pendingPath = ''
    this.pendingDefaultName = ''
    this.inputCustomName = ''
    this.pathHistory = ['/']
    this.previousSelectedMap = new Map()
    this.uncheckedMap = new Map()
    this.directoryLoadSeq = 0
  }

  hydrateSelectedDirectories(directories: FileSourceDirectory[]): void {
    const selectedMap = new Map<string, string>()
    directories.forEach((directory: FileSourceDirectory) => {
      selectedMap.set(directory.directoryPath, directory.customName ?? '')
    })
    this.selectedMap = selectedMap
    this.isAllSelected = this.selectedMap.has('/') && this.selectedMap.size === 1
    if (!this.isAllSelected) {
      this.previousSelectedMap = new Map(this.selectedMap)
    }
  }

  async loadCurrentDirectory(): Promise<void> {
    const loadSeq = ++this.directoryLoadSeq
    this.isLoading = true
    this.errorMessage = ''
    try {
      const result = await this.adapter.load(this.currentPath)
      if (loadSeq !== this.directoryLoadSeq) {
        return
      }
      this.directories = result.entries
      if (result.errorMessage !== undefined && result.errorMessage.length > 0 && result.entries.length === 0) {
        this.errorMessage = result.errorMessage
      } else if (result.entries.length === 0) {
        this.errorMessage = '此目录下没有文件夹'
      }
    } finally {
      if (loadSeq === this.directoryLoadSeq) {
        this.isLoading = false
      }
    }
  }

  async retryCurrentDirectory(): Promise<void> {
    await this.loadCurrentDirectory()
  }

  enterDirectory(directory: DirectorySelectorEntry): void {
    this.pathHistory.push(this.currentPath)
    this.currentPath = directory.path
    void this.loadCurrentDirectory()
  }

  goBack(): void {
    if (this.pathHistory.length <= 1) {
      return
    }
    const previousPath = this.pathHistory.pop()
    if (previousPath !== undefined) {
      this.currentPath = previousPath
      void this.loadCurrentDirectory()
    }
  }

  handleBack(): boolean {
    if (this.pathHistory.length > 1) {
      this.goBack()
      return true
    }
    return false
  }

  getBreadcrumbs(): DirectorySelectorBreadcrumbItem[] {
    const breadcrumbs: DirectorySelectorBreadcrumbItem[] = []
    const rootItem: DirectorySelectorBreadcrumbItem = {
      name: this.rootLabel,
      path: '/'
    }
    breadcrumbs.push(rootItem)
    if (this.currentPath !== '/') {
      const segments = this.currentPath.split('/').filter((segment: string) => segment.length > 0)
      let accumulatedPath = ''
      segments.forEach((segment: string) => {
        accumulatedPath += '/' + segment
        const item: DirectorySelectorBreadcrumbItem = {
          name: segment,
          path: accumulatedPath
        }
        breadcrumbs.push(item)
      })
    }
    return breadcrumbs
  }

  jumpToBreadcrumb(targetPath: string): void {
    if (targetPath === this.currentPath) {
      return
    }
    const targetIndex = this.pathHistory.indexOf(targetPath)
    if (targetIndex !== -1) {
      this.pathHistory = this.pathHistory.slice(0, targetIndex + 1)
    } else {
      const segments = targetPath.split('/').filter((segment: string) => segment.length > 0)
      this.pathHistory = ['/']
      let accumulatedPath = ''
      segments.forEach((segment: string) => {
        accumulatedPath += '/' + segment
        this.pathHistory.push(accumulatedPath)
      })
    }
    this.currentPath = targetPath
    void this.loadCurrentDirectory()
  }

  toggleSelectAll(): void {
    if (this.isAllSelected) {
      this.selectedMap = new Map(this.previousSelectedMap)
      this.isAllSelected = false
      return
    }
    this.previousSelectedMap = new Map(this.selectedMap)
    this.selectedMap = new Map([['/', '']])
    this.isAllSelected = true
  }

  toggleDirectorySelection(directory: DirectorySelectorEntry): void {
    if (this.selectedMap.has(directory.path)) {
      const savedName = this.selectedMap.get(directory.path) ?? ''
      this.uncheckedMap.set(directory.path, savedName)
      this.selectedMap.delete(directory.path)
      this.selectedMap = new Map(this.selectedMap)
      return
    }
    this.pendingPath = directory.path
    this.pendingDefaultName = directory.name
    this.inputCustomName = this.uncheckedMap.get(directory.path) ?? directory.name
    this.showNameDialog = true
  }

  confirmPendingSelection(): void {
    const finalName = this.inputCustomName.trim().length > 0 ? this.inputCustomName.trim() : this.pendingDefaultName
    this.selectedMap.set(this.pendingPath, finalName)
    this.selectedMap = new Map(this.selectedMap)
    this.uncheckedMap.delete(this.pendingPath)
    this.showNameDialog = false
    this.pendingPath = ''
    this.pendingDefaultName = ''
    this.inputCustomName = ''
  }

  cancelPendingSelection(): void {
    this.showNameDialog = false
    this.pendingPath = ''
    this.pendingDefaultName = ''
    this.inputCustomName = ''
  }

  isSelected(directory: DirectorySelectorEntry): boolean {
    return this.selectedMap.has(directory.path)
  }

  getCustomName(directory: DirectorySelectorEntry): string {
    return this.selectedMap.get(directory.path) ?? ''
  }

  hasCustomName(directory: DirectorySelectorEntry): boolean {
    return this.getCustomName(directory).length > 0
  }

  buildSaveEntries(): FileSourceDirectory[] {
    const directories: FileSourceDirectory[] = []
    this.selectedMap.forEach((customName: string, path: string) => {
      const directory: FileSourceDirectory = {
        sourceId: this.sourceId,
        directoryPath: path,
        customName: customName.length > 0 ? customName : undefined
      }
      directories.push(directory)
    })
    return directories
  }
}
