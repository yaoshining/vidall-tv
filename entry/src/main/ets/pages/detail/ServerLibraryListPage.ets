import { VideoServerModel } from "../../stores/servers/VideoServerModel"
import { VideoServerStore } from "../../stores/servers/VideoServerStore"
import { VideoServer, VideoServerType } from "../../db/models/VideoServerEntity"
import { JellyfinClient, VideoServerMediaItem } from "../../lib/JellyfinClient"
import { PlexClient } from "../../lib/PlexClient"
import { ServerMediaDetailPage, ServerMediaDetailPageParam } from "./ServerMediaDetailPage"
import { BusinessError } from "@kit.BasicServicesKit"

export interface ServerLibraryListPageParam {
  serverId: number
  libraryId: string
  libraryName: string
  libraryType: string
}

const PAGE_SIZE = 100;

@ComponentV2
export struct ServerLibraryListPage {
  static PAGE_NAME = 'serverLibraryList'
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  videoServerModel: VideoServerModel = VideoServerStore.getState()
  @Local serverId: number = 0
  @Local libraryId: string = ''
  @Local libraryName: string = ''
  @Local libraryType: string = ''
  @Local items: VideoServerMediaItem[] = []
  @Local total: number = 0
  @Local isLoading: boolean = true
  @Local isLoadingMore: boolean = false
  @Local error: string = ''
  /** 服务端分页偏移量（独立于去重后的 items.length） */
  private serverOffset: number = 0

  private async loadPage(startIndex: number): Promise<void> {
    try {
      await this.videoServerModel.loadVideoServers(startIndex === 0)
      const server: VideoServer | null = this.videoServerModel.getVideoServerById(this.serverId)
      if (!server) {
        this.error = '服务器不存在'
        return
      }
      if (server.type === VideoServerType.PLEX) {
        const page = await PlexClient.fromConfigJson(server.configJson).getLibraryItems(this.libraryId, startIndex, PAGE_SIZE)
        this.items = this.mergeItems(startIndex, page.items)
        this.total = page.total
        this.serverOffset = startIndex + page.items.length
      } else {
        const page = await JellyfinClient.fromConfigJson(server.configJson).getLibraryItems(this.libraryId, this.libraryType, startIndex, PAGE_SIZE)
        this.items = this.mergeItems(startIndex, page.items)
        this.total = page.total
        this.serverOffset = startIndex + page.items.length
      }
      if (startIndex > 0 && this.serverOffset === startIndex) {
        // 空页：服务端无更多数据，停止继续加载
        this.total = startIndex
      }
    } catch (e) {
      if (startIndex === 0) {
        this.error = (e as BusinessError).message ?? '加载失败'
      }
    } finally {
      this.isLoading = false
      this.isLoadingMore = false
    }
  }

  /** 分页追加时按 id 去重，避免服务器在两次请求间插入/重排导致 ForEach 键重复 */
  private mergeItems(startIndex: number, incoming: VideoServerMediaItem[]): VideoServerMediaItem[] {
    if (startIndex === 0) {
      return incoming
    }
    const seen = new Set<string>()
    for (const it of this.items) {
      seen.add(it.id)
    }
    const merged: VideoServerMediaItem[] = this.items.slice()
    for (const it of incoming) {
      if (!seen.has(it.id)) {
        seen.add(it.id)
        merged.push(it)
      }
    }
    return merged
  }

  private loadMore(): void {
    if (this.isLoading || this.isLoadingMore) {
      return
    }
    if (this.serverOffset >= this.total) {
      return
    }
    this.isLoadingMore = true
    this.loadPage(this.serverOffset).catch(() => {})
  }

  private retry(): void {
    this.isLoading = true
    this.error = ''
    this.serverOffset = 0
    this.loadPage(0).catch(() => {})
  }

  private openDetail(item: VideoServerMediaItem): void {
    const param: ServerMediaDetailPageParam = {
      serverId: this.serverId,
      itemId: item.id,
      title: item.title
    }
    this.pageStack.pushPathByName(ServerMediaDetailPage.PAGE_NAME, param)
  }

  @Builder
  PosterCard(item: VideoServerMediaItem) {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        if (item.posterUrl.length > 0) {
          Image(item.posterUrl)
            .width('100%').aspectRatio(2 / 3)
            .objectFit(ImageFit.Cover)
            .borderRadius(6)
        } else {
          Column() {
            Text(item.title)
              .fontSize(14).fontColor('#CCCCCC')
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).padding(8)
          }
          .width('100%').aspectRatio(2 / 3)
          .backgroundColor('#2A2A2A').borderRadius(6).justifyContent(FlexAlign.Center)
        }

        if (item.progress > 0) {
          Column() {
            Column()
              .width(Math.round(item.progress * 100).toString() + '%')
              .height('100%')
              .backgroundColor('#4A9FFF').borderRadius(2)
              .alignSelf(ItemAlign.Start)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%').height(4)
          .backgroundColor('rgba(0,0,0,0.6)').borderRadius(2)
          .position({ left: 0, bottom: 0 })
        }
      }
      .width('100%').aspectRatio(2 / 3)
      .borderRadius(6).clip(true)

      Text(item.title)
        .fontSize(15).fontColor('#DDDDDD').maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').textAlign(TextAlign.Center)
    }
    .width('100%')
    .onClick(() => { this.openDetail(item) })
  }

  build() {
    NavDestination() {
      Column() {
        Row() {
          Text(this.libraryName)
            .fontSize(30).fontColor(Color.White).fontWeight(FontWeight.Bold)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: 40, right: 40, top: 30, bottom: 20 })
        .alignItems(VerticalAlign.Center)

        if (this.isLoading) {
          Column() {
            LoadingProgress().width(40).height(40).color('#AAAAAA')
            Text('加载中...').fontSize(13).fontColor('#888888').margin({ top: 12 })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else if (this.error.length > 0) {
          Column({ space: 16 }) {
            Text(this.error).fontSize(16).fontColor('#FF6B6B')
            Text('重试')
              .fontSize(15).fontColor('#1B78F2')
              .focusable(true)
              .padding({ left: 20, right: 20, top: 8, bottom: 8 })
              .border({ width: 1, color: '#1B78F2' })
              .borderRadius(6)
              .onClick(() => { this.retry() })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else {
          Grid() {
            ForEach(this.items, (item: VideoServerMediaItem) => {
              GridItem() {
                this.PosterCard(item)
              }
            }, (item: VideoServerMediaItem) => item.id)
          }
          .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr')
          .columnsGap(16)
          .rowsGap(24)
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 40, right: 40, bottom: 40 })
          .scrollBar(BarState.Off)
          .onReachEnd(() => { this.loadMore() })
        }
      }
      .width('100%').height('100%')
      .backgroundColor('#111111')
    }
    .hideTitleBar(true)
    .onReady((context) => {
      const param = context.pathInfo.param as ServerLibraryListPageParam
      if (param) {
        this.serverId = param.serverId
        this.libraryId = param.libraryId
        this.libraryName = param.libraryName
        this.libraryType = param.libraryType
        this.loadPage(0).catch(() => {})
      }
    })
    .onBackPressed(() => {
      this.pageStack.pop()
      return true
    })
  }
}
