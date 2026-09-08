import { VideoServer } from '../../db/models/VideoServerEntity';
import { SearchScope } from '../../models/search/SearchScope';
import { VideoServerSearchResult, VideoServerSearchService } from './VideoServerSearchService';

export interface SearchWorkspaceContext {
  scope: SearchScope;
  server?: VideoServer;
}

/** Private value snapshots are never used as display keys or logged. */
class SearchRequestIdentity {
  readonly scopeKey: string;
  readonly serverId: number | undefined;
  readonly serverType: string;
  private readonly configuration: string;

  constructor(context: SearchWorkspaceContext) {
    this.scopeKey = context.scope.key;
    this.serverId = context.server?.id;
    this.serverType = context.server?.type ?? '';
    this.configuration = context.server?.configJson ?? '';
  }

  matches(context: SearchWorkspaceContext): boolean {
    return this.scopeKey === context.scope.key && this.serverId === context.server?.id &&
      this.serverType === (context.server?.type ?? '') &&
      this.configuration === (context.server?.configJson ?? '');
  }
}

export class SearchWorkspaceSession {
  private generation: number = 0;
  private active: boolean = true;

  invalidate(): void { this.generation++; }
  activate(): void { this.invalidate(); this.active = true; }
  dispose(): void { this.invalidate(); this.active = false; }

  async search(keyword: string, current: () => SearchWorkspaceContext,
    publish: (result: VideoServerSearchResult) => void,
    service: VideoServerSearchService = new VideoServerSearchService()): Promise<void> {
    const generation = ++this.generation;
    const context = current();
    if (!this.active || keyword.trim().length === 0 || context.scope.kind !== 'videoServer' ||
      context.server === undefined) { return; }
    const identity = new SearchRequestIdentity(context);
    const server: VideoServer = {
      id: context.server.id, type: context.server.type, name: context.server.name,
      configJson: context.server.configJson, createdAt: context.server.createdAt
    };
    const scope: SearchScope = {
      kind: context.scope.kind, key: context.scope.key, label: context.scope.label,
      serverId: context.scope.serverId, serverType: context.scope.serverType
    };
    publish(service.createLoadingState(scope, server, keyword));
    let result: VideoServerSearchResult;
    try {
      result = await service.search(scope, server, keyword);
    } catch {
      result = { status: 'error', scopeKey: scope.key, keyword: keyword.trim(), items: [], errorCode: 'network' };
    }
    if (this.active && generation === this.generation && identity.matches(current())) {
      publish(result);
    }
  }
}
