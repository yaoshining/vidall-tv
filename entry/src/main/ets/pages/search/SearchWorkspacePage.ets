import { titleSuggestions } from '../../services/search/SearchSuggestions';
import { SearchSession } from '../../services/search/SearchSession';
import { SearchResultSource } from './SearchResultSource';
import { SearchWorkspaceSession, SearchWorkspaceContext } from '../../services/search/SearchWorkspaceSession';
import { VideoServerSearchResult, VideoServerSearchItem } from '../../services/search/VideoServerSearchService';
import { SearchScope, SearchRouteParam, createUnavailableSearchScope, resolveSearchRoute, getSearchCapabilities } from '../../models/search/SearchScope';
import { SourceSwitchModel } from '../../stores/media/SourceSwitchModel';
import { VideoServerStore } from '../../stores/servers/VideoServerStore';
import { MediaItem, SearchHistoryEntry, SeriesGroup } from '../../db/models/MediaEntity';
import { FileSourceDatabase } from '../../db/files/FileSourceDatabase';
import { ServerMediaDetailPage, ServerMediaDetailPageParam } from '../detail/ServerMediaDetailPage';

import { SeriesDetailPage } from '../detail/SeriesDetailPage';
import { MovieDetailPage } from '../detail/MovieDetailPage';
import { KeyCode } from '@kit.InputKit';

// ─────────────────────────────────────────────────────────────────────────────
// Design Token Constants — strictly follows Pencil vidall_pages.pen
// ─────────────────────────────────────────────────────────────────────────────

const C_PAGE_BG: string = '#232425';
const C_KBD_BG: string = '#1C1E22';
const C_HIST_CHIP_BG: string = '#23272E';
const C_COMPONENT_BG: string = '#2C3138';
const C_LETTER_KEY_BG: string = '#3A3F46';
const C_BKSP_BG: string = '#565D67';
const C_CLEAR_BG: string = '#6B3339';
const C_SEL_BLUE: string = '#3B77D4';
const C_BORDER: string = '#464E58';
const C_HIST_BORDER: string = '#454C55';
const C_CLEAR_BORDER: string = '#B85A64';
const C_TEXT_TITLE: string = '#EAF3FF';
const C_TEXT_BODY: string = '#DDE4EE';
const C_KEY_TEXT: string = '#F3F6FA';
const C_PLACEHOLDER: string = '#C7CED8';
const C_SECONDARY: string = '#8E96A3';
const C_ICON: string = '#AAB4C3';
const C_HIST_TEXT: string = '#E6EDF5';
const C_CLEAR_ICON: string = '#FFD7DB';
const TRANSPARENT: string = '#00000000';

// ─────────────────────────────────────────────────────────────────────────────
// Keyboard layout arrays — row1/row2/row3, left letters + right numbers
// ─────────────────────────────────────────────────────────────────────────────

const KBD_R1_L: string[] = ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'];
const KBD_R1_R: string[] = ['1', '2', '3', '4'];
const KBD_R2_L: string[] = ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'];
const KBD_R2_R: string[] = ['5', '6', '7', '8'];
const KBD_R3_L: string[] = ['Z', 'X', 'C', 'V', 'B', 'N', 'M'];

// ─────────────────────────────────────────────────────────────────────────────
// Module-level helpers (avoid logic in build())
// ─────────────────────────────────────────────────────────────────────────────

function scoreColor(s: number): string {
  if (s >= 8.5) { return '#F7C06C'; }
  if (s >= 8.0) { return '#F6B85F'; }
  if (s >= 7.0) { return '#E6786C'; }
  return '#D0A26B';
}

function posterSrc(item: MediaItem): string {
  if (item.posterLocalPath !== undefined && item.posterLocalPath.length > 0) {
    return 'file://' + item.posterLocalPath;
  }
  if (item.posterUrl !== undefined && item.posterUrl.length > 0) {
    return item.posterUrl;
  }
  return '';
}

// ─────────────────────────────────────────────────────────────────────────────
// KeyButton — single keyboard key component
// ─────────────────────────────────────────────────────────────────────────────

@ComponentV2
struct KeyButton {
  @Param label: string = '';
  @Param kbg: string = C_LETTER_KEY_BG;
  @Event onFocused: () => void = () => {};
  @Event onPress: () => void = () => {};
  @Local isFocused: boolean = false;
  @Local isHovered: boolean = false;
  @Local isPressed: boolean = false;

  // State priority: Active > Focus > Hover > Default
  private getBgColor(): string {
    if (this.isPressed && this.isFocused) { return '#2C5C96'; }
    if (this.isPressed) { return '#202020'; }
    if (this.isFocused) { return C_SEL_BLUE; }
    if (this.isHovered) { return '#464E58'; }
    return this.kbg;
  }

  private getBorderColor(): string {
    if (this.isPressed && this.isFocused) { return '#76B6FF'; }
    if (this.isPressed) { return '#454545'; }
    if (this.isFocused) { return '#4A9FFF'; }
    if (this.isHovered) { return '#5A5A5A'; }
    return TRANSPARENT;
  }

  private getBorderWidth(): number {
    if (this.isPressed && this.isFocused) { return 1; }
    if (this.isFocused) { return 2; }
    if (this.isPressed || this.isHovered) { return 1; }
    return 0;
  }

  private getScale(): number {
    return this.isPressed ? 0.97 : 1.0;
  }

  build() {
    Text(this.label)
      .fontSize(20)
      .fontWeight(600)
      .fontColor('#FFFFFF')
      .textAlign(TextAlign.Center)
      .width('100%')
      .height(36)
      .id(`search-key-${this.label}`)
      .borderRadius(10)
      .backgroundColor(this.getBgColor())
      .border({ width: this.getBorderWidth(), color: this.getBorderColor() })
      .scale({ x: this.getScale(), y: this.getScale() })
      .animation({ duration: 100, curve: Curve.EaseOut })
      .focusable(true)
      .onFocus(() => { this.isFocused = true; this.onFocused(); })
      .onBlur(() => { this.isFocused = false; this.isHovered = false; this.isPressed = false; })
      .onHover((isHover: boolean) => { this.isHovered = isHover; })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.isPressed = true;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.isPressed = false;
        }
      })
      .onKeyEvent((event: KeyEvent) => {
        if (event.keyCode === KeyCode.KEYCODE_DPAD_CENTER || event.keyCode === KeyCode.KEYCODE_ENTER) {
          if (event.type === KeyType.Down) { this.isPressed = true; }
          else if (event.type === KeyType.Up) { this.isPressed = false; }
        }
      })
      .onClick(() => { this.onPress(); })
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ActionKey — functional key component (clear / backspace / wide keys)
// ─────────────────────────────────────────────────────────────────────────────

