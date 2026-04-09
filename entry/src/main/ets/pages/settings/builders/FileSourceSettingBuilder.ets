import { SettingListItem } from "../SettingListItem";
import { SettingListItemGroup } from "../SettingListItemGroup";
import { SettingContainer } from "../SettingContainer";
import { SettingsController } from "../SettingsController";
import SettingType from "../SettingType";
import {
  WebdavIcon,
  SmbIcon,
  AliyunIcon,
  Cloud139Icon,
  BaiduIcon,
  Cloud123Icon,
  Cloud115Icon,
  OtherIcon
} from "./IconBuilders";
import promptAction from '@ohos.promptAction';
import { FileSourceStore } from "../../../stores/files/FileSourceStore";
import { FileSource, FileSourceType, WebDAVSourceConfig, SMBSourceConfig } from "../../../db/models/FileSourceEntity"
import { FileSourceModel, DirectoryItem } from "../../../stores/files/FileSourceModel";

@ComponentV2
struct FileSourceSettingBuilderComponent {
  @Consumer('settingsController') controller: SettingsController = new SettingsController()
  @Local fileSourceModel: FileSourceModel = FileSourceStore.getState()
  @Local isLoading: boolean = false

  // 一键清理弹窗状态
  @Local showCleanupDialog: boolean = false
  @Local cleanupTarget: DirectoryItem | null = null
  @Local isCleaningUp: boolean = false

  // 删除文件源确认弹窗状态
  @Local showDeleteDialog: boolean = false
  @Local deleteTarget: FileSource | null = null
  @Local isDeletingSource: boolean = false

  aboutToAppear(): void {
    // 加载文件源列表
    this.loadFileSources()
  }

  async loadFileSources(): Promise<void> {
    try {
      this.isLoading = true
      await this.fileSourceModel.loadFileSources()
    } catch (error) {
      console.error('FileSourceSettingBuilder: Failed to load file sources', JSON.stringify(error))
      this.getUIContext().getPromptAction().showToast({
        message: '加载文件源失败'
      } as promptAction.ShowToastOptions)
    } finally {
      this.isLoading = false
    }
  }

  /**
   * 获取文件源类型的中文名称
   */
  getFileSourceTypeName(type: FileSourceType): string {
    const typeMap: Record<string, string> = {
      'webdav': 'WebDAV',
      'smb': 'SMB',
      'aliyun': '阿里云盘',
      'cloud139': '139网盘',
      'baidu': '百度网盘',
      'cloud123': '123网盘',
      'cloud115': '115网盘',
      'other': '其他'
    }
    return typeMap[type] || '未知类型'
  }

  @Builder
  getFileSourceTypeIcon(type: FileSourceType) {
    if (type === FileSourceType.WEBDAV) {
      WebdavIcon()
    } else if (type === FileSourceType.SMB) {
      SmbIcon()
    } else if (type === FileSourceType.ALIYUN) {
      AliyunIcon()
    } else if (type === FileSourceType.CLOUD_139) {
      Cloud139Icon()
    } else if (type === FileSourceType.BAIDU) {
      BaiduIcon()
    } else if (type === FileSourceType.CLOUD_123) {
      Cloud123Icon()
    } else if (type === FileSourceType.CLOUD_115) {
      Cloud115Icon()
    } else {
      OtherIcon()
    }
  }

  /**
   * 构建右侧更多按钮
   */
  @Builder
  buildMoreButton() {
    Text("⋮")
      .fontSize(24)
      .fontColor($r('sys.color.font_secondary'))
  }

