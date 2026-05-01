import { SettingContainer } from "../SettingContainer"
import { SettingsController } from "../SettingsController"
import promptAction from '@ohos.promptAction'
import { FileSourceDatabase } from "../../../db/files/FileSourceDatabase"
import { FileSourceStore } from "../../../stores/files/FileSourceStore"
import { FileSourceModel } from "../../../stores/files/FileSourceModel"
import { getFileExplorerErrorMessage } from "../../../components/core/file/FileExplorerAdapter"
import {
  createDirectorySelectorRouteParams,
  createDirectorySelectorSourceDescriptor,
  DirectorySelectorEntry,
  DirectorySelectorRouteParams
} from "../directorySelector/DirectorySelectorContainer"
import { DirectorySelectorBreadcrumbItem, DirectorySelectorState } from "../directorySelector/DirectorySelectorState"

@ComponentV2
struct DirectorySelectorBuilderComponent {
  @Consumer('settingsController') controller: SettingsController = new SettingsController()
  @Local isSaving: boolean = false
  fileSourceModel: FileSourceModel = FileSourceStore.getState()
  private selectorState: DirectorySelectorState = new DirectorySelectorState()
  private nameInputController: TextInputController = new TextInputController()

  aboutToAppear(): void {
    this.controller.setBackHandler(() => this.selectorState.handleBack())
    void this.initializeSelector()
  }

  aboutToDisappear(): void {
    this.controller.setBackHandler(null)
  }

  private async initializeSelector(): Promise<void> {
    const routeParams = createDirectorySelectorRouteParams(this.controller.params)
    if (routeParams === undefined) {
      this.selectorState.errorMessage = '配置参数不完整'
      return
    }
    await this.applyRouteParams(routeParams)
    await this.loadSelectedDirectories()
    await this.selectorState.loadCurrentDirectory()
  }

  private async applyRouteParams(routeParams: DirectorySelectorRouteParams): Promise<void> {
    try {
      const descriptor = await createDirectorySelectorSourceDescriptor(routeParams)
      this.selectorState.configure(descriptor.sourceId, descriptor.provider)
      console.info(`[DirectorySelector] 初始化协议=${descriptor.protocol} endpoint=${descriptor.endpointSummary}`)
    } catch (error) {
      this.selectorState.errorMessage = '初始化失败：' + getFileExplorerErrorMessage(error)
    }
  }

  private async loadSelectedDirectories(): Promise<void> {
    try {
      const database = FileSourceDatabase.getInstance()
      const directories = await database.getDirectoriesBySourceId(this.selectorState.sourceId)
      this.selectorState.hydrateSelectedDirectories(directories)
    } catch (error) {
      console.error('[DirectorySelector] 加载已选目录失败', getFileExplorerErrorMessage(error))
    }
  }

  private handleCancel(): void {
    if (!this.selectorState.handleBack()) {
      this.controller.popType()
    }
  }

  private handleDirectoryClick(directory: DirectorySelectorEntry): void {
    if (!this.selectorState.isAllSelected && !this.selectorState.isLoading && !this.isSaving) {
      this.selectorState.enterDirectory(directory)
    }
  }

  private handleBreadcrumbClick(targetPath: string): void {
    if (!this.selectorState.isLoading && !this.isSaving) {
      this.selectorState.jumpToBreadcrumb(targetPath)
    }
  }

  private async handleComplete(): Promise<void> {
    this.isSaving = true
    try {
      const database = FileSourceDatabase.getInstance()
      const entries = this.selectorState.buildSaveEntries()
      await database.saveDirectoriesForSource(this.selectorState.sourceId, entries)
      await this.fileSourceModel.loadFileSources(true)
      this.getUIContext().getPromptAction().showToast({
        message: '保存成功'
      } as promptAction.ShowToastOptions)
      this.controller.popType()
    } catch (error) {
      this.getUIContext().showAlertDialog({
        title: '保存失败',
        message: '保存目录选择失败：' + getFileExplorerErrorMessage(error),
        primaryButton: {
          value: '确定',
          action: () => {}
        }
      })
    } finally {
      this.isSaving = false
    }
  }