@ComponentV2
struct ActionKey {
  @Param label: string = '';
  @Param bgColor: string = C_LETTER_KEY_BG;
  @Param focusBgColor: string = C_SEL_BLUE;
  @Param focusPressBgColor: string = '#2C5C96';
  @Param hoverBgColor: string = '#464E58';
  @Param activeBgColor: string = '#2E3540';
  @Param keyBorderColor: string = '';
  @Param keyFocusColor: string = '#5B9BD5';
  @Param hoverBorderColor: string = '#5A5A5A';
  @Param activeBorderColor: string = '#454545';
  @Param labelColor: string = C_KEY_TEXT;
  @Param labelFontSize: number = 20;
  @Param sublabel: string = '';
  @Param sublabelFontSize: number = 16;
  @Param keyAspect: number = 112 / 60;
  @Param focusId: string = '';
  @Event onFocused: () => void = () => {};
  @Event onPress: () => void = () => {};
  @Local isFocused: boolean = false;
  @Local isHovered: boolean = false;
  @Local isPressed: boolean = false;

  // State priority: Active > Focus > Hover > Default
  private getBgColor(): string {
    if (this.isPressed && this.isFocused) { return this.focusPressBgColor; }
    if (this.isPressed) { return this.activeBgColor; }
    if (this.isFocused) { return this.focusBgColor; }
    if (this.isHovered) { return this.hoverBgColor; }
    return this.bgColor;
  }

  private getBorderColor(): string {
    if (this.isPressed && this.isFocused) { return '#76B6FF'; }
    if (this.isPressed) { return this.activeBorderColor; }
    if (this.isFocused) { return this.keyFocusColor; }
    if (this.isHovered) { return this.hoverBorderColor; }
    return this.keyBorderColor.length > 0 ? this.keyBorderColor : TRANSPARENT;
  }

  private getBorderWidth(): number {
    if (this.isPressed && this.isFocused) { return 1; }
    if (this.isFocused) { return 2; }
    if (this.isPressed || this.isHovered) { return 1; }
    return this.keyBorderColor.length > 0 ? 1 : 0;
  }

  // Wide keys (aspect > 2) use 0.98 scale to keep press feel proportional
  private getScale(): number {
    if (this.isPressed) {
      return this.keyAspect > 2 ? 0.98 : 0.97;
    }
    return 1.0;
  }

  build() {
    Row() {
      if (this.sublabel.length > 0) {
        Text() {
          Span(this.label)
            .fontSize(this.labelFontSize)
            .fontColor(this.labelColor)
            .lineHeight(24)
          Span('\u2009' + this.sublabel)
            .fontSize(this.sublabelFontSize)
            .fontColor(this.labelColor)
            .lineHeight(24)
        }
        .textAlign(TextAlign.Center)
      } else {
        Text(this.label)
          .fontSize(this.labelFontSize)
          .fontColor(this.labelColor)
          .textAlign(TextAlign.Center)
      }
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .height(36)
    .id(this.focusId)
    .borderRadius(10)
    .backgroundColor(this.getBgColor())
    .border({ width: this.getBorderWidth(), color: this.getBorderColor() })
    .scale({ x: this.getScale(), y: this.getScale() })
    .animation({ duration: 100, curve: Curve.EaseOut })
    .focusable(true)
    .onFocus(() => { this.isFocused = true; this.onFocused(); })
    .onBlur(() => { this.isFocused = false; this.isHovered = false; this.isPressed = false; })
    .onHover((isHover: boolean) => { this.isHovered = isHover; })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.isPressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.isPressed = false;
      }
    })
    .onKeyEvent((event: KeyEvent) => {
      if (event.keyCode === KeyCode.KEYCODE_DPAD_CENTER || event.keyCode === KeyCode.KEYCODE_ENTER) {
        if (event.type === KeyType.Down) { this.isPressed = true; }
        else if (event.type === KeyType.Up) { this.isPressed = false; }
      }
    })
    .onClick(() => { this.onPress(); })
  }
}

// 联想词与历史共用一行；长标题聚焦时滚动，不缩小字号。
@ComponentV2
struct SearchWordChip {
  @Param title: string = '';
  @Param focusId: string = '';
  @Param selected: boolean = false;
  @Param removable: boolean = false;
  @Event onPress: () => void = () => {};
  @Event onDelete: () => void = () => {};
  @Event onFocused: () => void = () => {};
  @Event onNavigate: (event: KeyEvent) => void = () => {};
  @Local focused: boolean = false;
  @Local deleteFocused: boolean = false;

