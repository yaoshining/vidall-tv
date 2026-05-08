/**
 * PlayerAspectRatioUtil — 视频显示宽高比计算工具
 *
 * 从 IjkPlayerAdapter 中提取，独立为可复用的纯函数模块：
 * - 无任何 native 依赖，可直接在 UnitTestBuild 侧测试
 * - 其他 Adapter（如 AVPlayerAdapter）或 UI 层如需 DAR 计算可直接引用
 */

/**
 * 计算视频 Display Aspect Ratio（DAR）。
 *
 * 公式：
 *   - sarNum > 0 && sarDen > 0：DAR = (w * sarNum) / (h * sarDen)
 *   - 否则回退到像素比：DAR = w / h
 *
 * 安全策略：分母为 0（h=0 或 h*sarDen=0）时返回 0，调用方须在 DAR > 0 时才触发回调。
 *
 * @param w      视频宽度（像素）
 * @param h      视频高度（像素）
 * @param sarNum Sample Aspect Ratio 分子（native 上报）
 * @param sarDen Sample Aspect Ratio 分母（native 上报）
 * @returns DAR 值，或 0（不可用 / 分母为零）
 */
export function computeDar(w: number, h: number, sarNum: number, sarDen: number): number {
  if (sarNum > 0 && sarDen > 0) {
    const denom = h * sarDen;
    if (denom === 0) {
      return 0;
    }
    return (w * sarNum) / denom;
  }
  if (h === 0) {
    return 0;
  }
  return w / h;
}

/**
 * 计算 DAR 并在有效值（> 0）时调用回调。
 *
 * 这是 IjkPlayerAdapter.onVideoSizeChanged 中回调分发逻辑的提取，
 * 单独测试此函数即可覆盖"合法 DAR 触发回调 / 非正 DAR 不触发"这一关键行为链路，
 * 而无需实例化依赖 native .so 的 IjkPlayerAdapter。
 *
 * @param w      视频宽度（像素）
 * @param h      视频高度（像素）
 * @param sarNum Sample Aspect Ratio 分子
 * @param sarDen Sample Aspect Ratio 分母
 * @param cb     DAR 回调；为 null 时不调用
 */
export function dispatchDarCallback(
  w: number, h: number, sarNum: number, sarDen: number,
  cb: ((ratio: number) => void) | null
): void {
  const dar = computeDar(w, h, sarNum, sarDen);
  if (dar > 0 && cb !== null) {
    cb(dar);
  }
}