  build() {
    Stack() {
      SettingContainer({ title: "选择文件夹" }) {
        Column() {
          Column() {
            if (this.selectorState.currentPath !== '/') {
              Row() {
                Button("← 返回")
                  .fontSize(14)
                  .height(32)
                  .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
                  .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
                  .onClick(() => this.selectorState.goBack())
                  .enabled(!this.selectorState.isLoading && !this.isSaving)
              }
              .width('100%')
              .margin({ bottom: 8 })
            }

            Scroll() {
              Row({ space: 4 }) {
                ForEach(this.selectorState.getBreadcrumbs(), (breadcrumb: DirectorySelectorBreadcrumbItem, index: number) => {
                  Row({ space: 4 }) {
                    Text(breadcrumb.name)
                      .fontSize(14)
                      .fontColor(breadcrumb.path === this.selectorState.currentPath ?
                        $r('sys.color.ohos_id_color_emphasize') :
                        $r('sys.color.ohos_id_color_text_secondary'))
                      .fontWeight(breadcrumb.path === this.selectorState.currentPath ? FontWeight.Medium : FontWeight.Normal)
                      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                      .borderRadius(4)
                      .backgroundColor(breadcrumb.path === this.selectorState.currentPath ?
                        $r('sys.color.ohos_id_color_click_effect') :
                        Color.Transparent)
                      .onClick(() => this.handleBreadcrumbClick(breadcrumb.path))
                      .enabled(!this.selectorState.isLoading && !this.isSaving)

                    if (index < this.selectorState.getBreadcrumbs().length - 1) {
                      Text('/')
                        .fontSize(14)
                        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                    }
                  }
                }, (breadcrumb: DirectorySelectorBreadcrumbItem) => breadcrumb.path)
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

          Column() {
            if (this.selectorState.isLoading) {
              Row() {
                LoadingProgress()
                  .width(30)
                  .height(30)
                  .color($r('sys.color.ohos_id_color_emphasize'))
              }
              .width('100%')
              .padding({ top: 40 })
              .justifyContent(FlexAlign.Center)
            } else if (this.selectorState.errorMessage.length > 0) {
              Row() {
                Text(this.selectorState.errorMessage)
                  .fontSize(14)
                  .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                Button('重试')
                  .fontSize(14)
                  .height(32)
                  .margin({ left: 12 })
                  .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
                  .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
                  .onClick(() => {
                    void this.selectorState.retryCurrentDirectory()
                  })
                  .enabled(!this.selectorState.isLoading && !this.isSaving)
              }
              .width('100%')
              .padding({ top: 40 })
              .justifyContent(FlexAlign.Center)
            } else {
              Scroll() {
                Column({ space: 0 }) {
                  Row() {
                    Text('📂')
                      .fontSize(24)
                      .margin({ right: 12 })
                    Text('全部文件夹')
                      .fontSize(16)
                      .fontColor($r('sys.color.ohos_id_color_emphasize'))
                      .fontWeight(FontWeight.Medium)
                      .layoutWeight(1)
                    Checkbox()
                      .select(this.selectorState.isAllSelected)
                      .selectedColor($r('sys.color.ohos_id_color_emphasize'))
                      .onChange(() => this.selectorState.toggleSelectAll())
                  }
                  .width('100%')
                  .height(56)
                  .padding({ left: 16, right: 16 })
                  .border({ width: { bottom: 2 }, color: $r('sys.color.ohos_id_color_emphasize') })

                  ForEach(this.selectorState.directories, (directory: DirectorySelectorEntry) => {
                    Row() {
                      Text('📁')
                        .fontSize(24)
                        .margin({ right: 12 })
                      Column() {
                        Text(directory.name)
                          .fontSize(16)
                          .fontColor($r('sys.color.ohos_id_color_text_primary'))
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        if (this.selectorState.isSelected(directory) && this.selectorState.hasCustomName(directory)) {
                          Text('别名：' + this.selectorState.getCustomName(directory))
                            .fontSize(12)
                            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                        }
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)

                      if (!this.selectorState.isAllSelected) {
                        Checkbox()
                          .select(this.selectorState.isSelected(directory))
                          .selectedColor($r('sys.color.ohos_id_color_emphasize'))
                          .onChange(() => this.selectorState.toggleDirectorySelection(directory))
                      }
                    }
                    .width('100%')
                    .height(56)
                    .padding({ left: 16, right: 16 })
                    .onClick(() => this.handleDirectoryClick(directory))
                    .border({ width: { bottom: 1 }, color: $r('sys.color.ohos_id_color_list_separator') })
                    .opacity(this.selectorState.isAllSelected ? 0.5 : 1)
                  }, (directory: DirectorySelectorEntry) => directory.path)
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
              .onClick(() => {
                void this.handleComplete()
              })
              .enabled(!this.isSaving)
          }
          .width('100%')
          .padding(16)
        }
        .width('100%')
        .height('100%')
      }

      if (this.selectorState.showNameDialog) {
        Column() {
          Column({ space: 16 }) {
            Text('自定义文件夹名称')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.ohos_id_color_text_primary'))

            Text('文件夹：' + this.selectorState.pendingDefaultName)
              .fontSize(13)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            TextInput({
              placeholder: this.selectorState.pendingDefaultName,
              text: this.selectorState.inputCustomName,
              controller: this.nameInputController
            })
              .onChange((value: string) => {
                this.selectorState.inputCustomName = value
              })
              .onAppear(() => {
                this.nameInputController.caretPosition(this.selectorState.inputCustomName.length)
                focusControl.requestFocus('directorySelectorNameInput')
              })
              .id('directorySelectorNameInput')
              .defaultFocus(true)
              .fontSize(16)
              .borderRadius(8)

            Row({ space: 12 }) {
              Button('取消')
                .layoutWeight(1)
                .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
                .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
                .onClick(() => this.selectorState.cancelPendingSelection())

              Button('确定')
                .layoutWeight(1)
                .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
                .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
                .onClick(() => this.selectorState.confirmPendingSelection())
            }
            .width('100%')
          }
          .width('72%')
          .padding(24)
          .backgroundColor($r('sys.color.ohos_id_color_background'))
          .borderRadius(12)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#66000000')
      }
    }
  }
}

@Builder
export function DirectorySelectorBuilder() {
  DirectorySelectorBuilderComponent()
}