  build() {
    Row({ space: 0 }) {
      Button({ type: ButtonType.Normal }) {
        Text(this.title)
          .fontSize(18).fontColor(C_HIST_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: this.focused || this.deleteFocused ? TextOverflow.MARQUEE : TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: this.removable ? 188 : 220 })
      }
      .id(this.focusId).height(40)
      .padding({ left: 14, right: 14 })
      .backgroundColor(this.focused ? C_SEL_BLUE : Color.Transparent)
      .borderRadius(20)
      .focusable(true)
      .onFocus(() => { this.focused = true; this.onFocused(); })
      .onBlur(() => { this.focused = false; })
      .onClick(() => this.onPress())
      if (this.removable) {
        Button('×')
          .id(this.focusId + '-delete').width(30).height(40)
          .fontSize(18).fontColor(C_HIST_TEXT)
          .backgroundColor(this.deleteFocused ? C_SEL_BLUE : Color.Transparent)
          .focusable(true)
          .onFocus(() => { this.deleteFocused = true; this.onFocused(); })
          .onBlur(() => { this.deleteFocused = false; })
          .onClick(() => this.onDelete())
      }
    }
    .height(42).borderRadius(22)
    .backgroundColor(C_HIST_CHIP_BG)
    .border({ width: this.selected || this.focused || this.deleteFocused ? 2 : 1,
      color: this.focused || this.deleteFocused ? '#4A9FFF' : this.selected ? C_TEXT_TITLE : C_HIST_BORDER })
    .onKeyEvent((event: KeyEvent) => this.onNavigate(event))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WorkspacePosterCard — shared local / server result card
// ─────────────────────────────────────────────────────────────────────────────

interface WorkspaceSearchItem {
  key: string;
  scopeKey: string;
  title: string;
  poster: string;
  label: string;
  rating?: number;
  localItem?: MediaItem;
  serverItem?: VideoServerSearchItem;
}

@ComponentV2
struct WorkspacePosterCard {
  @Require @Param item: WorkspaceSearchItem;
  @Param focusId: string = '';
  @Param cardWidth: number = 180;
  @Event onFocused: () => void = () => {};
  @Event onPress: () => void = () => {};
  @Local isFocused: boolean = false;

  build() {
    Column({ space: 8 }) {
      Stack() {
        if (this.item.poster.length > 0) {
          Image(this.item.poster)
            .width(this.cardWidth)
            .height(this.cardWidth * 1.5)
            .objectFit(ImageFit.Cover)
        } else {
          Column() {
            Text('\u{1F3AC}')
              .fontSize(36)
              .opacity(0.4)
          }
          .width(this.cardWidth)
          .height(this.cardWidth * 1.5)
          .backgroundColor(C_COMPONENT_BG)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        }
      }
      .width(this.cardWidth)
      .height(this.cardWidth * 1.5)
      .clip(true)
      .borderRadius(8)
      .border({ width: this.isFocused ? 2 : 0, color: '#FF3B77D4' })
      .shadow({
        radius: this.isFocused ? 12 : 0,
        color: this.isFocused ? '#803B77D4' : TRANSPARENT,
        offsetX: 0,
        offsetY: 0
      })
      .scale({ x: this.isFocused ? 1.04 : 1.0, y: this.isFocused ? 1.04 : 1.0 })
      .animation({ duration: 140, curve: Curve.EaseInOut })

      Text(this.item.title ?? '')
        .fontSize(18)
        .fontColor('#E3E7ED')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(this.cardWidth)

      Row() {
        Text(this.item.label).fontSize(16).fontColor(C_SECONDARY).layoutWeight(1)
        if (this.item.rating !== undefined && this.item.rating > 0) {
          Text(this.item.rating.toFixed(1)).fontSize(16).fontColor(scoreColor(this.item.rating))
        }
      }.width('100%')
    }
    .width(this.cardWidth)
    .alignItems(HorizontalAlign.Start)
    .id(this.focusId)
    .focusable(true)
    .onFocus(() => { this.isFocused = true; this.onFocused(); })
    .onBlur(() => { this.isFocused = false; })
    .onClick(() => { this.onPress(); })
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SearchWorkspacePage — main search entry page (TV vertical layout)
// ─────────────────────────────────────────────────────────────────────────────

@ComponentV2
struct SearchWorkspacePage {
  static readonly PAGE_NAME: string = 'SearchWorkspacePage';

  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();

  @Local scope: SearchScope = createUnavailableSearchScope();
  @Local searchText: string = '';
  @Local session: SearchSession<MediaItem> = new SearchSession<MediaItem>();
  private resultSource: SearchResultSource<WorkspaceSearchItem> = new SearchResultSource<WorkspaceSearchItem>();
  private resultScroller: Scroller = new Scroller();
  private focusedResult: number = 0;
  private restoreResult: boolean = false;
  @Local suggestions: string[] = [];
  @Local selectedSuggestion: string = '';
  private suggestionScroller: Scroller = new Scroller();
  private historyScroller: Scroller = new Scroller();
  private lastKeyboardKey: string = 'search-key-Z';
  private focusedHistoryIndex: number = 0;
  @Local resultViewportWidth: number = 1200;
  @Local resultViewportHeight: number = 380;
  @Local historyList: SearchHistoryEntry[] = [];
  @Local isSearching: boolean = false;
  @Local isSearchBarFocused: boolean = false;

  @Local serverResult: VideoServerSearchResult | null = null;
  private serverSession: SearchWorkspaceSession = new SearchWorkspaceSession();
  private unsubscribeSource: () => void = () => {};
  private unsubscribeConfiguration: () => void = () => {};
  private pageActive: boolean = false;
  private sourceBound: boolean = false;
  private inputController: TextInputController = new TextInputController();
  // 返回层级只记录用户主动编辑；程序获焦也可能异步上报 onEditChange(true)。
  private isEditing: boolean = false;
  private resultsFocused: boolean = false;
  private db: FileSourceDatabase | null = null;
  @Local private searchDebounceTimer: number = -1;
  // 竞态保护：快速连续输入时，丢弃旧请求的返回结果
  private historyLoadGeneration: number = 0;
  private historySourceGeneration: number = 0;

  private showToastSafe(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration: 2000 });
    } catch (e) {}
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  private initializeRoute(param: SearchRouteParam | string | null | undefined): void {
    const servers = VideoServerStore.getState().videoServers;
    const route = resolveSearchRoute(param, SourceSwitchModel.getState().getSearchScope(servers), servers);
    // 仅复用当前来源的路由关键词，旧来源的输入不得自动发往当前实例。
    this.searchText = route.scope.key === this.currentContext().scope.key ? route.keyword : '';
    this.resumeSearch();
  }

  private currentContext(): SearchWorkspaceContext {
    const servers = VideoServerStore.getState().videoServers;
    const scope = SourceSwitchModel.getState().getSearchScope(servers);
    const context: SearchWorkspaceContext = {
      scope, server: servers.find((server) => server.id === scope.serverId)
    };
    return context;
  }

