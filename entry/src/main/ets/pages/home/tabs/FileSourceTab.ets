import { LengthMetrics } from "@kit.ArkUI"
import { BusinessError } from '@kit.BasicServicesKit'
import { WebDAVConfig } from "../../../lib/WebDAVClient"
import { FileExplorerPage } from "../../files"
import { SmbFileExplorerPage, SmbFileExplorerPageParam } from "../../files/SmbFileExplorerPage"
import promptAction from '@ohos.promptAction'
import { FileSource, FileSourceType, WebDAVSourceConfig, SMBSourceConfig } from "../../../db/models/FileSourceEntity"
import { FileSourceStore } from "../../../stores/files/FileSourceStore"
import { DirectoryItem, FileSourceModel } from "../../../stores/files/FileSourceModel"
import { FileSourceDatabase } from "../../../db/files/FileSourceDatabase"

@ComponentV2
export struct FileSourceTab {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  @Local fileSourceModel: FileSourceModel = FileSourceStore.getState()
  @Local isLoading: boolean = false
  private refreshTimer: number = -1

  aboutToAppear(): void {
    FileSourceDatabase.onReady(() => {
      // 更新软件源
      this.fileSourceModel.loadFileSources(true)
    })
  }

  aboutToDisappear(): void {
    // 清除定时器
    if (this.refreshTimer !== -1) {
      clearInterval(this.refreshTimer)
      this.refreshTimer = -1
    }
  }

  @Monitor('fileSourceStore.fileSources')
  onFileSourcesChange(mon: IMonitor) {
    const newFileSources = mon.value<FileSource[]>("fileSourceStore.fileSources")?.now
    console.log('new file sources: ' + JSON.stringify(newFileSources))
  }

  @Monitor('fileSourceModel.refreshTick')
  onRefreshTickChange() {
    if (this.fileSourceModel.refreshTick > 0) {
      this.refresh()
    }
  }

  /**
   * 供父组件调用，刷新列表
   */
  async refresh(): Promise<void> {
    try {
      await this.fileSourceModel.loadFileSources(true)
      this.getUIContext().getPromptAction().showToast({
        message: '刷新成功'
      } as promptAction.ShowToastOptions)
    } catch (error) {
      const err = error as BusinessError
      console.error('FileSourceTab', `刷新失败: code=${err.code} msg=${err.message}`)
    }
  }

  /**
   * 构造 WebDAV 配置并指定初始路径
   */
  private buildWebDAVConfigForDirectory(item: DirectoryItem): WebDAVConfig | null {
    try {
      const config = JSON.parse(item.fileSource.configJson) as WebDAVSourceConfig

      // 处理服务器地址和端口
      let serverAddress = config.url
      let port = config.port

      if (serverAddress.includes(':')) {
        const parts = serverAddress.split(':')
        serverAddress = parts[0]
        const portInUrl = parseInt(parts[1])
        if (!isNaN(portInUrl)) {
          port = portInUrl
        }
      }

      // 构造基础 URL
      let baseUrl = `${config.protocol}://${serverAddress}:${port}`

      // 添加根路径
      const rootPath = config.rootPath || '/'
      if (rootPath !== '/') {
        const formattedPath = rootPath.startsWith('/') ? rootPath : '/' + rootPath
        baseUrl = baseUrl + formattedPath
      }

      // 将文件夹路径添加到 baseUrl
      const fullPath = rootPath === '/' ? item.directoryPath : rootPath + item.directoryPath

      return {
        baseUrl: baseUrl + item.directoryPath,
        username: config.username,
        password: config.password,
        timeout: 10000
      }
    } catch (error) {
      const err = error as BusinessError
      console.error('FileSourceTab', `构造 WebDAV 配置失败: code=${err.code} msg=${err.message}`)
      return null
    }
  }

  /**
   * 处理文件夹点击
   */
  private handleDirectoryClick(item: DirectoryItem): void {
    if (item.fileSource.type === FileSourceType.WEBDAV) {
      const config = this.buildWebDAVConfigForDirectory(item)
      if (config) {
        this.pageStack.pushPath({
          name: FileExplorerPage.PAGE_NAME,
          param: config as WebDAVConfig
        }, false)
      }
    } else if (item.fileSource.type === FileSourceType.SMB) {
      try {
        const smbConfig = JSON.parse(item.fileSource.configJson) as SMBSourceConfig
        const param: SmbFileExplorerPageParam = {
          config: smbConfig,
          initialPath: item.directoryPath && item.directoryPath !== '/' ? item.directoryPath : '/'
        }
        this.pageStack.pushPath({
          name: SmbFileExplorerPage.PAGE_NAME,
          param: param
        }, false)
      } catch (e) {
        const err = e as BusinessError
        console.error('FileSourceTab', `解析 SMB 配置失败: code=${err.code} msg=${err.message}`)
        this.getUIContext().getPromptAction().showToast({
          message: '解析 SMB 配置失败'
        } as promptAction.ShowToastOptions)
      }
    } else {
      console.warn('FileSourceTab: Unsupported file source type', item.fileSource.type)
    }
  }

  @Builder
  buildTabIcon(type: FileSourceType) {
    if (type === FileSourceType.WEBDAV) {
      Image($r('app.media.webdav_folder'))
        .width(30).height(30).objectFit(ImageFit.Contain)
    } else if (type === FileSourceType.SMB) {
      Image($r('app.media.smb_folder'))
        .width(30).height(30).objectFit(ImageFit.Contain)
    } else {
      Image($r('app.media.empty_folder'))
        .width(30).height(30).objectFit(ImageFit.Contain)
    }
  }

  build() {
    GridRow({
      gutter: 10,
      columns: 2
    }) {
      // 从数据库加载的文件夹列表
      ForEach(this.fileSourceModel.directories, (item: DirectoryItem) => {
        GridCol() {
          Flex({
            alignItems: ItemAlign.Center,
            justifyContent: FlexAlign.Start,
            space: {
              main: LengthMetrics.vp(20)
            }
          }) {
            Column() {
              this.buildTabIcon(item.fileSource.type)
            }
            .width(60)
            .height(60)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            Flex({
              direction: FlexDirection.Column,
              justifyContent: FlexAlign.SpaceAround,
            }) {
              Text(item.customName)
                .fontSize($r('app.float.font_subtitle_1'))
                .fontWeight(FontWeight.Bold)
              Text(item.fileSourceName)
                .opacity(0.6)
            }
            .height("100%")
          }
        }
        .onClick(() => {
          this.handleDirectoryClick(item)
        })
        .height(80)
        .padding({ left: 20, right: 20, top: 10, bottom: 10 })
        .borderRadius(6)
        .backgroundColor("#373737")
        .hoverEffect(HoverEffect.Highlight)
      }, (item: DirectoryItem) => `${item.fileSource.id}_${item.directoryPath}_${item.customName}`)

    }
  }
}