  /**
   * 编辑文件源
   */
  handleEdit(fileSource: FileSource): void {
    console.info('FileSourceSettingBuilder: Edit file source', fileSource.id)

    // 检查 id 是否存在
    if (!fileSource.id) {
      promptAction.showToast({
        message: '文件源 ID 不存在'
      } as promptAction.ShowToastOptions)
      return
    }

    // 根据类型跳转到对应的编辑页面
    if (fileSource.type === FileSourceType.WEBDAV) {
      const params: ESObject = {}
      params['fileSourceId'] = fileSource.id as Object
      this.controller.pushType(SettingType.WEBDAV_CONFIG, params as Record<string, Object>)
    } else if (fileSource.type === FileSourceType.SMB) {
      const params: ESObject = {}
      params['fileSourceId'] = fileSource.id as Object
      this.controller.pushType(SettingType.SMB_CONFIG, params as Record<string, Object>)
    } else {
      promptAction.showToast({
        message: '暂不支持编辑该协议类型'
      } as promptAction.ShowToastOptions)
    }
  }

  /**
   * 删除文件源（弹出确认 Dialog）
   */
  handleDelete(fileSource: FileSource): void {
    this.deleteTarget = fileSource;
    this.showDeleteDialog = true;
  }

  /**
   * 确认删除文件源
   */
  async confirmDeleteFileSource(): Promise<void> {
    const target = this.deleteTarget;
    if (!target || !target.id) {
      return;
    }
    try {
      this.isDeletingSource = true;
      await this.fileSourceModel.deleteFileSource(target.id);
      await this.fileSourceModel.loadFileSources(true);
      this.getUIContext().getPromptAction().showToast({
        message: '文件源已删除'
      } as promptAction.ShowToastOptions);
    } catch (error) {
      console.error('FileSourceSettingBuilder: 删除文件源失败', JSON.stringify(error));
      this.getUIContext().getPromptAction().showToast({
        message: '删除失败，请重试'
      } as promptAction.ShowToastOptions);
    } finally {
      this.isDeletingSource = false;
      this.showDeleteDialog = false;
      this.deleteTarget = null;
    }
  }

  /**
   * 一键清理缺失目录（弹出确认 Dialog）
   */
  handleCleanupMissingDir(item: DirectoryItem): void {
    this.cleanupTarget = item;
    this.showCleanupDialog = true;
  }

  /**
   * 确认清理缺失目录
   */
  async confirmCleanupDir(): Promise<void> {
    const target = this.cleanupTarget;
    if (!target || target.dirId === undefined) {
      return;
    }
    try {
      this.isCleaningUp = true;
      await this.fileSourceModel.clearMissingDirectory(
        target.dirId,
        target.fileSource.id ?? 0,
        target.directoryPath
      );
      this.getUIContext().getPromptAction().showToast({
        message: '目录已清理'
      } as promptAction.ShowToastOptions);
    } catch (error) {
      console.error('FileSourceSettingBuilder: 清理失败', JSON.stringify(error));
      this.getUIContext().getPromptAction().showToast({
        message: '清理失败，请重试'
      } as promptAction.ShowToastOptions);
    } finally {
      this.isCleaningUp = false;
      this.showCleanupDialog = false;
      this.cleanupTarget = null;
    }
  }

  /**
   * 重新定位目录（进入编辑目录界面）
   */
  handleRelocateDir(item: DirectoryItem): void {
    this.showCleanupDialog = false;
    this.cleanupTarget = null;
    this.handleOpenDirectorySelector(item.fileSource);
  }