  private resumeSearch(): void {
    if (this.pageActive) { return; }
    this.pageActive = true;
    this.serverSession.activate();
    this.unsubscribeSource = SourceSwitchModel.getState().subscribeSearchSource(() => this.refreshSource());
    this.unsubscribeConfiguration = VideoServerStore.getState()
      .subscribeSearchConfiguration(() => this.refreshSource());
    this.refreshSource();
  }

  private refreshSource(): void {
    this.invalidateSearch(true);
    this.invalidateHistorySource();
    const nextScope = this.currentContext().scope;
    if (this.sourceBound && this.scope.key !== nextScope.key) {
      this.searchText = '';
      this.restoreResult = false;
      this.focusedResult = 0;
      this.focusInput();
    }
    this.scope = nextScope;
    this.sourceBound = true;
    this.session.invalidate(true);
    this.resultSource.replace([]);
    this.db = null;
    if (this.scope.kind !== 'unavailable') {
      this.db = FileSourceDatabase.getInstance();
    }
    this.scheduleSearch();
    this.loadHistory();
  }

  private invalidateSearch(clear: boolean = false): void {
    this.session.invalidate(clear);
    this.serverSession.invalidate();
    this.serverResult = null;
    if (clear) {
      this.resultSource.replace([]);
      this.suggestions = [];
      this.selectedSuggestion = '';
    }
    this.isSearching = false;
    if (this.searchDebounceTimer !== -1) {
      clearTimeout(this.searchDebounceTimer);
      this.searchDebounceTimer = -1;
    }
  }

  private focusInput(): void {
    this.isEditing = false;
    this.inputController.stopEditing();
    this.resultsFocused = false;
    this.getUIContext().getFocusController().requestFocus('search-workspace-input');
  }

  private handleBack(): boolean {
    if (this.resultsFocused) {
      console.info('[SearchWorkspace] back: results -> input');
      this.focusInput();
      return true;
    }
    if (this.isEditing) {
      console.info('[SearchWorkspace] back: editing -> input');
      this.isEditing = false;
      this.inputController.stopEditing();
      return true;
    }
    console.info('[SearchWorkspace] back: leave');
    this.leaveSearch();
    this.pageStack.pop();
    return true;
  }

  private leaveSearch(): void {
    this.isEditing = false;
    this.inputController.stopEditing();
    this.resultsFocused = false;
    this.pageActive = false;
    this.invalidateSearch(true);
    this.invalidateHistorySource();
    this.serverSession.dispose();
    this.unsubscribeSource();
    this.unsubscribeConfiguration();
  }

  aboutToDisappear(): void { this.leaveSearch(); }

  // ── Data helpers ──────────────────────────────────────────────────────────

  private invalidateHistoryRequests(): void {
    this.historyLoadGeneration++;
  }

  private invalidateHistorySource(): void {
    this.focusedHistoryIndex = 0;
    this.historySourceGeneration++;
    this.invalidateHistoryRequests();
    this.historyList = [];
  }

  private loadHistory(): void {
    if (this.scope.kind === 'unavailable' || this.db === null) { return; }
    const sourceGeneration = this.historySourceGeneration;
    const loadGeneration = ++this.historyLoadGeneration;
    this.db.getSearchHistory(this.scope.key, 20)
      .then((list: SearchHistoryEntry[]) => {
        if (this.pageActive && sourceGeneration === this.historySourceGeneration &&
          loadGeneration === this.historyLoadGeneration &&
          this.scope.kind !== 'unavailable') { this.historyList = list; }
      })
      .catch(() => {});
  }


  private scheduleSearch(): void {
    this.invalidateSearch(this.scope.kind === 'localFiles' || this.searchText.trim().length === 0);
    if (!this.pageActive || this.searchText.trim().length === 0) { return; }
    const capabilities = getSearchCapabilities(this.scope);
    if (!capabilities.localSearch && !capabilities.serverSearch) { return; }
    if (capabilities.localSearch) { this.session.prepare(); }
    this.isSearching = true;
    this.searchDebounceTimer = setTimeout(() => {
      this.searchDebounceTimer = -1;
      if (getSearchCapabilities(this.scope).serverSearch) {
        this.executeServerSearch();
      } else {
        this.executeSearch();
      }
    }, capabilities.localSearch ? 250 : 800);
  }

  private executeServerSearch(): void {
    this.invalidateSearch();
    this.serverSession.search(this.searchText, () => this.currentContext(),
      (result: VideoServerSearchResult) => {
        this.serverResult = result;
        this.isSearching = result.status === 'loading';
        if (result.status === 'success' || result.status === 'empty') { this.updateResultSource(); }
      });
  }

  private serverErrorText(): string {
    switch (this.serverResult?.errorCode) {
      case 'auth': return '服务器认证失败，请检查来源配置后重试';
      case 'timeout': return '搜索超时，请重试';
      case 'invalidResponse': return '服务器响应无效，请重试';
      case 'unavailable': return '来源不可用，请返回重新选择来源';
      default: return '无法连接服务器，请检查网络后重试';
    }
  }

  private resultStatus(): string {
    if (!this.pageActive || this.searchText.trim().length === 0) { return 'idle'; }
    if (getSearchCapabilities(this.scope).localSearch) {
      return this.session.status === 'results' ? 'success' : this.session.status;
    }
    if (this.isSearching) { return 'loading'; }
    return this.serverResult?.status ?? 'idle';
  }

  private resultErrorText(): string {
    return getSearchCapabilities(this.scope).localSearch
      ? '本地搜索失败，请重试' : this.serverErrorText();
  }

  private retrySearch(): void {
    if (!this.pageActive || this.resultStatus() !== 'error') { return; }
    this.invalidateSearch();
    if (getSearchCapabilities(this.scope).localSearch) {
      this.executeSearch(this.selectedSuggestion || this.searchText.trim(), this.selectedSuggestion.length === 0);
    } else if (getSearchCapabilities(this.scope).serverSearch) {
      this.executeServerSearch();
    }
  }

