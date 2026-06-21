import { AppPreferences, PrefKey } from '../utils/AppPreferences';
import { sha256Hex } from './SubtitleDownloader';
import { SubtitleTrackItem } from '../components/core/player/SubtitleBridgeAdapter';
import { SubtitleCacheManager } from './SubtitleCacheManager';

// ─────────────────────────────────────────────
// 公共接口 / 类型
// ─────────────────────────────────────────────

/** 用户字幕绑定类型 */
export type SubtitleBindingType = 'local-file' | 'cached' | 'downloaded' | 'internal' | 'disabled';

/** 用户字幕绑定记录（存储在 AppPreferences 中） */
export interface SubtitleBinding {
  /** 视频完整 URL */
  videoPath: string;
  /**
   * 字幕标识符，语义因 subtitleType 而异：
   * - `local-file`：外置字幕的完整 URL
   * - `downloaded` / `cached`：本地缓存文件路径
    * - `internal`：优先使用 `@idx:<internalIndex>` 稳定 token（兼容历史 displayName）
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
  type: 'user-specified' | 'local-cache' | 'none';
  /** 匹配到的轨道在 allSubtitleTracks 中的索引（type=user-specified 时有效） */
  trackIndex?: number;
  /** 本地缓存文件完整路径（type=local-cache 时有效） */
  localPath?: string;
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
  private static readonly INTERNAL_INDEX_TOKEN_PREFIX: string = '@idx:';
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

