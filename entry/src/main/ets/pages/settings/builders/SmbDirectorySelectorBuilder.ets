import { SettingContainer } from "../SettingContainer"
import { SettingsController } from "../SettingsController"
import { SMBClient, SmbFileInfo, SMBClientConfig } from "../../../lib/SMBClient"
import promptAction from '@ohos.promptAction'
import { FileSourceDatabase } from "../../../db/files/FileSourceDatabase"
import { FileSourceDirectory } from "../../../db/models/FileSourceEntity"
import { FileSourceModel } from "../../../stores/files/FileSourceModel"
import { FileSourceStore } from "../../../stores/files/FileSourceStore"
import { BusinessError } from '@kit.BasicServicesKit'

interface BreadcrumbItem {
  name: string
  path: string
}

@ComponentV2
struct SmbDirectorySelectorBuilderComponent {
  @Consumer('settingsController') controller: SettingsController = new SettingsController()

  @Local directories: SmbFileInfo[] = []
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
  @Local pendingPath: string = ''
  @Local pendingDefaultName: string = ''
  @Local inputCustomName: string = ''
  private nameInputController: TextInputController = new TextInputController()

  private pathHistory: string[] = ['/']
  private sourceId: number = 0
  private smbClient: SMBClient | null = null
  private previousSelectedMap: Map<string, string> = new Map()
  private directoryLoadSeq: number = 0
  private uncheckedMap: Map<string, string> = new Map()

  aboutToAppear(): void {
    this.controller.setBackHandler(() => this.handleBackPressed())
    this.initializeSelector()
  }

  aboutToDisappear(): void {
    this.controller.setBackHandler(null)
  }

  private async initializeSelector(): Promise<void> {
    try {
      const params = this.controller.params
      if (!params) {
        this.errorMessage = '缺少必要参数'
        return
      }
      this.sourceId = params['sourceId'] as number
      const host = params['host'] as string
      const username = params['username'] as string
      const password = params['password'] as string
      const port = (params['port'] as number) || 445
      const domain = (params['domain'] as string) || ''

      if (!this.sourceId || !host) {
        this.errorMessage = '配置参数不完整'
        return
      }

      const clientConfig: SMBClientConfig = {
        host: host,
        port: port,
        username: username,
        password: password,
        domain: domain,
        timeoutMs: 10000
      }
      this.smbClient = new SMBClient(clientConfig)
      await this.loadSelectedDirectories()
      await this.loadCurrentDirectory()
    } catch (e) {
      const err = e as BusinessError
      const errMsg = err.message ?? String(e)
      console.error('[SmbDirSelector] 初始化失败', errMsg)
      this.errorMessage = '初始化失败：' + errMsg
    }
  }

  private async loadSelectedDirectories(): Promise<void> {
    try {
      const database = FileSourceDatabase.getInstance()
      const dirs = await database.getDirectoriesBySourceId(this.sourceId)
      dirs.forEach((dir: FileSourceDirectory) => {
        this.selectedMap.set(dir.directoryPath, dir.customName ?? '')
      })
      if (this.selectedMap.has('/') && this.selectedMap.size === 1) {
        this.isAllSelected = true
      }
      console.info(`[SmbDirSelector] 已加载 ${this.selectedMap.size} 个已选目录`)
    } catch (e) {
      const err = e as BusinessError
      console.error('[SmbDirSelector] 加载已选目录失败', err.message ?? String(e))
    }
  }

  private async loadCurrentDirectory(): Promise<void> {
    if (!this.smbClient) {
      this.errorMessage = 'SMB 客户端未初始化'
      return
    }
    const seq = ++this.directoryLoadSeq
    const requestPath = this.currentPath
    this.isLoading = true
    this.errorMessage = ''
    try {
      console.info('[SmbDirSelector] 加载目录:', requestPath)
      const result = await this.smbClient.listDirectory(requestPath)
      if (seq !== this.directoryLoadSeq || requestPath !== this.currentPath) {
        return
      }
      if (result.error && result.files.length === 0) {
        this.errorMessage = result.error
      } else {
        this.directories = result.files.filter((item: SmbFileInfo) => item.isDirectory)
        if (this.directories.length === 0 && !result.error) {
          this.errorMessage = '此目录下没有文件夹'
        }
        if (result.error) {
          console.warn('[SmbDirSelector] 部分错误:', result.error)
        }
      }
      console.info(`[SmbDirSelector] 找到 ${this.directories.length} 个文件夹`)
    } catch (e) {
      if (seq !== this.directoryLoadSeq) {
        return
      }
      const err = e as BusinessError
      const errMsg = err.message ?? String(e)
      console.error('[SmbDirSelector] 加载目录失败', errMsg)
      this.errorMessage = errMsg
    } finally {
      if (seq === this.directoryLoadSeq) {
        this.isLoading = false
      }
    }
  }

  private handleEnterDirectory(directory: SmbFileInfo): void {
    this.pathHistory.push(this.currentPath)
    this.currentPath = directory.path
    console.info('[SmbDirSelector] 进入目录:', this.currentPath)
    this.loadCurrentDirectory()
  }

  private handleGoBack(): void {
    if (this.pathHistory.length <= 1) {
      return
    }
    const previousPath = this.pathHistory.pop()
    if (previousPath) {
      this.currentPath = previousPath
      console.info('[SmbDirSelector] 返回:', this.currentPath)
      this.loadCurrentDirectory()
    }
  }

