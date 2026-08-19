import http from '@ohos.net.http'
import image from '@ohos.multimedia.image'
import effectKit from '@ohos.effectKit'
import { VideoServerModel } from "../../stores/servers/VideoServerModel"
import { VideoServerStore } from "../../stores/servers/VideoServerStore"
import { VideoServer, VideoServerType } from "../../db/models/VideoServerEntity"
import { JellyfinClient, VideoServerEpisode, VideoServerPerson, VideoServerMediaItem } from "../../lib/JellyfinClient"
import { PlexClient } from "../../lib/PlexClient"
import { PlayerPage, PlayerPageParam } from "../player/index"
import { reportServerPlaybackStarted } from "../../lib/ServerProgressReporter"
import { ServerPersonDetailPage, ServerPersonDetailPageParam } from "./ServerPersonDetailPage"
import {
  DetailCastSection,
  DetailEpisodesSection,
  DetailCastMember,
  DetailEpisode,
  DetailHeroSection,
  DetailHeroData,
  DetailOverviewDialog,
  formatDetailDurationMs
} from "../../components/detail/DetailSections"

export interface ServerSeasonDetailPageParam {
  serverId: number
  seriesId: string
  seasonId: string
  seasonNumber: number
  seasonName: string
  seriesTitle: string
  seasonPosterUrl: string
}

@ComponentV2
export struct ServerSeasonDetailPage {
  static PAGE_NAME = 'serverSeasonDetail'
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  videoServerModel: VideoServerModel = VideoServerStore.getState()
  @Local serverId: number = 0
  @Local seriesId: string = ''
  @Local seasonId: string = ''
  @Local seasonNumber: number = 0
  @Local seasonName: string = ''
  @Local seriesTitle: string = ''
  @Local seasonPosterUrl: string = ''
  @Local episodes: VideoServerEpisode[] = []
  @Local cast: VideoServerPerson[] = []
  @Local seriesBackdropUrl: string = ''
  @Local seriesYear: number = 0
  @Local seriesRating: number = 0
  @Local seriesGenres: string[] = []
  @Local seriesOverview: string = ''
  @Local isLoading: boolean = true
  @Local error: string = ''
  @Local isPlaying: boolean = false
  @Local showOverviewDialog: boolean = false
  @Local dominantBgColor: string = '#111111'
  /** 整剧「接下来」单集（用于跨季「继续上次观看」入口） */
  @Local nextUp: VideoServerMediaItem | null = null

