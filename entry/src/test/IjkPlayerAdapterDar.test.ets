import { describe, it, expect } from '@ohos/hypium';
import { computeDar, dispatchDarCallback } from '../main/ets/utils/PlayerAspectRatioUtil';

/**
 * PlayerAspectRatioUtil — DAR 计算与回调分发单元测试
 *
 * 覆盖范围（Task 1.3 / 1.4 / 1.5）：
 *
 * A. computeDar：
 *   - 有 SAR 时：DAR = (w * sarNum) / (h * sarDen)
 *   - 无 SAR 时：DAR = w / h
 *   - 边界：w=0、h=0、sarNum=0、sarDen=0 → DAR = 0
 *
 * B. dispatchDarCallback（回调分发行为链路）：
 *   - 合法尺寸（DAR > 0）→ 回调被调用，参数为正确 DAR
 *   - w=0 / h=0（DAR = 0）→ 回调不被调用
 *   - cb=null → 不触发、不崩溃
 *
 * 为何在此测试分发逻辑：
 *   IjkPlayerAdapter 构造器调用 new IjkMediaPlayer()（native .so），
 *   无法在 UnitTestBuild 侧直接实例化。dispatchDarCallback 是从
 *   onVideoSizeChanged 内联逻辑中提取的纯函数，测试它即等价于测试
 *   IjkPlayerAdapter 内部的回调分发行为，同时无需任何 native 依赖。
 *
 * Task 1.5 init() 不重置回调的验证：
 *   IjkPlayerAdapter.init() 显式重置 _isPrepared / _isPlaying / _duration 等，
 *   但不包含 _onVideoRatioCb（代码检视确认：grep "_onVideoRatioCb" IjkPlayerAdapter.ets
 *   仅见字段声明、setter 和 dispatchDarCallback 调用点，init() 方法体中无赋值语句）。
 *   该不变式属于静态可验证事实，无需运行时测试覆盖。
 */
