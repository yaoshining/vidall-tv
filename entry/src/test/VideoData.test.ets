import { describe, it, expect } from '@ohos/hypium';
import { PresetAudioTrack, PresetSubtitleTrack, VideoData } from '../main/ets/components/core/player/VideoData';
import { VideoDataType } from '../main/ets/components/core/player/Constants';


export default function videoDataTest() {
  describe('VideoData', () => {
    it('PresetAudioTrack 必填字段 displayName 读写正确', 0, () => {
      const track: PresetAudioTrack = { trackIndex: 0, displayName: '中文 (AC-3)' };
      expect(track.displayName).assertEqual('中文 (AC-3)');
      expect(track.trackIndex).assertEqual(0);
    });

    it('PresetAudioTrack 可选字段可独立赋值', 0, () => {
      const track: PresetAudioTrack = {
        trackIndex: 1,
        displayName: 'English (DTS)',
        language: 'eng',
        mimeType: 'audio/vnd.dts',
        channels: 6,
        bitrate: 1536000
      };
      expect(track.language).assertEqual('eng');
      expect(track.mimeType).assertEqual('audio/vnd.dts');
      expect(track.channels).assertEqual(6);
      expect(track.bitrate).assertEqual(1536000);
    });

    it('PresetSubtitleTrack displayName 和 codecName 字段读写正确', 0, () => {
      const sub: PresetSubtitleTrack = {
        trackIndex: 2,
        displayName: '中文 (SRT)',
        codecName: 'subrip'
      };
      expect(sub.displayName).assertEqual('中文 (SRT)');
      expect(sub.codecName).assertEqual('subrip');
    });

    it('VideoData videoSrc 和 type 字段赋值正确', 0, () => {
      const data: VideoData = {
        videoSrc: 'http://192.168.1.1/video.mkv',
        type: VideoDataType.URL
      };
      expect(data.videoSrc).assertEqual('http://192.168.1.1/video.mkv');
      expect(data.type).assertEqual(VideoDataType.URL);
    });
  });
}
