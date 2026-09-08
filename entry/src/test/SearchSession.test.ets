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
      slow.resolve(['late']);
      expect(await pending).assertFalse();
      expect(session.status).assertEqual('error');
      await session.run(() => Promise.resolve(['retry']));
      expect(session.results[0]).assertEqual('retry');
    });
  });
}
