import { AppPreferences, PrefKey } from '../utils/AppPreferences';
import { sha256Hex } from './SubtitleDownloader';
import { SubtitleTrackItem } from '../components/core/player/SubtitleBridgeAdapter';
import { SubtitleCacheManager } from './SubtitleCacheManager';

// ─────────────────────────────────────────────
// 公共接口 / 类型
// ─────────────────────────────────────────────

/** 用户字幕绑定类型 */
export type SubtitleBindingType = 'local-file' | 'cached' | 'downloaded' | 'internal';

/** 用户字幕绑定记录（存储在 AppPreferences 中） */
export interface SubtitleBinding {
  /** 视频完整 URL */
  videoPath: string;
  /**
   * 字幕标识符，语义因 subtitleType 而异：
   * - `local-file`：外置字幕的完整 URL
   * - `downloaded` / `cached`：本地缓存文件路径
   * - `internal`：内置轨道的 displayName（用于按名称重定位轨道索引）
   */
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

/** 步骤 4 缓存查询所需的存储上下文（可选传入） */
export interface SubtitleCacheContext {
  filesDir: string;
  sourceType: string;
  sourceId: string;
}

/**
 * 字幕优先级调度器。
 *
 * 在 `VideoPlayerController.loadSubtitleTracks()` 内、`subtitleAdapter.init()` 返回后调用，
 * 覆盖 adapter 的自动选轨结果。
 *
 * 5 步优先级链：
 *   1. 用户指定字幕（持久化绑定）
 *   2-3. adapter 已处理（内置 + 同目录外置）→ 调度器不介入
 *   4. 本地缓存（通过 SubtitleCacheManager.getLastUsedSubtitle() 查询）
 *   5. 无字幕 → 返回 { type: 'none' }
 */
export class SubtitleDispatcher {
  private readonly cacheManager: SubtitleCacheManager;

  constructor(cacheManager?: SubtitleCacheManager) {
    if (cacheManager !== undefined) {
      this.cacheManager = cacheManager;
    } else {
      this.cacheManager = new SubtitleCacheManager();
    }
  }

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
      console.error(`[SubtitleDispatcher] saveUserBinding 失败: ${String(e)}`);
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
      console.error(`[SubtitleDispatcher] clearUserBinding 失败: ${String(e)}`);
    }
  }

  /**
   * 按 5 步优先级链裁决字幕来源。
   *
   * - 步骤 1：查用户绑定
   *   - local-file：在 allSubtitleTracks 中按 URL 精确匹配（外置字幕）
   *   - internal：在 allSubtitleTracks 中按 displayName 精确匹配（内置字幕）
   * - 步骤 2-3：adapter 已处理，此处不介入（返回 none，让 adapter 的自动选轨生效）
   * - 步骤 4：查本地缓存（需要传入 cacheContext）
   * - 步骤 5：返回 { type: 'none' }
   *
   * @param videoPath  视频完整 URL
   * @param allSubtitleTracks  adapter.init() 后的完整字幕轨道列表
   * @param cacheContext  可选，用于步骤 4 缓存查询（filesDir / sourceType / sourceId）
   */
  async resolveSubtitle(
    videoPath: string,
    allSubtitleTracks: SubtitleTrackItem[],
    cacheContext?: SubtitleCacheContext
  ): Promise<SubtitleResolution> {
    // 步骤 1：用户指定字幕
    try {
      const binding = await this.getUserBinding(videoPath);
      if (binding !== null) {
        if (binding.subtitleType === 'local-file') {
          // 外置字幕：按 URL 精确匹配
          let foundIndex = -1;
          for (let i = 0; i < allSubtitleTracks.length; i++) {
            if (allSubtitleTracks[i].url === binding.subtitlePath) {
              foundIndex = i;
              break;
            }
          }
          if (foundIndex >= 0) {
            console.info(`[SubtitleDispatcher] 步骤1命中用户绑定(external): index=${foundIndex} url=${binding.subtitlePath}`);
            const resolution: SubtitleResolution = { type: 'user-specified', trackIndex: foundIndex };
            return resolution;
          } else {
            console.warn(`[SubtitleDispatcher] 绑定 URL 不在轨道列表中，自动清除: ${binding.subtitlePath}`);
            await this.clearUserBinding(videoPath);
          }
        } else if (binding.subtitleType === 'internal') {
          // 内置字幕：按 displayName 精确匹配
          let foundIndex = -1;
          for (let i = 0; i < allSubtitleTracks.length; i++) {
            if (allSubtitleTracks[i].kind === 'internal' && allSubtitleTracks[i].displayName === binding.subtitlePath) {
              foundIndex = i;
              break;
            }
          }
          if (foundIndex >= 0) {
            console.info(`[SubtitleDispatcher] 步骤1命中用户绑定(internal): index=${foundIndex} displayName=${binding.subtitlePath}`);
            const resolution: SubtitleResolution = { type: 'user-specified', trackIndex: foundIndex };
            return resolution;
          } else {
            console.warn(`[SubtitleDispatcher] 绑定 displayName 不在轨道列表中，自动清除: ${binding.subtitlePath}`);
            await this.clearUserBinding(videoPath);
          }
        }
        // downloaded / cached → step 4 处理
      }
    } catch {
      // getUserBinding 失败时安全降级，继续步骤 2
    }

    // 步骤 4：查本地缓存
    if (cacheContext !== undefined) {
      try {
        const cachedPath = await this.getLastUsedSubtitle(
          cacheContext.filesDir,
          cacheContext.sourceType,
          cacheContext.sourceId,
          videoPath
        );
        if (cachedPath !== null) {
          // 以文件名（url 后缀）匹配轨道列表
          const cachedFileName = cachedPath.split('/').pop() ?? '';
          let foundIndex = -1;
          for (let i = 0; i < allSubtitleTracks.length; i++) {
            const trackUrl = allSubtitleTracks[i].url ?? '';
            if (trackUrl.endsWith(cachedFileName)) {
              foundIndex = i;
              break;
            }
          }
          if (foundIndex >= 0) {
            console.info(`[SubtitleDispatcher] 步骤4命中缓存字幕: index=${foundIndex} path=${cachedPath}`);
            const resolution: SubtitleResolution = { type: 'user-specified', trackIndex: foundIndex };
            return resolution;
          } else {
            console.info(`[SubtitleDispatcher] 步骤4缓存路径未在轨道列表中找到对应 track: ${cachedPath}`);
          }
        }
      } catch {
        // 缓存查询失败，降级到步骤 5
      }
    }

    // 步骤 5：无字幕（adapter 自动选轨已生效，调度器不覆盖）
    const none: SubtitleResolution = { type: 'none' };
    return none;
  }

  /**
   * 步骤 4：查询本地缓存最后使用的字幕路径。
   */
  private async getLastUsedSubtitle(
    filesDir: string,
    sourceType: string,
    sourceId: string,
    videoPath: string
  ): Promise<string | null> {
    return this.cacheManager.getLastUsedSubtitle(filesDir, sourceType, sourceId, videoPath);
  }
}