  /** 本地联想搜索：自动选中首项时保存片名历史，不跳转。 */
  private async executeSearch(keyword: string = this.searchText.trim(), suggest: boolean = true): Promise<void> {
    if (!getSearchCapabilities(this.scope).localSearch || this.db === null || !this.pageActive) { return; }
    const kw: string = keyword;
    if (kw.length === 0) {
      this.invalidateSearch(true);
      return;
    }
    this.invalidateSearch();
    const accepted = await this.session.run(async (): Promise<MediaItem[]> => {
      if (this.db === null) { throw new Error('搜索数据库尚未就绪'); }
      const items = await this.db.searchMediaItems(kw, { limit: 200 }, true);
      const seen: Set<string> = new Set<string>();
      return items.filter((item: MediaItem) => {
        const key = item.tvSeriesId !== undefined ? `tv-${item.tvSeriesId}` :
          item.movieId !== undefined ? `mv-${item.movieId}` : `v-${item.id}`;
        if (seen.has(key)) { return false; }
        seen.add(key);
        return true;
      });
    });
    if (!accepted) { return; }
    if (suggest) {
      this.suggestions = titleSuggestions(this.scope, this.session.results);
      this.selectedSuggestion = this.suggestions[0] ?? '';
      if (this.selectedSuggestion.length > 0) {
        this.saveSearchHistory(this.selectedSuggestion);
        await this.executeSearch(this.selectedSuggestion, false);
        return;
      }
    }
    this.updateResultSource();
  }

  /** 执行搜索并保存历史 */
  private executeSearchWithHistory(): void {
    if (this.scope.kind === 'unavailable') { return; }
    if (this.scope.kind === 'localFiles' && this.selectedSuggestion.length > 0) {
      this.selectSuggestion(this.selectedSuggestion);
      return;
    }
    const kw: string = this.searchText.trim();
    if (kw.length === 0) { return; }
    this.saveSearchHistory(kw);
    if (getSearchCapabilities(this.scope).serverSearch) {
      this.executeServerSearch();
    } else {
      this.executeSearch();
    }
  }

  private selectSuggestion(title: string): void {
    if (!this.pageActive || this.scope.kind !== 'localFiles' || !this.suggestions.includes(title)) { return; }
    this.selectedSuggestion = title;
    this.saveSearchHistory(title);
    this.executeSearch(title, false);
  }

  private saveSearchHistory(kw: string): void {
    if (this.scope.kind === 'unavailable' || !this.pageActive) { return; }
    if (this.db !== null) {
      this.invalidateHistoryRequests();
      const sourceGeneration = this.historySourceGeneration;
      const updateGeneration = this.historyLoadGeneration;
      this.db.upsertSearchHistory(this.scope.key, kw)
        .then(() => {
          if (this.pageActive && sourceGeneration === this.historySourceGeneration &&
            updateGeneration === this.historyLoadGeneration) {
            this.loadHistory();
          }
        })
        .catch(() => {});
    }
  }

  private appendChar(c: string): void {
    this.searchText += c;
    this.scheduleSearch();
  }

  private deleteLastChar(): void {
    if (this.searchText.length > 0) {
      this.searchText = this.searchText.slice(0, -1);
      this.scheduleSearch();
    }
  }

  private clearSearch(): void {
    this.searchText = '';
    this.focusInput();
    this.session.invalidate(true);
    this.resultSource.replace([]);
    this.scheduleSearch();
  }

  private deleteHistory(keyword: string): void {
    if (this.scope.kind === 'unavailable' || this.db === null) { return; }
    this.invalidateHistoryRequests();
    const sourceGeneration = this.historySourceGeneration;
    const deleteGeneration = this.historyLoadGeneration;
    this.db.deleteSearchHistory(this.scope.key, keyword)
      .then(() => {
        if (this.pageActive && sourceGeneration === this.historySourceGeneration &&
          deleteGeneration === this.historyLoadGeneration) {
          this.loadHistory();
        }
      })
      .catch(() => {});
  }

  private clearAllHistory(): void {
    if (this.scope.kind === 'unavailable' || this.db === null) { return; }
    this.invalidateHistoryRequests();
    const sourceGeneration = this.historySourceGeneration;
    const clearGeneration = this.historyLoadGeneration;
    this.db.clearSearchHistory(this.scope.key)
      .then(() => {
        if (this.pageActive && sourceGeneration === this.historySourceGeneration &&
          clearGeneration === this.historyLoadGeneration &&
          this.scope.kind !== 'unavailable') {
          this.historyList = [];
        }
      })
      .catch(() => {});
  }

  private navigateToDetail(item: MediaItem): void {
    if (!getSearchCapabilities(this.scope).localDetail) { return; }
    this.restoreResult = true;
    item.searchScope = this.scope;
    if (item.tvSeriesId !== undefined) {
      const group: SeriesGroup = {
        searchScope: this.scope,
        title: item.title ?? '',
        tvSeriesId: item.tvSeriesId,
        posterUrl: item.posterUrl,
        posterLocalPath: item.posterLocalPath,
        backdropUrl: item.backdropUrl,
        rating: item.rating,
        episodeCount: 0,
        episodes: [item],
        latestScannedAt: item.scannedAt ?? 0,
      };
      this.pageStack.pushPathByName(SeriesDetailPage.PAGE_NAME, group);
    } else {
      this.pageStack.pushPathByName(MovieDetailPage.PAGE_NAME, item);
    }
  }

  private openServerResultDetail(item: VideoServerSearchItem): void {
    const context = this.currentContext();
    if (!item.sourceSnapshot.matches(context.scope, context.server)) {
      if (context.scope.kind !== 'videoServer' || context.server === undefined ||
        context.scope.serverId !== item.selection.serverId || context.scope.serverType !== item.selection.serverType) {
        this.showToastSafe('当前来源已变化，请返回重新选择来源');
      } else {
        this.showToastSafe('当前服务器配置已变更，请重新搜索');
      }
      this.refreshSource();
      return;
    }
    const param: ServerMediaDetailPageParam = {
      serverId: item.selection.serverId,
      serverType: item.selection.serverType,
      mediaId: item.selection.mediaId,
      mediaType: item.selection.mediaType,
      itemId: item.selection.detailItemId,
      title: item.media.title
    };
    this.restoreResult = true;
    this.pageStack.pushPathByName(ServerMediaDetailPage.PAGE_NAME, param);
  }