  private parseInternalBindingIndexToken(subtitlePath: string): number {
    if (!subtitlePath.startsWith(SubtitleDispatcher.INTERNAL_INDEX_TOKEN_PREFIX)) {
      return -1;
    }
    const rawIndex = subtitlePath.substring(SubtitleDispatcher.INTERNAL_INDEX_TOKEN_PREFIX.length);
    if (rawIndex.length === 0) {
      return -1;
    }
    const parsedIndex = Number.parseInt(rawIndex, 10);
    if (Number.isNaN(parsedIndex)) {
      return -1;
    }
    return parsedIndex;
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
      // disabled 标记可能 subtitlePath 为空；其它类型必须有 4 字段。
      if (parsed['subtitleType'] === 'disabled') {
        if (!parsed['videoPath'] || !parsed['savedAt']) {
          return null;
        }
      } else if (!parsed['videoPath'] || !parsed['subtitlePath'] || !parsed['subtitleType'] || !parsed['savedAt']) {
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
   * 清除用户字幕绑定（标记 disabled 状态）。
   *
   * 历史行为：把 AppPreferences 里的 binding key 清空。
   * 改造后：写入 `{ subtitleType: 'disabled' }` 标记用户主动关闭过字幕。
   *
   * 之所以改成"标记"而不是"清空"：
   * - 步骤 1 看到 disabled 返回 `{ type: 'user-specified', trackIndex: -1 }`
   *   （**显式关闭字幕**，避免 adapter 自动选轨继续显示字幕，而非 return none 让 adapter 自行处理）
   * - 步骤 4（lastUsed 自动恢复）**仍然能命中** metadata.json.lastUsed 指向的缓存字幕
   * - 这样：
   *   1. 关闭字幕后重开视频不会自动应用 lastUsed（用户主动意图生效）
   *   2. 缓存字幕文件**不会被清除**，仍可通过后续扩展在菜单中列出供用户重新启用
   *
   * 注意事项：使用本方法必须确认调用方表达的是"用户主动关闭字幕"语义。
   * 如果是"绑定失效/轨道列表变化"等**非用户主动**的清理场景，应改用
   * `clearUserBindingForce`（直接清空 key），避免误写 disabled 标记导致
   * 下次进入同一视频时字幕被强制关闭。
   */
  async clearUserBinding(videoPath: string): Promise<void> {
    try {
      const key = await this.buildKey(videoPath);
      const binding: SubtitleBinding = {
        videoPath,
        subtitlePath: '',
        subtitleType: 'disabled',
        savedAt: Date.now()
      };
      await AppPreferences.set(key, JSON.stringify(binding));
    } catch (e) {
      console.error(`[SubtitleDispatcher] clearUserBinding 失败: ${String(e)}`);
    }
  }

  /**
   * 强制清空用户字幕绑定（不写 disabled 标记）。
   *
   * 调用场景：avplayer → ijkplayer 格式回退时。fallback 不是用户主动行为，
   * 应当不继承 disabled 状态，让 `resolveSubtitle` 步骤 4 仍能命中 lastUsed 自动恢复缓存字幕。
   *
   * 与 `clearUserBinding` 的区别：
   * - `clearUserBinding` 写 `{ subtitleType: 'disabled' }` 标记（v2 fix 引入，保留"用户主动关闭"语义）
   * - `clearUserBindingForce` 直接清空 key，让 resolveSubtitle 走原始步骤 4 命中逻辑
   *
   * 失败仅 warn，不抛。
   */
  async clearUserBindingForce(videoPath: string): Promise<void> {
    try {
      const key = await this.buildKey(videoPath);
      await AppPreferences.set(key, '');
    } catch (e) {
      console.error(`[SubtitleDispatcher] clearUserBindingForce 失败: ${String(e)}`);
    }
  }

  /**
   * 按 5 步优先级链裁决字幕来源。
   *
   * - 步骤 1：查用户绑定
   *   - local-file：在 allSubtitleTracks 中按 URL 精确匹配（外置字幕）
  *   - internal：优先按 @idx token 匹配 internalIndex，再兼容 displayName（内置字幕）
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
        // 用户主动关闭过字幕 → 返回 user-specified trackIndex=-1，让控制器显式关闭字幕
        // 注意：返回 { type: 'none' } 会让适配器的自动选轨保留，导致字幕仍显示。
        // metadata.json.lastUsed 不会被清除，缓存文件保留供未来 UI 重新加载。
        if (binding.subtitleType === 'disabled') {
          console.info(`[SubtitleDispatcher] 步骤1命中 disabled 用户标记，返回 trackIndex=-1 关闭字幕`);
          const disabled: SubtitleResolution = { type: 'user-specified', trackIndex: -1 };
          return disabled;
        }
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
            // 注：失效清理使用 clearUserBindingForce（清空 key）而不是 clearUserBinding（写 disabled 标记）。
            // clearUserBinding 会写入 { subtitleType: 'disabled' }，等价于"用户主动关闭字幕"，
            // 会在后续 resolveSubtitle 步骤 1 短路返回 trackIndex=-1，错误地把"轨道列表变化/绑定失效"
            // 当作"用户主动关闭"处理，导致下次进入同一视频时字幕被强制关闭。
            // 失效清理应当让 adapter / 缓存字幕按正常流程接管，而非继承 disabled 状态。
            await this.clearUserBindingForce(videoPath);
          }
        } else if (binding.subtitleType === 'internal') {
          // 内置字幕：优先按 @idx token 精确匹配 internalIndex，兼容历史 displayName 匹配。
          let foundIndex = -1;
          const boundInternalIndex = this.parseInternalBindingIndexToken(binding.subtitlePath);
          if (boundInternalIndex >= 0) {
            for (let i = 0; i < allSubtitleTracks.length; i++) {
              const track = allSubtitleTracks[i];
              const trackInternalIndex = track.internalIndex ?? -1;
              if (track.kind === 'internal' && trackInternalIndex === boundInternalIndex) {
                foundIndex = i;
                console.info(`[SubtitleDispatcher] 步骤1 internal token 匹配: token=${binding.subtitlePath} index=${i}`);
                break;
              }
            }
          }

          // 兼容历史 binding（displayName）
          for (let i = 0; i < allSubtitleTracks.length; i++) {
            if (foundIndex < 0) {
              if (allSubtitleTracks[i].kind === 'internal' && allSubtitleTracks[i].displayName === binding.subtitlePath) {
                foundIndex = i;
                break;
              }
            }
          }
          if (foundIndex < 0) {
            // 模糊匹配：binding.subtitlePath 形如 "英语 (SRT)" 时，剥去 " (xxx)" 后缀再与轨道 displayName 比对
            const boundBase = binding.subtitlePath.replace(/\s*\([^)]*\)\s*$/, '').trim();
            if (boundBase.length > 0 && boundBase !== binding.subtitlePath) {
              for (let i = 0; i < allSubtitleTracks.length; i++) {
                if (allSubtitleTracks[i].kind === 'internal' && allSubtitleTracks[i].displayName === boundBase) {
                  foundIndex = i;
                  console.info(`[SubtitleDispatcher] 步骤1 internal 模糊匹配: binding="${binding.subtitlePath}" → displayName="${allSubtitleTracks[i].displayName}" index=${i}`);
                  break;
                }
              }
            }
          }
          if (foundIndex >= 0) {
            console.info(`[SubtitleDispatcher] 步骤1命中用户绑定(internal): index=${foundIndex} displayName=${binding.subtitlePath}`);
            const resolution: SubtitleResolution = { type: 'user-specified', trackIndex: foundIndex };
            return resolution;
          } else {
            console.warn(`[SubtitleDispatcher] 绑定 displayName 不在轨道列表中，自动清除: ${binding.subtitlePath}`);
            // 同样：失效清理使用 clearUserBindingForce，避免误写 disabled 标记导致下次进入视频时字幕被强制关闭。
            await this.clearUserBindingForce(videoPath);
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
            // 缓存文件不在当前轨道列表（如下载缓存存于 filesDir/subtitles/），需追加加载
            // TODO: 补充单元测试覆盖此分支（需 mock SubtitleCacheManager），见 Issue #230
            console.info(`[SubtitleDispatcher] 步骤4缓存路径需追加到轨道列表: ${cachedPath}`);
            const localCache: SubtitleResolution = { type: 'local-cache', localPath: cachedPath };
            return localCache;
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