  /**
   * 打开文件夹选择器
   */
  handleOpenDirectorySelector(fileSource: FileSource): void {
    console.info('FileSourceSettingBuilder: Open directory selector', fileSource.id)

    // 检查 id 是否存在
    if (!fileSource.id) {
      this.getUIContext().getPromptAction().showToast({
        message: '文件源 ID 不存在'
      } as promptAction.ShowToastOptions)
      return
    }

    if (fileSource.type === FileSourceType.WEBDAV) {
      try {
        // 解析配置
        const config = JSON.parse(fileSource.configJson) as WebDAVSourceConfig

        // 构造完整的 baseUrl
        let serverAddress = config.url
        let port = config.port

        // 如果服务器地址中已经包含端口，提取它们
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

        // 添加路径
        const path = config.rootPath || '/'
        if (path !== '/') {
          const formattedPath = path.startsWith('/') ? path : '/' + path
          baseUrl = baseUrl + formattedPath
        }

        // 跳转到文件夹选择器
        const params: ESObject = {}
        params['sourceId'] = fileSource.id as Object
        params['baseUrl'] = baseUrl as Object
        params['username'] = config.username as Object
        params['password'] = config.password as Object
        params['protocol'] = config.protocol as Object
        params['port'] = port as Object
        params['rootPath'] = path as Object

        this.controller.pushType(SettingType.DIRECTORY_SELECTOR, params as Record<string, Object>)
      } catch (error) {
        console.error('FileSourceSettingBuilder: Failed to parse config', JSON.stringify(error))
        promptAction.showToast({
          message: '解析配置失败'
        } as promptAction.ShowToastOptions)
      }
    } else if (fileSource.type === FileSourceType.SMB) {
      try {
        const config = JSON.parse(fileSource.configJson) as SMBSourceConfig
        const params: ESObject = {}
        params['sourceId'] = fileSource.id as Object
        params['host'] = config.host as Object
        params['username'] = config.username as Object
        params['password'] = (config.password ?? '') as Object
        params['port'] = (config.port ?? 445) as Object
        params['domain'] = (config.domain ?? '') as Object
        this.controller.pushType(SettingType.SMB_DIRECTORY_SELECTOR, params as Record<string, Object>)
      } catch (e) {
        console.error('FileSourceSettingBuilder: Failed to parse SMB config', JSON.stringify(e))
        promptAction.showToast({
          message: '解析 SMB 配置失败'
        } as promptAction.ShowToastOptions)
      }
    } else {
      promptAction.showToast({
        message: '该类型暂不支持文件夹管理'
      } as promptAction.ShowToastOptions)
    }
  }