  private historyVisible(): boolean {
    return this.historyList.length > 0 && (this.scope.kind !== 'localFiles' || this.searchText.trim().length === 0);
  }

  private rememberKeyboardKey(id: string): void {
    this.lastKeyboardKey = id;
    this.resultsFocused = false;
  }

  private focusKeyboard(): void {
    if (getSearchCapabilities(this.scope).localSearch) {
      this.resultsFocused = false;
      this.getUIContext().getFocusController().requestFocus(this.lastKeyboardKey);
    } else {
      this.focusInput();
    }
  }

  private focusWordRow(fromKeyboard: boolean = false): void {
    if (this.scope.kind === 'localFiles' && this.suggestions.length > 0) {
      const index = Math.max(0, this.suggestions.indexOf(this.selectedSuggestion));
      this.suggestionScroller.scrollToIndex(index);
      this.getUIContext().getFocusController().requestFocus(`search-suggestion-${index}`);
    } else if (this.historyVisible()) {
      const index = Math.min(this.focusedHistoryIndex, this.historyList.length);
      this.historyScroller.scrollToIndex(index);
      this.getUIContext().getFocusController().requestFocus(index === 0 ? 'search-history-clear' : `search-history-${index - 1}`);
    } else if (fromKeyboard && this.resultSource.totalCount() > 0) {
      this.focusResults();
    } else if (fromKeyboard) {
      this.focusInput();
    } else {
      this.focusKeyboard();
    }
  }

  private handleKeyboardNavigation(event: KeyEvent): void {
    if (event.type !== KeyType.Down) { return; }
    const bottomKeys: string[] = ['Z', 'X', 'C', 'V', 'B', 'N', 'M', '9', '0', 'backspace'];
    if (event.keyCode === KeyCode.KEYCODE_DPAD_DOWN &&
      bottomKeys.some((key: string) => this.lastKeyboardKey === `search-key-${key}`)) {
      this.focusWordRow(true);
      event.stopPropagation();
    }
  }

  private handleWordNavigation(event: KeyEvent): void {
    if (event.type !== KeyType.Down) { return; }
    if (event.keyCode === KeyCode.KEYCODE_DPAD_UP) {
      this.focusKeyboard();
      event.stopPropagation();
    } else if (event.keyCode === KeyCode.KEYCODE_DPAD_DOWN && this.resultSource.totalCount() > 0) {
      this.focusResults();
      event.stopPropagation();
    }
  }

  private posterWidth(): number {
    // 为焦点外框、标题和元数据预留空间，首排不被底部裁切。
    return Math.max(60, Math.min((this.resultViewportWidth - 96) / 6, (this.resultViewportHeight - 76) / 1.5));
  }

  // ── @Builder sections ─────────────────────────────────────────────────────

  @Builder
  buildBackRow() {
    Button('‹')
      .fontSize(26).fontColor(C_TEXT_BODY)
      .width(40).height(40).borderRadius(20)
      .backgroundColor(C_COMPONENT_BG)
      .focusable(true)
      .onClick(() => { this.leaveSearch(); this.pageStack.pop(); })
  }

  @Builder
  buildSearchBar() {
    Row({ space: 12 }) {
      Text('\uD83D\uDD0D')
        .fontSize(22)
        .fontColor(C_ICON)
        .width(22)
        .height(22)
      TextInput({ text: this.searchText, placeholder: this.scope.kind === 'localFiles' ? '首字母 / 全拼 / 中文' : '输入片名，如 Dune', controller: this.inputController })
        .id('search-workspace-input')
        .enableKeyboardOnFocus(false)
        .enterKeyType(EnterKeyType.Search)
        .fontSize(20)
        .fontColor(C_TEXT_TITLE)
        .placeholderColor(C_PLACEHOLDER)
        .backgroundColor(C_COMPONENT_BG)
        .height(44)
        .borderRadius(10)
        .layoutWeight(1)
        .defaultFocus(true)
        .onEditChange((editing: boolean) => {
          console.info(`[SearchWorkspace] edit callback=${editing}, userEditing=${this.isEditing}`);
          // true 也可能来自 requestFocus / IME 延迟绑定，不能据此新增返回层级。
          if (!editing) { this.isEditing = false; }
        })
        .onClick(() => { this.isEditing = true; })
        .onKeyEvent((event: KeyEvent) => {
          if (event.type === KeyType.Down &&
            (event.keyCode === KeyCode.KEYCODE_DPAD_CENTER || event.keyCode === KeyCode.KEYCODE_ENTER)) {
            this.isEditing = true;
          }
        })
        .onBlur(() => { this.isEditing = false; })
        .onFocus(() => { this.resultsFocused = false; })
        .onChange((value: string) => {
          this.isEditing = true;
          this.searchText = value;
          this.scheduleSearch();
        })
        .onSubmit(() => {
          this.inputController.stopEditing();
          this.isEditing = false;
          this.executeSearchWithHistory();
        })
      if (this.scope.kind !== 'unavailable') {
        ActionKey({
          label: '搜索',
          onPress: () => {
            this.inputController.stopEditing();
            this.isEditing = false;
            this.executeSearchWithHistory();
          }
        })
          .id('search-workspace-submit')
          .width(72)
        ActionKey({
          label: '清空',
          bgColor: C_CLEAR_BG,
          keyBorderColor: C_CLEAR_BORDER,
          labelColor: C_CLEAR_ICON,
          onPress: () => { this.clearSearch(); }
        })
          .id('search-workspace-clear')
          .width(72)
      }
    }
    .layoutWeight(1)
    .height(48)
    .alignItems(VerticalAlign.Center)
    .onFocus(() => { this.isSearchBarFocused = true; })
    .onBlur(() => { this.isSearchBarFocused = false; })
  }

