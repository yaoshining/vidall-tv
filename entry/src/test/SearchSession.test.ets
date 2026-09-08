import { describe, it, expect } from '@ohos/hypium';
import { SearchSession } from '../main/ets/services/search/SearchSession';

class DeferredSearch {
  resolve: (items: string[]) => void = () => {};
  reject: (reason: Error) => void = () => {};
  promise: Promise<string[]> = new Promise<string[]>((resolve, reject) => {
    this.resolve = resolve;
    this.reject = reject;
  });
}

async function awaitSettled(pending: Promise<boolean>): Promise<boolean> {
  let timer: number = -1;
  const deadline = new Promise<boolean>((resolve, reject) => {
    timer = setTimeout(() => reject(new Error('搜索等待未及时结束')), 200);
  });
  try {
    return await Promise.race([pending, deadline]);
  } finally {
    clearTimeout(timer);
  }
}

export default function searchSessionTest() {
  describe('SearchSession', () => {
    it('invalidates immediately before the next debounced request', 0, async () => {
      const session = new SearchSession<string>();
      const old = new DeferredSearch();
      const pending = session.run(() => old.promise);
      session.prepare();
      old.resolve(['old']);
      expect(await pending).assertFalse();
      expect(session.results.length).assertEqual(0);
      expect(session.status).assertEqual('loading');
      session.invalidate();
    });
    it('clear, source replacement and page leave discard late responses', 0, async () => {
      const session = new SearchSession<string>();
      for (let i = 0; i < 3; i++) {
        const old = new DeferredSearch();
        const pending = session.run(() => old.promise);
        session.invalidate(true);
        old.resolve(['old source']);
        expect(await pending).assertFalse();
        expect(session.status).assertEqual('idle');
        expect(session.results.length).assertEqual(0);
      }
    });
    it('late failure cannot replace newer success', 0, async () => {
      const session = new SearchSession<string>();
      const old = new DeferredSearch();
      const pending = session.run(() => old.promise);
      await session.run(() => Promise.resolve(['new']));
      old.reject(new Error('private-url'));
      await pending;
      expect(session.results[0]).assertEqual('new');
      expect(session.status).assertEqual('results');
    });
    it('refresh preserves results, failure is distinct from empty, retry succeeds', 0, async () => {
      const session = new SearchSession<string>();
      await session.run(() => Promise.resolve(['previous']));
      const refresh = new DeferredSearch();
      const pending = session.run(() => refresh.promise);
      expect(session.status).assertEqual('refreshing');
      expect(session.results[0]).assertEqual('previous');
      refresh.reject(new Error('password=secret'));
      await pending;
      expect(session.status).assertEqual('error');
      expect(session.results[0]).assertEqual('previous');
      await session.run(() => Promise.resolve([]));
      expect(session.status).assertEqual('empty');
    });
    it('timeout stays an error when provider eventually responds', 0, async () => {
      const session = new SearchSession<string>();
      const slow = new DeferredSearch();
      const pending = session.run(() => slow.promise, 1);
      await new Promise<void>((resolve) => { setTimeout(resolve, 10); });
      expect(session.status).assertEqual('error');
      expect(await awaitSettled(pending)).assertFalse();
      slow.resolve(['late']);
      await Promise.resolve();
      expect(session.status).assertEqual('error');
      await session.run(() => Promise.resolve(['retry']));
      expect(session.results[0]).assertEqual('retry');
    });
    it('失效立即释放未完成调用，旧超时不影响重试', 0, async () => {
      const session = new SearchSession<string>();
      const old = new DeferredSearch();
      const pending = session.run(() => old.promise, 10);
      session.prepare();
      expect(await awaitSettled(pending)).assertFalse();
      const retry = new DeferredSearch();
      const current = session.run(() => retry.promise, 1000);
      await new Promise<void>((resolve) => { setTimeout(resolve, 30); });
      expect(session.status).assertEqual('loading');
      old.resolve(['旧结果']);
      await Promise.resolve();
      expect(session.results.length).assertEqual(0);
      retry.resolve(['重试结果']);
      expect(await awaitSettled(current)).assertTrue();
      expect(session.results[0]).assertEqual('重试结果');
    });
    it('超时后迟到拒绝被消费且不影响新代次', 0, async () => {
      const session = new SearchSession<string>();
      const old = new DeferredSearch();
      const pending = session.run(() => old.promise, 1);
      expect(await awaitSettled(pending)).assertFalse();
      expect(session.status).assertEqual('error');
      const retry = new DeferredSearch();
      const current = session.run(() => retry.promise, 1000);
      old.reject(new Error('私有地址'));
      await new Promise<void>((resolve) => { setTimeout(resolve, 10); });
      expect(session.status).assertEqual('loading');
      retry.resolve(['新结果']);
      expect(await awaitSettled(current)).assertTrue();
      expect(session.results[0]).assertEqual('新结果');
    });
    it('清空与离页不等待数据源完成', 0, async () => {
      const session = new SearchSession<string>();
      const old = new DeferredSearch();
      const pending = session.run(() => old.promise);
      session.invalidate(true);
      expect(await awaitSettled(pending)).assertFalse();
      expect(session.status).assertEqual('idle');
    });
  });
}
