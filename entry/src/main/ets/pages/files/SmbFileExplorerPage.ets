import { common } from '@kit.AbilityKit'
import { FileExplorer } from '../../components/core/file/FileExplorer'
import { SmbFileExplorerAdapter } from '../../components/core/file/FileExplorerAdapter'
import { FileExplorerController } from '../../components/core/file/FileExplorerController'
import { ImagePreviewDialog } from '../../components/core/file/ImagePreview'
import { DialogHandle, ImagePreviewSessionController } from '../../components/core/file/ImagePreviewSessionController'
import { SMBSourceConfig } from '../../db/models/FileSourceEntity'
import { SMBClient, SmbFileInfo, SmbListDirectoryResult } from '../../lib/SMBClient'
import { PlayerPage, PlayerPageParam } from '../player'
import { FfprobeUtil } from '../../utils/FfprobeUtil'
import { isVideoFile } from '../../utils/VideoFileUtil'
import { PresetAudioTrack, PresetSubtitleTrack } from '../../components/core/player/VideoData'
import { FileExplorerContext } from '../../components/core/player/PlaybackContext'

// ─────────────────────────────────────────────────────────────────────────────
// 对外导出的路由参数接口
// ─────────────────────────────────────────────────────────────────────────────

export interface SmbFileExplorerPageParam {
  config: SMBSourceConfig
  /** 初始目录路径，默认 "/" 列举所有共享 */
  initialPath?: string
}

// ─────────────────────────────────────────────────────────────────────────────
// 内部辅助类型
// ─────────────────────────────────────────────────────────────────────────────

interface PathItem {
  name: string
  path: string
}

interface ColorsInterface {
  background: string
  surface: string
  surfaceVariant: string
  primaryText: string
  secondaryText: string
  tertiaryText: string
  accent: string
  divider: string
  button: string
}

// ─────────────────────────────────────────────────────────────────────────────
// SmbFileExplorerPage
// ─────────────────────────────────────────────────────────────────────────────

// 占位用默认配置，真实配置在 onReady 中替换
const DEFAULT_SMB_CONFIG: SMBSourceConfig = {
  host: '',
  username: '',
  password: ''
}

@ComponentV2
export struct SmbFileExplorerPage {
  static PAGE_NAME = 'smbFileExplorerPage'

  @Local private imagePath: string = ''
  @Local private files: SmbFileInfo[] = []
  @Local private currentPath: string = '/'
  @Local private isLoading: boolean = false

  // 导航历史栈：记录已访问路径（含当前）；初始值在 onReady 中按 initialPath 覆盖
  private pathHistory: string[] = ['/']
  @Local private errorMessage: string = ''
  @Local private sortField: string = 'name'
  @Local private sortAscending: boolean = true
  @Local private showHiddenFiles: boolean = false
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()

  private config: SMBSourceConfig = DEFAULT_SMB_CONFIG
  private client: SMBClient = SMBClient.fromSourceConfig(DEFAULT_SMB_CONFIG)
  private imagePreviewSessionController: ImagePreviewSessionController = new ImagePreviewSessionController()
  private fileExplorerAdapter: SmbFileExplorerAdapter = new SmbFileExplorerAdapter(
    (path: string): Promise<SmbListDirectoryResult> => this.client.listDirectory(path)
  )
  private fileExplorerController: FileExplorerController = new FileExplorerController({
    resources: [],
    currentPath: '/',
    rootPath: '/',
    onFolderChange: (path: string): void => {
      this.loadDirectory(path)
    },
    onBack: (): boolean => {
      this.pageStack.pop(true)
      return true
    }
  })

  private readonly COLORS: ColorsInterface = {
    background: '#000000',
    surface: '#1C1C1E',
    surfaceVariant: '#2C2C2E',
    primaryText: '#FFFFFF',
    secondaryText: '#EBEBF5',
    tertiaryText: '#98989D',
    accent: '#0A84FF',
    divider: '#38383A',
    button: '#48484A'
  }

  // ── 路径面包屑 ──────────────────────────────────────────────────────────────

  @Computed
  get pathItems(): PathItem[] {
    const items: PathItem[] = []
    items.push({ name: '根目录', path: '/' })

    if (this.currentPath === '/') {
      return items
    }

    const parts = this.currentPath.split('/').filter(p => p.length > 0)
    let accumulated = ''
    for (let i = 0; i < parts.length; i++) {
      accumulated += '/' + parts[i]
      items.push({ name: parts[i], path: accumulated })
    }
    return items
  }

  @Computed
  get sortedFiles(): SmbFileInfo[] {
    let filtered = this.files
    if (!this.showHiddenFiles) {
      filtered = this.files.filter((f: SmbFileInfo) => !f.name.startsWith('.'))
    }
    const sorted = filtered.slice()
    sorted.sort((a: SmbFileInfo, b: SmbFileInfo) => {
      if (a.isDirectory && !b.isDirectory) return -1
      if (!a.isDirectory && b.isDirectory) return 1
      let cmp = 0
      if (this.sortField === 'name') {
        cmp = a.name.localeCompare(b.name)
      } else if (this.sortField === 'size') {
        cmp = a.size - b.size
      } else if (this.sortField === 'date') {
        cmp = a.lastModifiedMs - b.lastModifiedMs
      }
      return this.sortAscending ? cmp : -cmp
    })
    return sorted
  }

