import { describe, it, expect } from '@ohos/hypium';
import { SmbSubtitleBridgeAdapter } from '../main/ets/components/core/player/SmbSubtitleBridgeAdapter';
import { IPlayer, SubtitleInfo, TrackInfo } from '../main/ets/components/core/player/IPlayer';
import { VideoData, PresetSubtitleTrack } from '../main/ets/components/core/player/VideoData';
import { VideoDataType } from '../main/ets/components/core/player/Constants';

class MinimalMockPlayer implements IPlayer {
  duration: number = 10000;
  currentTime: number = 0;

  init(_videoData: VideoData, _surfaceId: string): Promise<void> { return Promise.resolve(); }
  play(): Promise<void> { return Promise.resolve(); }
  pause(): Promise<void> { return Promise.resolve(); }
  toggle(): Promise<void> { return Promise.resolve(); }
  release(): Promise<void> { return Promise.resolve(); }

  seek(_timeMs: number): void {}
  forward(_milliseconds: number): Promise<void> { return Promise.resolve(); }
  backward(_milliseconds: number): Promise<void> { return Promise.resolve(); }

  getTrackInfos(): Promise<TrackInfo[]> { return Promise.resolve([]); }
  selectTrack(_trackIndex: number): Promise<void> { return Promise.resolve(); }
  setSubtitleDelay(_delayMs: number): void {}
  setPlaybackSpeed(_speed: number): void {}

  onReady(_callback: () => void): void {}
  onPlay(_callback: () => void): void {}
  onPaused(_callback: () => void): void {}
  onCompleted(_callback: () => void): void {}
  onStopped(_callback: () => void): void {}
  onTimeUpdate(_callback: (currentTime: number) => void): void {}
  onBuffering(_callback: (isBuffering: boolean) => void): void {}
  onError(_callback: (error: Error) => void): void {}
  onUnsupportedFormat(_callback: () => void): void {}
  onSeekDone(_callback: () => void): void {}
  onSubtitleUpdate(_callback: (info: SubtitleInfo) => void): void {}
}

export default function smbSubtitleBridgeTest() {
  describe('SmbSubtitleBridge', () => {
    it('SmbSubtitleBridgeAdapter: loadInternalTracks 保留 language 字段', 0, async (done: () => void) => {
      const player = new MinimalMockPlayer();
      const adapter = new SmbSubtitleBridgeAdapter();

      const presetTracks: PresetSubtitleTrack[] = [
        { trackIndex: 2, displayName: '中文', language: 'chi', codecName: 'subrip' },
        { trackIndex: 3, displayName: 'English', language: 'eng', codecName: 'ass' },
        { trackIndex: 4, displayName: '未知', codecName: 'subrip' }
      ];

      const videoData: VideoData = {
        type: VideoDataType.URL,
        videoSrc: 'smb://user:pass@192.168.1.1/share/video.mkv',
        presetSubtitleTracks: presetTracks
      };

      await adapter.init(player, videoData);
      const state = adapter.getState();

      expect(state.allSubtitleTracks.length).assertEqual(3);

      expect(state.allSubtitleTracks[0].kind).assertEqual('internal');
      expect(state.allSubtitleTracks[0].displayName).assertEqual('中文');
      expect(state.allSubtitleTracks[0].language).assertEqual('chi');

      expect(state.allSubtitleTracks[1].kind).assertEqual('internal');
      expect(state.allSubtitleTracks[1].displayName).assertEqual('English');
      expect(state.allSubtitleTracks[1].language).assertEqual('eng');

      expect(state.allSubtitleTracks[2].kind).assertEqual('internal');
      expect(state.allSubtitleTracks[2].displayName).assertEqual('未知');
      expect(state.allSubtitleTracks[2].language).assertEqual(undefined);

      done();
    });
  });
}
