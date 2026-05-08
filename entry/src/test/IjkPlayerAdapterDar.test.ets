import { describe, it, expect } from '@ohos/hypium';
import { dispatchDarCallback } from '../main/ets/utils/PlayerAspectRatioUtil';

/**
 * PlayerAspectRatioUtil — DAR 计算与回调分发单元测试
 *
 * 覆盖范围（Task 1.3 / 1.4 / 1.5）：
 *
 * ① DAR 数学计算路径（通过 dispatchDarCallback 验证接收值）
 *   - SAR 路径：(w * sarNum) / (h * sarDen)
 *   - 回退路径（sarNum=0 或 sarDen=0）：w / h
 *   - 边界：w=0、h=0（SAR 路径与像素路径均应返回 0，回调不触发）
 *
 * ② dispatchDarCallback 行为：
 *   - 合法 DAR（> 0）→ 回调被调用，参数为正确 DAR
 *   - 非正 DAR（w=0 / h=0）→ 回调不被调用
 *   - cb=null → 不触发、不崩溃
 *
 * ③ computeDar 为何不单独测试：
 *   computeDar 是模块内部函数，未导出（审查反馈 Important 2 采纳）。
 *   通过 dispatchDarCallback 可完整覆盖其数学计算路径，
 *   无需将其暴露为公共 API 即可实现等价覆盖。
 *
 * ④ adapter 接线链路为何不在本文件测试（Important 1 技术说明）：
 *   IjkPlayerAdapter 的两条接线链路在静态层面可验证：
 *     a) setOnVideoRatioCallback(cb) → this._onVideoRatioCb = cb;（1 行赋值，可读代码检视）
 *     b) bindListeners/onVideoSizeChanged → dispatchDarCallback(w, h, sarNum, sarDen, this._onVideoRatioCb)
 *        （参数原封不动传入，可读代码检视）
 *   无法自动化的根因：IjkPlayerAdapter 构造器调用 new IjkMediaPlayer()（native .so），
 *   UnitTestBuild 侧无法实例化该类。
 *   这是架构约束，非代码质量问题。adapter 接线的端到端验证应并入 2.3/2.4 集成测试
 *   或 QA/真机核对阶段。
 *
 * ⑤ Task 1.5 init() 不重置回调的验证：
 *   IjkPlayerAdapter.init() 显式重置 _isPrepared / _isPlaying / _duration 等，
 *   但不包含 _onVideoRatioCb。代码检视已确认（grep 仅见字段声明、setter、调用点，
 *   init() 方法体中无赋值语句），属静态可验证事实，无需运行时测试覆盖。
 */
