import { describe, it, expect } from '@ohos/hypium';
import buffer from '@ohos.buffer';
import {
  AvSubtitleBridgeAdapter,
  decodeSubtitlePayload,
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
  onBuffering(_callback: (isBuffering: boolean) => void): void {}
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

    it('decodeSubtitlePayload: ArrayBuffer UTF-8 中文字幕可正确解码', 0, (done: () => void) => {
      const source = '因为彼此 我们都受尽了折磨';
      const utf8 = buffer.from(source, 'utf-8');
      const arrayBuffer = utf8.buffer.slice(utf8.byteOffset, utf8.byteOffset + utf8.length) as ArrayBuffer;

      const decoded = decodeSubtitlePayload(arrayBuffer);

      expect(decoded).assertEqual(source);
      done();
    });

    it('decodeSubtitlePayload: 错误转成字符串的 UTF-8 中文字幕可恢复', 0, (done: () => void) => {
      const source = '因为彼此 我们都受尽了折磨';
      const utf8 = buffer.from(source, 'utf-8');
      let mojibake = '';
      for (let i = 0; i < utf8.length; i++) {
        mojibake += String.fromCharCode(utf8[i]);
      }

      const decoded = decodeSubtitlePayload(mojibake);

      expect(decoded).assertEqual(source);
      done();
    });

    it('decodeSubtitlePayload: Uint8Array 带偏移时仍能正确解码 UTF-8 中文字幕', 0, (done: () => void) => {
      const source = '因为彼此 我们都受尽了折磨';
      const utf8 = buffer.from(source, 'utf-8');
      const merged = new Uint8Array(utf8.length + 8);
      for (let i = 0; i < 4; i++) {
        merged[i] = 0xFF;
      }
      for (let i = 0; i < utf8.length; i++) {
        merged[4 + i] = utf8[i];
      }
      for (let i = utf8.length + 4; i < merged.length; i++) {
        merged[i] = 0xEE;
      }

      const view = merged.subarray(4, 4 + utf8.length);
      const decoded = decodeSubtitlePayload(view);

      expect(decoded).assertEqual(source);
      done();
    });
  });
}
