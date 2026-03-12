import { describe, it, expect } from '@ohos/hypium';
import {
  AvSubtitleBridgeAdapter,
  IjkSubtitleBridgeAdapter,
  NoSubtitleBridgeAdapter
} from '../main/ets/components/core/player/SubtitleBridgeAdapter';
import { IPlayer, SubtitleInfo, TrackInfo } from '../main/ets/components/core/player/IPlayer';
import { VideoData } from '../main/ets/components/core/player/VideoData';
import { VideoDataType } from '../main/ets/components/core/player/Constants';

class MockPlayer implements IPlayer {
  duration: number = 10000;
  currentTime: number = 0;
  trackInfos: TrackInfo[] = [];
  selectedTrack: number = -99;

  init(_videoData: VideoData, _surfaceId: string): Promise<void> { return Promise.resolve(); }
  play(): Promise<void> { return Promise.resolve(); }
  pause(): Promise<void> { return Promise.resolve(); }
  toggle(): Promise<void> { return Promise.resolve(); }
  release(): Promise<void> { return Promise.resolve(); }

  seek(timeMs: number): void { this.currentTime = timeMs; }
  forward(milliseconds: number): Promise<void> {
    this.currentTime += milliseconds;
    return Promise.resolve();
  }
  backward(milliseconds: number): Promise<void> {
    this.currentTime -= milliseconds;
    return Promise.resolve();
  }

  getTrackInfos(): Promise<TrackInfo[]> {
    return Promise.resolve(this.trackInfos);
  }
  selectTrack(trackIndex: number): Promise<void> {
    this.selectedTrack = trackIndex;
    return Promise.resolve();
  }
  setSubtitleDelay(_delayMs: number): void {}

  onReady(_callback: () => void): void {}
  onPlay(_callback: () => void): void {}
  onPaused(_callback: () => void): void {}
  onCompleted(_callback: () => void): void {}
  onStopped(_callback: () => void): void {}
  onTimeUpdate(_callback: (currentTime: number) => void): void {}
  onError(_callback: (error: Error) => void): void {}
  onUnsupportedFormat(_callback: () => void): void {}
  onSeekDone(_callback: () => void): void {}
  onSubtitleUpdate(_callback: (info: SubtitleInfo) => void): void {}
}

export default function subtitleBridgeAdapterTest() {
  describe('SubtitleBridgeAdapter', () => {
    it('AvSubtitleBridgeAdapter: 初始化后可构建统一字幕状态', 0, async (done: () => void) => {
      const player = new MockPlayer();
      player.trackInfos = [
        { trackIndex: 0, trackType: 'video' },
        { trackIndex: 2, trackType: 'subtitle', language: 'chi' },
        { trackIndex: 3, trackType: 'subtitle', language: 'eng' }
      ];

      const adapter = new AvSubtitleBridgeAdapter();
      const videoData: VideoData = {
        type: VideoDataType.FILE_URI,
        videoSrc: 'file:///test.mp4'
      };

      await adapter.init(player, videoData);
      const state = adapter.getState();
      expect(state.allSubtitleTracks.length).assertEqual(2);
      expect(state.activeSubtitleIndex).assertEqual(0);
      expect(player.selectedTrack).assertEqual(2);
      done();
    });

    it('IjkSubtitleBridgeAdapter: 当前策略下隐藏内嵌字幕轨', 0, async (done: () => void) => {
      const player = new MockPlayer();
      const adapter = new IjkSubtitleBridgeAdapter();
      const videoData: VideoData = {
        type: VideoDataType.FILE_URI,
        videoSrc: 'file:///movie.mkv',
        presetSubtitleTracks: [
          { trackIndex: 5, displayName: '中文 (SRT)' }
        ]
      };

      await adapter.init(player, videoData);
      let state = adapter.getState();
        expect(state.allSubtitleTracks.length).assertEqual(0);
        expect(state.activeSubtitleIndex).assertEqual(-1);
        expect(player.selectedTrack).assertEqual(-99);

      await adapter.switchTrack(-1);
      state = adapter.getState();
      expect(state.activeSubtitleIndex).assertEqual(-1);
      expect(player.selectedTrack).assertEqual(-1);
      done();
    });

    it('NoSubtitleBridgeAdapter: 初始化失败兜底状态稳定', 0, async (done: () => void) => {
      const player = new MockPlayer();
      const adapter = new NoSubtitleBridgeAdapter();
      const videoData: VideoData = {
        type: VideoDataType.FILE_URI,
        videoSrc: 'file:///empty.mp4'
      };

      await adapter.init(player, videoData);
      adapter.adjustDelay(500);
      adapter.onTimeUpdate(1200);
      adapter.onSubtitleUpdate({ text: 'ignored' });

      const state = adapter.getState();
      expect(state.allSubtitleTracks.length).assertEqual(0);
      expect(state.currentSubtitleText).assertEqual('');
      expect(state.subtitleDelayMs).assertEqual(0);
      done();
    });
  });
}
