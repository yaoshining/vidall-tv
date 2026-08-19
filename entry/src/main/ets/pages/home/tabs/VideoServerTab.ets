import { LengthMetrics } from "@kit.ArkUI"
import { VideoServer, VideoServerType } from "../../../db/models/VideoServerEntity"
import { VideoServerStore } from "../../../stores/servers/VideoServerStore"
import { VideoServerModel, videoServerTypeLabel } from "../../../stores/servers/VideoServerModel"
import { SourceSwitchModel } from "../../../stores/media/SourceSwitchModel"
import { VideoServerTypeIcon } from "../../settings/builders/IconBuilders"
import { TabBarModel } from "../../../stores/tabbar/TabBarModel"
import { TabBarStore } from "../../../stores/tabbar/TabBarStore"
import { SettingsPage, SettingsPageParam } from "../../settings/Index"
import SettingType from "../../settings/SettingType"

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
      await this.sourceSwitchModel.load(this.videoServerModel.videoServers.map(s => s.id ?? -1))
    } catch (error) {
      console.error('VideoServerTab: 加载服务器失败', JSON.stringify(error))
    } finally {
      this.isLoading = false
    }
  }

  private showToastSafe(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration: 2000 })
    } catch (_e) {}
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

  private openEdit(server: VideoServer): void {
    if (!server.id) {
      this.showToastSafe('服务器 ID 不存在')
      return
    }
    this.pageStack.pushPath({
      name: SettingsPage.PAGE_NAME,
      param: {
        type: this.settingTypeFor(server.type),
        serverType: server.type,
        serverId: server.id
      } as SettingsPageParam
    })
  }

  private handleCardClick(server: VideoServer): void {
    // 点击卡片设为当前源并切到媒体库
    this.sourceSwitchModel.setVideoServer(server)
    this.tabBarModel.currentTabIndex = 0
  }

  private handleDelete(server: VideoServer): void {
    this.deleteTarget = server
    this.showDeleteDialog = true
  }

  private async confirmDeleteServer(): Promise<void> {
    const target = this.deleteTarget
    if (!target || !target.id) {
      return
    }
    try {
      this.isDeletingServer = true
      await this.videoServerModel.deleteVideoServer(target.id)
      // 若删除的是当前源，回退到文件源
      if (this.sourceSwitchModel.getActiveServerId() === target.id) {
        this.sourceSwitchModel.setFileSource()
      }
      this.showToastSafe('服务器已删除')
    } catch (error) {
      console.error('VideoServerTab: 删除服务器失败', JSON.stringify(error))
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
