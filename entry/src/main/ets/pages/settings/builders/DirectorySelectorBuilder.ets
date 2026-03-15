import { SettingContainer } from "../SettingContainer"
import { SettingsController } from "../SettingsController"
import { WebDAVClient, WebDAVConfig, WebDAVResource } from "../../../lib/WebDAVClient"
import promptAction from '@ohos.promptAction'
import { FileSourceDatabase } from "../../../db/files/FileSourceDatabase";
import { FileSourceDirectory } from "../../../db/models/FileSourceEntity";
import { FileSourceModel } from "../../../stores/files/FileSourceModel";
import { FileSourceStore } from "../../../stores/files/FileSourceStore";

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
  // path -> customName（空字符串表示使用默认名）
  @Local selectedMap: Map<string, string> = new Map()
  @Local isAllSelected: boolean = false
  fileSourceModel: FileSourceModel = FileSourceStore.getState()

  // 命名弹窗状态
  @Local showNameDialog: boolean = false
  @Local pendingPath: string = ''          // 待命名的路径
  @Local pendingDefaultName: string = ''   // 默认名（文件夹名）
  @Local inputCustomName: string = ''      // 弹窗输入框内容
  private nameInputController: TextInputController = new TextInputController()

  // 私有变量
  private pathHistory: string[] = ['/']
  private sourceId: number = 0
  private webdavClient: WebDAVClient | null = null
  private previousSelectedMap: Map<string, string> = new Map()
  // 暂存取消勾选的路径→名字，下次再勾选时带回
  private uncheckedMap: Map<string, string> = new Map()

  aboutToAppear(): void {
    this.controller.setBackHandler(() => this.handleBackPressed())
    this.initializeSelector()
  }

  aboutToDisappear(): void {
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
      const errMsg = (error as Error).message ?? String(error);
      console.error('DirectorySelector: Failed to initialize', errMsg)
      this.errorMessage = '初始化失败：' + errMsg
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
        this.selectedMap.set(dir.directoryPath, dir.customName ?? '')
      })

      // 检查是否选择了"全部文件夹"（根路径标记）
      if (this.selectedMap.has('/') && this.selectedMap.size === 1) {
        // 只有一个路径且是根路径，说明用户之前选择了"全部文件夹"
        this.isAllSelected = true
        console.info('DirectorySelector: Detected "all folders" selection')
      }

      console.info(`DirectorySelector: Loaded ${this.selectedMap.size} selected paths`)
    } catch (error) {
      console.error('DirectorySelector: Failed to load selected directories', (error as Error).message ?? String(error))
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
      const errMsg = (error as Error).message ?? String(error);
      console.error('DirectorySelector: Failed to load directory', errMsg)
      // 截断 raw CURL 部分，只显示可读的前缀（如 "TLS 证书验证失败：..."）
      const displayIdx = errMsg.indexOf(' [CURL:');
      this.errorMessage = displayIdx > 0 ? errMsg.substring(0, displayIdx) : errMsg;
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
   * 获取文件夹完整路径
   */
  private getFullPath(directory: WebDAVResource): string {
    const separator = this.currentPath.endsWith('/') ? '' : '/'
    return this.currentPath + separator + directory.displayName
  }

  /**
   * 勾选 checkbox —— 弹出命名弹窗
   */
  private handleCheckboxChange(directory: WebDAVResource): void {
    const fullPath = this.getFullPath(directory)
    if (this.selectedMap.has(fullPath)) {
      // 已选中 → 取消选中：把当前名字存入 uncheckedMap，从 selectedMap 移除
      const savedName = this.selectedMap.get(fullPath) ?? ''
      this.uncheckedMap.set(fullPath, savedName)
      this.selectedMap.delete(fullPath)
      this.selectedMap = new Map(this.selectedMap)
    } else {
      // 未选中 → 弹出命名弹窗
      this.pendingPath = fullPath
      this.pendingDefaultName = directory.displayName
      // 优先用上次保存的名字，否则默认为文件夹名
      this.inputCustomName = this.uncheckedMap.get(fullPath) ?? directory.displayName
      this.showNameDialog = true
    }
  }

  /**
   * 确认命名弹窗
   */
  private confirmNameDialog(): void {
    // 名字为空时回退到文件夹名
    const finalName = this.inputCustomName.trim().length > 0
      ? this.inputCustomName.trim()
      : this.pendingDefaultName
    this.selectedMap.set(this.pendingPath, finalName)
    this.selectedMap = new Map(this.selectedMap)
    // 确认后清除暂存
    this.uncheckedMap.delete(this.pendingPath)
    this.showNameDialog = false
  }

  /**
   * 取消命名弹窗 —— 不保存，不清除 uncheckedMap 暂存
   */
  private cancelNameDialog(): void {
    this.showNameDialog = false
    this.pendingPath = ''
    this.inputCustomName = ''
  }

  private isSelected(directory: WebDAVResource): boolean {
    return this.selectedMap.has(this.getFullPath(directory))
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

      const dirEntries: FileSourceDirectory[] = []
      this.selectedMap.forEach((customName: string, path: string) => {
        const entry: FileSourceDirectory = {
          sourceId: this.sourceId,
          directoryPath: path,
          customName: customName.length > 0 ? customName : undefined
        }
        dirEntries.push(entry)
      })

      // 插入新选择
      await database.insertDirectories(this.sourceId, dirEntries)
      await this.fileSourceModel.loadFileSources(true)
      // 保存成功后清除所有暂存
      this.uncheckedMap.clear()

      console.info(`DirectorySelector: Saved ${dirEntries.length} directories`)

      this.getUIContext().getPromptAction().showToast({
        message: '保存成功'
      } as promptAction.ShowToastOptions)

      // 返回文件源列表
      this.controller.popType()
    } catch (error) {
      const errMsg = (error as Error).message ?? String(error);
      console.error('DirectorySelector: Failed to save', errMsg)

      AlertDialog.show({
        title: '保存失败',
        message: '保存目录选择失败：' + errMsg,
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

  /**
   * 全部选择或取消选择
   */
  private handleSelectAll(): void {
    if (this.isAllSelected) {
      // 取消全选 - 恢复之前的选择状态
      this.selectedMap = new Map(this.previousSelectedMap)
      this.isAllSelected = false
      console.info('DirectorySelector: Deselected all folders, restored previous selection')
    } else {
      // 全选 - 备份当前选择，然后只保存根路径标记
      this.previousSelectedMap = new Map(this.selectedMap)

      // 清空当前选择，只保留根路径标记表示"全部文件夹"
      this.selectedMap = new Map([[' /', '']])
      this.isAllSelected = true
      console.info('DirectorySelector: Selected all folders (saved as root path)')
    }
  }

  private getCustomName(directory: WebDAVResource): string {
    return this.selectedMap.get(this.getFullPath(directory)) ?? ''
  }

  private hasCustomName(directory: WebDAVResource): boolean {
    return this.getCustomName(directory).length > 0
  }

  build() {
    Stack() {
      SettingContainer({ title: "选择文件夹" }) {
        Column() {
          // 顶部面包屑
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

          // 内容区
          Column() {
            if (this.isLoading) {
              // 加载状态
              Row() {
                LoadingProgress()
                  .width(30).height(30)
                  .color($r('sys.color.ohos_id_color_emphasize'))
              }
              .width('100%').padding({ top: 40 })
              .justifyContent(FlexAlign.Center)
            } else if (this.errorMessage) {
              // 错误提示
              Row() {
                Text(this.errorMessage)
                  .fontSize(14)
                  .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              }
              .width('100%').padding({ top: 40 })
              .justifyContent(FlexAlign.Center)
            } else {
              Scroll() {
                Column({ space: 0 }) {
                  // 全部文件夹选项
                  Row() {
                    Text('📂').fontSize(24).margin({ right: 12 })
                    Text('全部文件夹')
                      .fontSize(16)
                      .fontColor($r('sys.color.ohos_id_color_emphasize'))
                      .fontWeight(FontWeight.Medium)
                      .layoutWeight(1)
                    Checkbox()
                      .select(this.isAllSelected)
                      .selectedColor($r('sys.color.ohos_id_color_emphasize'))
                      .onChange(() => { this.handleSelectAll() })
                  }
                  .width('100%').height(56)
                  .padding({ left: 16, right: 16 })
                  .border({ width: { bottom: 2 }, color: $r('sys.color.ohos_id_color_emphasize') })

                  // 文件夹列表
                  ForEach(this.directories, (directory: WebDAVResource) => {
                    Row() {
                      Text('📁').fontSize(24).margin({ right: 12 })
                      Column() {
                        Text(directory.displayName)
                          .fontSize(16)
                          .fontColor($r('sys.color.ohos_id_color_text_primary'))
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        // 显示自定义名（如果有）
                        if (this.isSelected(directory) && this.hasCustomName(directory)) {
                          Text('别名：' + this.getCustomName(directory))
                            .fontSize(12)
                            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                        }
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)

                      if (!this.isAllSelected) {
                        Checkbox()
                          .select(this.isSelected(directory))
                          .selectedColor($r('sys.color.ohos_id_color_emphasize'))
                          .onChange(() => { this.handleCheckboxChange(directory) })
                      }
                    }
                    .width('100%').height(56)
                    .padding({ left: 16, right: 16 })
                    .onClick(() => {
                      if (!this.isAllSelected) {
                        this.handleEnterDirectory(directory)
                      }
                    })
                    .border({ width: { bottom: 1 }, color: $r('sys.color.ohos_id_color_list_separator') })
                    .opacity(this.isAllSelected ? 0.5 : 1)
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
        }
        .width('100%').height('100%')
      }

      // 自定义命名弹窗（蒙层 + 弹窗卡片）
      if (this.showNameDialog) {
        Column() {
          Column({ space: 16 }) {
            Text('自定义文件夹名称')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.ohos_id_color_text_primary'))

            Text('文件夹：' + this.pendingDefaultName)
              .fontSize(13)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            TextInput({
              placeholder: this.pendingDefaultName,
              text: this.inputCustomName,
              controller: this.nameInputController
            })
              .onChange((val: string) => { this.inputCustomName = val })
              .onAppear(() => {
                // 弹窗出现后自动请求焦点
                this.nameInputController.caretPosition(this.inputCustomName.length)
                focusControl.requestFocus('nameInput')
              })
              .id('nameInput')
              .defaultFocus(true)
              .fontSize(16)
              .borderRadius(8)

            Row({ space: 12 }) {
              Button('取消')
                .layoutWeight(1)
                .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
                .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
                .onClick(() => { this.cancelNameDialog() })
              Button('确定')
                .layoutWeight(1)
                .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
                .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
                .onClick(() => { this.confirmNameDialog() })
            }
            .width('100%')
          }
          .width('80%')
          .padding(24)
          .borderRadius(16)
          .backgroundColor($r('sys.color.ohos_id_color_background'))
          .shadow({ radius: 20, color: '#33000000', offsetX: 0, offsetY: 4 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#80000000')
        .onClick(() => {
          // 点击蒙层不关闭，避免误触
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}

@Builder
export function DirectorySelectorBuilder() {
  DirectorySelectorBuilderComponent()
}
