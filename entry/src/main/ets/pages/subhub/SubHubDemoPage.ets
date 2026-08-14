import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import {
  SubHubClient,
  SubHubSearchResult,
  SubHubSearchOutcome,
  SubHubDownloadResult,
  SubHubApiError,
  SubHubNetworkError
} from '../../lib/SubHubClient';
import { AppEnv } from '../../config/AppEnv';
import { AppPreferences, PrefKey } from '../../utils/AppPreferences';

/**
 * SubHub 字幕网关演示页。
 *
 * 提供两个独立演示入口，验证统一字幕出口 API：
 *   - 演示一「字幕搜索」：GET /api/subtitles/search
 *   - 演示二「字幕下载」：GET /api/subtitles/download
 *
 * 参考：https://subhub.softeehub.com/docs/api
 */
@ComponentV2
export struct SubHubDemoPage {
  static readonly PAGE_NAME: string = 'SubHubDemoPage';
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();

  // ── 配置 ──
  @Local baseUrl: string = AppEnv.SUBHUB_BASE_URL;
  @Local callerKey: string = AppEnv.SUBHUB_API_KEY;

  // ── 演示一：搜索 ──
  @Local searchTitle: string = '流浪地球';
  @Local searchLanguage: string = 'zh-CN';
  @Local searchYear: string = '';
  @Local searchResults: SubHubSearchResult[] = [];
  @Local searchStatus: string = '';
  @Local searchProviderFailures: string = '';
  @Local isSearching: boolean = false;

  // ── 演示二：下载 ──
  @Local downloadSubtitleId: string = 'opensubtitles:provider_TZ3ViU1INs9hTFLjonEjZg:4977833';
  @Local downloadFallbackName: string = 'The.Wandering.Earth.2019.zh-CN.srt';
  @Local downloadResult: string = '';
  @Local downloadPreview: string = '';
  @Local isDownloading: boolean = false;

  /** 页面滚动控制器（用于下载后自动滚到结果区）。 */
  private scroller: Scroller = new Scroller();

  private buildClient(): SubHubClient {
    const base = this.baseUrl.trim().length > 0 ? this.baseUrl.trim() : AppEnv.SUBHUB_BASE_URL;
    return new SubHubClient(base, this.callerKey.trim());
  }

  private loadConfig(): void {
    AppPreferences.get(PrefKey.SUBHUB_DEMO_CALLER_KEY, '').then((value: string) => {
      this.callerKey = value.length > 0 ? value : AppEnv.SUBHUB_API_KEY;
    }).catch(() => {});
  }

  private updateBaseUrl(value: string): void {
    // base URL 仅本次会话生效，不持久化；默认固定为线上 SubHub 地址。
    this.baseUrl = value;
  }

  private persistCallerKey(value: string): void {
    this.callerKey = value;
    AppPreferences.set(PrefKey.SUBHUB_DEMO_CALLER_KEY, value).catch(() => {});
  }

  // ── 演示一：搜索 ──
  private async runSearch(): Promise<void> {
    const title = this.searchTitle.trim();
    if (title.length === 0) {
      this.searchStatus = '请先输入标题（title 为必填参数）。';
      return;
    }
    this.isSearching = true;
    this.searchStatus = '搜索中…';
    this.searchResults = [];
    this.searchProviderFailures = '';
    try {
      const client = this.buildClient();
      const outcome: SubHubSearchOutcome = await client.search({
        title: title,
        // xunlei provider 的 adapter 要求 query（映射为上游 name），
        // 缺省时会把 xunlei 记为 skipped_missing_fields（不计入错误）。
        // demo 中让 query 与 title 同值，保证两个 provider 都能出结果。
        query: title,
        language: this.searchLanguage.trim().length > 0 ? this.searchLanguage.trim() : undefined,
        year: this.parseYear(this.searchYear)
      });
      this.searchResults = outcome.results;
      this.searchStatus = `搜索成功：status=${outcome.status}，共 ${outcome.results.length} 条结果。`;
      if (outcome.providerFailures.length > 0) {
        this.searchProviderFailures = outcome.providerFailures.map(
          (f) => `${f.provider}:${f.reason} ${f.message ?? ''}`
        ).join('；');
      }
    } catch (e) {
      this.searchStatus = this.describeError(e as object);
    } finally {
      this.isSearching = false;
    }
  }

  private parseYear(raw: string): number | undefined {
    const trimmed = raw.trim();
    if (trimmed.length === 0) {
      return undefined;
    }
    const n = Number(trimmed);
    if (Number.isNaN(n) || n < 1800 || n > 3000) {
      return undefined;
    }
    return n;
  }

  // ── 演示二：下载 ──
  private selectForDownload(result: SubHubSearchResult): void {
    this.downloadSubtitleId = result.id;
    const base = result.releaseName ?? 'subtitle';
    const ext = result.format.length > 0 ? result.format : 'srt';
    this.downloadFallbackName = `${base}.${ext}`;
    this.downloadResult = '';
    this.downloadPreview = '';
  }

