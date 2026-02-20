import { LengthMetrics } from "@kit.ArkUI"
import { WebDAVConfig } from "../../../lib/WebDAVClient"
import { FileExplorerPage } from "../../files"
import promptAction from '@ohos.promptAction'
import { FileSource, FileSourceType, WebDAVSourceConfig } from "../../../db/models/FileSourceEntity"
import { FileSourceStore } from "../../../stores/files/FileSourceStore"
import { DirectoryItem, FileSourceModel } from "../../../stores/files/FileSourceModel"

const config1: WebDAVConfig = {
  baseUrl: 'http://192.168.3.59:5445/dav',
  username: 'yao',
  password: 'ys198756'
}

const config2: WebDAVConfig = {
  baseUrl: 'http://dav.mypikpak.com',
  username: 'cdkd',
  password: 'dartvjhx'
}

@ComponentV2
export struct FileSourceTab {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  @Local fileSourceModel: FileSourceModel = FileSourceStore.getState()
  @Local isLoading: boolean = false
  @Local isRefreshing: boolean = false
  private refreshTimer: number = -1

  aboutToAppear(): void {
    // 更新软件源
    this.fileSourceModel.loadFileSources(true)

    // 监听文件源变化，自动刷新列表
    this.startAutoRefresh()
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

  /**
   * 启动自动刷新监听
   * 每隔一段时间检查文件源是否有变化
   */
  private startAutoRefresh(): void {
    // 每3秒检查一次是否需要刷新
    this.refreshTimer = setInterval(() => {
      // this.loadDirectories(true).catch((error: BusinessError) => {
      //   console.error('FileSourceTab: Auto refresh failed', JSON.stringify(error))
      // })
      // // 强制重新加载文件源缓存
      // this.fileSourceStore.loadFileSources(true).then(() => {
      //   // 静默刷新目录列表
      //   this.loadDirectories(true)
      // }).catch((error: BusinessError) => {
      //   console.error('FileSourceTab: Auto refresh failed', JSON.stringify(error))
      // })
    }, 3000)
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
      console.error('FileSourceTab: Failed to build WebDAV config', JSON.stringify(error))
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
    } else {
      console.warn('FileSourceTab: Unsupported file source type', item.fileSource.type)
    }
  }

  /**
   * 处理下拉刷新
   */
  private async handleRefresh(): Promise<void> {
    this.isRefreshing = true

    try {
      // 强制重新加载数据
      await this.fileSourceModel.loadFileSources(true)

      this.getUIContext().getPromptAction().showToast({
        message: '刷新成功'
      } as promptAction.ShowToastOptions)
    } catch (error) {
      console.error('FileSourceTab: Refresh failed', JSON.stringify(error))
      promptAction.showToast({
        message: '刷新失败'
      } as promptAction.ShowToastOptions)
    } finally {
      this.isRefreshing = false
    }
  }

  build() {
    Refresh({ refreshing: $$this.isRefreshing }) {
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
              Image($r('app.media.empty_folder'))
                .height("100%")
              Flex({
                direction: FlexDirection.Column,
                justifyContent: FlexAlign.SpaceAround,
              }) {
                Text(item.directoryName)
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
        }, (item: DirectoryItem) => `${item.fileSource.id}_${item.directoryPath}`)

        // 原有的写死的两个配置（保留用于测试）
        GridCol() {
          Flex({
            alignItems: ItemAlign.Center,
            justifyContent: FlexAlign.Start,
            space: {
              main: LengthMetrics.vp(20)
            }
          }) {
            Image($r('app.media.empty_folder'))
              .height("100%")
            Flex({
              direction: FlexDirection.Column,
              justifyContent: FlexAlign.SpaceAround,
            }) {
              Text("全部文件")
                .fontSize($r('app.float.font_subtitle_1'))
                .fontWeight(FontWeight.Bold)
              Text("我的OpenList")
                .opacity(0.6)
            }
            .height("100%")
          }
        }
        .onClick(() => {
          this.pageStack.pushPath({
            name: FileExplorerPage.PAGE_NAME,
            param: config1 as WebDAVConfig
          }, false)
        })
        .height(80)
        .padding({ left: 20, right: 20, top: 10, bottom: 10 })
        .borderRadius(6)
        .backgroundColor("#373737")
        .hoverEffect(HoverEffect.Highlight)

        GridCol() {
          Flex({
            alignItems: ItemAlign.Center,
            justifyContent: FlexAlign.Start,
            space: {
              main: LengthMetrics.vp(20)
            }
          }) {
            Image($r('app.media.empty_folder'))
              .height("100%")
            Flex({
              direction: FlexDirection.Column,
              justifyContent: FlexAlign.SpaceAround,
            }) {
              Text("全部文件")
                .fontSize($r('app.float.font_subtitle_1'))
                .fontWeight(FontWeight.Bold)
              Text("我的PickPack")
                .opacity(0.6)
            }
            .height("100%")
          }
        }
        .onClick(() => {
          this.pageStack.pushPath({
            name: FileExplorerPage.PAGE_NAME,
            param: config2 as WebDAVConfig
          }, false)
        })
        .height(80)
        .padding({ left: 20, right: 20, top: 10, bottom: 10 })
        .borderRadius(6)
        .backgroundColor("#373737")
        .hoverEffect(HoverEffect.Highlight)

        ForEach(Array.from(Array(10)), () => {
          GridCol() {
            Flex({
              alignItems: ItemAlign.Center,
              justifyContent: FlexAlign.Start,
              space: {
                main: LengthMetrics.vp(20)
              }
            }) {
              Image($r('app.media.empty_folder'))
                .height("100%")
              Flex({
                direction: FlexDirection.Column,
                justifyContent: FlexAlign.SpaceAround,
              }) {
                Text("全部文件")
                  .fontSize($r('app.float.font_subtitle_1'))
                  .fontWeight(FontWeight.Bold)
                Text("我的WebDAV")
                  .opacity(0.6)
              }
              .height("100%")
            }
          }
          .height(80)
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .borderRadius(6)
          .backgroundColor("#373737")
          .hoverEffect(HoverEffect.Highlight)
        })
      }
    }
    .onRefreshing(() => {
      this.handleRefresh()
    })
  }
}