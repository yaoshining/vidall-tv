import { describe, it, expect } from '@ohos/hypium'
import {
  EpisodePlaybackManager,
  EpisodePlaybackManagerState
} from '../main/ets/components/core/player/EpisodePlaybackManager'
import { FileExplorerContext, MediaLibraryContext, PlaybackContextItem } from '../main/ets/components/core/player/PlaybackContext'

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

    it('非媒体库上下文或无下一集时安全降级', 0, () => {
      const manager: EpisodePlaybackManager = new EpisodePlaybackManager()
      const fileExplorerContext = new FileExplorerContext()
      fileExplorerContext.items = [buildEpisodeItem(0), buildEpisodeItem(1)]
      fileExplorerContext.currentIndex = 0

      manager.updateSettings(true, 8)
      const fileExplorerState: EpisodePlaybackManagerState = manager.sync(fileExplorerContext, 1795000, 1800000)
      expect(fileExplorerState.visible).assertFalse()
      expect(fileExplorerState.shouldPlayNext).assertFalse()

      const mediaContext = buildMediaLibraryContext(2)
      const lastEpisodeState: EpisodePlaybackManagerState = manager.sync(mediaContext, 1795000, 1800000)
      expect(lastEpisodeState.visible).assertFalse()
      expect(lastEpisodeState.shouldPlayNext).assertFalse()
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