  /** 搜索结果里的「下载」按钮：选中并立即下载，然后滚到结果区展示。 */
  private downloadFromResult(item: SubHubSearchResult): void {
    this.selectForDownload(item);
    this.showToast('已选中字幕，开始下载…');
    this.scroller.scrollEdge(Edge.Bottom);
    this.runDownload().catch(() => {});
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch {
      console.warn(`[SubHubDemo] toast failed: ${message}`);
    }
  }

  private async runDownload(): Promise<void> {
    const subtitleId = this.downloadSubtitleId.trim();
    if (subtitleId.length === 0) {
      this.downloadResult = '请先输入 subtitleId（可先在“演示一”中搜索并点击“下载”自动填入）。';
      return;
    }
    this.isDownloading = true;
    this.downloadResult = '下载中…';
    this.downloadPreview = '';
    try {
      const client = this.buildClient();
      const fallback = this.downloadFallbackName.trim().length > 0
        ? this.downloadFallbackName.trim()
        : 'subtitle.srt';
      const result: SubHubDownloadResult = await client.download(subtitleId, fallback);
      const localPath = this.saveToLocal(result.content, result.fileName);
      this.downloadResult = `下载成功：${result.fileName}（mime=${result.mime}）\n已保存到：${localPath}\n大小：${result.content.byteLength} 字节`;
      this.downloadPreview = this.decodePreview(result.content);
      this.showToast(`下载成功：${result.fileName}`);
    } catch (e) {
      this.downloadResult = this.describeError(e as object);
      this.showToast('下载失败，详见下方结果');
    } finally {
      this.isDownloading = false;
    }
  }

