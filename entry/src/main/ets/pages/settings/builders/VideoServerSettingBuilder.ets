import { SettingListItem } from "../SettingListItem";
import { SettingListItemGroup } from "../SettingListItemGroup";
import { SettingContainer } from "../SettingContainer";
import { SettingsController } from "../SettingsController";
import SettingType from "../SettingType";
import { VideoServerTypeIcon } from "./IconBuilders";
import { VideoServerStore } from "../../../stores/servers/VideoServerStore";
import { VideoServerModel, videoServerTypeLabel } from "../../../stores/servers/VideoServerModel";
import { VideoServer, VideoServerType } from "../../../db/models/VideoServerEntity";

@ComponentV2
struct VideoServerSettingBuilderComponent {
  @Consumer('settingsController') controller: SettingsController = new SettingsController()
  @Local videoServerModel: VideoServerModel = VideoServerStore.getState()
  @Local isLoading: boolean = false

  // 删除确认弹窗状态
  @Local showDeleteDialog: boolean = false
  @Local deleteTarget: VideoServer | null = null
  @Local isDeletingServer: boolean = false

  private showToastSafe(message: string, duration: number = 2000): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration })
    } catch (_e) {}
  }

  aboutToAppear(): void {
    this.loadVideoServers()
  }

  async loadVideoServers(): Promise<void> {
    try {
      this.isLoading = true
      await this.videoServerModel.loadVideoServers(true)
    } catch (error) {
      console.error('VideoServerSettingBuilder: Failed to load video servers', (error as Error).message ?? String(error))
      this.showToastSafe('加载影视服务器失败')
    } finally {
      this.isLoading = false
    }
  }

  private settingTypeFor(serverType: VideoServerType): SettingType {
    switch (serverType) {
      case VideoServerType.JELLYFIN:
        return SettingType.JELLYFIN_CONFIG
      case VideoServerType.EMBY:
        return SettingType.EMBY_CONFIG
      case VideoServerType.PLEX:
        return SettingType.PLEX_CONFIG
      default:
        return SettingType.JELLYFIN_CONFIG
    }
  }

  handleEdit(server: VideoServer): void {
    if (server.id === undefined) {
      this.showToastSafe('服务器 ID 不存在')
      return
    }
    const params: Record<string, Object> = {}
    params['serverType'] = server.type as Object
    params['serverId'] = server.id as Object
    this.controller.pushType(this.settingTypeFor(server.type), params)
  }

  handleDelete(server: VideoServer): void {
    this.deleteTarget = server
    this.showDeleteDialog = true
  }

  async confirmDeleteServer(): Promise<void> {
    const target = this.deleteTarget
    if (target === null || target.id === undefined) {
      return
    }
    try {
      this.isDeletingServer = true
      await this.videoServerModel.deleteVideoServer(target.id)
      this.showToastSafe('服务器已删除')
    } catch (error) {
      console.error('VideoServerSettingBuilder: 删除服务器失败', (error as Error).message ?? String(error))
      this.showToastSafe('删除失败，请重试')
    } finally {
      this.isDeletingServer = false
      this.showDeleteDialog = false
      this.deleteTarget = null
    }
  }

  @Builder
  buildMoreButton() {
    Text("⋮")
      .fontSize(24)
      .fontColor($r('sys.color.font_secondary'))
  }

  build() {
    Stack() {
      SettingContainer({
        title: "影视服务器"
      }) {
        SettingListItemGroup({
          title: "已添加的服务器"
        }) {
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

          ForEach(this.videoServerModel.videoServers, (server: VideoServer) => {
            SettingListItem({
              icon: () => {
                VideoServerTypeIcon(server.type)
              },
              title: server.name,
              value: videoServerTypeLabel(server.type),
              rightIcon: () => {
                this.buildMoreButton()
              },
              menuItems: [
                {
                  value: '编辑',
                  action: () => {
                    this.handleEdit(server)
                  }
                },
                {
                  value: '删除',
                  action: () => {
                    this.handleDelete(server)
                  }
                }
              ],
              onItemClick: () => {
                this.handleEdit(server)
              }
            })
          }, (server: VideoServer) => (server.id?.toString() || '') + '_' + server.name)

          // 添加服务器按钮
          SettingListItem({
            title: "添加服务器",
            isLink: true,
            onItemClick: () => {
              this.controller.pushType(SettingType.ADD_VIDEO_SERVER)
            }
          })
        }
      }

      // ── 删除服务器确认弹窗 ──
      if (this.showDeleteDialog) {
        Column() {
          Column() {
            Text('删除影视服务器')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .margin({ bottom: 12 })
            Text('确认删除该影视服务器？此操作仅移除服务器配置，不影响其他数据。')
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
                  this.showDeleteDialog = false
                  this.deleteTarget = null
                })
              Button(this.isDeletingServer ? '删除中...' : '确认删除')
                .layoutWeight(1)
                .fontColor(Color.White)
                .backgroundColor('#FF4444')
                .enabled(!this.isDeletingServer)
                .onClick(() => {
                  this.confirmDeleteServer()
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
        .onClick(() => {})
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
  }
}

@Builder
export function VideoServerSettingBuilder() {
  VideoServerSettingBuilderComponent()
}
