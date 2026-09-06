import { LengthMetrics } from "@kit.ArkUI"
import { BusinessError } from "@kit.BasicServicesKit"
import { VideoServer, VideoServerType } from "../../../db/models/VideoServerEntity"
import { VideoServerStore } from "../../../stores/servers/VideoServerStore"
import { VideoServerModel, videoServerTypeLabel, settingTypeFor } from "../../../stores/servers/VideoServerModel"
import { SourceSwitchModel } from "../../../stores/media/SourceSwitchModel"
import { VideoServerTypeIcon } from "../../settings/builders/IconBuilders"
import { TabBarModel, TabItem, TabItemCode } from "../../../stores/tabbar/TabBarModel"
import { TabBarStore } from "../../../stores/tabbar/TabBarStore"
import { SettingsPage, SettingsPageParam } from "../../settings/Index"
import { DeleteServerDialog } from "../../../components/dialogs/DeleteServerDialog"

@ComponentV2
export struct VideoServerTab {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  @Local videoServerModel: VideoServerModel = VideoServerStore.getState()
  tabBarModel: TabBarModel = TabBarStore.getState()
  sourceSwitchModel: SourceSwitchModel = SourceSwitchModel.getState()
  @Local isLoading: boolean = false
  @Local showDeleteDialog: boolean = false
  @Local deleteTarget: VideoServer | null = null
  @Local isDeletingServer: boolean = false

  aboutToAppear(): void {
    this.loadServers()
  }

  async loadServers(): Promise<void> {
    try {
      this.isLoading = true
      await this.videoServerModel.loadVideoServers(true)
      // 校验当前源仍有效（服务器被删则回退文件源）
      await this.sourceSwitchModel.load(this.videoServerModel.videoServers)
    } catch (error) {
      console.error('VideoServerTab: 加载服务器失败', (error as BusinessError).message ?? String(error))
    } finally {
      this.isLoading = false
    }
  }

  private showToastSafe(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration: 2000 })
    } catch (_e) {}
  }

  private openEdit(server: VideoServer): void {
    if (server.id === undefined) {
      this.showToastSafe('服务器 ID 不存在')
      return
    }
    const param: SettingsPageParam = {
      type: settingTypeFor(server.type),
      serverType: server.type,
      serverId: server.id
    }
    this.pageStack.pushPath({
      name: SettingsPage.PAGE_NAME,
      param: param
    })
  }

  private handleCardClick(server: VideoServer): void {
    // 点击卡片设为当前源并切到媒体库（按 code 定位，避免硬编码 tab 索引）
    this.sourceSwitchModel.setVideoServer(server).catch(() => {})
    const index = this.tabBarModel.tabs.findIndex((t: TabItem) => t.code === TabItemCode.MEDIA_LIBRARY)
    if (index >= 0) {
      this.tabBarModel.currentTabIndex = index
    }
  }

  private handleDelete(server: VideoServer): void {
    this.deleteTarget = server
    this.showDeleteDialog = true
  }

  private async confirmDeleteServer(): Promise<void> {
    const target = this.deleteTarget
    if (target === null || target.id === undefined) {
      return
    }
    try {
      this.isDeletingServer = true
      await this.videoServerModel.deleteVideoServerWithFallback(target.id)
      this.showToastSafe('服务器已删除')
    } catch (error) {
      console.error('VideoServerTab: 删除服务器失败', (error as BusinessError).message ?? String(error))
      this.showToastSafe('删除失败，请重试')
    } finally {
      this.isDeletingServer = false
      this.showDeleteDialog = false
      this.deleteTarget = null
    }
  }

  @Builder
  buildTypeIcon(type: VideoServerType) {
    VideoServerTypeIcon(type)
  }

  @Builder
  buildMoreMenu(server: VideoServer) {
    Text("⋮")
      .fontSize(22)
      .fontColor($r('sys.color.font_secondary'))
      .width(28)
      .height(28)
      .textAlign(TextAlign.Center)
      .borderRadius(4)
      .hoverEffect(HoverEffect.Highlight)
      .bindMenu([
        { value: '编辑', action: () => { this.openEdit(server) } },
        { value: '删除', action: () => { this.handleDelete(server) } }
      ])
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        if (this.isLoading) {
          Column() {
            LoadingProgress().width(40).height(40).color('#AAAAAA')
          }
          .width('100%')
          .height(200)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else if (this.videoServerModel.videoServers.length === 0) {
          Column() {
            Text('暂无服务器')
              .fontSize(16)
              .fontColor('#666666')
            Text('点击顶部栏「添加影视服务器」接入 Jellyfin / Emby / Plex')
              .fontSize(12)
              .fontColor('#444444')
              .margin({ top: 8 })
          }
          .width('100%')
          .height(200)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else {
          GridRow({
            gutter: 10,
            columns: 2
          }) {
            ForEach(this.videoServerModel.videoServers, (server: VideoServer) => {
              GridCol() {
                Flex({
                  alignItems: ItemAlign.Center,
                  justifyContent: FlexAlign.Start,
                  space: {
                    main: LengthMetrics.vp(20)
                  }
                }) {
                  Column() {
                    this.buildTypeIcon(server.type)
                  }
                  .width(60)
                  .height(60)
                  .justifyContent(FlexAlign.Center)
                  .alignItems(HorizontalAlign.Center)
                  Flex({
                    direction: FlexDirection.Column,
                    justifyContent: FlexAlign.SpaceAround,
                  }) {
                    Text(server.name)
                      .fontSize($r('app.float.font_subtitle_1'))
                      .fontWeight(FontWeight.Bold)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(videoServerTypeLabel(server.type))
                      .opacity(0.6)
                  }
                  .height("100%")
                  .layoutWeight(1)
                  this.buildMoreMenu(server)
                }
              }
              .onClick(() => {
                this.handleCardClick(server)
              })
              .height(80)
              .padding({ left: 20, right: 20, top: 10, bottom: 10 })
              .borderRadius(6)
              .backgroundColor("#373737")
              .hoverEffect(HoverEffect.Highlight)
            }, (server: VideoServer) => (server.id?.toString() || '') + '_' + server.name)
          }
          .width('100%')
        }
      }
      .width('100%')

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
