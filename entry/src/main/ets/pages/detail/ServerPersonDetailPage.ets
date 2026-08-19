import { VideoServerModel } from "../../stores/servers/VideoServerModel"
import { VideoServerStore } from "../../stores/servers/VideoServerStore"
import { VideoServerType } from "../../db/models/VideoServerEntity"
import { JellyfinClient, VideoServerPersonDetail, VideoServerMediaItem } from "../../lib/JellyfinClient"
import { PlexClient } from "../../lib/PlexClient"
import { ServerMediaDetailPage, ServerMediaDetailPageParam } from "./ServerMediaDetailPage"
import { BusinessError } from "@kit.BasicServicesKit"

export interface ServerPersonDetailPageParam {
  serverId: number
  personId: string
  name: string
  role: string
  imageUrl: string
}

@ComponentV2
export struct ServerPersonDetailPage {
  static PAGE_NAME = 'serverPersonDetail'
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  videoServerModel: VideoServerModel = VideoServerStore.getState()
  @Local serverId: number = 0
  @Local personId: string = ''
  @Local fallbackName: string = ''
  @Local role: string = ''
  @Local fallbackImageUrl: string = ''
  @Local detail: VideoServerPersonDetail | null = null
  @Local isLoading: boolean = true
  @Local bioExpanded: boolean = false
  @Local error: string = ''

  private async loadData(): Promise<void> {
    this.isLoading = true
    this.error = ''
    try {
      await this.videoServerModel.loadVideoServers(true)
      const server = this.videoServerModel.getVideoServerById(this.serverId)
      if (!server) {
        this.error = '服务器不存在'
        return
      }
      if (server.type === VideoServerType.PLEX) {
        this.detail = await PlexClient.fromConfigJson(server.configJson).getPersonDetail(this.personId)
      } else {
        this.detail = await JellyfinClient.fromConfigJson(server.configJson).getPersonDetail(this.personId)
      }
    } catch (e) {
      this.error = (e as BusinessError).message ?? '加载失败'
    } finally {
      this.isLoading = false
    }
  }

  private name(): string {
    const d = this.detail
    if (d !== null && d !== undefined && d.name.length > 0) {
      return d.name
    }
    return this.fallbackName
  }

  private imageUrl(): string {
    const d = this.detail
    if (d !== null && d !== undefined && d.imageUrl.length > 0) {
      return d.imageUrl
    }
    return this.fallbackImageUrl
  }

  private overview(): string {
    return this.detail?.overview ?? ''
  }

  private getInitial(): string {
    const n = this.name()
    return n.length > 0 ? n[0].toUpperCase() : '?'
  }