export default function ijkPlayerAdapterDarTest() {

  // ─── ① DAR 数学计算路径（通过 dispatchDarCallback 验证接收值）──────────────

  describe('DAR 数学计算', () => {

    // --- SAR 路径：DAR = (w * sarNum) / (h * sarDen) ----------------------

    it('1280x720 sar=1/1 → 接收 DAR ≈ 16/9', 0, () => {
      let received = -1;
      dispatchDarCallback(1280, 720, 1, 1, (r: number) => { received = r; });
      expect(Math.abs(received - 1280 / 720) < 1e-9).assertTrue();
    });

    it('1920x1080 sar=1/1 → 接收 DAR = 16/9', 0, () => {
      let received = -1;
      dispatchDarCallback(1920, 1080, 1, 1, (r: number) => { received = r; });
      expect(Math.abs(received - 16 / 9) < 1e-9).assertTrue();
    });

    it('720x576 sar=64/45 → 接收 DAR ≈ 16/9（PAL 宽银幕）', 0, () => {
      // (720 * 64) / (576 * 45) = 46080 / 25920 = 16/9
      let received = -1;
      dispatchDarCallback(720, 576, 64, 45, (r: number) => { received = r; });
      expect(Math.abs(received - 16 / 9) < 1e-9).assertTrue();
    });

    it('1920x800 sar=1/1 → 接收 DAR = 2.4（2.40:1 宽银幕）', 0, () => {
      let received = -1;
      dispatchDarCallback(1920, 800, 1, 1, (r: number) => { received = r; });
      expect(Math.abs(received - 2.4) < 1e-9).assertTrue();
    });

    it('480x480 sar=4/3 → 接收 DAR ≈ 4/3（正方形像素 4:3）', 0, () => {
      // (480 * 4) / (480 * 3) = 4/3
      let received = -1;
      dispatchDarCallback(480, 480, 4, 3, (r: number) => { received = r; });
      expect(Math.abs(received - 4 / 3) < 1e-9).assertTrue();
    });

    // --- 回退路径：sarNum=0 或 sarDen=0 → DAR = w / h ---------------------

    it('sarNum=0 → 回退到 w/h，接收正确值', 0, () => {
      let received = -1;
      dispatchDarCallback(1280, 720, 0, 1, (r: number) => { received = r; });
      expect(Math.abs(received - 1280 / 720) < 1e-9).assertTrue();
    });

    it('sarDen=0 → 回退到 w/h，接收正确值', 0, () => {
      let received = -1;
      dispatchDarCallback(1280, 720, 1, 0, (r: number) => { received = r; });
      expect(Math.abs(received - 1280 / 720) < 1e-9).assertTrue();
    });

    it('sarNum=0 sarDen=0 → 回退到 w/h，接收正确值', 0, () => {
      let received = -1;
      dispatchDarCallback(1280, 720, 0, 0, (r: number) => { received = r; });
      expect(Math.abs(received - 1280 / 720) < 1e-9).assertTrue();
    });

    // --- 边界：DAR=0（除零保护），回调不触发 --------------------------------

    it('w=0 → DAR=0，回调不被调用', 0, () => {
      let called = false;
      dispatchDarCallback(0, 720, 1, 1, () => { called = true; });
      expect(called).assertFalse();
    });

    it('h=0 sar=1/1 → SAR 路径除零保护，回调不被调用', 0, () => {
      // (1280 * 1) / (0 * 1) → 分母为 0 → 0
      let called = false;
      dispatchDarCallback(1280, 0, 1, 1, () => { called = true; });
      expect(called).assertFalse();
    });

    it('h=0 无 SAR → 像素路径除零保护，回调不被调用', 0, () => {
      let called = false;
      dispatchDarCallback(1280, 0, 0, 0, () => { called = true; });
      expect(called).assertFalse();
    });

    it('w=0 h=0 → DAR=0，回调不被调用', 0, () => {
      let called = false;
      dispatchDarCallback(0, 0, 1, 1, () => { called = true; });
      expect(called).assertFalse();
    });

  });

  // ─── ② dispatchDarCallback 回调分发行为 ─────────────────────────────────

  describe('dispatchDarCallback — 回调分发', () => {

    // --- 合法 DAR：回调必须被调用，参数为正确 DAR --------------------------

    it('标准 16:9 → 回调被调用，dar 值正确', 0, () => {
      let called = false;
      let receivedDar = 0;
      dispatchDarCallback(1920, 1080, 1, 1, (ratio: number) => {
        called = true;
        receivedDar = ratio;
      });
      expect(called).assertTrue();
      expect(Math.abs(receivedDar - 16 / 9) < 1e-9).assertTrue();
    });

    it('PAL 宽银幕 720x576 sar=64/45 → 回调被调用，dar ≈ 16/9', 0, () => {
      let called = false;
      let receivedDar = 0;
      dispatchDarCallback(720, 576, 64, 45, (ratio: number) => {
        called = true;
        receivedDar = ratio;
      });
      expect(called).assertTrue();
      expect(Math.abs(receivedDar - 16 / 9) < 1e-9).assertTrue();
    });

    it('无 SAR 回退（sarNum=sarDen=0）→ 回调被调用', 0, () => {
      let called = false;
      dispatchDarCallback(1280, 720, 0, 0, () => { called = true; });
      expect(called).assertTrue();
    });

    // --- 非正 DAR：回调不触发 ---------------------------------------------

    it('w=0 → 回调不被调用', 0, () => {
      let called = false;
      dispatchDarCallback(0, 720, 1, 1, () => { called = true; });
      expect(called).assertFalse();
    });

    it('h=0 sar=1/1 → 回调不被调用', 0, () => {
      let called = false;
      dispatchDarCallback(1280, 0, 1, 1, () => { called = true; });
      expect(called).assertFalse();
    });

    it('w=0 h=0 → 回调不被调用', 0, () => {
      let called = false;
      dispatchDarCallback(0, 0, 0, 0, () => { called = true; });
      expect(called).assertFalse();
    });

    // --- cb=null：不崩溃 --------------------------------------------------

    it('cb=null，合法尺寸 → 不崩溃', 0, () => {
      dispatchDarCallback(1920, 1080, 1, 1, null);
      expect(true).assertTrue();
    });

    it('cb=null，w=0 → 不崩溃', 0, () => {
      dispatchDarCallback(0, 720, 1, 1, null);
      expect(true).assertTrue();
    });

  });

}