  @Builder
  buildAlphabetKbd() {
    Grid() {
      ForEach(KBD_R1_L, (key: string) => {
        GridItem() {
          KeyButton({ label: key, onFocused: () => this.rememberKeyboardKey(`search-key-${key}`),
            onPress: () => { this.appendChar(key); } })
        }
      }, (key: string) => key)

      ForEach(KBD_R2_L, (key: string) => {
        GridItem() {
          KeyButton({ label: key, onFocused: () => this.rememberKeyboardKey(`search-key-${key}`),
            onPress: () => { this.appendChar(key); } })
        }
      }, (key: string) => key)

      GridItem() {
        ActionKey({
          label: '清空',
          focusId: 'search-key-clear',
          onFocused: () => this.rememberKeyboardKey('search-key-clear'),
          bgColor: '#3A2525',
          focusBgColor: '#356DAE',
          focusPressBgColor: '#2C5C96',
          hoverBgColor: '#4A2F2F',
          activeBgColor: '#2E1E1E',
          keyBorderColor: '#E06070',
          keyFocusColor: '#4A9FFF',
          hoverBorderColor: '#F07B89',
          activeBorderColor: '#C95463',
          labelColor: C_CLEAR_ICON,
          labelFontSize: 22,
          onPress: () => { this.clearSearch(); }
        })
      }

      ForEach(KBD_R3_L, (key: string) => {
        GridItem() {
          KeyButton({ label: key, onFocused: () => this.rememberKeyboardKey(`search-key-${key}`),
            onPress: () => { this.appendChar(key); } })
        }
      }, (key: string) => key)

      GridItem() {
        ActionKey({
          label: '\u232B',
          sublabel: '退格',
          focusId: 'search-key-backspace',
          onFocused: () => this.rememberKeyboardKey('search-key-backspace'),
          keyAspect: 352 / 60,
          onPress: () => { this.deleteLastChar(); }
        })
      }
      .columnStart(7)
      .columnEnd(9)
    }
    .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr')
    .columnsGap(8)
    .rowsGap(8)
    .rowsTemplate('1fr 1fr 1fr')
    .height(124).layoutWeight(10)
  }

  @Builder
  buildNumericKbd() {
    Grid() {
      ForEach([...KBD_R1_R, ...KBD_R2_R], (key: string) => {
        GridItem() {
          KeyButton({ label: key, onFocused: () => this.rememberKeyboardKey(`search-key-${key}`),
            onPress: () => { this.appendChar(key); } })
        }
      })

      GridItem() {
        KeyButton({ label: '9', onFocused: () => this.rememberKeyboardKey('search-key-9'), onPress: () => { this.appendChar('9'); } })
      }

      GridItem() {
        ActionKey({
          label: '0',
          focusId: 'search-key-0',
          onFocused: () => this.rememberKeyboardKey('search-key-0'),
          keyAspect: 352 / 60,
          onPress: () => { this.appendChar('0'); }
        })
      }
      .columnStart(1)
      .columnEnd(3)
    }
    .columnsTemplate('1fr 1fr 1fr 1fr')
    .columnsGap(8)
    .rowsGap(8)
    .rowsTemplate('1fr 1fr 1fr')
    .height(124).layoutWeight(4)
  }

  @Builder
  buildKeyboard() {
    Row({ space: 24 }) {
      this.buildAlphabetKbd()
      this.buildNumericKbd()
    }
    .width('100%').height(124)
    .onKeyEvent((event: KeyEvent) => this.handleKeyboardNavigation(event))
  }

  @Builder
  buildSuggestions() {
    if (this.scope.kind === 'localFiles' && this.suggestions.length > 0) {
      Row({ space: 8 }) {
        List({ space: 8, scroller: this.suggestionScroller }) {
          ForEach(this.suggestions, (title: string, index: number) => {
            ListItem() {
              SearchWordChip({ title, focusId: `search-suggestion-${index}`,
                selected: this.selectedSuggestion === title,
                onFocused: () => {
                  this.resultsFocused = true;
                  this.suggestionScroller.scrollToIndex(index);
                },
                onPress: () => this.selectSuggestion(title),
                onNavigate: (event: KeyEvent) => this.handleWordNavigation(event)
              })
            }
          }, (title: string) => title)
        }
        .listDirection(Axis.Horizontal).height(48).layoutWeight(1)
        .scrollBar(BarState.Off)
        if (this.suggestions.length > 6) { Text('›').fontSize(24).fontColor(C_SECONDARY) }
      }.width('100%').height(48)
    }
  }

  @Builder
  buildHistory() {
    if (this.historyVisible()) {
      Row({ space: 8 }) {
        List({ space: 8, scroller: this.historyScroller }) {
          ListItem() {
            SearchWordChip({ title: '清空当前来源历史', focusId: 'search-history-clear',
              onFocused: () => { this.resultsFocused = true; this.focusedHistoryIndex = 0; this.historyScroller.scrollToIndex(0); },
              onPress: () => { this.clearAllHistory(); this.focusKeyboard(); },
              onNavigate: (event: KeyEvent) => this.handleWordNavigation(event)
            })
          }
          ForEach(this.historyList, (entry: SearchHistoryEntry, index: number) => {
            ListItem() {
              SearchWordChip({ title: entry.keyword, focusId: `search-history-${index}`, removable: true,
                onFocused: () => {
                  this.resultsFocused = true;
                  this.focusedHistoryIndex = index + 1;
                  this.historyScroller.scrollToIndex(index + 1);
                },
                onPress: () => {
                  this.suggestions = [];
                  this.selectedSuggestion = '';
                  this.searchText = entry.keyword;
                  this.focusInput();
                  this.executeSearchWithHistory();
                },
                onDelete: () => { this.deleteHistory(entry.keyword); this.focusKeyboard(); },
                onNavigate: (event: KeyEvent) => this.handleWordNavigation(event)
              })
            }
          }, (entry: SearchHistoryEntry) => entry.keyword)
        }
        .listDirection(Axis.Horizontal).height(48).layoutWeight(1)
        .scrollBar(BarState.Off)
        if (this.historyList.length > 5) { Text('›').fontSize(24).fontColor(C_SECONDARY) }
      }.width('100%').height(48)
    }
  }

