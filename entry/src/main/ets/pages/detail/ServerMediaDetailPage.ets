import { VideoServerModel } from "../../stores/servers/VideoServerModel"
import { VideoServerStore } from "../../stores/servers/VideoServerStore"
import { VideoServer, VideoServerType } from "../../db/models/VideoServerEntity"
import { JellyfinClient, VideoServerItemDetail, VideoServerSeason, VideoServerPerson, VideoServerMediaItem } from "../../lib/JellyfinClient"
import { PlexClient } from "../../lib/PlexClient"
import { PlayerPage, PlayerPageParam } from "../player/index"
import { reportServerPlaybackStarted } from "../../lib/ServerProgressReporter"
import { toOpaqueColor } from "../../utils/MediaFormatUtil"
import { buildServerEpisodePlaybackContext } from "../../utils/ServerEpisodePlaybackContextUtil"
import { PlaybackContext } from "../../components/core/player/PlaybackContext"
import { ServerSeasonDetailPage, ServerSeasonDetailPageParam } from "./ServerSeasonDetailPage"
import { ServerPersonDetailPage, ServerPersonDetailPageParam } from "./ServerPersonDetailPage"
import { BusinessError } from "@kit.BasicServicesKit"
import {
  DetailCastSection,
  DetailSeasonsSection,
  DetailOverviewDialog,
  DetailCastMember,
  DetailSeason,
  formatDetailDurationMs
} from "../../components/detail/DetailSections"

export interface ServerMediaDetailPageParam {
  serverId: number
  itemId: string
  title: string
}

@ComponentV2
export struct ServerMediaDetailPage {
  static PAGE_NAME = 'serverMediaDetail'
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  videoServerModel: VideoServerModel = VideoServerStore.getState()
  @Local serverId: number = 0
  @Local itemId: string = ''
  @Local fallbackTitle: string = ''
  @Local detail: VideoServerItemDetail | null = null
  @Local seasons: VideoServerSeason[] = []
  @Local isLoading: boolean = true
  @Local error: string = ''
  @Local isPlaying: boolean = false
  @Local showOverviewDialog: boolean = false
  /** 页面背景固定深灰（此页不提取主色，与季详情页的提取逻辑保持独立） */
  private readonly dominantBgColor: string = '#111111'
  /** 剧集详情页的「接下来」单集（续播集/第一集），用于播放与进度展示 */
  @Local nextUp: VideoServerMediaItem | null = null
  /** 首次 onShown 跳过静默刷新（onReady 已发起首次加载），避免首帧重复请求 */
  @Local initialLoadDone: boolean = false