  private openCredit(item: VideoServerMediaItem): void {
    if (item.id.length === 0) {
      return
    }
    const t = item.type.toLowerCase()
    if (t !== 'movie' && t !== 'series' && t !== 'show') {
      return
    }
    const param: ServerMediaDetailPageParam = {
      serverId: this.serverId,
      itemId: item.id,
      title: item.title
    }
    this.pageStack.pushPathByName(ServerMediaDetailPage.PAGE_NAME, param)
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        Column()
          .width('100%').height('100%')
          .backgroundColor('#111111')

        if (this.isLoading) {
          Column() {
            Text('加载中…').fontSize(16).fontColor('#888888')
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else if (this.error.length > 0) {
          Column({ space: 12 }) {
            Text(this.error).fontSize(16).fontColor('#FF6B6B')
            Text('重试')
              .fontSize(15).fontColor('#1B78F2')
              .focusable(true)
              .padding({ left: 20, right: 20, top: 8, bottom: 8 })
              .border({ width: 1, color: '#1B78F2' })
              .borderRadius(6)
              .onClick(() => { this.loadData().catch(() => {}) })
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else {
          Scroll() {
            Column({ space: 0 }) {
              Row({ space: 24 }) {
                if (this.imageUrl().length > 0) {
                  Image(this.imageUrl())
                    .width(140).height(210)
                    .borderRadius(8)
                    .objectFit(ImageFit.Cover)
                } else {
                  Column() {
                    Text(this.getInitial())
                      .fontSize(48).fontColor(Color.White).fontWeight(FontWeight.Bold)
                  }
                  .width(140).height(210)
                  .backgroundColor('#333333').borderRadius(8)
                  .justifyContent(FlexAlign.Center)
                  .alignItems(HorizontalAlign.Center)
                }

                Column({ space: 8 }) {
                  Text(this.name())
                    .fontSize(28).fontColor(Color.White).fontWeight(FontWeight.Bold)
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })

                  if (this.role.length > 0) {
                    Text(this.role)
                      .fontSize(14).fontColor('#1B78F2')
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }

                  if (this.detail !== null && this.detail !== undefined && this.detail.birthDate.length > 0) {
                    Text('生日：' + this.detail.birthDate)
                      .fontSize(13).fontColor('#AAAAAA')
                  }

                  if (this.detail !== null && this.detail !== undefined && this.detail.birthPlace.length > 0) {
                    Text('出生地：' + this.detail.birthPlace)
                      .fontSize(13).fontColor('#AAAAAA')
                      .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding({ left: 40, right: 40, top: 80, bottom: 24 })
              .alignItems(VerticalAlign.Top)

              if (this.overview().length > 0) {
                Column({ space: 8 }) {
                  Text('简介')
                    .fontSize(16).fontColor('#CCCCCC').fontWeight(FontWeight.Bold)

                  Text(this.overview())
                    .fontSize(14).fontColor('#AAAAAA').lineHeight(22)
                    .maxLines(this.bioExpanded ? 100 : 4)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  if (this.overview().length > 120) {
                    Text(this.bioExpanded ? '收起' : '展开')
                      .fontSize(13).fontColor('#1B78F2')
                      .focusable(true)
                      .onClick(() => { this.bioExpanded = !this.bioExpanded; })
                  }
                }
                .width('100%')
                .padding({ left: 40, right: 40, bottom: 24 })
                .alignItems(HorizontalAlign.Start)
              }

              if (this.detail !== null && this.detail !== undefined && this.detail.credits.length > 0) {
                Column({ space: 12 }) {
                  Text('参演作品')
                    .fontSize(16).fontColor('#CCCCCC').fontWeight(FontWeight.Bold)
                    .padding({ left: 40 })

                  Scroll() {
                    Row({ space: 12 }) {
                      ForEach(this.detail.credits, (item: VideoServerMediaItem) => {
                        Column({ space: 6 }) {
                          if (item.posterUrl.length > 0) {
                            Image(item.posterUrl)
                              .width(100).height(150)
                              .borderRadius(6).objectFit(ImageFit.Cover)
                          } else {
                            Column() {
                              Text('🎬').fontSize(24)
                            }
                            .width(100).height(150)
                            .backgroundColor('#222222').borderRadius(6)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                          }

                          Text(item.title)
                            .fontSize(12).fontColor('#CCCCCC')
                            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                            .width(100).textAlign(TextAlign.Center)
                        }
                        .alignItems(HorizontalAlign.Start)
                        .focusable(true)
                        .onClick(() => { this.openCredit(item); })
                      }, (item: VideoServerMediaItem) => item.id + '_' + item.title)
                    }
                    .padding({ left: 40, right: 40 })
                  }
                  .scrollable(ScrollDirection.Horizontal)
                  .scrollBar(BarState.Off)
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding({ bottom: 40 })
              }
            }
          }
          .width('100%').height('100%')
          .scrollBar(BarState.Off)
        }
      }
      .width('100%').height('100%')
    }
    .hideTitleBar(true)
    .onReady((context: NavDestinationContext) => {
      const p = context.pathInfo.param as ServerPersonDetailPageParam
      if (p) {
        this.serverId = p.serverId
        this.personId = p.personId
        this.fallbackName = p.name
        this.role = p.role
        this.fallbackImageUrl = p.imageUrl
        this.loadData().catch(() => {})
      }
    })
    .onBackPressed(() => {
      this.pageStack.pop()
      return true
    })
  }
}
