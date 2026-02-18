import { SettingContainer } from "../SettingContainer"
import { SettingsController } from "../SettingsController"
import { WebDAVClient, WebDAVConfig, WebDAVResource } from "../../../lib/WebDAVClient"
import { FileSourceDatabase } from "../../../lib/database/FileSourceDatabase"
import { FileSourceDirectory } from "../../../lib/models/FileSourceModel"
import promptAction from '@ohos.promptAction'

/**
 * 面包屑项接口
 */
interface BreadcrumbItem {
  name: string;
  path: string;
}

@ComponentV2
struct DirectorySelectorBuilderComponent {
  @Consumer('settingsController') controller: SettingsController = new SettingsController()

  // 状态变量
  @Local directories: WebDAVResource[] = []
  @Local isLoading: boolean = false
  @Local isSaving: boolean = false
  @Local errorMessage: string = ''
  @Local currentPath: string = '/'
  @Local selectedPaths: Set<string> = new Set()

  // 私有变量
  private pathHistory: string[] = ['/']
  private sourceId: number = 0
  private webdavClient: WebDAVClient | null = null

  aboutToAppear(): void {
    // 注册自定义返回处理器
    this.controller.setBackHandler(() => this.handleBackPressed())

    // 初始化选择器
    this.initializeSelector()
  }

  aboutToDisappear(): void {
    // 清除自定义返回处理器
    this.controller.setBackHandler(null)
  }

  /**
   * 初始化选择器
   */
  private async initializeSelector(): Promise<void> {
    try {
      // 从参数获取配置
      const params = this.controller.params
      if (!params) {
        this.errorMessage = '缺少必要参数'
        return
      }

      this.sourceId = params['sourceId'] as number
      const baseUrl = params['baseUrl'] as string
      const username = params['username'] as string
      const password = params['password'] as string

      if (!this.sourceId || !baseUrl || !username || !password) {
        this.errorMessage = '配置参数不完整'
        return
      }

      // 创建 WebDAV 客户端
      const config: WebDAVConfig = {
        baseUrl: baseUrl,
        username: username,
        password: password,
        timeout: 10000
      }
      this.webdavClient = new WebDAVClient(config)

      // 加载已保存的目录
      await this.loadSelectedDirectories()

      // 加载根目录
      await this.loadCurrentDirectory()
    } catch (error) {
      console.error('DirectorySelector: Failed to initialize', JSON.stringify(error))
      this.errorMessage = '初始化失败：' + JSON.stringify(error)
    }
  }

  /**
   * 加载已保存的目录路径
   */
  private async loadSelectedDirectories(): Promise<void> {
    try {
      const database = FileSourceDatabase.getInstance()
      const directories = await database.getDirectoriesBySourceId(this.sourceId)

      directories.forEach((dir: FileSourceDirectory) => {
        this.selectedPaths.add(dir.directoryPath)
      })

      console.info(`DirectorySelector: Loaded ${this.selectedPaths.size} selected paths`)
    } catch (error) {
      console.error('DirectorySelector: Failed to load selected directories', JSON.stringify(error))
      // 不阻断流程，继续执行
    }
  }

  /**
   * 加载当前目录的文件夹列表
   */
  private async loadCurrentDirectory(): Promise<void> {
    if (!this.webdavClient) {
      this.errorMessage = 'WebDAV 客户端未初始化'
      return
    }

    this.isLoading = true
    this.errorMessage = ''

    try {
      console.info('DirectorySelector: Loading directory:', this.currentPath)

      const resources = await this.webdavClient.listDirectory(this.currentPath)

      // 过滤出文件夹，并排除第一条（当前目录本身）
      // WebDAV PROPFIND depth=1 会返回当前目录作为第一条结果
      this.directories = resources
        .filter((item: WebDAVResource) => item.isCollection)
        .filter((item: WebDAVResource, index: number) => index > 0)

      console.info(`DirectorySelector: Found ${this.directories.length} directories`)

      if (this.directories.length === 0) {
        this.errorMessage = '此目录下没有文件夹'
      }
    } catch (error) {
      console.error('DirectorySelector: Failed to load directory', JSON.stringify(error))
      this.errorMessage = '加载失败，请检查网络连接'
    } finally {
      this.isLoading = false
    }
  }

  /**
   * 进入子目录
   */
  private handleEnterDirectory(directory: WebDAVResource): void {
    // 将当前路径加入历史
    this.pathHistory.push(this.currentPath)

    // 构造新路径
    const separator = this.currentPath.endsWith('/') ? '' : '/'
    this.currentPath = this.currentPath + separator + directory.displayName

    console.info('DirectorySelector: Enter directory:', this.currentPath)

    // 加载新目录
    this.loadCurrentDirectory()
  }