  private getSortIcon(field: string): string {
    if (this.sortField !== field) return ''
    return this.sortAscending ? '↑' : '↓'
  }

  private changeSortField(field: string): void {
    if (this.sortField === field) {
      this.sortAscending = !this.sortAscending
    } else {
      this.sortField = field
      this.sortAscending = true
    }
  }

  // ── 列举目录 ────────────────────────────────────────────────────────────────

  private loadDirectory(path: string): void {
    console.info('[SmbExplorer] loadDirectory path=' + path)
    this.isLoading = true
    this.errorMessage = ''
    this.fileExplorerAdapter.list(path).then((result) => {
      this.isLoading = false
      this.errorMessage = result.errorMessage ?? ''
      this.fileExplorerController.resources = result.resources
      this.fileExplorerController.currentPath = path
      this.currentPath = path
    }).catch(() => {
      this.isLoading = false
      this.fileExplorerController.resources = []
      this.errorMessage = '加载目录失败'
      console.error('[SmbExplorer] listDirectory catch path=' + path)
    })
  }

  // ── 脱敏辅助：隐藏 URL 中的用户名与密码，仅用于日志输出 ─────────────────

  private maskSmbUrl(url: string): string {
    return url.replace(/smb:\/\/[^@]+@/, 'smb://***@')
  }

  // ── 构造 SMB 播放 URL（内嵌凭据供播放器使用）──────────────────────────────
  // 注意：凭据仅用于 libsmb2 认证，不得将完整 URL 记录到日志。
  //       日志输出请统一使用 maskSmbUrl() 脱敏后的版本。

  private buildPlaybackUrl(filePath: string): string {
    const host = this.config.host
    const port = this.config.port ?? 445
    const username = encodeURIComponent(this.config.username)
    const password = encodeURIComponent(this.config.password)

    // filePath 格式：/<shareName>/sub/path/file.mkv
    let normalized = filePath
    if (!normalized.startsWith('/')) {
      normalized = '/' + normalized
    }

    return `smb://${username}:${password}@${host}:${port}${normalized}`
  }

  // ── 文件点击处理 ────────────────────────────────────────────────────────────

  private handleFileClick(file: SmbFileInfo): void {
    if (file.isDirectory) {
      this.loadDirectory(file.path)
    } else if (isVideoFile(file.name)) {
      this.playVideo(file)
    } else if (this.isImageFile(file.name)) {
      this.previewImage(file.path, file.name)
    }
  }

