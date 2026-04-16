import { describe, it, expect } from '@ohos/hypium';
import { DebounceUtil, CancellableFunction } from '../main/ets/utils/DebounceUtil';

export default function debounceUtilTest() {
  describe('DebounceUtil', () => {
    it('debounce 默认参数返回 CancellableFunction 实例', 0, () => {
      const fn = (_arg: string): void => {};
      const result: CancellableFunction = DebounceUtil.debounce(fn);
      expect(result !== null && result !== undefined).assertTrue();
    });

    it('debounce 自定义 delay 返回 CancellableFunction 实例', 0, () => {
      const fn = (_arg: string): void => {};
      const result: CancellableFunction = DebounceUtil.debounce(fn, 500);
      expect(result !== null && result !== undefined).assertTrue();
    });

    it('cancel 在未调用 call 前可安全调用不抛出异常', 0, () => {
      const fn = (_arg: string): void => {};
      const cancellable: CancellableFunction = DebounceUtil.debounce(fn);
      let threw = false;
      try {
        cancellable.cancel();
      } catch (e) {
        threw = true;
      }
      expect(threw).assertFalse();
    });

    it('cancel 连续调用两次不抛出异常（幂等）', 0, () => {
      const fn = (_arg: string): void => {};
      const cancellable: CancellableFunction = DebounceUtil.debounce(fn, 300);
      let threw = false;
      try {
        cancellable.cancel();
        cancellable.cancel();
      } catch (e) {
        threw = true;
      }
      expect(threw).assertFalse();
    });
  });
}