  /**
   * 返回上一级目录
   */
  private handleGoBack(): void {
    if (this.pathHistory.length <= 1) {
      return
    }

    // 从历史中弹出最后一个路径，这就是上一级目录
    const previousPath = this.pathHistory.pop()

    // 设置当前路径为弹出的路径
    if (previousPath) {
      this.currentPath = previousPath
      console.info('DirectorySelector: Go back to:', this.currentPath)

      // 加载目录
      this.loadCurrentDirectory()
    }
  }

  /**
   * 切换文件夹选中状态
   */
  private handleToggleSelection(directory: WebDAVResource): void {
    const separator = this.currentPath.endsWith('/') ? '' : '/'
    const fullPath = this.currentPath + separator + directory.displayName

    if (this.selectedPaths.has(fullPath)) {
      this.selectedPaths.delete(fullPath)
      console.info('DirectorySelector: Deselected:', fullPath)
    } else {
      this.selectedPaths.add(fullPath)
      console.info('DirectorySelector: Selected:', fullPath)
    }
  }

  /**
   * 判断文件夹是否已选中
   */
  private isSelected(directory: WebDAVResource): boolean {
    const separator = this.currentPath.endsWith('/') ? '' : '/'
    const fullPath = this.currentPath + separator + directory.displayName
    return this.selectedPaths.has(fullPath)
  }

  /**
   * 完成选择并保存
   */
  private async handleComplete(): Promise<void> {
    this.isSaving = true

    try {
      const database = FileSourceDatabase.getInstance()

      // 删除旧记录
      await database.deleteDirectoriesBySourceId(this.sourceId)

      // 插入新选择
      const pathsArray = Array.from(this.selectedPaths)
      await database.insertDirectories(this.sourceId, pathsArray)

      console.info(`DirectorySelector: Saved ${pathsArray.length} directories`)

      promptAction.showToast({
        message: '保存成功'
      } as promptAction.ShowToastOptions)

      // 返回文件源列表
      this.controller.popType()
    } catch (error) {
      console.error('DirectorySelector: Failed to save', JSON.stringify(error))

      AlertDialog.show({
        title: '保存失败',
        message: '保存目录选择失败：' + JSON.stringify(error),
        primaryButton: {
          value: '确定',
          action: () => {}
        }
      })
    } finally {
      this.isSaving = false
    }
  }

  /**
   * 取消选择
   */
  private handleCancel(): void {
    // 如果在非根目录，返回上一级
    if (this.pathHistory.length > 1) {
      this.handleGoBack()
    } else {
      // 在根目录才返回文件源列表
      this.controller.popType()
    }
  }

  /**
   * 处理返回键按下事件
   * @returns true 表示消费事件，false 表示不消费
   */
  private handleBackPressed(): boolean {
    // 如果在非根目录，返回上一级
    if (this.pathHistory.length > 1) {
      this.handleGoBack()
      return true // 消费事件，不继续传递
    }
    // 在根目录时返回 false，让上层处理（返回文件源列表）
    return false
  }

  /**
   * 获取面包屑路径数组
   * 将当前路径解析为面包屑路径段
   */
  private getBreadcrumbs(): BreadcrumbItem[] {
    const breadcrumbs: BreadcrumbItem[] = []

    // 添加根目录
    const rootItem: BreadcrumbItem = { name: '根目录', path: '/' }
    breadcrumbs.push(rootItem)

    // 如果当前路径不是根目录，解析路径
    if (this.currentPath !== '/') {
      const segments = this.currentPath.split('/').filter(seg => seg.length > 0)
      let accumulatedPath = ''

      segments.forEach((segment) => {
        accumulatedPath += '/' + segment
        const item: BreadcrumbItem = {
          name: segment,
          path: accumulatedPath
        }
        breadcrumbs.push(item)
      })
    }

    return breadcrumbs
  }

  /**
   * 处理面包屑点击，跳转到指定路径
   */
  private handleBreadcrumbClick(targetPath: string): void {
    if (targetPath === this.currentPath) {
      // 点击的是当前路径，不做处理
      return
    }

    // 重建路径历史栈
    // 找到目标路径在当前历史中的位置
    const targetIndex = this.pathHistory.indexOf(targetPath)

    if (targetIndex !== -1) {
      // 目标路径在历史栈中，移除之后的所有路径
      this.pathHistory = this.pathHistory.slice(0, targetIndex + 1)
    } else {
      // 目标路径不在历史栈中（可能是通过面包屑跳转的）
      // 重新构建历史栈：根据目标路径构建从根到目标的路径序列
      const segments = targetPath.split('/').filter(seg => seg.length > 0)
      this.pathHistory = ['/']

      let accumulatedPath = ''
      segments.forEach((segment) => {
        accumulatedPath += '/' + segment
        this.pathHistory.push(accumulatedPath)
      })
    }

    // 更新当前路径
    this.currentPath = targetPath

    console.info('DirectorySelector: Jump to breadcrumb:', targetPath)

    // 加载目标目录
    this.loadCurrentDirectory()
  }

