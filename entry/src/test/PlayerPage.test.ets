import { describe, it, expect } from '@ohos/hypium'
import {
  buildMediaLibraryEpisodeSwitchParam,
  commitMediaLibraryEpisodeSwitch,
  PlayerPage,
  PlayerPageParam,
  ResolvedEpisodePlaybackSource
} from '../main/ets/pages/player/index'
import {
  MediaLibraryContext,
  FileExplorerContext,
  PlaybackContext,
  PlaybackContextItem
} from '../main/ets/components/core/player/PlaybackContext'
import { MediaItem, TvEpisodeEntity } from '../main/ets/db/models/MediaEntity'

interface PlayerPageAccessor {
  applyPlayerPageParam(pageParam: PlayerPageParam): void
  persistCurrentPlaybackState(): void
  resolveEpisodePlaybackSource(item: PlaybackContextItem): Promise<ResolvedEpisodePlaybackSource | null>
  handleEpisodeSelect(item: PlaybackContextItem): Promise<boolean>
  resumePlaybackForParam(pageParam: PlayerPageParam): void
  currentMediaKey: string
  currentMediaSeason: number
  currentMediaEpisode: number
  currentPageParam?: PlayerPageParam
  episodeSwitching: boolean
  showResumeDialog: boolean
  pendingSeekMs: number
  videoData?: PlayerPageVideoDataAccessor
  videoPlayerController: PlayerPageControllerAccessor
}

interface PlayerPageVideoDataAccessor {
  videoSrc: string
}

interface PlayerPageProgressContextAccessor {
  videoId: number
  seriesProviderId: string
  seasonNumber: number
  episodeNumber: number
  positionMs: number
  durationMs: number
  updatedAt: number
}

interface PlayerPageControllerAccessor {
  currentTime: number
  duration: number
  playbackContext?: MediaLibraryContext
  progressContext: PlayerPageProgressContextAccessor | null
  saveProgressNow(): void
  reloadSource(videoData: PlayerPageVideoDataAccessor, autoPlay: boolean): Promise<void>
}

interface PlayerPageControllerPlaybackAccessor extends PlayerPageControllerAccessor {
  play(): Promise<void>
}

interface BoundHandleEpisodeSelectMethod {
  bind(target: Object): (item: PlaybackContextItem) => Promise<boolean>
}

class TestPlayerPageController implements PlayerPageControllerAccessor {
  currentTime: number = 120000
  duration: number = 1800000
  playbackContext?: MediaLibraryContext
  progressContext: PlayerPageProgressContextAccessor | null = null

  constructor(context: MediaLibraryContext) {
    this.playbackContext = context
  }

  saveProgressNow(): void {}

  async reloadSource(_videoData: PlayerPageVideoDataAccessor, _autoPlay: boolean): Promise<void> {}
}

interface EpisodeSelectNoOpSideEffectCalls {
  persistCurrentPlaybackState: number
  reloadSource: number
  resumePlaybackForParam: number
  saveProgressNow: number
  play: number
}

interface PlayerPageCurrentEpisodeHelperAccessor extends PlayerPageAccessor {
  isCurrentMediaLibraryEpisodeSelection?: (
    currentParam: PlayerPageParam,
    playbackContext: PlaybackContext | undefined,
    item: PlaybackContextItem
  ) => boolean
}

class SpyEpisodeSwitchController extends TestPlayerPageController {
  private calls: EpisodeSelectNoOpSideEffectCalls

  constructor(context: MediaLibraryContext, calls: EpisodeSelectNoOpSideEffectCalls) {
    super(context)
    this.calls = calls
  }

  saveProgressNow(): void {
    this.calls.saveProgressNow += 1
    this.calls.persistCurrentPlaybackState += 1
    throw new Error('当前集点击不应进入 persistCurrentPlaybackState')
  }

  async reloadSource(_videoData: PlayerPageVideoDataAccessor, _autoPlay: boolean): Promise<void> {
    this.calls.reloadSource += 1
    throw new Error('当前集点击不应进入 reloadSource')
  }

