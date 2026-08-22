import { describe, it, expect } from '@ohos/hypium';
import {
  buildRoutingDecision,
  rankAudioTracksByCapability
} from '../main/ets/services/audioRouting/AudioTrackRoutingService';
import {
  AudioRoutingInput,
  AudioTrackAnalysis
} from '../main/ets/services/audioRouting/AudioRoutingTypes';
import { AudioTrackItem } from '../main/ets/components/core/player/VideoPlayerController';
import {
  AudioTrackCompatibility,
  AudioCapabilitySource
} from '../main/ets/services/audioCapability/AudioCapabilityTypes';

function makeAnalysis(
  index: number,
  codec: string,
  channels: number,
  compatible: boolean,
  isHardware: boolean,
  source: 'probe' | 'preset',
  capabilitySource: AudioCapabilitySource
): AudioTrackAnalysis {
  const a: AudioTrackAnalysis = {
    index,
    codec,
    channels,
    compatible,
    isHardware,
    source,
    capabilitySource,
    hardSupported: isHardware,
    maxChannels: 0
  };
  return a;
}

function makeInput(tracks: AudioTrackAnalysis[]): AudioRoutingInput {
  const input: AudioRoutingInput = {
    presetCodecName: '',
    presetChannels: 2,
    presetHasAudio: false,
    probeCodecName: '',
    probeChannels: 2,
    probeVideoCodecName: '',
    probeVideoHdrType: '',
    probeVideoWidth: undefined,
    probeVideoHeight: undefined,
    probeSuccess: true,
    probeError: '',
    precheckProbeFailed: false,
    precheckProbeError: '',
    trackAnalyses: tracks
  };
  return input;
}

function makeCompatibility(
  codec: string,
  channels: number,
  compatible: boolean,
  isHardware: boolean,
  maxChannels: number
): AudioTrackCompatibility {
  const c: AudioTrackCompatibility = {
    codec,
    channels,
    compatible,
    isHardware,
    maxChannels,
    source: 'system'
  };
  return c;
}

export default function audioTrackRoutingTest() {
  describe('buildRoutingDecision - 设备能力路由', () => {
    it('存在兼容音轨时选 AVPlayer 并预选硬解最优轨', 0, () => {
      const tracks: AudioTrackAnalysis[] = [
        makeAnalysis(0, 'truehd', 8, false, false, 'probe', 'system'),
        makeAnalysis(1, 'eac3', 6, true, false, 'probe', 'system'),
        makeAnalysis(2, 'aac', 2, true, true, 'probe', 'system')
      ];
      const d = buildRoutingDecision(makeInput(tracks));
      expect(d.preferredBackend).assertEqual('avplayer');
      expect(d.recommendedInitialTrackIndex).assertEqual(2);
      expect(d.recommendedCodec).assertEqual('aac');
    });

    it('无兼容音轨时直接选 MPV', 0, () => {
      const tracks: AudioTrackAnalysis[] = [
        makeAnalysis(0, 'truehd', 8, false, false, 'probe', 'system'),
        makeAnalysis(1, 'dts', 6, false, false, 'probe', 'system')
      ];
      const d = buildRoutingDecision(makeInput(tracks));
      expect(d.preferredBackend).assertEqual('mpv');
    });

    it('能力未知时保守选 MPV', 0, () => {
      const tracks: AudioTrackAnalysis[] = [
        makeAnalysis(0, 'eac3', 6, false, false, 'probe', 'unknown')
      ];
      const d = buildRoutingDecision(makeInput(tracks));
      expect(d.preferredBackend).assertEqual('mpv');
    });

    it('探测失败且无音轨提示时沿用历史行为选 AVPlayer', 0, () => {
      const d = buildRoutingDecision(makeInput([]));
      expect(d.preferredBackend).assertEqual('avplayer');
    });
  });

  describe('rankAudioTracksByCapability - 能力选轨', () => {
    it('硬解优先于软解', 0, () => {
      const tracks: AudioTrackItem[] = [
        { trackIndex: 0, displayName: 'E-AC-3', language: 'chi', codecName: 'eac3' },
        { trackIndex: 1, displayName: 'AAC', language: 'chi', codecName: 'aac' }
      ];
      const comps: AudioTrackCompatibility[] = [
        makeCompatibility('eac3', 6, true, false, 6),
        makeCompatibility('aac', 2, true, true, 2)
      ];
      expect(rankAudioTracksByCapability(tracks, comps)).assertEqual(1);
    });

    it('声道超上限的轨被排除', 0, () => {
      const tracks: AudioTrackItem[] = [
        { trackIndex: 0, displayName: 'TrueHD 7.1', language: 'chi', codecName: 'truehd', channels: 8 },
        { trackIndex: 1, displayName: 'AAC 2.0', language: 'eng', codecName: 'aac', channels: 2 }
      ];
      const comps: AudioTrackCompatibility[] = [
        makeCompatibility('truehd', 8, false, false, 2),
        makeCompatibility('aac', 2, true, true, 2)
      ];
      expect(rankAudioTracksByCapability(tracks, comps)).assertEqual(1);
    });

    it('兼容时优先同语言再考虑声道', 0, () => {
      const tracks: AudioTrackItem[] = [
        { trackIndex: 0, displayName: '英文 AAC 2.0', language: 'eng', codecName: 'aac', channels: 2 },
        { trackIndex: 1, displayName: '中文 AAC 5.1', language: 'chi', codecName: 'aac', channels: 6 },
        { trackIndex: 2, displayName: '英文 AAC 5.1', language: 'eng', codecName: 'aac', channels: 6 }
      ];
      const comps: AudioTrackCompatibility[] = [
        makeCompatibility('aac', 2, true, true, 6),
        makeCompatibility('aac', 6, true, true, 6),
        makeCompatibility('aac', 6, true, true, 6)
      ];
      expect(rankAudioTracksByCapability(tracks, comps)).assertEqual(2);
    });
  });
}
