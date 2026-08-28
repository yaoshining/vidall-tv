import { describe, it, expect } from '@ohos/hypium'
import {
  EpisodePlaybackManager,
  EpisodePlaybackManagerState
} from '../main/ets/components/core/player/EpisodePlaybackManager'
import {
  FileExplorerContext,
  MediaLibraryContext,
  ServerMediaLibraryContext,
  ServerMediaLibraryMeta,
  PlaybackContextItem
} from '../main/ets/components/core/player/PlaybackContext'
import { VideoServerEpisode } from '../main/ets/lib/JellyfinClient'

function buildEpisodeItem(index: number): PlaybackContextItem {
  return {
    index,
    title: `第${index + 1}集`,
    videoPath: `/series/s01e0${index + 1}.mkv`,
    videoId: 101 + index,
    sourceId: 201 + index,
    seasonNumber: 1,
    episodeNumber: index + 1,
    durationMs: 1800000
  }
}

function buildMediaLibraryContext(currentIndex: number = 0): MediaLibraryContext {
  const context = new MediaLibraryContext()
  context.items = [buildEpisodeItem(0), buildEpisodeItem(1), buildEpisodeItem(2)]
  context.currentIndex = currentIndex
  return context
}

function buildServerEpisode(id: string, episodeNumber: number): VideoServerEpisode {
  const ep: VideoServerEpisode = {
    id,
    episodeNumber,
    seasonNumber: 1,
    title: `服务器第${episodeNumber}集`,
    overview: '',
    stillUrl: `${id}-still`,
    durationMs: 1800000,
    rating: 0,
    positionMs: 0,
    lastPlayedDate: 0
  }
  return ep
}

function buildServerLibraryContext(currentIndex: number): ServerMediaLibraryContext {
  const episodes = [buildServerEpisode('srv-ep1', 1), buildServerEpisode('srv-ep2', 2)]
  const meta: ServerMediaLibraryMeta = {
    serverType: 'jellyfin',
    serverId: 7,
    seriesId: 'srv-series',
    seriesTitle: '服务器剧集',
    seasonNumber: 1,
    seasonName: '第 1 季',
    posterUrl: '',
    backdropUrl: ''
  }
  const context = ServerMediaLibraryContext.build(episodes, 'srv-ep1', meta)
  context.currentIndex = currentIndex
  return context
}

