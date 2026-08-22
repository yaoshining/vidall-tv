import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeAudioCodec,
  codecCompatibilityRank,
  normalizeTargetChannels,
  normalizeChannelsForSort,
  isLikelySystemHardDecodeSupported
} from '../main/ets/services/audioRouting/AudioCodecUtil';

export default function audioCodecUtilTest() {
  describe('AudioCodecUtil', () => {
    it('normalizeAudioCodec 归一化 AAC MIME', 0, () => {
      expect(normalizeAudioCodec('audio/mp4a-latm')).assertEqual('aac');
      expect(normalizeAudioCodec('mp4a')).assertEqual('aac');
    });

    it('normalizeAudioCodec 归一化 E-AC-3 / DTS-HD', 0, () => {
      expect(normalizeAudioCodec('audio/eac3')).assertEqual('eac3');
      expect(normalizeAudioCodec('audio/vnd.dts.hd')).assertEqual('vnd.dts.hd');
      expect(normalizeAudioCodec('audio/vnd.dts')).assertEqual('vnd.dts');
    });

    it('normalizeAudioCodec 去除连字符', 0, () => {
      expect(normalizeAudioCodec('audio/ac-3')).assertEqual('ac3');
    });

    it('codecCompatibilityRank 硬解友好为 1、软解常见为 2、未知为 4', 0, () => {
      expect(codecCompatibilityRank('aac')).assertEqual(1);
      expect(codecCompatibilityRank('mp3')).assertEqual(1);
      expect(codecCompatibilityRank('ac3')).assertEqual(2);
      expect(codecCompatibilityRank('eac3')).assertEqual(2);
      expect(codecCompatibilityRank('')).assertEqual(4);
      expect(codecCompatibilityRank('unknowncodec')).assertEqual(4);
    });

    it('normalizeTargetChannels 声道边界', 0, () => {
      expect(normalizeTargetChannels(1)).assertEqual(1);
      expect(normalizeTargetChannels(2)).assertEqual(2);
      expect(normalizeTargetChannels(6)).assertEqual(6);
      expect(normalizeTargetChannels(8)).assertEqual(8);
      expect(normalizeTargetChannels(10)).assertEqual(8);
      expect(normalizeTargetChannels(0)).assertEqual(2);
    });

    it('normalizeChannelsForSort 排序归一化', 0, () => {
      expect(normalizeChannelsForSort(1)).assertEqual(1);
      expect(normalizeChannelsForSort(2)).assertEqual(2);
      expect(normalizeChannelsForSort(5)).assertEqual(6);
      expect(normalizeChannelsForSort(9)).assertEqual(8);
    });

    it('isLikelySystemHardDecodeSupported 软解关键字判定', 0, () => {
      expect(isLikelySystemHardDecodeSupported('aac')).assertTrue();
      expect(isLikelySystemHardDecodeSupported('eac3')).assertFalse();
      expect(isLikelySystemHardDecodeSupported('truehd')).assertFalse();
    });
  });
}
