import { BusinessError } from '@kit.BasicServicesKit'
import { SMBSourceConfig } from '../../db/models/FileSourceEntity'
import { SMBClient, SmbFileInfo } from '../../lib/SMBClient'
import { PlayerPage, PlayerPageParam } from '../player'

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

  @Local private files: SmbFileInfo[] = []
  @Local private currentPath: string = '/'
  @Local private isLoading: boolean = false
  @Local private errorMessage: string = ''
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()

  private config: SMBSourceConfig = DEFAULT_SMB_CONFIG
  private client: SMBClient = SMBClient.fromSourceConfig(DEFAULT_SMB_CONFIG)

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

  // ── 列举目录 ────────────────────────────────────────────────────────────────

  private loadDirectory(path: string): void {
    this.isLoading = true
    this.errorMessage = ''
    this.client.listDirectory(path).then((result) => {
      this.isLoading = false
      if (result.error) {
        this.errorMessage = result.error
      }
      this.files = result.files
      this.currentPath = path
    }).catch(() => {
      this.isLoading = false
      this.errorMessage = '加载目录失败'
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
    } else if (this.isVideoFile(file.name)) {
      this.playVideo(file)
    }
  }

  private playVideo(file: SmbFileInfo): void {
    const url = this.buildPlaybackUrl(file.path)
    console.info('SmbFileExplorerPage', `播放视频: ${this.maskSmbUrl(url)}`)
    const pageParam: PlayerPageParam = {
      url: url,
      title: file.name
    }
    this.pageStack.pushPath({
      name: PlayerPage.PAGE_NAME,
      param: pageParam
    })
  }

  // ── 返回导航 ────────────────────────────────────────────────────────────────

  private handleBack(): boolean {
    if (this.currentPath === '/') {
      this.pageStack.pop(true)
      return true
    }
    const lastSlash = this.currentPath.lastIndexOf('/')
    const parentPath = lastSlash > 0 ? this.currentPath.substring(0, lastSlash) : '/'
    this.loadDirectory(parentPath)
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
    if (this.isVideoFile(name)) {
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

  private isVideoFile(name: string): boolean {
    const exts = ['.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.ts', '.m2ts']
    const lower = name.toLowerCase()
    return exts.some(ext => lower.endsWith(ext))
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
      Column() {
        // ── 标题栏 ────────────────────────────────────────────────────────────
        Row() {
          Text('SMB 文件浏览器')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.COLORS.primaryText)
            .layoutWeight(1)

          if (this.isLoading) {
            LoadingProgress()
              .width(24)
              .height(24)
              .color(this.COLORS.accent)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .backgroundColor(this.COLORS.surface)

        // ── 路径面包屑 ────────────────────────────────────────────────────────
        Scroll() {
          Row() {
            ForEach(this.pathItems, (item: PathItem, index: number) => {
              Row() {
                Text(item.name)
                  .fontSize(14)
                  .fontColor(index === this.pathItems.length - 1
                    ? this.COLORS.primaryText
                    : this.COLORS.accent)
                  .fontWeight(index === this.pathItems.length - 1
                    ? FontWeight.Bold
                    : FontWeight.Normal)
                  .onClick(() => {
                    if (index !== this.pathItems.length - 1) {
                      this.loadDirectory(item.path)
                    }
                  })

                if (index < this.pathItems.length - 1) {
                  Text(' / ')
                    .fontSize(14)
                    .fontColor(this.COLORS.tertiaryText)
                    .margin({ left: 4, right: 4 })
                }
              }
            }, (item: PathItem) => item.path)
          }
          .padding({ left: 16, right: 16 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(40)
        .backgroundColor(this.COLORS.surfaceVariant)

        Divider()
          .color(this.COLORS.divider)

        // ── 排序栏头 ──────────────────────────────────────────────────────────
        Row() {
          Text('名称')
            .fontSize(13)
            .fontColor(this.COLORS.tertiaryText)
            .layoutWeight(3)

          Text('大小')
            .fontSize(13)
            .fontColor(this.COLORS.tertiaryText)
            .layoutWeight(2)
            .textAlign(TextAlign.End)

          Text('修改日期')
            .fontSize(13)
            .fontColor(this.COLORS.tertiaryText)
            .layoutWeight(2)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.COLORS.surface)

        Divider()
          .color(this.COLORS.divider)

        // ── 错误提示 ──────────────────────────────────────────────────────────
        if (this.errorMessage.length > 0) {
          Row() {
            Text('⚠️  ' + this.errorMessage)
              .fontSize(14)
              .fontColor('#FF6B6B')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          }
          .width('100%')
          .backgroundColor(this.COLORS.surface)
        }

        // ── 文件列表 ──────────────────────────────────────────────────────────
        if (this.files.length === 0 && !this.isLoading) {
          Column() {
            Text('📂')
              .fontSize(48)
              .margin({ bottom: 12 })

            Text('此文件夹为空')
              .fontSize(16)
              .fontColor(this.COLORS.tertiaryText)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.COLORS.background)
        } else {
          List({ space: 0 }) {
            ForEach(this.files, (file: SmbFileInfo, index: number) => {
              ListItem() {
                Row() {
                  // 图标 + 文件名
                  Row({ space: 12 }) {
                    Text(this.getFileIcon(file))
                      .fontSize(20)

                    Column() {
                      Text(file.name)
                        .fontSize(15)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.MARQUEE })
                        .fontColor(file.isDirectory
                          ? this.COLORS.accent
                          : this.COLORS.primaryText)
                        .width('100%')
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                  }
                  .layoutWeight(3)
                  .alignItems(VerticalAlign.Center)

                  // 大小
                  Text(file.isDirectory ? '-' : this.formatFileSize(file.size))
                    .fontSize(13)
                    .fontColor(this.COLORS.tertiaryText)
                    .layoutWeight(2)
                    .textAlign(TextAlign.End)
                    .maxLines(1)

                  // 修改日期
                  Text(this.formatDate(file.lastModifiedMs))
                    .fontSize(13)
                    .fontColor(this.COLORS.tertiaryText)
                    .layoutWeight(2)
                    .textAlign(TextAlign.End)
                    .maxLines(1)
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .backgroundColor(index % 2 === 0
                  ? this.COLORS.background
                  : this.COLORS.surface)
              }
              .onClick(() => {
                this.handleFileClick(file)
              })
            }, (file: SmbFileInfo) => file.path)
          }
          .width('100%')
          .layoutWeight(1)
          .backgroundColor(this.COLORS.background)
          .divider({
            strokeWidth: 0.5,
            color: this.COLORS.divider,
            startMargin: 16,
            endMargin: 16
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.COLORS.background)
    }
    .onReady((context) => {
      const param = context.pathInfo.param as SmbFileExplorerPageParam
      this.config = param.config
      this.client = SMBClient.fromSourceConfig(param.config)
      const startPath = param.initialPath ?? '/'
      this.loadDirectory(startPath)
    })
    .onBackPressed(() => {
      return this.handleBack()
    })
    .mode(NavDestinationMode.DIALOG)
    .hideTitleBar(true)
  }
}