export default function episodePlaybackManagerTest() {
  describe('EpisodePlaybackManager', () => {
    it('启用自动下一集时会在接近结束时展示倒计时并触发下一集', 0, () => {
      const manager: EpisodePlaybackManager = new EpisodePlaybackManager()
      const context = buildMediaLibraryContext(0)

      manager.updateSettings(true, 8)
      const countdownState: EpisodePlaybackManagerState = manager.sync(context, 1793000, 1800000)
      expect(countdownState.visible).assertTrue()
      expect(countdownState.remainingSeconds).assertEqual(7)
      expect(countdownState.nextItem?.videoPath ?? '').assertEqual('/series/s01e02.mkv')

      const autoplayState: EpisodePlaybackManagerState = manager.sync(context, 1800000, 1800000)
      expect(autoplayState.shouldPlayNext).assertTrue()
      expect(autoplayState.nextItem?.videoPath ?? '').assertEqual('/series/s01e02.mkv')
    })

    it('播放器末尾不再上报进度时倒计时仍会结束', 0, () => {
      const manager: EpisodePlaybackManager = new EpisodePlaybackManager()
      const context = buildMediaLibraryContext(0)

      manager.updateSettings(true, 8)
      const initialState: EpisodePlaybackManagerState = manager.sync(context, 1797000, 1800000, 1000)
      expect(initialState.remainingSeconds).assertEqual(3)

      const frozenState: EpisodePlaybackManagerState = manager.sync(context, 1797000, 1800000, 2500)
      expect(frozenState.remainingSeconds).assertEqual(2)

      const autoplayState: EpisodePlaybackManagerState = manager.sync(context, 1797000, 1800000, 4000)
      expect(autoplayState.visible).assertFalse()
      expect(autoplayState.shouldPlayNext).assertTrue()
    })

    it('关闭自动下一集后即使接近结束也不展示倒计时', 0, () => {
      const manager: EpisodePlaybackManager = new EpisodePlaybackManager()
      const context = buildMediaLibraryContext(0)

      manager.updateSettings(false, 8)
      const state: EpisodePlaybackManagerState = manager.sync(context, 1795000, 1800000)

      expect(state.visible).assertFalse()
      expect(state.shouldPlayNext).assertFalse()
      expect(state.nextItem === null).assertTrue()
    })

    it('用户取消后当前集不再自动切换，直到当前播放项发生变化', 0, () => {
      const manager: EpisodePlaybackManager = new EpisodePlaybackManager()
      const context = buildMediaLibraryContext(0)

      manager.updateSettings(true, 8)
      manager.sync(context, 1794000, 1800000)
      manager.cancelCurrentEpisode()

      const cancelledState: EpisodePlaybackManagerState = manager.sync(context, 1800000, 1800000)
      expect(cancelledState.shouldPlayNext).assertFalse()
      expect(cancelledState.visible).assertFalse()

      context.jumpTo(1)
      const resumedState: EpisodePlaybackManagerState = manager.sync(context, 1799000, 1800000)
      expect(resumedState.visible).assertTrue()
      expect(resumedState.nextItem?.videoPath ?? '').assertEqual('/series/s01e03.mkv')
    })

    it('file_explorer 上下文有下一集时显示自动播放倒计时', 0, () => {
      const manager: EpisodePlaybackManager = new EpisodePlaybackManager()
      const fileExplorerContext = new FileExplorerContext()
      fileExplorerContext.items = [buildEpisodeItem(0), buildEpisodeItem(1)]
      fileExplorerContext.currentIndex = 0

      manager.updateSettings(true, 8)
      const fileExplorerState: EpisodePlaybackManagerState = manager.sync(fileExplorerContext, 1795000, 1800000)
      expect(fileExplorerState.visible).assertTrue()
      expect(fileExplorerState.shouldPlayNext).assertFalse()

      const mediaContext = buildMediaLibraryContext(2)
      const lastEpisodeState: EpisodePlaybackManagerState = manager.sync(mediaContext, 1795000, 1800000)
      expect(lastEpisodeState.visible).assertFalse()
      expect(lastEpisodeState.shouldPlayNext).assertFalse()
    })

    it('server_media_library 上下文有下一集时显示自动播放倒计时并触发下一集', 0, () => {
      const manager: EpisodePlaybackManager = new EpisodePlaybackManager()
      const serverContext = buildServerLibraryContext(0)

      manager.updateSettings(true, 8)
      const countdownState: EpisodePlaybackManagerState = manager.sync(serverContext, 1793000, 1800000)
      expect(countdownState.visible).assertTrue()
      expect(countdownState.remainingSeconds).assertEqual(7)
      expect(countdownState.nextItem?.videoPath ?? '').assertEqual('srv-ep2')

      const autoplayState: EpisodePlaybackManagerState = manager.sync(serverContext, 1800000, 1800000)
      expect(autoplayState.shouldPlayNext).assertTrue()
      expect(autoplayState.nextItem?.videoPath ?? '').assertEqual('srv-ep2')
    })

    it('server_media_library 上下文最后一集不展示倒计时也不触发下一集', 0, () => {
      const manager: EpisodePlaybackManager = new EpisodePlaybackManager()
      const serverContext = buildServerLibraryContext(1)

      manager.updateSettings(true, 8)
      const lastEpisodeState: EpisodePlaybackManagerState = manager.sync(serverContext, 1795000, 1800000)
      expect(lastEpisodeState.visible).assertFalse()
      expect(lastEpisodeState.shouldPlayNext).assertFalse()
      expect(lastEpisodeState.nextItem).assertNull()
    })

    it('自动切换失败后当前集保持降级停用，不会重复重试', 0, () => {
      const manager: EpisodePlaybackManager = new EpisodePlaybackManager()
      const context = buildMediaLibraryContext(0)

      manager.updateSettings(true, 8)
      const initialState: EpisodePlaybackManagerState = manager.sync(context, 1800000, 1800000)
      expect(initialState.shouldPlayNext).assertTrue()

      manager.markAutoplayFailed()
      const failedState: EpisodePlaybackManagerState = manager.sync(context, 1800000, 1800000)
      expect(failedState.shouldPlayNext).assertFalse()
      expect(failedState.visible).assertFalse()
    })
  })
}
