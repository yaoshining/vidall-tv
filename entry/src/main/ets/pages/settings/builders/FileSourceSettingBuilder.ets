import { SettingListItem } from "../SettingListItem";
import { SettingListItemGroup } from "../SettingListItemGroup";
import { SettingContainer } from "../SettingContainer";
import { SettingsController } from "../SettingsController";
import SettingType from "../SettingType";
import { FileSourceStore } from "../../../lib/stores/FileSourceStore";
import { FileSource, FileSourceType } from "../../../lib/models/FileSourceModel";
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

@ComponentV2
struct FileSourceSettingBuilderComponent {
  @Consumer('settingsController') controller: SettingsController = new SettingsController()
  @Local fileSourceStore: FileSourceStore = FileSourceStore.getInstance()
  @Local isLoading: boolean = false

  aboutToAppear(): void {
    // 加载文件源列表
    this.loadFileSources()
  }

  async loadFileSources(): Promise<void> {
    try {
      this.isLoading = true
      await this.fileSourceStore.loadFileSources()
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
        ForEach(this.fileSourceStore.fileSources, (fileSource: FileSource) => {
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
              // 点击进入文件列表详情页（后续实现）
              console.info('FileSourceSettingBuilder: Click file source', fileSource.id)
              promptAction.showToast({
                message: '文件列表功能即将上线'
              } as promptAction.ShowToastOptions)
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
