import { AppPreferences, PrefKey } from '../utils/AppPreferences';
import { sha256Hex } from './SubtitleDownloader';
import { SubtitleTrackItem } from '../components/core/player/SubtitleBridgeAdapter';

// ─────────────────────────────────────────────
// 公共接口 / 类型
// ─────────────────────────────────────────────

/** 用户字幕绑定类型 */
export type SubtitleBindingType = 'local-file' | 'cached' | 'downloaded';

/** 用户字幕绑定记录（存储在 AppPreferences 中） */
export interface SubtitleBinding {
  /** 视频完整 URL */
  videoPath: string;
  /** 字幕完整 URL（local-file）或本地路径（downloaded/cached） */
  subtitlePath: string;
  /** 绑定类型 */
  subtitleType: SubtitleBindingType;
  /** 写入时的 Unix 时间戳（毫秒） */
  savedAt: number;
}

/** 字幕调度结果 */
export interface SubtitleResolution {
  /** 调度来源类型 */
  type: 'user-specified' | 'none';
  /** 匹配到的轨道在 allSubtitleTracks 中的索引（type=user-specified 时有效） */
  trackIndex?: number;
}

// ─────────────────────────────────────────────
// SubtitleDispatcher
// ─────────────────────────────────────────────

/**
 * 字幕优先级调度器。
 *
 * 在 `VideoPlayerController.loadSubtitleTracks()` 内、`subtitleAdapter.init()` 返回后调用，
 * 覆盖 adapter 的自动选轨结果。
 *
 * 5 步优先级链：
 *   1. 用户指定字幕（持久化绑定）
 *   2-3. adapter 已处理（内置 + 同目录外置）→ 调度器不介入
 *   4. 本地缓存（stub，始终返回 null，待 #28 接入）
 *   5. 无字幕 → 返回 { type: 'none' }
 */
export class SubtitleDispatcher {

  // ──────────────────────────────────────────
  // 绑定存储 key 计算
  // ──────────────────────────────────────────

  private async buildKey(videoPath: string): Promise<string> {
    const hash = await sha256Hex(videoPath);
    return `${PrefKey.SUBTITLE_BINDING_PREFIX}_${hash.slice(0, 12)}`;
  }

  // ──────────────────────────────────────────
  // 公开 API
  // ──────────────────────────────────────────

  /**
   * 读取用户字幕绑定。
   * - key 存在且合法 JSON → 返回 SubtitleBinding
   * - key 不存在或 JSON 损坏 → 返回 null（不抛异常）
   */
  async getUserBinding(videoPath: string): Promise<SubtitleBinding | null> {
    try {
      const key = await this.buildKey(videoPath);
      const raw = await AppPreferences.get(key, '');
      if (raw.length === 0) {
        return null;
      }
      const parsed = JSON.parse(raw) as Record<string, string | number>;
      if (!parsed['videoPath'] || !parsed['subtitlePath'] || !parsed['subtitleType'] || !parsed['savedAt']) {
        return null;
      }
      const binding: SubtitleBinding = {
        videoPath: parsed['videoPath'] as string,
        subtitlePath: parsed['subtitlePath'] as string,
        subtitleType: parsed['subtitleType'] as SubtitleBindingType,
        savedAt: parsed['savedAt'] as number
      };
      return binding;
    } catch {
      return null;
    }
  }

  /**
   * 保存用户字幕绑定。
   * 在用户手动选择外置字幕时调用。
   */
  async saveUserBinding(
    videoPath: string,
    subtitlePath: string,
    type: SubtitleBindingType
  ): Promise<void> {
    try {
      const key = await this.buildKey(videoPath);
      const binding: SubtitleBinding = {
        videoPath,
        subtitlePath,
        subtitleType: type,
        savedAt: Date.now()
      };
      await AppPreferences.set(key, JSON.stringify(binding));
    } catch (e) {
      console.error(`[SubtitleDispatcher] saveUserBinding 失败: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 清除用户字幕绑定。
   * 在用户关闭字幕或绑定 URL 匹配失败时调用。
   */
  async clearUserBinding(videoPath: string): Promise<void> {
    try {
      const key = await this.buildKey(videoPath);
      await AppPreferences.set(key, '');
    } catch (e) {
      console.error(`[SubtitleDispatcher] clearUserBinding 失败: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 按 5 步优先级链裁决字幕来源。
   *
   * - 步骤 1：查用户绑定 → 在 allSubtitleTracks 中按 URL 精确匹配
   * - 步骤 2-3：adapter 已处理，此处不介入（返回 none，让 adapter 的自动选轨生效）
   * - 步骤 4：stub，始终跳过
   * - 步骤 5：返回 { type: 'none' }
   *
   * @param videoPath  视频完整 URL
   * @param allSubtitleTracks  adapter.init() 后的完整字幕轨道列表
   */
  async resolveSubtitle(
    videoPath: string,
    allSubtitleTracks: SubtitleTrackItem[]
  ): Promise<SubtitleResolution> {
    // 步骤 1：用户指定字幕
    try {
      const binding = await this.getUserBinding(videoPath);
      if (binding !== null) {
        if (binding.subtitleType === 'local-file') {
          // 在轨道列表中按 URL 精确匹配
          let foundIndex = -1;
          for (let i = 0; i < allSubtitleTracks.length; i++) {
            if (allSubtitleTracks[i].url === binding.subtitlePath) {
              foundIndex = i;
              break;
            }
          }
          if (foundIndex >= 0) {
            console.info(`[SubtitleDispatcher] 步骤1命中用户绑定: index=${foundIndex} url=${binding.subtitlePath}`);
            const resolution: SubtitleResolution = { type: 'user-specified', trackIndex: foundIndex };
            return resolution;
          } else {
            // URL 已失效，自动清除绑定
            console.warn(`[SubtitleDispatcher] 绑定 URL 不在轨道列表中，自动清除: ${binding.subtitlePath}`);
            await this.clearUserBinding(videoPath);
          }
        }
        // downloaded / cached → stub，跳过（步骤 4 接入后处理）
      }
    } catch {
      // getUserBinding 失败时安全降级，继续步骤 2
    }

    // 步骤 4：stub，始终返回 null（待 #28 接入）
    // const lastUsed = await this.getLastUsedSubtitle(videoPath); // always null

    // 步骤 5：无字幕（adapter 自动选轨已生效，调度器不覆盖）
    const none: SubtitleResolution = { type: 'none' };
    return none;
  }

  /**
   * 步骤 4 stub：始终返回 null。
   * #28 完成后，接入 SubtitleCacheManager 并真正实现。
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  private async getLastUsedSubtitle(_videoPath: string): Promise<string | null> {
    return null;
  }
}
