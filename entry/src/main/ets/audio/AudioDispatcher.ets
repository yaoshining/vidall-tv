import { AppPreferences, PrefKey } from '../utils/AppPreferences';
import { sha256Hex } from '../subtitle/SubtitleDownloader';
import { AudioTrackItem } from '../components/core/player/VideoPlayerController';

/** 用户音轨绑定记录 */
export interface AudioBinding {
  videoPath: string;
  displayName: string;
  savedAt: number;
}

/** 音轨调度结果 */
export interface AudioResolution {
  type: 'user-specified' | 'none';
  trackIndex?: number;
}

/**
 * 音频轨道优先级调度器。
 * 在 VideoPlayerController.loadAudioTracks() 内、轨道列表填充后调用，
 * 按用户历史绑定恢复上次选择的音轨。
 */
export class AudioDispatcher {

  private async buildKey(videoPath: string): Promise<string> {
    const hash = await sha256Hex(videoPath);
    return `${PrefKey.AUDIO_BINDING_PREFIX}_${hash.slice(0, 12)}`;
  }

  async getAudioBinding(videoPath: string): Promise<AudioBinding | null> {
    try {
      const key = await this.buildKey(videoPath);
      const raw = await AppPreferences.get(key, '');
      if (raw.length === 0) {
        return null;
      }
      const parsed = JSON.parse(raw) as Record<string, string | number>;
      if (!parsed['videoPath'] || !parsed['displayName'] || !parsed['savedAt']) {
        return null;
      }
      const binding: AudioBinding = {
        videoPath: parsed['videoPath'] as string,
        displayName: parsed['displayName'] as string,
        savedAt: parsed['savedAt'] as number
      };
      return binding;
    } catch {
      return null;
    }
  }

  async saveAudioBinding(videoPath: string, displayName: string): Promise<void> {
    try {
      const key = await this.buildKey(videoPath);
      const binding: AudioBinding = {
        videoPath,
        displayName,
        savedAt: Date.now()
      };
      await AppPreferences.set(key, JSON.stringify(binding));
    } catch (e) {
      console.error(`[AudioDispatcher] saveAudioBinding 失败: ${String(e)}`);
    }
  }

  async clearAudioBinding(videoPath: string): Promise<void> {
    try {
      const key = await this.buildKey(videoPath);
      await AppPreferences.set(key, '');
    } catch (e) {
      console.error(`[AudioDispatcher] clearAudioBinding 失败: ${String(e)}`);
    }
  }

  async resolveAudioTrack(
    videoPath: string,
    audioTracks: AudioTrackItem[]
  ): Promise<AudioResolution> {
    try {
      const binding = await this.getAudioBinding(videoPath);
      if (binding !== null) {
        let foundIndex = -1;
        for (let i = 0; i < audioTracks.length; i++) {
          if (audioTracks[i].displayName === binding.displayName) {
            foundIndex = i;
            break;
          }
        }
        if (foundIndex >= 0) {
          console.info(`[AudioDispatcher] 命中用户绑定: index=${foundIndex} displayName=${binding.displayName}`);
          const resolution: AudioResolution = { type: 'user-specified', trackIndex: foundIndex };
          return resolution;
        } else {
          console.warn(`[AudioDispatcher] 绑定 displayName 不在轨道列表中，自动清除: ${binding.displayName}`);
          await this.clearAudioBinding(videoPath);
        }
      }
    } catch {
      // 安全降级
    }
    const none: AudioResolution = { type: 'none' };
    return none;
  }
}