  private handleCheckboxChange(directory: SmbFileInfo): void {
    const path = directory.path
    if (this.selectedMap.has(path)) {
      const savedName = this.selectedMap.get(path) ?? ''
      this.uncheckedMap.set(path, savedName)
      this.selectedMap.delete(path)
      this.selectedMap = new Map(this.selectedMap)
    } else {
      this.pendingPath = path
      this.pendingDefaultName = directory.name
      this.inputCustomName = this.uncheckedMap.get(path) ?? directory.name
      this.showNameDialog = true
    }
  }

  private confirmNameDialog(): void {
    const finalName = this.inputCustomName.trim().length > 0
      ? this.inputCustomName.trim()
      : this.pendingDefaultName
    this.selectedMap.set(this.pendingPath, finalName)
    this.selectedMap = new Map(this.selectedMap)
    this.uncheckedMap.delete(this.pendingPath)
    this.showNameDialog = false
  }

  private cancelNameDialog(): void {
    this.showNameDialog = false
    this.pendingPath = ''
    this.inputCustomName = ''
  }

  private isSelected(directory: SmbFileInfo): boolean {
    return this.selectedMap.has(directory.path)
  }

  private async handleComplete(): Promise<void> {
    this.isSaving = true
    try {
      const database = FileSourceDatabase.getInstance()
      const dirEntries: FileSourceDirectory[] = []
      this.selectedMap.forEach((customName: string, path: string) => {
        const entry: FileSourceDirectory = {
          sourceId: this.sourceId,
          directoryPath: path,
          customName: customName.length > 0 ? customName : undefined
        }
        dirEntries.push(entry)
      })
      await database.saveDirectoriesForSource(this.sourceId, dirEntries)
      await this.fileSourceModel.loadFileSources(true)
      this.uncheckedMap.clear()
      console.info(`[SmbDirSelector] 保存 ${dirEntries.length} 个目录`)
      this.getUIContext().getPromptAction().showToast({
        message: '保存成功'
      } as promptAction.ShowToastOptions)
      this.controller.popType()
    } catch (e) {
      const err = e as BusinessError
      const errMsg = err.message ?? String(e)
      console.error('[SmbDirSelector] 保存失败', errMsg)
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

  private handleCancel(): void {
    if (this.pathHistory.length > 1) {
      this.handleGoBack()
    } else {
      this.controller.popType()
    }
  }

  private handleBackPressed(): boolean {
    if (this.pathHistory.length > 1) {
      this.handleGoBack()
      return true
    }
    return false
  }

  private getBreadcrumbs(): BreadcrumbItem[] {
    const breadcrumbs: BreadcrumbItem[] = []
    const rootItem: BreadcrumbItem = { name: '共享列表', path: '/' }
    breadcrumbs.push(rootItem)
    if (this.currentPath !== '/') {
      const segments = this.currentPath.split('/').filter((seg: string) => seg.length > 0)
      let accumulatedPath = ''
      segments.forEach((segment: string) => {
        accumulatedPath += '/' + segment
        const item: BreadcrumbItem = { name: segment, path: accumulatedPath }
        breadcrumbs.push(item)
      })
    }
    return breadcrumbs
  }

  private handleBreadcrumbClick(targetPath: string): void {
    if (targetPath === this.currentPath) {
      return
    }
    const targetIndex = this.pathHistory.indexOf(targetPath)
    if (targetIndex !== -1) {
      this.pathHistory = this.pathHistory.slice(0, targetIndex + 1)
    } else {
      const segments = targetPath.split('/').filter((seg: string) => seg.length > 0)
      this.pathHistory = ['/']
      let accumulatedPath = ''
      segments.forEach((segment: string) => {
        accumulatedPath += '/' + segment
        this.pathHistory.push(accumulatedPath)
      })
    }
    this.currentPath = targetPath
    console.info('[SmbDirSelector] 面包屑跳转:', targetPath)
    this.loadCurrentDirectory()
  }

  private handleSelectAll(): void {
    if (this.isAllSelected) {
      this.selectedMap = new Map(this.previousSelectedMap)
      this.isAllSelected = false
    } else {
      this.previousSelectedMap = new Map(this.selectedMap)
      this.selectedMap = new Map([['/', '']])
      this.isAllSelected = true
    }
  }

  private getCustomName(directory: SmbFileInfo): string {
    return this.selectedMap.get(directory.path) ?? ''
  }

  private hasCustomName(directory: SmbFileInfo): boolean {
    return this.getCustomName(directory).length > 0
  }

  build() {
    Stack() {
      SettingContainer({ title: "选择文件夹" }) {
        Column() {
          // 顶部导航区
          Column() {
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
              Row() {
                LoadingProgress()
                  .width(30).height(30)
                  .color($r('sys.color.ohos_id_color_emphasize'))
              }
              .width('100%').padding({ top: 40 })
              .justifyContent(FlexAlign.Center)
            } else if (this.errorMessage.length > 0) {
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

                  // 目录列表
                  ForEach(this.directories, (directory: SmbFileInfo) => {
                    Row() {
                      Text('📁').fontSize(24).margin({ right: 12 })
                      Column() {
                        Text(directory.name)
                          .fontSize(16)
                          .fontColor($r('sys.color.ohos_id_color_text_primary'))
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
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
                  }, (directory: SmbFileInfo) => directory.path)
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

      // 自定义命名弹窗
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
                this.nameInputController.caretPosition(this.inputCustomName.length)
                focusControl.requestFocus('smbNameInput')
              })
              .id('smbNameInput')
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
        .onClick(() => {})
      }
    }
    .width('100%')
    .height('100%')
  }
}

@Builder
export function SmbDirectorySelectorBuilder() {
  SmbDirectorySelectorBuilderComponent()
}
