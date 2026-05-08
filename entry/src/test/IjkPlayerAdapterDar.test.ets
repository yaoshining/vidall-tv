import { describe, it, expect } from '@ohos/hypium';
import { computeDar } from '../main/ets/components/core/player/IjkPlayerAdapter';

/**
 * IjkPlayerAdapter — DAR（Display Aspect Ratio）计算单元测试
 *
 * 覆盖范围（Task 1.3 / 1.4）：
 *   - 有 SAR 时：DAR = (w * sarNum) / (h * sarDen)
 *   - 无 SAR 时：DAR = w / h
 *   - 边界：w=0、h=0、sarNum=0、sarDen=0 → DAR ≤ 0（不触发回调）
 *
 * 注：IjkPlayerAdapter 构造器调用 `new IjkMediaPlayer()`（native .so），
 * 无法在 UnitTestBuild 侧直接实例化。回调注册链路（_onVideoRatioCb 注入 →
 * bindListeners 触发）属于集成级行为，须在设备侧 E2E 验证。
 * 此处仅对可提取的纯数学逻辑 computeDar() 做单元覆盖。
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
}