  private showToastSafe(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration: 2000 })
    } catch (_e) {}
  }

  private async loadDetail(silent: boolean = false): Promise<void> {
    if (!silent) {
      this.isLoading = true
    }
    this.error = ''
    try {
      await this.videoServerModel.loadVideoServers(true)
      const server = this.videoServerModel.getVideoServerById(this.serverId)
      if (!server) {
        if (!silent) {
          this.error = '服务器不存在'
        }
        return
      }
      if (server.type === VideoServerType.PLEX) {
        this.detail = await PlexClient.fromConfigJson(server.configJson).getItemDetail(this.itemId)
      } else {
        this.detail = await JellyfinClient.fromConfigJson(server.configJson).getItemDetail(this.itemId)
      }
      if (this.detail.media.type === 'series') {
        try {
          if (server.type === VideoServerType.PLEX) {
            const client = PlexClient.fromConfigJson(server.configJson)
            this.seasons = await client.getSeasons(this.itemId)
            this.nextUp = await client.getNextUp(this.itemId)
          } else {
            const client = JellyfinClient.fromConfigJson(server.configJson)
            this.seasons = await client.getSeasons(this.itemId)
            this.nextUp = await client.getNextUp(this.itemId)
          }
        } catch (e) {
          console.warn('[ServerMediaDetailPage] 获取季列表/下一集失败', (e as BusinessError).message)
        }
      } else {
        this.nextUp = null
      }
    } catch (e) {
      if (!silent) {
        this.error = (e as BusinessError).message ?? '加载详情失败'
      }
    } finally {
      if (!silent) {
        this.isLoading = false
      }
    }
  }

  private isSeries(): boolean {
    return this.detail?.media.type === 'series'
  }

  /** 播放目标：剧集→nextUp（续播集/第一集），电影→媒体本身 */
  private playTarget(): VideoServerMediaItem | null {
    const detail = this.detail
    if (!detail) {
      return null
    }
    if (detail.media.type === 'series') {
      return this.nextUp
    }
    return detail.media
  }

  /** 续播卡片副标题（剧集显示「S08E03 · 分集名」） */
  private playCardSubtitle(): string {
    if (this.isSeries() && this.nextUp !== null && this.nextUp.subtitle.length > 0) {
      return this.nextUp.subtitle
    }
    return ''
  }

  private async play(): Promise<void> {
    if (this.isPlaying) {
      return
    }
    const target = this.playTarget()
    if (!target) {
      if (this.isSeries() && this.nextUp === null) {
        this.showToastSafe('未找到可播放的集')
      }
      return
    }
    const server: VideoServer | null = this.videoServerModel.getVideoServerById(this.serverId)
    if (!server) {
      this.showToastSafe('服务器不存在')
      return
    }
    this.isPlaying = true
    try {
      let url = ''
      let header: Record<string, string> = {}
      if (server.type === VideoServerType.PLEX) {
        const client = PlexClient.fromConfigJson(server.configJson)
        url = await client.getStreamUrl(target.id)
        header = client.getStreamHeader()
      } else {
        const client = JellyfinClient.fromConfigJson(server.configJson)
        url = await client.getStreamUrl(target.id)
        header = client.getStreamHeader()
      }
      const playSessionId = 'vidall-' + Date.now().toString(36) + Math.random().toString(36).substring(2, 10)
      const playerTitle = this.isSeries() ? `${this.getTitle()} ${target.subtitle}` : target.title
      let playbackContext: PlaybackContext | undefined = undefined
      if (this.isSeries()) {
        try {
          playbackContext = (await buildServerEpisodePlaybackContext(server, this.itemId, target.id)) ?? undefined
        } catch (e) {
          console.warn('[ServerMediaDetailPage] 构建连续播放上下文失败', (e as BusinessError).message)
        }
      }
      const param: PlayerPageParam = {
        url: url,
        httpHeader: header,
        title: playerTitle,
        startPositionMs: target.positionMs > 0 ? target.positionMs : undefined,
        durationHintMs: target.durationMs > 0 ? target.durationMs : undefined,
        serverType: server.type,
        serverItemId: target.id,
        serverId: server.id,
        serverPlaySessionId: playSessionId,
        playbackContext: playbackContext,
        seasonNumber: target.seasonNumber,
        episodeNumber: target.episodeNumber,
        // 透传封面字段，供系统媒体中心（AVSession）展示海报
        posterUrl: target.posterUrl.length > 0 ? target.posterUrl : undefined,
        backdropUrl: target.backdropUrl.length > 0 ? target.backdropUrl : undefined
      }
      reportServerPlaybackStarted(server.type, server.id ?? 0, target.id, playSessionId, target.positionMs, target.durationMs)
        .catch(() => {})
      this.pageStack.pushPathByName(PlayerPage.PAGE_NAME, param)
    } catch (e) {
      console.warn('[ServerMediaDetailPage] 播放失败', (e as BusinessError).message)
      this.showToastSafe('播放失败，请重试')
    } finally {
      this.isPlaying = false
    }
  }

  private getTitle(): string {
    return this.detail?.media.title ?? this.fallbackTitle
  }

  private getBackdropUrl(): string {
    const d = this.detail
    if (!d) {
      return ''
    }
    return d.media.backdropUrl.length > 0 ? d.media.backdropUrl : d.media.posterUrl
  }

  private getYear(): string {
    const d = this.detail
    return d && d.year > 0 ? String(d.year) : ''
  }

  private getRuntimeText(): string {
    const d = this.detail
    return d ? formatDetailDurationMs(d.media.durationMs) : ''
  }

  private getRating(): number | undefined {
    const d = this.detail
    return d && d.rating > 0 ? d.rating : undefined
  }

  private getGenres(): string[] {
    return this.detail?.genres ?? []
  }

  private getGenresText(): string {
    return this.getGenres().join(' / ')
  }

  private getPosterUrl(): string {
    const d = this.detail
    if (!d) {
      return ''
    }
    return d.media.posterUrl.length > 0 ? d.media.posterUrl : d.media.backdropUrl
  }

  private getOverview(): string {
    return this.detail?.overview ?? ''
  }

  private isOverviewLong(): boolean {
    return this.getOverview().length > 100
  }

  private getOverviewShort(): string {
    return this.getOverview().substring(0, 100) + '...'
  }

  private hasProgress(): boolean {
    const t = this.playTarget()
    return t !== null && t.positionMs > 0
  }

  private getProgressPercent(): number {
    const t = this.playTarget()
    if (!t) {
      return 0
    }
    const p = t.progress
    return p < 0 ? 0 : (p > 1 ? 1 : p)
  }

  private positionText(): string {
    const t = this.playTarget()
    if (!t) {
      return ''
    }
    return formatDetailDurationMs(t.positionMs) + ' / ' + formatDetailDurationMs(t.durationMs)
  }

  private getSeasonLabel(s: VideoServerSeason): string {
    if (s.seasonNumber > 0) {
      return `第${s.seasonNumber}季`
    }
    return s.name.length > 0 ? s.name : '特别篇'
  }

  private openSeason(s: VideoServerSeason): void {
    const param: ServerSeasonDetailPageParam = {
      serverId: this.serverId,
      seriesId: this.itemId,
      seasonId: s.id,
      seasonNumber: s.seasonNumber,
      seasonName: this.getSeasonLabel(s),
      seriesTitle: this.getTitle(),
      seasonPosterUrl: s.posterUrl
    }
    this.pageStack.pushPathByName(ServerSeasonDetailPage.PAGE_NAME, param)
  }

  private castMembers(): DetailCastMember[] {
    const result: DetailCastMember[] = []
    for (const c of this.detail?.cast ?? []) {
      result.push({ name: c.name ?? '', role: c.role ?? '', imageUrl: c.imageUrl ?? '', personId: c.personId ?? '' })
    }
    return result
  }

  private openPerson(c: DetailCastMember): void {
    if (c.personId.length === 0) {
      return
    }
    const param: ServerPersonDetailPageParam = {
      serverId: this.serverId,
      personId: c.personId,
      name: c.name,
      role: c.role,
      imageUrl: c.imageUrl
    }
    this.pageStack.pushPathByName(ServerPersonDetailPage.PAGE_NAME, param)
  }

  private seasonList(): DetailSeason[] {
    const result: DetailSeason[] = []
    for (const s of this.seasons) {
      result.push({ id: s.id, label: this.getSeasonLabel(s), posterUrl: s.posterUrl })
    }
    return result
  }

  @Builder
  PlayCard() {
    Column() {
      Row({ space: 14 }) {
        if (this.getBackdropUrl().length > 0) {
          Image(this.getBackdropUrl())
            .width(150).height(84)
            .borderRadius(4)
            .objectFit(ImageFit.Cover)
            .border({ width: 1, color: '#2E2E2E' })
        } else {
          Column()
            .width(150).height(84)
            .backgroundColor('#1C1C1C')
            .borderRadius(4)
            .border({ width: 1, color: '#2E2E2E' })
        }

        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Text(this.getTitle())
              .fontSize(14).fontColor('#CCCCCC').fontWeight(FontWeight.Medium)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .alignItems(VerticalAlign.Center)

          if (this.playCardSubtitle().length > 0) {
            Text(this.playCardSubtitle())
              .fontSize(12).fontColor('#888888')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }

          Column() {
            Column()
              .width(Math.round(this.getProgressPercent() * 100).toString() + '%')
              .height('100%')
              .backgroundColor('#1B78F2').borderRadius(2)
              .alignSelf(ItemAlign.Start)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%').height(4)
          .backgroundColor('#2E2E2E').borderRadius(2)

          Row({ space: 10 }) {
            Row({ space: 6 }) {
              Text('▶').fontSize(12).fontColor(Color.White)
              Text(this.hasProgress() ? '继续播放' : '开始播放')
                .fontSize(14).fontColor(Color.White).fontWeight(FontWeight.Bold)
            }
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor('#1B78F2').borderRadius(4)
            .onClick(() => { this.play() })

            if (this.hasProgress()) {
              Text(this.positionText())
                .fontSize(12).fontColor('#888888')
            }
          }
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.SpaceBetween)
        .height(84)
      }
      .alignItems(VerticalAlign.Center)
    }
    .padding({ left: 16, right: 20, top: 14, bottom: 14 })
    .backgroundColor('#18FFFFFF')
    .borderRadius(8)
    .border({ width: 1, color: '#22FFFFFF' })
    .width(500)
  }

  @Builder
  HeroSection() {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.getBackdropUrl().length > 0) {
        Image(this.getBackdropUrl())
          .width('100%').height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        Column()
          .width('100%').height('100%')
          .linearGradient({
            angle: 135,
            colors: [['#1A1A2E', 0.0], ['#16213E', 0.5], ['#0F3460', 1.0]]
          })
      }

      Column()
        .width('100%').height('68%')
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.0], [toOpaqueColor(this.dominantBgColor), 1.0]]
        })
        .position({ left: 0, bottom: 0 })
        .hitTestBehavior(HitTestMode.Transparent)

      Column()
        .width('55%').height('100%')
        .linearGradient({
          angle: 90,
          colors: [[toOpaqueColor(this.dominantBgColor), 0.0], ['#00000000', 1.0]]
        })
        .position({ left: 0, top: 0 })
        .hitTestBehavior(HitTestMode.Transparent)

      Row({ space: 40 }) {
        Column({ space: 14 }) {
          Text(this.getTitle())
            .fontSize(52).fontColor(Color.White).fontWeight(FontWeight.Bold)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .textShadow({ radius: 8, color: '#88000000', offsetX: 2, offsetY: 2 })
            .constraintSize({ maxWidth: 720 })

          Row({ space: 12 }) {
            if (this.getYear().length > 0) {
              Text(this.getYear())
                .fontSize(18).fontColor('#CCCCCC').fontWeight(FontWeight.Medium)
            }
            if (this.getRuntimeText().length > 0) {
              Text(this.getRuntimeText())
                .fontSize(18).fontColor('#CCCCCC').fontWeight(FontWeight.Medium)
            }
            if (this.getRating() !== undefined) {
              Row({ space: 4 }) {
                Text('★').fontSize(16).fontColor('#FFA500')
                Text((this.getRating() as number).toFixed(1))
                  .fontSize(18).fontColor('#FFA500').fontWeight(FontWeight.Bold)
              }
            }
            ForEach(this.getGenres().slice(0, 3), (genre: string) => {
              Text(genre)
                .fontSize(14).fontColor('#CCCCCC')
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(4)
                .border({ width: 1, color: '#55FFFFFF' })
            }, (genre: string) => genre)
          }
          .alignItems(VerticalAlign.Center)

          if (this.getOverview().length > 0) {
            if (this.isOverviewLong()) {
              Text() {
                Span(this.getOverviewShort())
                  .fontSize(16).fontColor('#BBBBBB').lineHeight(26)
                Span('更多')
                  .fontSize(16).fontColor('#1B78F2')
                  .fontWeight(FontWeight.Medium)
                  .focusable(true)
                  .onClick(() => { this.showOverviewDialog = true; })
              }
              .constraintSize({ maxWidth: 700 })
            } else {
              Text(this.getOverview())
                .fontSize(16).fontColor('#BBBBBB').lineHeight(26)
                .constraintSize({ maxWidth: 700 })
            }
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        this.PlayCard()
      }
      .width('100%')
      .padding({ left: 80, right: 80, bottom: 52 })
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%').aspectRatio(1.778)
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        Scroll() {
          Column() {
            if (this.isLoading) {
              Column() {
                LoadingProgress().width(40).height(40).color('#AAAAAA')
                Text('加载中...').fontSize(13).fontColor('#888888').margin({ top: 12 })
              }
              .width('100%').height(400).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
            } else if (this.error.length > 0) {
              Column() {
                Text(this.error).fontSize(16).fontColor('#FF6B6B')
              }
              .width('100%').height(400).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
            } else {
              this.HeroSection()
              DetailSeasonsSection({
                seasons: this.seasonList(),
                onSeasonClick: (s: DetailSeason) => {
                  const orig = this.seasons.find(x => x.id === s.id)
                  if (orig) {
                    this.openSeason(orig)
                  }
                }
              })
              DetailCastSection({
                members: this.castMembers(),
                onCastClick: (c: DetailCastMember) => { this.openPerson(c) }
              })
              Column().height(80)
            }
          }
          .width('100%')
          .backgroundColor(this.dominantBgColor)
        }
        .width('100%').height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)

        DetailOverviewDialog({
          visible: this.showOverviewDialog,
          title: this.getTitle(),
          posterUrl: this.getPosterUrl(),
          overview: this.getOverview(),
          genresText: this.getGenresText(),
          runtimeText: this.getRuntimeText(),
          year: this.getYear(),
          onClose: () => { this.showOverviewDialog = false }
        })
      }
      .width('100%').height('100%')
      .backgroundColor(this.dominantBgColor)
    }
    .onReady((context) => {
      const param = context.pathInfo.param as ServerMediaDetailPageParam
      if (param) {
        this.serverId = param.serverId
        this.itemId = param.itemId
        this.fallbackTitle = param.title
        this.loadDetail()
      }
    })
    .onShown(() => {
      // 首次显示由 onReady 发起加载，跳过静默刷新；之后（如从播放器返回）才刷新续播位置 / 进度
      if (!this.initialLoadDone) {
        this.initialLoadDone = true
        return
      }
      if (this.itemId.length > 0) {
        this.loadDetail(true)
      }
    })
    .onBackPressed(() => {
      if (this.showOverviewDialog) {
        this.showOverviewDialog = false
        return true
      }
      this.pageStack.pop()
      return true
    })
    .hideTitleBar(true)
  }
}