  private resultItems(): WorkspaceSearchItem[] {
    if (getSearchCapabilities(this.scope).localSearch) {
      return this.session.results.map((item: MediaItem): WorkspaceSearchItem => {
        const result: WorkspaceSearchItem = {
          key: `${this.scope.key}:${item.id}`, scopeKey: this.scope.key,
          title: item.title ?? '', poster: posterSrc(item), rating: item.rating,
          label: item.tvSeriesId !== undefined ? '剧集' : '电影', localItem: item
        };
        return result;
      });
    }
    return (this.serverResult?.items ?? []).map((item: VideoServerSearchItem): WorkspaceSearchItem => {
      const result: WorkspaceSearchItem = {
        key: item.key, scopeKey: item.scopeKey, title: item.media.title, poster: item.media.posterUrl,
        label: item.selection.mediaType === 'movie' ? '电影' : item.selection.mediaType === 'series' ? '剧集' : '单集',
        serverItem: item
      };
      return result;
    });
  }

  private openResult(item: WorkspaceSearchItem): void {
    if (!this.pageActive || item.scopeKey !== this.currentContext().scope.key) { return; }
    if (item.serverItem !== undefined) {
      this.openServerResultDetail(item.serverItem);
    } else if (item.localItem !== undefined) {
      this.navigateToDetail(item.localItem);
    }
  }

  private updateResultSource(): void {
    this.resultSource.replace(this.resultItems());
    if (this.restoreResult && this.resultSource.totalCount() > 0) {
      this.restoreResult = false;
      this.focusResults();
    }
  }

  private focusResults(): void {
    if (this.resultSource.totalCount() === 0) { return; }
    this.isEditing = false;
    this.inputController.stopEditing();
    this.resultsFocused = true;
    this.focusedResult = Math.min(this.focusedResult, this.resultSource.totalCount() - 1);
    this.resultScroller.scrollToIndex(this.focusedResult);
    this.getUIContext().getFocusController().requestFocus(`search-workspace-result-${this.focusedResult}`);
  }

  @Builder
  buildResultList() {
    Row({ space: 12 }) {
      Text(this.selectedSuggestion || '搜索结果').fontSize(22).fontColor(C_TEXT_TITLE)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      Text(getSearchCapabilities(this.scope).serverSearch ? '首批最多 100 项' : '最多 200 项')
        .fontSize(14).fontColor(C_SECONDARY)
    }.height(30).width('100%')
    Grid(this.resultScroller) {
      LazyForEach(this.resultSource, (item: WorkspaceSearchItem, index: number) => {
        GridItem() {
          WorkspacePosterCard({
            item: item,
            cardWidth: this.posterWidth(),
            focusId: `search-workspace-result-${index}`,
            onFocused: () => { this.focusedResult = index; this.resultsFocused = true; },
            onPress: () => { this.openResult(item); }
          })
        }
        .onKeyEvent((event: KeyEvent) => {
          if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_DPAD_UP && index < 6) {
            this.focusWordRow();
            event.stopPropagation();
          }
        })
      }, (item: WorkspaceSearchItem) => item.key)
    }
    .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr')
    .columnsGap(16).rowsGap(16).cachedCount(2)
    .padding(8)
    .width('100%').layoutWeight(1)
    .onAreaChange((_old: Area, area: Area) => {
      this.resultViewportWidth = Number(area.width);
      this.resultViewportHeight = Number(area.height);
    })
  }

  @Builder
  buildSearchResults() {
    Column({ space: 8 }) {
      if (this.resultStatus() === 'loading' || this.resultStatus() === 'refreshing') {
        Text(this.resultSource.totalCount() > 0 ? '正在更新，以下为上次结果…' : '正在搜索…').fontSize(22).fontColor(C_TEXT_BODY)
      } else if (this.resultStatus() === 'error') {
        Text(this.resultErrorText()).fontSize(22).fontColor(C_TEXT_BODY)
        Row() {
          ActionKey({ label: '重试', keyAspect: 3, onPress: () => this.retrySearch() })
        }.width(180)
      } else if (this.resultStatus() === 'empty') {
        Text(getSearchCapabilities(this.scope).localSearch
          ? '本地媒体库未找到匹配内容' : '当前服务器未找到匹配内容')
          .fontSize(22).fontColor(C_TEXT_BODY)
      } else if (this.resultStatus() === 'idle') {
        Text(getSearchCapabilities(this.scope).localSearch
          ? '输入片名搜索本地媒体库' : '输入片名搜索当前服务器')
          .fontSize(22).fontColor(C_SECONDARY)
      }
      if (this.resultSource.totalCount() > 0) { this.buildResultList() }
    }
    .width('100%').layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    NavDestination() {
      Column({ space: 12 }) {
        Row({ space: 12 }) {
          this.buildBackRow()
          Text('搜索').fontSize(26).fontWeight(700).fontColor(C_TEXT_TITLE)
          Text(this.scope.label).fontSize(16).fontColor(C_TEXT_BODY)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 160 })
          if (getSearchCapabilities(this.scope).inputModes.length > 0) {
            this.buildSearchBar()
          }
        }.width('100%').height(48)
        if (getSearchCapabilities(this.scope).inputModes.length > 0) {
          if (getSearchCapabilities(this.scope).inputModes.includes('pinyin')) {
            this.buildKeyboard()
          }
          this.buildHistory()
          this.buildSuggestions()
          this.buildSearchResults()
        } else {
          Text(getSearchCapabilities(this.scope).hint).fontSize(18).fontColor(C_SECONDARY)
        }
      }
      .width('100%').height('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 24, right: 24, top: 16, bottom: 16 })
      .backgroundColor(C_PAGE_BG)
    }
    .onReady((context: NavDestinationContext) => {
      this.initializeRoute(context.pathInfo.param as SearchRouteParam | string | null | undefined);
    })
    .onShown(() => { this.resumeSearch(); this.focusInput(); })
    .onWillHide(() => { this.leaveSearch(); })
    .hideTitleBar(true)
    .onBackPressed(() => {
      return this.handleBack();
    })
  }
}

export { SearchWorkspacePage };