  private saveToLocal(content: ArrayBuffer, fileName: string): string {
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const dir = `${hostCtx.filesDir}/subhub_demo`;
    try {
      fs.mkdirSync(dir, true);
    } catch {
      // 目录已存在时忽略
    }
    const safeName = fileName.replace(/[\\/:*?"<>|]/g, '_');
    const localPath = `${dir}/${safeName}`;
    try {
      const file = fs.openSync(localPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, content);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      const be = e as BusinessError;
      throw new Error(`字幕写入本地失败: ${be.message ?? JSON.stringify(e)}`);
    }
    return localPath;
  }

  private decodePreview(content: ArrayBuffer): string {
    try {
      const decoder = new util.TextDecoder('utf-8', { fatal: false, ignoreBOM: true });
      const text = decoder.decodeToString(new Uint8Array(content));
      return text.length > 800 ? text.substring(0, 800) + '\n…（已截断）' : text;
    } catch {
      return '（无法以 UTF-8 预览内容）';
    }
  }

  private describeError(e: object): string {
    if (e instanceof SubHubApiError) {
      const apiErr = e as SubHubApiError;
      return `接口错误：HTTP ${apiErr.statusCode} code=${apiErr.code} message=${apiErr.message}`;
    }
    if (e instanceof SubHubNetworkError) {
      const netErr = e as SubHubNetworkError;
      return `网络错误：${netErr.message}`;
    }
    const be = e as BusinessError;
    return `未知错误：${be.message ?? JSON.stringify(e)}`;
  }

  // ── UI 构建器 ──

  @Builder
  SectionTitle(text: string) {
    Text(text)
      .fontSize(20)
      .fontColor('#FFFFFF')
      .fontWeight(FontWeight.Bold)
      .margin({ top: 24, bottom: 12 })
  }

  @Builder
  LabelText(text: string) {
    Text(text)
      .fontSize(14)
      .fontColor('#AAAAAA')
      .margin({ bottom: 6 })
  }

  build() {
    NavDestination() {
      Column() {
        // ── 页头 ──
        Row() {
          Button('← 返回')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor('rgba(255,255,255,0.08)')
            .borderRadius(6)
            .focusable(true)
            .onClick(() => {
              this.pageStack.pop();
            })
          Text('SubHub 字幕网关演示')
            .fontSize(22)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Row().width(80).height(36)
        }
        .width('100%')
        .height(72)
        .padding({ left: 24, right: 24 })
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)

        Scroll(this.scroller) {
          Column() {
            // ── 连接配置 ──
            this.SectionTitle('连接配置')
            Row({ space: 12 }) {
              Column() {
                this.LabelText('Base URL')
                TextInput({ text: this.baseUrl, placeholder: AppEnv.SUBHUB_BASE_URL })
                  .width('100%')
                  .height(44)
                  .fontSize(14)
                  .onChange((value: string) => this.updateBaseUrl(value))
              }
              .layoutWeight(1)

              Column() {
                this.LabelText('Caller Key（Bearer Token）')
                TextInput({ text: this.callerKey, placeholder: '粘贴 SubHub Caller Key' })
                  .type(InputType.Password)
                  .width('100%')
                  .height(44)
                  .fontSize(14)
                  .onChange((value: string) => this.persistCallerKey(value))
              }
              .layoutWeight(2)
            }
            .width('100%')
            .alignItems(VerticalAlign.Bottom)

            // ── 演示一：搜索 ──
            this.SectionTitle('演示一：字幕搜索')
            Text('GET /api/subtitles/search，鉴权 Authorization: Bearer <CallerKey>')
              .fontSize(13)
              .fontColor('#888888')
              .margin({ bottom: 12 })

            Row({ space: 12 }) {
              Column() {
                this.LabelText('标题 title（必填）')
                TextInput({ text: this.searchTitle, placeholder: '如 The Matrix / 流浪地球' })
                  .width('100%')
                  .height(44)
                  .fontSize(14)
                  .onChange((value: string) => this.searchTitle = value)
              }
              .layoutWeight(3)

              Column() {
                this.LabelText('语言 language（可选）')
                TextInput({ text: this.searchLanguage, placeholder: '如 chi / zho / eng' })
                  .width('100%')
                  .height(44)
                  .fontSize(14)
                  .onChange((value: string) => this.searchLanguage = value)
              }
              .layoutWeight(1)

              Column() {
                this.LabelText('年份 year（可选）')
                TextInput({ text: this.searchYear, placeholder: '如 1999' })
                  .width('100%')
                  .height(44)
                  .fontSize(14)
                  .onChange((value: string) => this.searchYear = value)
              }
              .layoutWeight(1)

              Button(this.isSearching ? '搜索中…' : '搜索')
                .fontSize(14)
                .height(44)
                .fontColor('#FFFFFF')
                .backgroundColor('#2E6BE6')
                .borderRadius(6)
                .focusable(true)
                .enabled(!this.isSearching)
                .onClick(() => {
                  this.runSearch().catch(() => {});
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Bottom)

            if (this.searchStatus.length > 0) {
              Text(this.searchStatus)
                .fontSize(13)
                .fontColor('#4EB3EC')
                .margin({ top: 10 })
                .width('100%')
            }
            if (this.searchProviderFailures.length > 0) {
              Text(`provider 状态摘要：${this.searchProviderFailures}`)
                .fontSize(12)
                .fontColor('#FF8D4D')
                .margin({ top: 6 })
                .width('100%')
            }

            if (this.searchResults.length > 0) {
              List({ space: 8 }) {
                ForEach(this.searchResults, (item: SubHubSearchResult) => {
                  ListItem() {
                    Row({ space: 12 }) {
                      Column() {
                        Text(`${item.language ?? '—'} · ${item.format} · ${item.provider}`)
                          .fontSize(12)
                          .fontColor('#888888')
                        Text(item.releaseName ?? '(无 releaseName)')
                          .fontSize(15)
                          .fontColor('#FFFFFF')
                          .maxLines(2)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(item.id)
                          .fontSize(11)
                          .fontColor('#666666')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)

                      Button('下载')
                        .fontSize(13)
                        .height(36)
                        .fontColor('#FFFFFF')
                        .backgroundColor('#2E6BE6')
                        .borderRadius(6)
                        .focusable(true)
                        .onClick(() => {
                          this.downloadFromResult(item);
                        })
                    }
                    .width('100%')
                    .padding(10)
                    .backgroundColor('rgba(255,255,255,0.04)')
                    .borderRadius(8)
                    .alignItems(VerticalAlign.Center)
                  }
                }, (item: SubHubSearchResult) => item.id)
              }
              .width('100%')
              .height(320)
              .margin({ top: 12 })
              .scrollBar(BarState.Off)
            }

            // ── 演示二：下载 ──
            this.SectionTitle('演示二：字幕下载')
            Text('GET /api/subtitles/download?subtitleId=…，返回字幕文件内容。')
              .fontSize(13)
              .fontColor('#888888')
              .margin({ bottom: 12 })

            Row({ space: 12 }) {
              Column() {
                this.LabelText('subtitleId（来自搜索结果 results[].id）')
                TextInput({ text: this.downloadSubtitleId, placeholder: '如 opensubtitles:{providerId}:{file_id}' })
                  .width('100%')
                  .height(44)
                  .fontSize(14)
                  .onChange((value: string) => this.downloadSubtitleId = value)
              }
              .layoutWeight(1)

              Button(this.isDownloading ? '下载中…' : '下载字幕')
                .fontSize(14)
                .height(44)
                .fontColor('#FFFFFF')
                .backgroundColor('#2E6BE6')
                .borderRadius(6)
                .focusable(true)
                .enabled(!this.isDownloading)
                .onClick(() => {
                  this.runDownload().catch(() => {});
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Bottom)

            if (this.downloadResult.length > 0) {
              Text(this.downloadResult)
                .fontSize(13)
                .fontColor('#4EB3EC')
                .margin({ top: 10 })
                .width('100%')
            }
            if (this.downloadPreview.length > 0) {
              Text('内容预览（前 800 字符）：')
                .fontSize(12)
                .fontColor('#AAAAAA')
                .margin({ top: 12, bottom: 6 })
              Text(this.downloadPreview)
                .fontSize(12)
                .fontColor('#DDDDDD')
                .width('100%')
                .backgroundColor('rgba(255,255,255,0.04)')
                .borderRadius(6)
                .padding(10)
            }

            // 底部留白
            Row().height(40)
          }
          .width('100%')
          .padding({ left: 24, right: 24 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#1A1A1A')
    }
    .hideTitleBar(true)
    .onShown(() => {
      this.loadConfig();
    })
  }
}