  build() {
    Stack() {
      SettingContainer({
        title: "文件源"
      }) {
        SettingListItemGroup({
          title: "已添加的文件源"
        }) {
          // 显示加载状态
          if (this.isLoading) {
            Row() {
              LoadingProgress()
                .width(30)
                .height(30)
                .margin(20)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
          }

          // 显示文件源列表
          ForEach(this.fileSourceModel.fileSources, (fileSource: FileSource) => {
            SettingListItem({
              icon: () => {
                this.getFileSourceTypeIcon(fileSource.type)
              },
              title: fileSource.name,
              value: this.getFileSourceTypeName(fileSource.type),
              rightIcon: () => {
                this.buildMoreButton()
              },
              menuItems: [
                {
                  value: '编辑',
                  action: () => {
                    this.handleEdit(fileSource)
                  }
                },
                {
                  value: '删除',
                  action: () => {
                    this.handleDelete(fileSource)
                  }
                }
              ],
              onItemClick: () => {
                // 点击打开文件夹选择器
                this.handleOpenDirectorySelector(fileSource)
              }
            })
            // 展示该文件源下的目录状态（缺失/不可达时显示标记）
            ForEach(
              this.fileSourceModel.directories.filter(
                (d: DirectoryItem) => d.fileSource.id === fileSource.id && d.dirStatus !== 'active'
              ),
              (dirItem: DirectoryItem) => {
                Row() {
                  // 状态标识徽章
                  Text(dirItem.dirStatus === 'missing' ? '路径缺失' : '暂不可达')
                    .fontSize(10)
                    .fontColor(dirItem.dirStatus === 'missing' ? '#FF4444' : '#FF8800')
                    .backgroundColor(dirItem.dirStatus === 'missing' ? '#FFE8E8' : '#FFF3E0')
                    .borderRadius(4)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .margin({ right: 8 })
                  Text(dirItem.customName || dirItem.directoryName)
                    .fontSize(12)
                    .fontColor($r('sys.color.font_secondary'))
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (dirItem.dirStatus === 'missing') {
                    Button('一键清理')
                      .fontSize(11)
                      .height(28)
                      .padding({ left: 10, right: 10 })
                      .fontColor(Color.White)
                      .backgroundColor('#FF4444')
                      .borderRadius(4)
                      .onClick(() => {
                        this.handleCleanupMissingDir(dirItem)
                      })
                  }
                }
                .width('100%')
                .padding({ left: 56, right: 16, top: 4, bottom: 4 })
                .alignItems(VerticalAlign.Center)
              },
              (dirItem: DirectoryItem) => (dirItem.dirId ?? 0).toString() + dirItem.dirStatus
            )
          }, (fileSource: FileSource) => fileSource.id?.toString() || '')

          // 添加文件源按钮
          SettingListItem({
            title: "添加文件源",
            isLink: true,
            onItemClick: () => {
              this.controller.pushType(SettingType.ADD_FILE_SOURCE)
            }
          })
        }
      }

      // ── 删除文件源确认弹窗 ──
      if (this.showDeleteDialog) {
        Column() {
          Column() {
            Text('删除文件源')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .margin({ bottom: 12 })
            Text('确认删除文件源？此操作将同时删除：文件源配置记录、所有目录配置、所有扫描媒体记录。')
              .fontSize(14)
              .fontColor($r('sys.color.font_secondary'))
              .textAlign(TextAlign.Start)
              .margin({ bottom: 20 })
            Row() {
              Button('取消')
                .layoutWeight(1)
                .margin({ right: 8 })
                .fontColor($r('sys.color.font_primary'))
                .backgroundColor($r('sys.color.comp_background_tertiary'))
                .onClick(() => {
                  this.showDeleteDialog = false;
                  this.deleteTarget = null;
                })
              Button(this.isDeletingSource ? '删除中...' : '确认删除')
                .layoutWeight(1)
                .fontColor(Color.White)
                .backgroundColor('#FF4444')
                .enabled(!this.isDeletingSource)
                .onClick(() => {
                  this.confirmDeleteFileSource()
                })
            }
            .width('100%')
          }
          .width(360)
          .padding(24)
          .backgroundColor($r('sys.color.comp_background_primary'))
          .borderRadius(12)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      // ── 一键清理缺失目录确认弹窗 ──
      if (this.showCleanupDialog) {
        Column() {
          Column() {
            Text('移除路径缺失目录')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .margin({ bottom: 12 })
            Text('该目录在服务器上已不存在。确认后将清除该目录的配置记录及所有扫描媒体记录。')
              .fontSize(14)
              .fontColor($r('sys.color.font_secondary'))
              .textAlign(TextAlign.Start)
              .margin({ bottom: 20 })
            Row() {
              Button('稍后重试')
                .layoutWeight(1)
                .margin({ right: 6 })
                .fontColor($r('sys.color.font_primary'))
                .backgroundColor($r('sys.color.comp_background_tertiary'))
                .onClick(() => {
                  this.showCleanupDialog = false;
                  this.cleanupTarget = null;
                })
              Button('重新定位')
                .layoutWeight(1)
                .margin({ right: 6 })
                .fontColor($r('sys.color.font_primary'))
                .backgroundColor($r('sys.color.comp_background_tertiary'))
                .onClick(() => {
                  const target = this.cleanupTarget;
                  if (target !== null) {
                    this.handleRelocateDir(target);
                  }
                })
              Button(this.isCleaningUp ? '清理中...' : '一键清理')
                .layoutWeight(1)
                .fontColor(Color.White)
                .backgroundColor('#FF4444')
                .enabled(!this.isCleaningUp)
                .onClick(() => {
                  this.confirmCleanupDir()
                })
            }
            .width('100%')
          }
          .width(400)
          .padding(24)
          .backgroundColor($r('sys.color.comp_background_primary'))
          .borderRadius(12)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
  }
}

@Builder
export function FileSourceSettingBuilder(
  controller: SettingsController
) {
  FileSourceSettingBuilderComponent()
}