  play(): Promise<void> {
    this.calls.play += 1
    this.calls.resumePlaybackForParam += 1
    throw new Error('当前集点击不应进入 resumePlaybackForParam')
  }
}

class CountingEpisodeSwitchController extends TestPlayerPageController implements PlayerPageControllerPlaybackAccessor {
  private calls: EpisodeSelectNoOpSideEffectCalls
  lastVideoSrc: string = ''

  constructor(context: MediaLibraryContext, calls: EpisodeSelectNoOpSideEffectCalls) {
    super(context)
    this.calls = calls
  }

  saveProgressNow(): void {
    this.calls.saveProgressNow += 1
    this.calls.persistCurrentPlaybackState += 1
  }

  async reloadSource(videoData: PlayerPageVideoDataAccessor, _autoPlay: boolean): Promise<void> {
    this.calls.reloadSource += 1
    this.lastVideoSrc = videoData.videoSrc
  }

  play(): Promise<void> {
    this.calls.play += 1
    this.calls.resumePlaybackForParam += 1
    return Promise.resolve()
  }
}

class TestEpisodeSwitchPage {
  currentPageParam?: PlayerPageParam
  episodeSwitching: boolean = false
  showResumeDialog: boolean = false
  pendingSeekMs: number = -1
  currentMediaKey: string = ''
  currentMediaSeason: number = 0
  currentMediaEpisode: number = 0
  videoData?: PlayerPageVideoDataAccessor
  videoPlayerController: PlayerPageControllerPlaybackAccessor
  private readonly handleEpisodeSelectImpl: (item: PlaybackContextItem) => Promise<boolean>
  private readonly resolvedSourceUrl: string

  constructor(context: MediaLibraryContext, calls: EpisodeSelectNoOpSideEffectCalls, resolvedSourceUrl: string) {
    const page = buildPlayerPageAccessor()
    const handleEpisodeSelect = page.handleEpisodeSelect as Object as BoundHandleEpisodeSelectMethod
    this.handleEpisodeSelectImpl = handleEpisodeSelect.bind(this as Object)
    this.videoPlayerController = new CountingEpisodeSwitchController(context, calls)
    this.resolvedSourceUrl = resolvedSourceUrl
  }

  handleEpisodeSelect(item: PlaybackContextItem): Promise<boolean> {
    return this.handleEpisodeSelectImpl(item)
  }

  persistCurrentPlaybackState(): void {
    this.videoPlayerController.saveProgressNow()
  }

  async resolveEpisodePlaybackSource(_item: PlaybackContextItem): Promise<ResolvedEpisodePlaybackSource | null> {
    return buildResolvedSource(this.resolvedSourceUrl)
  }

  buildVideoDataFromParam(pageParam: PlayerPageParam): PlayerPageVideoDataAccessor | undefined {
    const url = pageParam.url ?? ''
    if (url.length === 0) {
      return undefined
    }
    const videoData: PlayerPageVideoDataAccessor = {
      videoSrc: url
    }
    return videoData
  }

  buildProgressContext(pageParam: PlayerPageParam): PlayerPageProgressContextAccessor {
    const progressContext: PlayerPageProgressContextAccessor = {
      videoId: pageParam.videoId ?? 0,
      seriesProviderId: pageParam.seriesProviderId ?? '',
      seasonNumber: pageParam.seasonNumber ?? 0,
      episodeNumber: pageParam.episodeNumber ?? 0,
      positionMs: 0,
      durationMs: 0,
      updatedAt: 0
    }
    return progressContext
  }

  resumePlaybackForParam(_pageParam: PlayerPageParam): void {
    this.videoPlayerController.play().catch(() => {})
  }
}

function buildSelectedEpisode(index: number): PlaybackContextItem {
  return {
    index,
    title: `第${index + 1}集`,
    videoPath: `/series/s01e0${index + 1}.mkv`,
    videoId: 100 + index,
    sourceId: 200 + index,
    seasonNumber: 1,
    episodeNumber: index + 1,
    durationMs: 1800000
  }
}