  build() {
    SettingContainer({
      title: "选择文件夹"
    }) {
      Column() {
        // 顶部面包屑导航栏
        Column() {
          // 返回按钮行
          if (this.pathHistory.length > 1) {
            Row() {
              Button("← 返回")
                .fontSize(14)
                .height(32)
                .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
                .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
                .onClick(() => this.handleGoBack())
                .enabled(!this.isLoading && !this.isSaving)
            }
            .width('100%')
            .margin({ bottom: 8 })
          }

          // 面包屑导航
          Scroll() {
            Row({ space: 4 }) {
              ForEach(this.getBreadcrumbs(), (breadcrumb: BreadcrumbItem, index: number) => {
                Row({ space: 4 }) {
                  // 面包屑项
                  Text(breadcrumb.name)
                    .fontSize(14)
                    .fontColor(breadcrumb.path === this.currentPath ?
                      $r('sys.color.ohos_id_color_emphasize') :
                      $r('sys.color.ohos_id_color_text_secondary'))
                    .fontWeight(breadcrumb.path === this.currentPath ? FontWeight.Medium : FontWeight.Normal)
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .borderRadius(4)
                    .backgroundColor(breadcrumb.path === this.currentPath ?
                      $r('sys.color.ohos_id_color_click_effect') :
                      Color.Transparent)
                    .onClick(() => {
                      if (!this.isLoading && !this.isSaving) {
                        this.handleBreadcrumbClick(breadcrumb.path)
                      }
                    })
                    .enabled(!this.isLoading && !this.isSaving)

                  // 分隔符（最后一项不显示）
                  if (index < this.getBreadcrumbs().length - 1) {
                    Text('/')
                      .fontSize(14)
                      .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                  }
                }
              }, (breadcrumb: BreadcrumbItem) => breadcrumb.path)
            }
            .padding({ left: 4, right: 4 })
          }
          .width('100%')
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
        }
        .width('100%')
        .padding(12)
        .backgroundColor($r('sys.color.ohos_id_color_background'))

        // 中间内容区域
        Column() {
          if (this.isLoading) {
            // 加载状态
            Row() {
              LoadingProgress()
                .width(30)
                .height(30)
                .color($r('sys.color.ohos_id_color_emphasize'))
            }
            .width('100%')
            .padding({ top: 40 })
            .justifyContent(FlexAlign.Center)
          } else if (this.errorMessage) {
            // 错误提示
            Row() {
              Text(this.errorMessage)
                .fontSize(14)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            }
            .width('100%')
            .padding({ top: 40 })
            .justifyContent(FlexAlign.Center)
          } else {
            // 文件夹列表
            Scroll() {
              Column({ space: 0 }) {
                ForEach(this.directories, (directory: WebDAVResource) => {
                  Row() {
                    Text('📁')
                      .fontSize(24)
                      .margin({ right: 12 })

                    Text(directory.displayName)
                      .fontSize(16)
                      .fontColor($r('sys.color.ohos_id_color_text_primary'))
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })

                    Checkbox()
                      .select(this.isSelected(directory))
                      .selectedColor($r('sys.color.ohos_id_color_emphasize'))
                      .onChange(() => {
                        this.handleToggleSelection(directory)
                      })
                  }
                  .width('100%')
                  .height(56)
                  .padding({ left: 16, right: 16 })
                  .onClick(() => {
                    this.handleEnterDirectory(directory)
                  })
                  .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
                  .border({
                    width: { bottom: 1 },
                    color: $r('sys.color.ohos_id_color_list_separator')
                  })
                  .stateStyles({
                    pressed: {
                      .backgroundColor($r('sys.color.ohos_id_color_click_effect'))
                    }
                  })
                }, (directory: WebDAVResource) => directory.href)
              }
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Auto)
            .align(Alignment.Top)
          }
        }
        .layoutWeight(1)
        .backgroundColor($r('sys.color.ohos_id_color_background'))
        .alignItems(HorizontalAlign.Start)

        // 底部操作栏
        Row({ space: 12 }) {
          Button('取消')
            .fontSize(16)
            .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
            .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
            .layoutWeight(1)
            .onClick(() => this.handleCancel())
            .enabled(!this.isSaving)

          Button('完成')
            .fontSize(16)
            .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
            .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
            .layoutWeight(1)
            .onClick(() => this.handleComplete())
            .enabled(!this.isSaving)
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('sys.color.ohos_id_color_background'))
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.ohos_id_color_background'))
    }
  }
}

@Builder
export function DirectorySelectorBuilder() {
  DirectorySelectorBuilderComponent()
}