  private showToastSafe(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration: 2000 })
    } catch (_e) {}
  }

  private async loadEpisodes(silent: boolean = false): Promise<void> {
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
        this.episodes = await PlexClient.fromConfigJson(server.configJson).getEpisodes(this.seriesId, this.seasonId)
      } else {
        this.episodes = await JellyfinClient.fromConfigJson(server.configJson).getEpisodes(this.seriesId, this.seasonId)
      }
      try {
        if (server.type === VideoServerType.PLEX) {
          this.nextUp = await PlexClient.fromConfigJson(server.configJson).getNextUp(this.seriesId)
        } else {
          this.nextUp = await JellyfinClient.fromConfigJson(server.configJson).getNextUp(this.seriesId)
        }
      } catch (e) {
        console.warn('[ServerSeasonDetailPage] 获取下一集失败', (e as Error).message)
      }
      try {
        if (server.type === VideoServerType.PLEX) {
          const d = await PlexClient.fromConfigJson(server.configJson).getItemDetail(this.seriesId)
          this.cast = d.cast
          this.seriesBackdropUrl = d.media.backdropUrl
          this.seriesYear = d.year
          this.seriesRating = d.rating
          this.seriesGenres = d.genres
          this.seriesOverview = d.overview
        } else {
          const d = await JellyfinClient.fromConfigJson(server.configJson).getItemDetail(this.seriesId)
          this.cast = d.cast
          this.seriesBackdropUrl = d.media.backdropUrl
          this.seriesYear = d.year
          this.seriesRating = d.rating
          this.seriesGenres = d.genres
          this.seriesOverview = d.overview
        }
      } catch (e) {
        console.warn('[ServerSeasonDetailPage] 获取系列详情失败', (e as Error).message)
      }
      if (!silent) {
        const bd = this.backdropUrl()
        if (bd.length > 0) {
          this.extractDominantColor(bd)
        }
      }
    } catch (e) {
      if (!silent) {
        this.error = (e as Error).message ?? '加载集列表失败'
      }
    } finally {
      if (!silent) {
        this.isLoading = false
      }
    }
  }

  /** 下载 backdrop 并提取深色主色作为页面背景（与文件源季详情页一致） */
  private async extractDominantColor(url: string): Promise<void> {
    try {
      const req = http.createHttp();
      let buf: ArrayBuffer | undefined;
      try {
        const resp = await req.request(url, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: 8000, readTimeout: 8000
        });
        req.destroy();
        if (resp.responseCode !== 200) { return; }
        buf = resp.result as ArrayBuffer;
      } catch (e) { req.destroy(); return; }
      if (buf === undefined || buf.byteLength === 0) { return; }

      const imgSrc = image.createImageSource(buf);
      const pixelMap = await imgSrc.createPixelMap({
        desiredSize: { width: 64, height: 36 },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      imgSrc.release();

      const picker = await effectKit.createColorPicker(pixelMap);
      const mainColor = picker.getMainColorSync();
      pixelMap.release();

      const darken = (v: number): number => Math.round(v * 0.4);
      const toHex = (v: number): string => { const h = v.toString(16); return h.length < 2 ? '0' + h : h; };
      const r = darken(mainColor.red & 0xFF);
      const g = darken(mainColor.green & 0xFF);
      const b = darken(mainColor.blue & 0xFF);
      this.dominantBgColor = '#' + toHex(r) + toHex(g) + toHex(b);
    } catch (e) {
      console.warn('[ServerSeasonDetailPage] extractDominantColor failed', JSON.stringify(e));
    }
  }

  private async playEpisode(ep: VideoServerEpisode): Promise<void> {
    if (this.isPlaying) {
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
        url = await client.getStreamUrl(ep.id)
        header = client.getStreamHeader()
      } else {
        const client = JellyfinClient.fromConfigJson(server.configJson)
        url = await client.getStreamUrl(ep.id)
        header = client.getStreamHeader()
      }
      const playSessionId = 'vidall-' + Date.now().toString(36) + Math.random().toString(36).substring(2, 10)
      const param: PlayerPageParam = {
        url: url,
        httpHeader: header,
        title: `${this.seriesTitle} ${this.seasonName}`,
        startPositionMs: ep.positionMs > 0 ? ep.positionMs : undefined,
        durationHintMs: ep.durationMs > 0 ? ep.durationMs : undefined,
        serverType: server.type,
        serverItemId: ep.id,
        serverConfigJson: server.configJson,
        serverPlaySessionId: playSessionId
      }
      reportServerPlaybackStarted(server.type, server.configJson, ep.id, playSessionId, ep.positionMs, ep.durationMs)
        .catch(() => {})
      this.pageStack.pushPathByName(PlayerPage.PAGE_NAME, param)
    } catch (e) {
      console.warn('[ServerSeasonDetailPage] 播放失败', (e as Error).message)
      this.showToastSafe('播放失败，请重试')
    } finally {
      this.isPlaying = false
    }
  }

  private backdropUrl(): string {
    return this.seriesBackdropUrl.length > 0 ? this.seriesBackdropUrl : this.seasonPosterUrl
  }

  private castMembers(): DetailCastMember[] {
    const result: DetailCastMember[] = []
    for (const c of this.cast) {
      result.push({ name: c.name ?? '', role: c.role ?? '', imageUrl: c.imageUrl ?? '', personId: c.personId ?? '' })
    }
    return result
  }

  private seasonTitle(): string {
    const base = this.seasonNumber === 0 ? '特别篇' : `第 ${this.seasonNumber} 季`
    const name = (this.seasonName ?? '').trim()
    if (name.length > 0 && name !== base && name.indexOf(base) < 0) {
      return `${base}：${name}`
    }
    return base
  }

  private resumeEpisode(): VideoServerEpisode | undefined {
    let best: VideoServerEpisode | undefined = undefined
    for (const ep of this.episodes) {
      if (ep.positionMs > 0 && ep.durationMs > 0 && (ep.positionMs / ep.durationMs) < 0.95) {
        if (best === undefined || ep.positionMs > best.positionMs) {
          best = ep
        }
      }
    }
    return best ?? (this.episodes.length > 0 ? this.episodes[0] : undefined)
  }

  private heroPlayLabel(): string {
    for (const ep of this.episodes) {
      if (ep.positionMs > 0 && ep.durationMs > 0 && (ep.positionMs / ep.durationMs) < 0.95) {
        return '继续本季'
      }
    }
    return '从本季开始'
  }

  private handleHeroPlayClick(): void {
    const ep = this.resumeEpisode()
    if (ep !== undefined) {
      this.playEpisode(ep).catch(() => {})
    }
  }

  private crossSeasonLabel(): string {
    const n = this.nextUp
    if (n === null || n.seasonNumber === this.seasonNumber) {
      return ''
    }
    return `继续上次观看 S${n.seasonNumber}E${n.episodeNumber}`
  }

  private crossSeasonMetaLabel(): string {
    const n = this.nextUp
    if (n === null || n.seasonNumber === this.seasonNumber) {
      return ''
    }
    const code = `S${n.seasonNumber}E${n.episodeNumber}`
    if (n.positionMs > 0 && n.durationMs > 0) {
      return `${code} · ${formatDetailDurationMs(n.positionMs)}`
    }
    return code
  }

  private handleCrossSeasonClick(): void {
    const n = this.nextUp
    if (n !== null) {
      this.playMediaItem(n).catch(() => {})
    }
  }

  /** 播放一个服务器媒体条目（跨季「继续上次观看」用） */
  private async playMediaItem(item: VideoServerMediaItem): Promise<void> {
    if (this.isPlaying) {
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
        url = await client.getStreamUrl(item.id)
        header = client.getStreamHeader()
      } else {
        const client = JellyfinClient.fromConfigJson(server.configJson)
        url = await client.getStreamUrl(item.id)
        header = client.getStreamHeader()
      }
      const playSessionId = 'vidall-' + Date.now().toString(36) + Math.random().toString(36).substring(2, 10)
      const param: PlayerPageParam = {
        url: url,
        httpHeader: header,
        title: `${this.seriesTitle} ${item.subtitle}`,
        startPositionMs: item.positionMs > 0 ? item.positionMs : undefined,
        durationHintMs: item.durationMs > 0 ? item.durationMs : undefined,
        serverType: server.type,
        serverItemId: item.id,
        serverConfigJson: server.configJson,
        serverPlaySessionId: playSessionId
      }
      reportServerPlaybackStarted(server.type, server.configJson, item.id, playSessionId, item.positionMs, item.durationMs)
        .catch(() => {})
      this.pageStack.pushPathByName(PlayerPage.PAGE_NAME, param)
    } catch (e) {
      console.warn('[ServerSeasonDetailPage] 播放失败', (e as Error).message)
      this.showToastSafe('播放失败，请重试')
    } finally {
      this.isPlaying = false
    }
  }

  /** Hero 区统一数据（映射到公用组件） */
  private heroData(): DetailHeroData {
    return {
      backdropUrl: this.backdropUrl(),
      dominantBgColor: this.dominantBgColor,
      supertitle: this.seriesTitle,
      title: this.seasonTitle(),
      year: this.seriesYear > 0 ? String(this.seriesYear) : '',
      ratingText: this.seriesRating > 0 ? this.seriesRating.toFixed(1) : '',
      countText: this.episodes.length > 0 ? `${this.episodes.length} 集` : '',
      genres: this.seriesGenres,
      overview: this.seriesOverview,
      playLabel: this.heroPlayLabel(),
      onPlayClick: () => { this.handleHeroPlayClick(); },
      crossSeasonLabel: this.crossSeasonLabel(),
      crossSeasonMetaLabel: this.crossSeasonMetaLabel(),
      onCrossSeasonClick: () => { this.handleCrossSeasonClick(); },
      onShowOverview: () => { this.showOverviewDialog = true; }
    }
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

  private episodeList(): DetailEpisode[] {
    const result: DetailEpisode[] = []
    for (const ep of this.episodes) {
      const label = (ep.title ?? '').length > 0 ? `第${ep.episodeNumber}集 · ${ep.title}` : `第${ep.episodeNumber}集`
      const progress = ep.durationMs > 0 && ep.positionMs > 0 ? ep.positionMs / ep.durationMs : 0
      result.push({
        id: ep.id,
        label,
        overview: ep.overview ?? '',
        stillUrl: ep.stillUrl ?? '',
        durationText: formatDetailDurationMs(ep.durationMs),
        ratingText: ep.rating > 0 ? ep.rating.toFixed(1) : '',
        progressPercent: progress,
        watched: progress >= 0.95,
        placeholderText: String(ep.episodeNumber)
      })
    }
    return result
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
              DetailHeroSection({ data: this.heroData() })
              DetailEpisodesSection({
                episodes: this.episodeList(),
                onEpisodeClick: (e: DetailEpisode) => {
                  const orig = this.episodes.find(x => x.id === e.id)
                  if (orig) {
                    this.playEpisode(orig)
                  }
                }
              })
              DetailCastSection({
                members: this.castMembers(),
                onCastClick: (c: DetailCastMember) => { this.openPerson(c) }
              })
              Column().height(40)
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
          title: this.seasonTitle(),
          posterUrl: this.seasonPosterUrl,
          overview: this.seriesOverview,
          genresText: this.seriesGenres.join(' / '),
          runtimeText: '',
          year: this.seriesYear > 0 ? String(this.seriesYear) : '',
          onClose: () => { this.showOverviewDialog = false }
        })
      }
      .width('100%').height('100%')
    }
    .hideTitleBar(true)
    .onReady((context) => {
      const param = context.pathInfo.param as ServerSeasonDetailPageParam
      if (param) {
        this.serverId = param.serverId
        this.seriesId = param.seriesId
        this.seasonId = param.seasonId
        this.seasonNumber = param.seasonNumber
        this.seasonName = param.seasonName
        this.seriesTitle = param.seriesTitle
        this.seasonPosterUrl = param.seasonPosterUrl
        this.loadEpisodes()
      }
    })
    .onShown(() => {
      // 从播放器返回后静默刷新集进度（进度条 / 已看状态）
      if (this.seriesId.length > 0) {
        this.loadEpisodes(true)
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
  }
}
