import hilog from '@ohos.hilog';
import * as VidAllNapi from 'libvidall_core_player_napi.so';
import { CommonConstants } from '../common/constants/CommonConstants';

const TAG = 'VpeEnhancerUtil';

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
    if (VpeEnhancerUtil._supportChecked) {
      return VpeEnhancerUtil._supported;
    }
    try {
      VpeEnhancerUtil._supported = VidAllNapi.isVpeDetailEnhancerSupported();
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
      const inputSurfaceId = VidAllNapi.createVpeDetailEnhancer(displaySurfaceId, level);
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
   * 销毁 VPE 实例并释放资源。幂等，未创建时调用无副作用。
   */
  static destroyEnhancer(): void {
    if (!VpeEnhancerUtil._isRunning) {
      return;
    }
    try {
      VidAllNapi.destroyVpeDetailEnhancer();
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