  private previewImage(filePath: string, displayName: string): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext
    const tempPath = context.tempDir + '/' + displayName
    this.client.downloadFileToLocal(filePath, tempPath).then((savedPath: string) => {
      this.closeImagePreview()
      this.imagePath = 'file://' + savedPath
      const dialogController: CustomDialogController = new CustomDialogController({
        builder: ImagePreviewDialog({
          imageSrc: this.imagePath
        }),
        width: '100%',
        height: '100%',
        maskColor: Color.Transparent,
        cornerRadius: 0,
        customStyle: true,
      })
      this.imagePreviewSessionController.openDialog(dialogController as DialogHandle)
    }).catch(() => {
      console.error('[SmbExplorer] 图片预览失败')
    })
  }

  private closeImagePreview(): boolean {
    const handled = this.imagePreviewSessionController.closeActiveDialog()
    if (handled) {
      this.imagePath = ''
    }
    return handled
  }

  private async playVideo(file: SmbFileInfo): Promise<void> {
    const url = this.buildPlaybackUrl(file.path)
    console.info('[SmbExplorer] 播放视频: ' + this.maskSmbUrl(url))

    // ── 探测音轨/字幕轨信息（失败时降级为空轨道，不阻断播放主流程）────────────
    let presetAudioTracks: PresetAudioTrack[] = []
    let presetSubtitleTracks: PresetSubtitleTrack[] = []
    try {
      const probeResult = await FfprobeUtil.probeSmb(url, 15000)
      if (probeResult.success) {
        console.info(
          '[SmbExplorer] 轨道探测成功: 音轨=' + probeResult.audioTracks.length.toString() +
          ' 字幕轨=' + probeResult.subtitleTracks.length.toString()
        )
        presetAudioTracks = FfprobeUtil.toPresetAudioTracks(probeResult.audioTracks)
        presetSubtitleTracks = FfprobeUtil.toPresetSubtitleTracks(probeResult.subtitleTracks)
      } else {
        console.warn('[SmbExplorer] 轨道探测未成功（降级为空轨道）: ' + (probeResult.errorMessage ?? '(未知原因)'))
      }
    } catch (e) {
      const err = e as BusinessError
      console.warn('[SmbExplorer] 轨道探测异常，不阻断播放: ' + (err.message ? err.message : JSON.stringify(e)))
    }

    const pageParam: PlayerPageParam = {
      url: url,
      title: file.name,
      presetAudioTracks: presetAudioTracks.length > 0 ? presetAudioTracks : undefined,
      presetSubtitleTracks: presetSubtitleTracks.length > 0 ? presetSubtitleTracks : undefined,
      playbackContext: FileExplorerContext.build(
        this.fileExplorerController.sortedResources,
        file.path,
        (p: string): string => this.buildPlaybackUrl(p)
      )
    }
    this.pageStack.pushPath({
      name: PlayerPage.PAGE_NAME,
      param: pageParam
    })
  }

  // ── 面包屑导航 ──────────────────────────────────────────────────────────────

  // 截断历史栈到目标路径并跳转（从 build() 的 onClick 提取，避免在 build() 内写变量声明）
  private navigateToBreadcrumb(path: string): void {
    const targetIndex = this.pathHistory.indexOf(path)
    if (targetIndex >= 0) {
      this.pathHistory = this.pathHistory.slice(0, targetIndex + 1)
    } else {
      this.pathHistory = [path]
    }
    this.loadDirectory(path)
  }

  // ── 返回导航 ────────────────────────────────────────────────────────────────

  // UI 返回箭头 / 系统返回键共用：历史栈 > 1 时回到上一级，否则关闭弹窗（与 WebDAV 行为一致）
  private navigateUp(): void {
    if (this.pathHistory.length > 1) {
      this.pathHistory.pop()
      this.loadDirectory(this.pathHistory[this.pathHistory.length - 1])
    } else {
      this.pageStack.pop(true)
    }
  }

  // 系统/遥控器返回键：与 navigateUp 行为一致（非根目录返回上级，根目录关闭）
  private handleBack(): boolean {
    this.navigateUp()
    return true
  }

  // ── 格式化辅助 ──────────────────────────────────────────────────────────────

  private formatFileSize(bytes: number): string {
    if (bytes <= 0) {
      return '-'
    }
    if (bytes < 1024) {
      return `${bytes} B`
    } else if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`
    } else if (bytes < 1024 * 1024 * 1024) {
      return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
    }
    return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`
  }

  private formatDate(ms: number): string {
    if (ms <= 0) {
      return '-'
    }
    const d = new Date(ms)
    const y = d.getFullYear()
    const mo = String(d.getMonth() + 1).padStart(2, '0')
    const day = String(d.getDate()).padStart(2, '0')
    return `${y}-${mo}-${day}`
  }

  private getFileIcon(file: SmbFileInfo): string {
    if (file.isDirectory) {
      return '📁'
    }
    const name = file.name.toLowerCase()
    if (isVideoFile(name)) {
      return '🎬'
    }
    if (this.isAudioFile(name)) {
      return '🎵'
    }
    if (this.isImageFile(name)) {
      return '🖼️'
    }
    return '📄'
  }

  private isAudioFile(name: string): boolean {
    const exts = ['.mp3', '.flac', '.aac', '.ogg', '.wav', '.m4a']
    const lower = name.toLowerCase()
    return exts.some(ext => lower.endsWith(ext))
  }

  private isImageFile(name: string): boolean {
    const exts = ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp']
    const lower = name.toLowerCase()
    return exts.some(ext => lower.endsWith(ext))
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  build() {
    NavDestination() {
      FileExplorer({
        controller: this.fileExplorerController,
        isLoading: this.isLoading,
        errorMessage: this.errorMessage,
        onFileClick: (event) => {
          if (isVideoFile(event.resource.name)) {
            const fileInfo: SmbFileInfo = {
              name: event.resource.name,
              path: event.resource.path,
              isDirectory: false,
              size: event.resource.size ?? 0,
              lastModifiedMs: event.resource.lastModifiedMs ?? 0
            }
            this.playVideo(fileInfo)
          } else if (this.isImageFile(event.resource.name)) {
            this.previewImage(event.resource.path, event.resource.name)
          }
        }
      })
    }
    .onReady((context) => {
      const param = context.pathInfo.param as SmbFileExplorerPageParam
      this.config = param.config
      this.client = SMBClient.fromSourceConfig(param.config)
      this.fileExplorerAdapter = new SmbFileExplorerAdapter(
        (path: string): Promise<SmbListDirectoryResult> => this.client.listDirectory(path)
      )
      const startPath = param.initialPath ?? '/'
      this.fileExplorerController.rootPath = startPath
      this.fileExplorerController.currentPath = startPath
      this.loadDirectory(startPath)
    })
    .onBackPressed(() => {
      if (this.imagePreviewSessionController.handleBack()) {
        this.imagePath = ''
        return true
      }
      this.fileExplorerController.handleBack()
      return true
    })
    .mode(NavDestinationMode.DIALOG)
    .hideTitleBar(true)
  }

  aboutToDisappear(): void {
    this.closeImagePreview()
  }
}