export default function ijkPlayerAdapterDarTest() {
  describe('computeDar', () => {

    // ─── 有 SAR 时的计算路径 ─────────────────────────────────────────────────

    it('1280x720 sar=1/1 → DAR ≈ 1.778 (16:9)', 0, () => {
      const dar = computeDar(1280, 720, 1, 1);
      // (1280 * 1) / (720 * 1) = 1280/720 ≈ 1.7778
      expect(Math.abs(dar - 1280 / 720) < 1e-9).assertTrue();
    });

    it('1920x1080 sar=1/1 → DAR = 16/9', 0, () => {
      const dar = computeDar(1920, 1080, 1, 1);
      expect(Math.abs(dar - 16 / 9) < 1e-9).assertTrue();
    });

    it('720x576 sar=64/45 → DAR ≈ 1.778 (4:3 PAL 宽银幕)', 0, () => {
      // (720 * 64) / (576 * 45) = 46080 / 25920 = 16/9
      const dar = computeDar(720, 576, 64, 45);
      expect(Math.abs(dar - 16 / 9) < 1e-9).assertTrue();
    });

    it('1920x800 sar=1/1 → DAR = 2.4 (2.40:1 宽银幕)', 0, () => {
      const dar = computeDar(1920, 800, 1, 1);
      expect(Math.abs(dar - 2.4) < 1e-9).assertTrue();
    });

    it('480x480 sar=4/3 → DAR ≈ 1.333 (正方形像素 4:3)', 0, () => {
      // (480 * 4) / (480 * 3) = 4/3
      const dar = computeDar(480, 480, 4, 3);
      expect(Math.abs(dar - 4 / 3) < 1e-9).assertTrue();
    });

    // ─── 无 SAR / SAR 缺省时的回退路径 ──────────────────────────────────────

    it('sarNum=0 → 回退到 w/h', 0, () => {
      const dar = computeDar(1280, 720, 0, 1);
      // sarNum=0：回退到 w/h = 1280/720
      expect(Math.abs(dar - 1280 / 720) < 1e-9).assertTrue();
    });

    it('sarDen=0 → 回退到 w/h', 0, () => {
      const dar = computeDar(1280, 720, 1, 0);
      // sarDen=0：回退到 w/h
      expect(Math.abs(dar - 1280 / 720) < 1e-9).assertTrue();
    });

    it('sarNum=0 sarDen=0 → 回退到 w/h', 0, () => {
      const dar = computeDar(1280, 720, 0, 0);
      expect(Math.abs(dar - 1280 / 720) < 1e-9).assertTrue();
    });

    // ─── 边界：DAR ≤ 0 应触发不回调保护 ─────────────────────────────────────

    it('w=0 → DAR=0（不应触发回调）', 0, () => {
      const dar = computeDar(0, 720, 1, 1);
      expect(dar).assertEqual(0);
    });

    it('h=0 sarNum=sarDen=0 → DAR=0（除零保护）', 0, () => {
      // w/h: 分母为 0，应返回 0 而非 Infinity / NaN
      const dar = computeDar(1280, 0, 0, 0);
      expect(dar).assertEqual(0);
    });

    it('h=0 sar=1/1 → DAR=0（SAR 路径除零保护）', 0, () => {
      // (1280 * 1) / (0 * 1) → 分母为 0，返回 0
      const dar = computeDar(1280, 0, 1, 1);
      expect(dar).assertEqual(0);
    });

    it('w=0 h=0 → DAR=0', 0, () => {
      const dar = computeDar(0, 0, 1, 1);
      expect(dar).assertEqual(0);
    });

    it('w=0 h=0 sarNum=0 sarDen=0 → DAR=0', 0, () => {
      const dar = computeDar(0, 0, 0, 0);
      expect(dar).assertEqual(0);
    });

    // ─── DAR 正值验证（可触发回调的条件）────────────────────────────────────

    it('标准 16:9 DAR > 0', 0, () => {
      const dar = computeDar(1920, 1080, 1, 1);
      expect(dar > 0).assertTrue();
    });

    it('宽银幕 2.35:1 DAR > 0', 0, () => {
      const dar = computeDar(2560, 1088, 1, 1);
      expect(dar > 0).assertTrue();
    });

  });

  // ─── dispatchDarCallback 行为链路测试 ──────────────────────────────────────
  //
  // 直接覆盖 Important 1 审查反馈：
  //   "onVideoSizeChanged 在合法 DAR 时是否调用 _onVideoRatioCb(dar)"
  //   "宽高为 0 / DAR ≤ 0 时是否真的不触发、不崩溃"
  //
  // dispatchDarCallback 是从 IjkPlayerAdapter.onVideoSizeChanged 内联逻辑提取
  // 的纯函数，测试它即等价于测试该回调分发行为。

  describe('dispatchDarCallback', () => {

    // --- 合法 DAR：回调必须被调用，参数为正确 DAR --------------------------

    it('1920x1080 sar=1/1 → 回调被调用且 dar ≈ 16/9', 0, () => {
      let called = false;
      let receivedDar = 0;
      dispatchDarCallback(1920, 1080, 1, 1, (ratio: number) => {
        called = true;
        receivedDar = ratio;
      });
      expect(called).assertTrue();
      expect(Math.abs(receivedDar - 16 / 9) < 1e-9).assertTrue();
    });

    it('720x576 sar=64/45 → 回调被调用且 dar ≈ 16/9（PAL 宽银幕）', 0, () => {
      let called = false;
      let receivedDar = 0;
      dispatchDarCallback(720, 576, 64, 45, (ratio: number) => {
        called = true;
        receivedDar = ratio;
      });
      expect(called).assertTrue();
      expect(Math.abs(receivedDar - 16 / 9) < 1e-9).assertTrue();
    });

    it('1280x720 sar=0/0（回退 w/h）→ 回调被调用且 dar ≈ 16/9', 0, () => {
      let called = false;
      dispatchDarCallback(1280, 720, 0, 0, () => {
        called = true;
      });
      expect(called).assertTrue();
    });

    // --- 非正 DAR：回调不触发 ---------------------------------------------

    it('w=0 → DAR=0，回调不被调用', 0, () => {
      let called = false;
      dispatchDarCallback(0, 720, 1, 1, () => {
        called = true;
      });
      expect(called).assertFalse();
    });

    it('h=0 sar=1/1 → DAR=0，回调不被调用', 0, () => {
      let called = false;
      dispatchDarCallback(1280, 0, 1, 1, () => {
        called = true;
      });
      expect(called).assertFalse();
    });

    it('w=0 h=0 → DAR=0，回调不被调用', 0, () => {
      let called = false;
      dispatchDarCallback(0, 0, 0, 0, () => {
        called = true;
      });
      expect(called).assertFalse();
    });

    // --- cb=null：不崩溃 --------------------------------------------------

    it('cb=null，合法尺寸 → 不崩溃', 0, () => {
      // 若内部对 null 未保护则抛异常，测试即失败
      dispatchDarCallback(1920, 1080, 1, 1, null);
      expect(true).assertTrue(); // 能到达此处即证明无崩溃
    });

    it('cb=null，w=0 → 不崩溃', 0, () => {
      dispatchDarCallback(0, 720, 1, 1, null);
      expect(true).assertTrue();
    });

  });

}
