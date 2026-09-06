import { describe, it, expect } from '@ohos/hypium';
import { VideoServer, VideoServerType } from '../main/ets/db/models/VideoServerEntity';
import { SearchScope, SearchScopeIdentity, resolveSearchScope, createLocalSearchScope } from '../main/ets/models/search/SearchScope';
import { SearchWorkspaceContext, SearchWorkspaceSession } from '../main/ets/services/search/SearchWorkspaceSession';
import { VideoServerSearchService, VideoServerSearchResult } from '../main/ets/services/search/VideoServerSearchService';

class PendingResult {
  private resolveResult: (result: VideoServerSearchResult) => void = () => {};
  promise: Promise<VideoServerSearchResult> = new Promise<VideoServerSearchResult>((resolve) => {
    this.resolveResult = resolve;
  });
  complete(scope: SearchScope, status: 'success' | 'empty' | 'error'): void {
    const result: VideoServerSearchResult = {
      status, scopeKey: scope.key, keyword: 'film', items: [], errorCode: status === 'error' ? 'network' : 'none'
    };
    this.resolveResult(result);
  }
}

class ControlledSearch extends VideoServerSearchService {
  pending: PendingResult[] = [];
  configurations: string[] = [];
  search(_scope: SearchScope, server: VideoServer, _keyword: string): Promise<VideoServerSearchResult> {
    const pending = new PendingResult();
    this.pending.push(pending);
    this.configurations.push(server.configJson);
    return pending.promise;
  }
}

function context(id: number): SearchWorkspaceContext {
  const server: VideoServer = {
    id, name: `Server ${id}`, type: VideoServerType.JELLYFIN, configJson: '{}', createdAt: 1
  };
  const identity: SearchScopeIdentity = { kind: 'videoServer', serverId: id };
  const result: SearchWorkspaceContext = { scope: resolveSearchScope(identity, [server]), server };
  return result;
}

export default function searchWorkspaceSessionTest() {
  describe('SearchWorkspaceSession', () => {
    for (const terminal of ['success', 'empty', 'error']) {
      it(`先发布加载态，再发布 ${terminal} 终态`, 0, async () => {
        const session = new SearchWorkspaceSession();
        const service = new ControlledSearch();
        const current = context(1);
        const states: string[] = [];
        const task = session.search('film', () => current, (result) => { states.push(result.status); }, service);
        expect(states.join(',')).assertEqual('loading');
        service.pending[0].complete(current.scope, terminal as 'success' | 'empty' | 'error');
        await task;
        expect(states.join(',')).assertEqual(`loading,${terminal}`);
      });
    }
    for (const action of ['input', 'clear', 'leave', 'source', 'configuration']) {
      it(`在 ${action} 后立即拒绝旧请求完成回调`, 0, async () => {
        const session = new SearchWorkspaceSession();
        const service = new ControlledSearch();
        const current = context(1);
        const states: string[] = [];
        const task = session.search('film', () => current, (result) => { states.push(result.status); }, service);
        if (action === 'leave') { session.dispose(); } else { session.invalidate(); }
        service.pending[0].complete(current.scope, 'error');
        await task;
        expect(states.join(',')).assertEqual('loading');
      });
    }
    it('同协议 A B A 切换拒绝此前请求与旧错误', 0, async () => {
      const session = new SearchWorkspaceSession();
      const service = new ControlledSearch();
      let current = context(1);
      const states: string[] = [];
      const publish = (result: VideoServerSearchResult): void => { states.push(`${result.scopeKey}:${result.status}`); };
      const a = session.search('film', () => current, publish, service);
      session.invalidate(); current = context(2);
      const b = session.search('film', () => current, publish, service);
      session.invalidate(); current = context(1);
      const latest = session.search('film', () => current, publish, service);
      service.pending[2].complete(current.scope, 'success'); await latest;
      service.pending[0].complete(context(1).scope, 'error'); await a;
      service.pending[1].complete(context(2).scope, 'success'); await b;
      expect(states.length).assertEqual(4);
      expect(states[3]).assertEqual('video-server:jellyfin:1:success');
    });
    it('相同关键词重试拒绝更早请求的错误', 0, async () => {
      const session = new SearchWorkspaceSession();
      const service = new ControlledSearch();
      const current = context(1);
      const states: string[] = [];
      const publish = (result: VideoServerSearchResult): void => { states.push(result.status); };
      const first = session.search('film', () => current, publish, service);
      const retry = session.search('film', () => current, publish, service);
      service.pending[1].complete(current.scope, 'empty'); await retry;
      service.pending[0].complete(current.scope, 'error'); await first;
      expect(states.join(',')).assertEqual('loading,loading,empty');
    });
    it('按值捕获配置并拒绝未通知的同身份原地修改', 0, async () => {
      const session = new SearchWorkspaceSession();
      const service = new ControlledSearch();
      const current = context(1);
      const states: string[] = [];
      const task = session.search('film', () => current, (result) => { states.push(result.status); }, service);
      if (current.server !== undefined) { current.server.configJson = '{"url":"changed"}'; }
      expect(service.configurations[0]).assertEqual('{}');
      service.pending[0].complete(current.scope, 'success'); await task;
      expect(states.join(',')).assertEqual('loading');
    });
    it('捕获的来源身份拒绝未通知的同协议切源', 0, async () => {
      const session = new SearchWorkspaceSession();
      const service = new ControlledSearch();
      let current = context(1);
      const states: string[] = [];
      const task = session.search('film', () => current, (result) => { states.push(result.status); }, service);
      current = context(2);
      service.pending[0].complete(context(1).scope, 'success'); await task;
      expect(states.join(',')).assertEqual('loading');
    });
    it('空关键词、本地、缺失及已销毁上下文不发起传输', 0, async () => {
      const session = new SearchWorkspaceSession();
      const service = new ControlledSearch();
      let current = context(1);
      const publish = (_result: VideoServerSearchResult): void => {};
      await session.search('  ', () => current, publish, service);
      current = { scope: createLocalSearchScope() };
      await session.search('film', () => current, publish, service);
      current = { scope: context(1).scope };
      await session.search('film', () => current, publish, service);
      current = context(1); session.dispose();
      await session.search('film', () => current, publish, service);
      expect(service.pending.length).assertEqual(0);
    });
    it('重新激活不恢复上一页面生命周期的请求', 0, async () => {
      const session = new SearchWorkspaceSession();
      const service = new ControlledSearch();
      const current = context(1);
      const states: string[] = [];
      const publish = (result: VideoServerSearchResult): void => { states.push(result.status); };
      const first = session.search('film', () => current, publish, service);
      session.dispose(); session.activate();
      const next = session.search('film', () => current, publish, service);
      service.pending[1].complete(current.scope, 'empty'); await next;
      service.pending[0].complete(current.scope, 'success'); await first;
      expect(states.join(',')).assertEqual('loading,loading,empty');
    });
  });
}