function buildResolvedSource(url: string): ResolvedEpisodePlaybackSource {
  const httpHeader = {} as Record<string, string>
  httpHeader.Authorization = 'Basic token'
  const resolvedSource: ResolvedEpisodePlaybackSource = {
    url,
    httpHeader,
    durationHintMs: 1800000
  }
  return resolvedSource
}

function buildPlayerPageAccessor(): PlayerPageAccessor {
  return new PlayerPage() as Object as PlayerPageAccessor
}

function buildEpisodeSwitchContext(currentIndex: number = 0): MediaLibraryContext {
  const context = new MediaLibraryContext()
  context.items = [buildSelectedEpisode(0), buildSelectedEpisode(1), buildSelectedEpisode(2)]
  context.currentIndex = currentIndex
  return context
}

function buildEpisodeSwitchParam(context: MediaLibraryContext): PlayerPageParam {
  const pageParam: PlayerPageParam = {
    url: 'https://example.com/current.mkv',
    title: '长夜余火 第一季-S1:E1-启程',
    seriesProviderId: 'tmdb-9527',
    seasonNumber: 1,
    episodeNumber: 1,
    playbackContext: context
  }
  return pageParam
}

function buildEpisodeSwitchController(context: MediaLibraryContext): PlayerPageControllerAccessor {
  return new TestPlayerPageController(context)
}

