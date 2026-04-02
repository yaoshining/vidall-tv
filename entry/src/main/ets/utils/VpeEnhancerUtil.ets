import hilog from '@ohos.hilog';
import * as VidAllNapiModule from 'libvidall_core_player_napi.so';
import { CommonConstants } from '../common/constants/CommonConstants';

const TAG = 'VpeEnhancerUtil';

// ─── NAPI Bridge（.so 模块必须通过 Bridge 模式获得类型安全访问）───────────────

interface VpeNapiBridge {
  isVpeDetailEnhancerSupported: () => boolean;
  createVpeDetailEnhancer: (displaySurfaceId: string, qualityLevel: number) => string;
  updateVpeQuality: (qualityLevel: number) => void;
  destroyVpeDetailEnhancer: () => void;
}

interface VpeNapiBridgeModule {
  default?: VpeNapiBridge;
}

function getVidAllCorePlayerNapi(): VpeNapiBridge {
  const mod = VidAllNapiModule as VpeNapiBridgeModule | VpeNapiBridge | undefined;
  if (mod === undefined) {
    throw new Error('libvidall_core_player_napi.so 未加载');
  }
  const def = (mod as VpeNapiBridgeModule).default;
  if (def !== undefined) {
    return def as VpeNapiBridge;
  }
  return mod as VpeNapiBridge;
}

/**
 * VPE AI 画质增强质量档位
 * 对应 native VideoDetailEnhancer_QualityLevel
 */
export type VpeQualityLevel = 'low' | 'medium' | 'high';

function qualityToLevel(quality: VpeQualityLevel): number {
  if (quality === 'high') { return 3; }
  if (quality === 'low') { return 1; }
  return 2; // medium 默认
}

/**
 * VPE（Video Processing Engine）AI 画质增强工具类。
 *
 * 使用方式：
 *   const vpeSurfaceId = VpeEnhancerUtil.createEnhancer(xcomponentSurfaceId, 'medium');
 *   if (vpeSurfaceId) {
 *     // 将 vpeSurfaceId 传给播放器（替代 xcomponentSurfaceId）
 *   } else {
 *     // 设备不支持，回退到原始 surfaceId
 *   }
 *   // 播放器释放时：
 *   VpeEnhancerUtil.destroyEnhancer();
 *
 * 注意：
 * - 仅适用于 AVPlayer 路径；ijkplayer 使用 XComponent native hook，无法插入 VPE
 * - 不支持的设备返回空字符串，不抛异常
 * - 单例：同时只能存在一个 VPE 实例
 */
export class VpeEnhancerUtil {
  private static _isRunning: boolean = false;
  private static _supportChecked: boolean = false;
  private static _supported: boolean = false;

  /**
   * 查询设备是否支持 VPE Detail Enhancer（有缓存，仅首次调用走 native）
   */
  static isSupported(): boolean {
    if (!canIUse('SystemCapability.Multimedia.VideoProcessingEngine')) {
      return false;
    }
    if (VpeEnhancerUtil._supportChecked) {
      return VpeEnhancerUtil._supported;
    }
    try {
      VpeEnhancerUtil._supported = getVidAllCorePlayerNapi().isVpeDetailEnhancerSupported();
    } catch {
      VpeEnhancerUtil._supported = false;
    }
    VpeEnhancerUtil._supportChecked = true;
    hilog.info(CommonConstants.LOG_DOMAIN, TAG,
      `设备 VPE 支持状态: ${VpeEnhancerUtil._supported}`);
    return VpeEnhancerUtil._supported;
  }

  /**
   * 创建 VPE 增强实例。
   * @param displaySurfaceId XComponent 的 surfaceId（最终显示目标）
   * @param quality 质量档位，默认 'medium'
   * @returns VPE 输入 surfaceId（传给播放器）；空字符串表示不支持或失败，调用方应回退到原 surfaceId
   */
  static createEnhancer(displaySurfaceId: string, quality: VpeQualityLevel = 'medium'): string {
    if (!VpeEnhancerUtil.isSupported()) {
      return '';
    }
    const level = qualityToLevel(quality);
    try {
      const inputSurfaceId = getVidAllCorePlayerNapi().createVpeDetailEnhancer(displaySurfaceId, level);
      if (inputSurfaceId && inputSurfaceId.length > 0) {
        VpeEnhancerUtil._isRunning = true;
        hilog.info(CommonConstants.LOG_DOMAIN, TAG,
          `VPE 已创建: quality=${quality}(${level}) inputSurfaceId=${inputSurfaceId}`);
        return inputSurfaceId;
      }
    } catch {
      // Native 层失败（不支持/GPU 异常），安全降级
    }
    hilog.warn(CommonConstants.LOG_DOMAIN, TAG,
      `VPE 创建失败，回退到原始 surfaceId（displaySurfaceId=${displaySurfaceId}）`);
    return '';
  }

  /**
   * 动态更新质量档位（不重建管线，避免 Surface 断开导致画面冻结）。
   * 仅在 VPE 正在运行时生效；未运行时静默忽略。
   */
  static updateQuality(quality: VpeQualityLevel): void {
    if (!VpeEnhancerUtil._isRunning) {
      hilog.warn(CommonConstants.LOG_DOMAIN, TAG, 'VPE updateQuality ignored: not running');
      return;
    }
    const level = qualityToLevel(quality);
    try {
      getVidAllCorePlayerNapi().updateVpeQuality(level);
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, `VPE 质量已更新: ${quality}(${level})`);
    } catch {
      // ignore
    }
  }

  /**
   * 关闭画质增强（设为 NONE/透传模式，保持管线完整避免画面冻结）。
   * VPE 仍运行但不做任何处理，仅做 Surface 转发。
   */
  static setPassthrough(): void {
    if (!VpeEnhancerUtil._isRunning) {
      return;
    }
    try {
      getVidAllCorePlayerNapi().updateVpeQuality(0); // NONE = 透传
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'VPE 已切换为透传模式（关闭增强）');
    } catch {
      // ignore
    }
  }

  /**
   * 销毁 VPE 实例并释放资源。仅在播放器完全释放时调用。
   * ⚠️ 不要在播放中途调用：会摧毁 AVPlayer 正在使用的输入 Surface，导致画面冻结。
   */
  static destroyEnhancer(): void {
    if (!VpeEnhancerUtil._isRunning) {
      return;
    }
    try {
      getVidAllCorePlayerNapi().destroyVpeDetailEnhancer();
      hilog.info(CommonConstants.LOG_DOMAIN, TAG, 'VPE 已销毁');
    } catch {
      // ignore
    } finally {
      VpeEnhancerUtil._isRunning = false;
    }
  }

  static get isRunning(): boolean {
    return VpeEnhancerUtil._isRunning;
  }
}
