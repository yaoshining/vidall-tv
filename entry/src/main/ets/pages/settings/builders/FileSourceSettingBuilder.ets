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
import { FileSource, FileSourceType, WebDAVSourceConfig } from "../../../db/models/FileSourceEntity";
import { FileSourceModel } from "../../../stores/files/FileSourceModel";

@ComponentV2
struct FileSourceSettingBuilderComponent {
  @Consumer('settingsController') controller: SettingsController = new SettingsController()
  @Local fileSourceModel: FileSourceModel = FileSourceStore.getState()
  @Local isLoading: boolean = false

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
      promptAction.showToast({
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

  /**
   * 获取文件源类型的图标
   */
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
    } else {
      promptAction.showToast({
        message: '该类型暂不支持编辑'
      } as promptAction.ShowToastOptions)
    }
  }

  /**
   * 删除文件源
   */
  handleDelete(fileSource: FileSource): void {
    // ...existing code...
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

    // 目前只支持 WebDAV 类型
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
    } else {
      promptAction.showToast({
        message: '该类型暂不支持文件夹管理'
      } as promptAction.ShowToastOptions)
    }
  }

  build() {
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
  }
}

@Builder
export function FileSourceSettingBuilder(
  controller: SettingsController
) {
  FileSourceSettingBuilderComponent()
}