export default function playerPageTest() {
  describe('PlayerPage episode switching', () => {
    it('初次进入播放器时会用 pageParam 初始化媒体级进度标识', 0, () => {
      const page = buildPlayerPageAccessor()
      const pageParam: PlayerPageParam = {
        url: 'https://example.com/s01e03.mkv',
        title: '第3集',
        mediaKey: 'media_progress_episode_tmdb_tmdb-9527_s1_e3',
        seasonNumber: 1,
        episodeNumber: 3
      }

      page.applyPlayerPageParam(pageParam)

      expect(page.currentMediaKey).assertEqual('media_progress_episode_tmdb_tmdb-9527_s1_e3')
      expect(page.currentMediaSeason).assertEqual(1)
      expect(page.currentMediaEpisode).assertEqual(3)
    })

    it('初次进入播放器且存在 mediaKey 时不会因空 key 跳过媒体级进度保存链路', 0, () => {
      const page = buildPlayerPageAccessor()
      const mediaKey = 'media_progress_episode_tmdb_tmdb-9527_s1_e3'
      page.applyPlayerPageParam({
        url: 'https://example.com/s01e03.mkv',
        title: '第3集',
        mediaKey,
        seasonNumber: 1,
        episodeNumber: 3
      })

      expect(page.currentMediaKey.length > 0).assertTrue()
      expect(page.currentMediaKey).assertEqual(mediaKey)
    })

    it('媒体库选集会生成新的播放参数，并在提交后让 currentIndex 与所选播放源对齐', 0, () => {
      const context = new MediaLibraryContext()
      context.items = [buildSelectedEpisode(0), buildSelectedEpisode(1), buildSelectedEpisode(2)]
      context.currentIndex = 0

      const currentParam: PlayerPageParam = {
        url: 'https://example.com/current.mkv',
        title: '当前播放',
        seriesProviderId: 'tmdb-9527',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: context
      }

      const nextParam = buildMediaLibraryEpisodeSwitchParam(
        currentParam,
        context,
        context.items[2],
        buildResolvedSource('https://example.com/s01e03.mkv')
      )

      expect(nextParam !== null).assertTrue()
      expect(context.currentIndex).assertEqual(0)
      if (nextParam !== null) {
        expect(nextParam.url).assertEqual('https://example.com/s01e03.mkv')
        expect(nextParam.videoId).assertEqual(102)
        expect(nextParam.seasonNumber).assertEqual(1)
        expect(nextParam.episodeNumber).assertEqual(3)
        expect(nextParam.mediaKey).assertEqual('media_progress_episode_tmdb_tmdb-9527_s1_e3')
        expect(nextParam.playbackContext?.currentIndex).assertEqual(0)
      }

      const committedItem = commitMediaLibraryEpisodeSwitch(context, context.items[2])
      expect(committedItem !== null).assertTrue()
      expect(context.currentIndex).assertEqual(2)
    })

    it('媒体库切集生成的新参数仍可更新媒体级进度标识', 0, () => {
      const page = buildPlayerPageAccessor()
      const context = new MediaLibraryContext()
      context.items = [buildSelectedEpisode(0), buildSelectedEpisode(1), buildSelectedEpisode(2)]
      context.currentIndex = 0

      const currentParam: PlayerPageParam = {
        url: 'https://example.com/current.mkv',
        title: '当前播放',
        seriesProviderId: 'tmdb-9527',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: context
      }

      const nextParam = buildMediaLibraryEpisodeSwitchParam(
        currentParam,
        context,
        context.items[1],
        buildResolvedSource('https://example.com/s01e02.mkv')
      )

      expect(nextParam !== null).assertTrue()
      if (nextParam !== null) {
        page.applyPlayerPageParam(nextParam)
        expect(page.currentMediaKey).assertEqual('media_progress_episode_tmdb_tmdb-9527_s1_e2')
        expect(page.currentMediaSeason).assertEqual(1)
        expect(page.currentMediaEpisode).assertEqual(2)
      }
    })

    it('非 media_library 场景不会生成播放器切源参数', 0, () => {
      const fileExplorerContext = new FileExplorerContext()
      fileExplorerContext.items = [buildSelectedEpisode(0), buildSelectedEpisode(1)]
      fileExplorerContext.currentIndex = 0

      const currentParam: PlayerPageParam = {
        url: 'https://example.com/current.mkv',
        title: '当前播放',
        seriesProviderId: 'tmdb-9527',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: fileExplorerContext
      }

      const nextParam = buildMediaLibraryEpisodeSwitchParam(
        currentParam,
        fileExplorerContext,
        fileExplorerContext.items[1],
        buildResolvedSource('https://example.com/s01e02.mkv')
      )

      expect(nextParam === null).assertTrue()
      expect(fileExplorerContext.currentIndex).assertEqual(0)
    })

    it('媒体库切集后标题保持详情页的完整格式', 0, () => {
      const fakeItems: MediaItem[] = [
        {
          id: 101, sourceId: 201, directoryPath: '/tv', scannedAt: 0,
          filePath: '/series/s01e01.mkv', fileName: 's01e01.mkv', seasonNumber: 1, episodeNumber: 1,
          title: '长夜余火'
        },
        {
          id: 102, sourceId: 202, directoryPath: '/tv', scannedAt: 0,
          filePath: '/series/s01e02.mkv', fileName: 's01e02.mkv', seasonNumber: 1, episodeNumber: 2,
          title: '长夜余火'
        }
      ]
      const episodeEntities: TvEpisodeEntity[] = [
        {
          seriesId: 7, provider: 'tmdb', providerId: 'ep-1',
          seasonNumber: 1, episodeNumber: 1, scrapedAt: 0,
          title: '启程'
        },
        {
          seriesId: 7, provider: 'tmdb', providerId: 'ep-2',
          seasonNumber: 1, episodeNumber: 2, scrapedAt: 0,
          title: '突围'
        }
      ]
      const buildResult = MediaLibraryContext.buildItems(fakeItems, 1, '/series/s01e01.mkv', episodeEntities)
      const context = new MediaLibraryContext()
      context.items = buildResult.items
      context.currentIndex = buildResult.currentIndex

      const currentParam: PlayerPageParam = {
        url: 'https://example.com/current.mkv',
        title: '长夜余火 第一季-S1:E1-启程',
        seriesProviderId: 'tmdb-9527',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: context
      }

      const nextParam = buildMediaLibraryEpisodeSwitchParam(
        currentParam,
        context,
        context.items[1],
        buildResolvedSource('https://example.com/s01e02.mkv')
      )

      expect(context.items[1].title).assertEqual('突围')
      expect(nextParam !== null).assertTrue()
      if (nextParam !== null) {
        expect(nextParam.title).assertEqual('长夜余火 第一季-S1:E2-突围')
        expect(nextParam.title === '突围').assertFalse()
        expect(nextParam.url).assertEqual('https://example.com/s01e02.mkv')
      }
    })

    it('媒体库切集后缺少集标题时仍保持完整标题格式并回退为第X集', 0, () => {
      const fakeItems: MediaItem[] = [
        {
          id: 101, sourceId: 201, directoryPath: '/tv', scannedAt: 0,
          filePath: '/series/s01e01.mkv', fileName: 's01e01.mkv', seasonNumber: 1, episodeNumber: 1,
          title: '长夜余火'
        },
        {
          id: 102, sourceId: 202, directoryPath: '/tv', scannedAt: 0,
          filePath: '/series/s01e02.mkv', fileName: 's01e02.mkv', seasonNumber: 1, episodeNumber: 2,
          title: '长夜余火'
        }
      ]
      const buildResult = MediaLibraryContext.buildItems(fakeItems, 1, '/series/s01e01.mkv')
      const context = new MediaLibraryContext()
      context.items = buildResult.items
      context.currentIndex = buildResult.currentIndex

      const currentParam: PlayerPageParam = {
        url: 'https://example.com/current.mkv',
        title: '长夜余火 第一季-S1:E1-启程',
        seriesProviderId: 'tmdb-9527',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: context
      }

      const nextParam = buildMediaLibraryEpisodeSwitchParam(
        currentParam,
        context,
        context.items[1],
        buildResolvedSource('https://example.com/s01e02.mkv')
      )

      expect(context.items[1].title).assertEqual('第2集')
      expect(nextParam !== null).assertTrue()
      if (nextParam !== null) {
        expect(nextParam.title).assertEqual('长夜余火 第一季-S1:E2-第2集')
        expect(nextParam.title === '第2集').assertFalse()
        expect(nextParam.url).assertEqual('https://example.com/s01e02.mkv')
      }
    })

    it('媒体库切集后当前标题缺少季集编码时优先保留当前标题', 0, () => {
      const fakeItems: MediaItem[] = [
        {
          id: 101, sourceId: 201, directoryPath: '/tv', scannedAt: 0,
          filePath: '/series/s01e01.mkv', fileName: 's01e01.mkv', seasonNumber: 1, episodeNumber: 1,
          title: '长夜余火'
        },
        {
          id: 102, sourceId: 202, directoryPath: '/tv', scannedAt: 0,
          filePath: '/series/s01e02.mkv', fileName: 's01e02.mkv', seasonNumber: 1, episodeNumber: 2,
          title: '长夜余火'
        }
      ]
      const episodeEntities: TvEpisodeEntity[] = [
        {
          seriesId: 7, provider: 'tmdb', providerId: 'ep-1',
          seasonNumber: 1, episodeNumber: 1, scrapedAt: 0,
          title: '启程'
        },
        {
          seriesId: 7, provider: 'tmdb', providerId: 'ep-2',
          seasonNumber: 1, episodeNumber: 2, scrapedAt: 0,
          title: '突围'
        }
      ]
      const buildResult = MediaLibraryContext.buildItems(fakeItems, 1, '/series/s01e01.mkv', episodeEntities)
      const context = new MediaLibraryContext()
      context.items = buildResult.items
      context.currentIndex = buildResult.currentIndex

      const currentParam: PlayerPageParam = {
        url: 'https://example.com/current.mkv',
        title: '长夜余火 第一季',
        seriesProviderId: 'tmdb-9527',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: context
      }

      const nextParam = buildMediaLibraryEpisodeSwitchParam(
        currentParam,
        context,
        context.items[1],
        buildResolvedSource('https://example.com/s01e02.mkv')
      )

      expect(context.items[1].title).assertEqual('突围')
      expect(nextParam !== null).assertTrue()
      if (nextParam !== null) {
        expect(nextParam.title).assertEqual('长夜余火 第一季')
        expect(nextParam.title === '突围').assertFalse()
        expect(nextParam.url).assertEqual('https://example.com/s01e02.mkv')
      }
    })

    it('播放器内点击当前集数时只关闭弹层且不触发切集链路', 0, async () => {
      const context = buildEpisodeSwitchContext(0)
      // 若误入 resolveEpisodePlaybackSource，sourceId <= 0 会导致 handleEpisodeSelect 返回 false
      context.items[0].sourceId = 0
      const calls: EpisodeSelectNoOpSideEffectCalls = {
        persistCurrentPlaybackState: 0,
        reloadSource: 0,
        resumePlaybackForParam: 0,
        saveProgressNow: 0,
        play: 0
      }
      const page = buildPlayerPageAccessor()
      page.videoPlayerController = new SpyEpisodeSwitchController(context, calls)
      page.currentPageParam = {
        url: 'https://example.com/current.mkv',
        title: '长夜余火 第一季-S1:E1-启程',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: context
      }

      const didSwitch = await page.handleEpisodeSelect(context.items[0])

      expect(didSwitch).assertTrue()
      expect(context.currentIndex).assertEqual(0)
      expect(page.currentPageParam?.episodeNumber ?? 0).assertEqual(1)
      expect(page.videoPlayerController.progressContext === null).assertTrue()
      expect(calls.persistCurrentPlaybackState).assertEqual(0)
      expect(calls.reloadSource).assertEqual(0)
      expect(calls.resumePlaybackForParam).assertEqual(0)
      expect(calls.saveProgressNow).assertEqual(0)
      expect(calls.play).assertEqual(0)
    })

    it('index 不同但季集元数据相同且资源不同时仍会继续切换', 0, async () => {
      const context = buildEpisodeSwitchContext(0)
      context.items[1].seasonNumber = 1
      context.items[1].episodeNumber = 1
      context.items[1].title = '启程-B'
      context.items[1].videoPath = '/series/s01e01-alt.mkv'
      context.items[1].videoId = 301
      const calls: EpisodeSelectNoOpSideEffectCalls = {
        persistCurrentPlaybackState: 0,
        reloadSource: 0,
        resumePlaybackForParam: 0,
        saveProgressNow: 0,
        play: 0
      }
      const page = new TestEpisodeSwitchPage(context, calls, 'https://example.com/s01e01-alt.mkv')
      const controller = page.videoPlayerController as Object as CountingEpisodeSwitchController
      page.currentPageParam = {
        url: 'https://example.com/current.mkv',
        title: '长夜余火 第一季-S1:E1-启程',
        seasonNumber: 1,
        episodeNumber: 1,
        playbackContext: context
      }

      const didSwitch = await page.handleEpisodeSelect(context.items[1])

      expect(didSwitch).assertTrue()
      expect(context.currentIndex).assertEqual(1)
      expect(controller.lastVideoSrc).assertEqual('https://example.com/s01e01-alt.mkv')
      expect(page.currentPageParam?.url ?? '').assertEqual('https://example.com/s01e01-alt.mkv')
      expect(page.currentPageParam?.videoId ?? 0).assertEqual(301)
      expect(page.currentPageParam?.episodeNumber ?? 0).assertEqual(1)
      expect(calls.persistCurrentPlaybackState).assertEqual(1)
      expect(calls.reloadSource).assertEqual(1)
      expect(calls.resumePlaybackForParam).assertEqual(1)
      expect(calls.saveProgressNow).assertEqual(1)
      expect(calls.play).assertEqual(1)
    })

    it('当前集短路判断保持在 handleEpisodeSelect 内，不额外新增 helper', 0, () => {
      const page = buildPlayerPageAccessor() as Object as PlayerPageCurrentEpisodeHelperAccessor

      expect(page.isCurrentMediaLibraryEpisodeSelection === undefined).assertTrue()
    })
  })
}
