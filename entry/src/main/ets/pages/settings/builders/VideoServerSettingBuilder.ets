import { SettingListItem } from "../SettingListItem";
import { SettingListItemGroup } from "../SettingListItemGroup";
import { SettingContainer } from "../SettingContainer";
import { SettingsController } from "../SettingsController";
import { VideoServerTypeIcon } from "./IconBuilders";
import { VideoServerStore } from "../../../stores/servers/VideoServerStore";
import { VideoServerModel, videoServerTypeLabel, settingTypeFor } from "../../../stores/servers/VideoServerModel";
import { VideoServer } from "../../../db/models/VideoServerEntity";
import { DeleteServerDialog } from "../../../components/dialogs/DeleteServerDialog";
import SettingType from "../SettingType";
import { BusinessError } from "@kit.BasicServicesKit";

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
      console.error('VideoServerSettingBuilder: Failed to load video servers', (error as BusinessError).message ?? String(error))
      this.showToastSafe('加载影视服务器失败')
    } finally {
      this.isLoading = false
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
    this.controller.pushType(settingTypeFor(server.type), params)
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
      await this.videoServerModel.deleteVideoServerWithFallback(target.id)
      this.showToastSafe('服务器已删除')
    } catch (error) {
      console.error('VideoServerSettingBuilder: 删除服务器失败', (error as BusinessError).message ?? String(error))
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
      DeleteServerDialog({
        visible: this.showDeleteDialog,
        isDeleting: this.isDeletingServer,
        onCancel: () => {
          this.showDeleteDialog = false
          this.deleteTarget = null
        },
        onConfirm: () => {
          this.confirmDeleteServer()
        }
      })
    }
    .width('100%')
    .height('100%')
  }
}

@Builder
export function VideoServerSettingBuilder() {
  VideoServerSettingBuilderComponent()
}
