import { VideoServer } from "../../../db/models/VideoServerEntity"
import { VideoServerStore } from "../../../stores/servers/VideoServerStore"
import { VideoServerModel, videoServerTypeLabel } from "../../../stores/servers/VideoServerModel"
import { SourceSwitchModel } from "../../../stores/media/SourceSwitchModel"
import { VideoServerTypeIcon } from "../../settings/builders/IconBuilders"

/**
 * 媒体库数据源切换弹窗：列出「文件源」与每台已添加的影视服务器。
 */
@ComponentV2
export struct SourceSwitchDialog {
  @Event onClose: () => void = () => {}
  @Local videoServerModel: VideoServerModel = VideoServerStore.getState()
  sourceSwitchModel: SourceSwitchModel = SourceSwitchModel.getState()
  @Local focusedKey: string = ''

  private handleSelectFileSource(): void {
    this.sourceSwitchModel.setFileSource().catch(() => {})
    this.onClose()
  }

  private handleSelectServer(server: VideoServer): void {
    this.sourceSwitchModel.setVideoServer(server).catch(() => {})
    this.onClose()
  }

  private isFileSourceActive(): boolean {
    return this.sourceSwitchModel.isFileSource()
  }

  private isServerActive(server: VideoServer): boolean {
    return this.sourceSwitchModel.getActiveServerId() === server.id
  }

  build() {
    Column() {
      Column() {
        Text('切换数据源')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 16 })

        // 文件源
        Row({ space: 12 }) {
          Text('📁')
            .fontSize(22)
          Text('文件源')
            .fontSize(16)
            .fontColor(this.isFileSourceActive() ? '#FFFFFF' : '#DDDDDD')
            .layoutWeight(1)
          if (this.isFileSourceActive()) {
            Text('✓')
              .fontSize(16)
              .fontColor('#4A9FFF')
          }
        }
        .width('100%')
        .height(48)
        .padding({ left: 16, right: 16 })
        .borderRadius(8)
        .backgroundColor(this.isFileSourceActive() ? '#2A4A6B' : '#333333')
        .border({ width: 2, color: this.focusedKey === 'file' ? '#4A9FFF' : '#00FFFFFF' })
        .hoverEffect(HoverEffect.Highlight)
        .focusable(true)
        .defaultFocus(true)
        .onFocus(() => { this.focusedKey = 'file' })
        .onBlur(() => { if (this.focusedKey === 'file') { this.focusedKey = '' } })
        .onClick(() => {
          this.handleSelectFileSource()
        })
        .margin({ bottom: 8 })

        // 各影视服务器
        ForEach(this.videoServerModel.videoServers, (server: VideoServer) => {
          Row({ space: 12 }) {
            Column() {
              VideoServerTypeIcon(server.type)
            }
            .width(26)
            .height(26)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            Text(server.name)
              .fontSize(16)
              .fontColor(this.isServerActive(server) ? '#FFFFFF' : '#DDDDDD')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(videoServerTypeLabel(server.type))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
            if (this.isServerActive(server)) {
              Text('✓')
                .fontSize(16)
                .fontColor('#4A9FFF')
            }
          }
          .width('100%')
          .height(48)
          .padding({ left: 16, right: 16 })
          .borderRadius(8)
          .backgroundColor(this.isServerActive(server) ? '#2A4A6B' : '#333333')
          .border({ width: 2, color: this.focusedKey === 'server_' + String(server.id ?? 0) ? '#4A9FFF' : '#00FFFFFF' })
          .hoverEffect(HoverEffect.Highlight)
          .focusable(true)
          .onFocus(() => { this.focusedKey = 'server_' + String(server.id ?? 0) })
          .onBlur(() => { if (this.focusedKey === 'server_' + String(server.id ?? 0)) { this.focusedKey = '' } })
          .onClick(() => {
            this.handleSelectServer(server)
          })
          .margin({ bottom: 8 })
        }, (server: VideoServer) => (server.id?.toString() || '') + '_' + server.name)

        // 取消
        Button('取消')
          .width('100%')
          .height(40)
          .fontSize(16)
          .fontColor($r('sys.color.font_primary'))
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .margin({ top: 8 })
          .onClick(() => {
            this.onClose()
          })
      }
      .width(360)
      .padding(24)
      .backgroundColor($r('sys.color.comp_background_primary'))
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#80000000')
    .onClick(() => {}) // 拦截蒙层点击穿透
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
