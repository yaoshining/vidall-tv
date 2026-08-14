import { VideoPlayerController, SubtitleTrackItem } from "./VideoPlayerController"
import { common } from '@kit.AbilityKit'
import { SubtitleSearchResult } from '../../../services/subtitleAcquisition/SubtitleAcquisitionTypes'
import { parseFileName, buildSearchTitles } from '../../../lib/ScrapeClient'
import { loadSubtitleSearchPreferenceSnapshot } from '../../../subtitle/SubtitleLanguagePreference'
import {
  defaultSubtitleAcquisitionService as subtitleService
} from '../../../services/subtitleAcquisition/SubtitleAcquisitionService'
import {
  SubtitleAcquisitionError,
} from '../../../services/subtitleAcquisition/SubtitleAcquisitionTypes'

@CustomDialog
export struct SubtitleSelectorDrawerDialog {
  controller: CustomDialogController
  @Require videoController: VideoPlayerController
  /** 当前播放视频的完整路径（用于提取搜索词和字幕目录 hash） */
  videoPath: string = ''
  /** 文件源类型，如 'webdav'、'local'、'network'（用于字幕本地存储目录） */
  sourceType: string = 'network'
  /** 文件源 ID 字符串（用于字幕本地存储目录） */
  sourceId: string = '0'
  /** 刮削得到的原始标题（英文，可选），优先用于 OpenSubtitles 搜索 */
  scrapeOriginalTitle: string = ''
  /** TMDB ID（可选），用于 OpenSubtitles tmdb_id 精准匹配 */
  tmdbId: string = ''
  /** IMDb ID（可选，tt + 数字），存在时优先于 tmdbId 精准匹配 */
  imdbId: string = ''
  /**
   * 由 VideoPlayer 注入：注册一个「尝试退出搜索结果」的回调。
   * 当 VideoPlayer 的 onWillDismiss 拦截到返回键时，调用此处注册的函数：
   *   - 若当前处于搜索结果视图：将 showSearchResults 置 false 并返回 true（dialog 保持打开）
   *   - 若当前处于轨道列表视图：返回 false（交由 VideoPlayer 调用 action.dismiss()）
   */
  onRegisterResetSearch?: (fn: () => boolean) => void

  @State panelOffsetX: number = 72
  @State panelOpacity: number = 0
  /** 是否显示搜索结果面板（替换字幕轨道列表） */
  @State showSearchResults: boolean = false
  /** 正在搜索中 */
  @State isSearching: boolean = false
  /** 搜索结果列表 */
  @State searchResults: SubtitleSearchResult[] = []
  /** 搜索完成但无结果 */
  @State searchNoResults: boolean = false
  /** 正在下载字幕 */
  @State isDownloading: boolean = false
  /** 正在下载的条目 subtitleId（用于 UI 高亮） */
  @State downloadingSubtitleId: string = ''

  aboutToAppear(): void {
    this.panelOffsetX = 72
    this.panelOpacity = 0
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.panelOffsetX = 0
      this.panelOpacity = 1
    })
    // 向 VideoPlayer 注册「退出搜索结果」回调，供 onWillDismiss 拦截返回键时调用
    this.onRegisterResetSearch?.(() => {
      if (this.showSearchResults) {
        this.showSearchResults = false
        return true
      }
      return false
    })
  }

  private getCurrentSubtitleName(): string {
    const activeIdx = this.videoController.activeSubtitleIndex
    if (activeIdx < 0) {
      return '已关闭字幕'
    }
    if (activeIdx < this.videoController.allSubtitleTracks.length) {
      return this.videoController.allSubtitleTracks[activeIdx].displayName
    }
    return '未选择字幕'
  }

  private getExternalSubtitleDownloadCount(trackIndex: number): string {
    let externalOrder = 0
    for (let i = 0; i <= trackIndex && i < this.videoController.allSubtitleTracks.length; i++) {
      if (this.videoController.allSubtitleTracks[i].kind === 'external') {
        externalOrder++
      }
    }

    if (externalOrder === 1) {
      return '12.4k'
    }
    if (externalOrder === 2) {
      return '3.1k'
    }
    return '1.2k'
  }

  private getLanguageTag(name: string): string {
    const lower = name.toLowerCase()
    if (lower.includes('中文') || lower.includes('chs') || lower.includes('cht') || lower.includes('chinese')) {
      return '中文'
    }
    if (lower.includes('日文') || lower.includes('jpn') || lower.includes('japanese') || lower.includes('日本')) {
      return '日文'
    }
    if (lower.includes('英文') || lower.includes('eng') || lower.includes('english')) {
      return 'EN'
    }
    return 'EN'
  }

  private getLanguageBadgeTextColor(tag: string): string {
    if (tag === '中文') {
      return '#93C5FD'
    }
    if (tag === '日文') {
      return '#FCD34D'
    }
    return '#93C5FD'
  }

  private getLanguageBadgeFillColor(tag: string): string {
    if (tag === '中文') {
      return 'rgba(29, 78, 216, 0.25)'
    }
    if (tag === '日文') {
      return 'rgba(120, 53, 15, 0.25)'
    }
    return 'rgba(29, 78, 216, 0.31)'
  }

  private getAvailableSubtitleCount(): number {
    const base = this.videoController.allSubtitleTracks.length - (this.videoController.activeSubtitleIndex >= 0 ? 1 : 0)
    return base + 1
  }

  // ─────────────────────────────────────────────
  // 在线字幕搜索辅助方法
  // ─────────────────────────────────────────────

  /** 从 videoPath 中提取文件名（含扩展名） */
  private extractFileName(): string {
    const path = this.videoPath
    const lastSlash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'))
    return lastSlash >= 0 ? path.substring(lastSlash + 1) : path
  }

  /** 格式化下载次数：≥1000 时显示 k */
  private formatDownloadCount(count: number): string {
    if (count >= 1000) {
      const k = Math.round(count / 100) / 10
      return `${k}k`
    }
    return `${count}`
  }

  /** 将 BCP-47 语言代码映射为显示标签 */
  private getResultLanguageTag(languageCode: string): string {
    const lower = languageCode.toLowerCase()
    if (lower === 'zh-cn' || lower === 'zh' || lower === 'chi' || lower === 'chs') {
      return '简中'
    }
    if (lower === 'zh-tw' || lower === 'cht' || lower === 'zht') {
      return '繁中'
    }
    if (lower === 'en' || lower === 'eng') {
      return 'EN'
    }
    if (lower === 'ja' || lower === 'jpn') {
      return '日文'
    }
    if (lower === 'ko' || lower === 'kor') {
      return '韩文'
    }
    return languageCode.toUpperCase().substring(0, 4)
  }

  /** 语言标签文字颜色 */
  private getResultBadgeTextColor(tag: string): string {
    if (tag === '简中' || tag === '繁中') {
      return '#93C5FD'
    }
    if (tag === '日文') {
      return '#FCD34D'
    }
    return '#93C5FD'
  }

  /** 语言标签背景颜色 */
  private getResultBadgeFillColor(tag: string): string {
    if (tag === '简中' || tag === '繁中') {
      return 'rgba(29, 78, 216, 0.25)'
    }
    if (tag === '日文') {
      return 'rgba(120, 53, 15, 0.25)'
    }
    return 'rgba(29, 78, 216, 0.31)'
  }

  /** 来源 chip 文案：opensubtitles → 直连，subhub → SubHub */
  private getSourceLabel(source: string): string {
    return source === 'opensubtitles' ? '直连' : 'SubHub'
  }

  /** 来源 chip 文字颜色 */
  private getSourceChipTextColor(source: string): string {
    return source === 'opensubtitles' ? '#4ADE80' : '#6B9EE0'
  }

  /** 来源 chip 背景颜色 */
  private getSourceChipFillColor(source: string): string {
    return source === 'opensubtitles' ? 'rgba(74, 222, 128, 0.16)' : 'rgba(107, 158, 224, 0.16)'
  }

  /** 显示 Toast 提示 */
  private showSearchToast(message: string, duration: number): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: duration })
    } catch (e) {}
  }

  /**
   * 触发在线字幕搜索。
   * 流程：提取文件名 → 解析搜索词 → 读取语言偏好 → 调用 SubtitleAcquisitionService.search()。
   */
  private async startSearch(): Promise<void> {
    this.isSearching = true
    this.showSearchResults = true
    this.searchResults = []
    this.searchNoResults = false

    try {
      const fileName = this.extractFileName()
      const parsed = parseFileName(fileName)

      // 优先使用刮削数据：originalTitle 质量远高于文件名解析
      let query: string
      let searchYear: number | undefined = parsed.year
      let searchSeason: number | undefined = parsed.seasonNumber
      let searchEpisode: number | undefined = parsed.episodeNumber
      let searchMediaType: 'movie' | 'tv' | undefined = parsed.mediaType
      let searchTmdbId: string | undefined = undefined
      let searchImdbId: string | undefined = undefined

      if (this.scrapeOriginalTitle.length > 0) {
        // 有刮削原始标题，直接使用
        query = this.scrapeOriginalTitle
      } else {
        // 无刮削数据，回退到文件名解析
        const titles = buildSearchTitles(parsed.title)
        query = titles.length > 0 ? titles[0] : parsed.title
      }

      if (this.tmdbId.length > 0) {
        searchTmdbId = this.tmdbId
      }
      if (this.imdbId.length > 0) {
        searchImdbId = this.imdbId
      }

      const snapshot = await loadSubtitleSearchPreferenceSnapshot()
      const languages = snapshot.languagesParam

      console.info(`[SubtitleSearch] 搜索词: "${query}", 语言: "${languages}", 年份: ${searchYear}, 季: ${searchSeason}, 集: ${searchEpisode}, tmdbId: ${searchTmdbId ?? 'none'}, imdbId: ${searchImdbId ?? 'none'}`)

      // 搜索词构造仍属 UI 编排（刮削优先 vs 文件名回退），实际检索委托给 service。
      const results = await subtitleService.search({
        query,
        languages,
        year: searchYear,
        seasonNumber: searchSeason,
        episodeNumber: searchEpisode,
        mediaType: searchMediaType,
        tmdbId: searchTmdbId,
        imdbId: searchImdbId
      });

      this.searchResults = results
      this.searchNoResults = results.length === 0
    } catch (e) {
      // 错误分类来自 service 的 SubtitleAcquisitionError.kind，UI 只决定 Toast 文案。
      this.showSearchToast(this.toastMessageForAcquisitionError(e, '搜索'), 4000)
      this.showSearchResults = false
    } finally {
      this.isSearching = false
    }
  }

  /**
   * 根据 `SubtitleAcquisitionError.kind` 输出对应 Toast 文案。
   * 搜索与下载共用同一组文案，避免 UI 重复维护。
   */
  private toastMessageForAcquisitionError(
    e: object,
    verb: '搜索' | '下载'
  ): string {
    // ArkTS 严格模式禁止在 object 上访问任意属性，因此用 instanceof 收窄后再读 kind。
    if (e instanceof SubtitleAcquisitionError) {
      const kind = e.kind;
      switch (kind) {
        case 'proxy_quota_exceeded':
          return `今日字幕${verb}配额已用完，请在设置页填写您自己的 API Key`;
        case 'proxy_unavailable':
          return `字幕服务暂时不可用，请在设置页填写您自己的 API Key`;
        case 'invalid_api_key':
          return 'API Key 无效，请在设置页重新填写';
        case 'download_failed':
          return `字幕${verb}失败，请稍后重试`;
        case 'subhub_auth_invalid':
          return '字幕服务配置异常，请稍后重试';
        case 'subhub_quota_exhausted':
          return '字幕源配额已耗尽，请稍后重试';
        case 'subhub_unavailable':
          return '字幕源暂时不可用，请稍后重试';
        case 'subhub_not_found':
          return '字幕已失效，请重新搜索';
        case 'unknown':
        default:
          return `字幕${verb}失败，请稍后重试`;
      }
    }
    return `字幕${verb}失败，请稍后重试`;
  }

  /**
   * 下载并尝试加载用户选择的字幕条目。
   *
   * 编排：
   * 1. `subtitleService.download()` 落盘字幕
   * 2. `videoController.addExternalSubtitle()` 挂载
   * 3. `videoController.switchSubtitleTrack()` 自动切换
   * 4. `subtitleService.markLastUsed()` 异步记 lastUsed（fire-and-forget，失败不抛）
   */
  private async downloadSubtitle(result: SubtitleSearchResult): Promise<void> {
    if (this.isDownloading) {
      return
    }
    this.isDownloading = true
    this.downloadingSubtitleId = result.subtitleId

    try {
      const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext
      const filesDir: string = hostCtx.filesDir
      const downloadOutcome = await subtitleService.download({
        result,
        stableVideoSrc: this.videoController.stableVideoSrcForCache,
        sourceType: this.sourceType,
        sourceId: this.sourceId,
        filesDir
      });

      console.info(`[SubtitleSearch] 字幕已写入: ${downloadOutcome.localPath}`)

      const trackCountBeforeAppend = this.videoController.allSubtitleTracks.length
      await this.videoController.addExternalSubtitle(downloadOutcome.localPath)
      if (this.videoController.allSubtitleTracks.length <= trackCountBeforeAppend) {
        throw new Error('下载字幕未能追加到轨道列表')
      }

      // 下载成功后自动切换到新追加的字幕轨道。
      const newSubtitleIndex = this.videoController.allSubtitleTracks.length - 1
      await this.videoController.switchSubtitleTrack(newSubtitleIndex)

      // 仅在字幕轨道追加并切换成功后才提示成功，避免挂载/切换失败时出现「成功+失败」连续提示。
      this.showSearchToast('字幕下载成功', 2000)

      // 标记最近使用字幕：按 OpenSpec 3.4 scenario 2 失败不影响下载挂载，fire-and-forget。
      subtitleService.markLastUsed({
        fileName: downloadOutcome.fileName,
        stableVideoSrc: this.videoController.stableVideoSrcForCache,
        sourceType: this.sourceType,
        sourceId: this.sourceId,
        filesDir
      }).catch(() => {});

      this.showSearchResults = false
    } catch (e) {
      const errMsg = (e as object as Record<string, string>)['message'] ?? JSON.stringify(e)
      console.error(`[SubtitleDownload] 下载异常 type=${(e as object)?.constructor?.name} msg=${errMsg}`)
      this.showSearchToast(this.toastMessageForAcquisitionError(e, '下载'), 4000)
    } finally {
      this.isDownloading = false
      this.downloadingSubtitleId = ''
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.controller.close()
        })

      Column({ space: 16 }) {
        // ── 面板标题（始终可见） ──
        Row() {
          if (this.showSearchResults) {
            Text('←')
              .fontSize(24)
              .fontColor('#97A9CD')
              .margin({ right: 12 })
              .focusable(true)
              .onClick(() => {
                this.showSearchResults = false
              })
          }
          Text(this.showSearchResults ? '在线搜索字幕' : '字幕')
            .fontSize(34)
            .fontColor('#F3F6FB')
            .fontWeight(FontWeight.Bold)
        }
        .height(48)
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (!this.showSearchResults) {
          // ── 正常视图：当前字幕 + 轨道列表 + 搜索按钮 ──
          Text('当前字幕')
            .fontSize(17)
            .fontColor('#97A9CD')

          Row({ space: 12 }) {
            if (this.videoController.activeSubtitleIndex >= 0) {
              Row() {
                Text(this.getLanguageTag(this.getCurrentSubtitleName()))
                  .fontSize(13)
                  .fontWeight(600)
                  .fontColor(this.getLanguageBadgeTextColor(this.getLanguageTag(this.getCurrentSubtitleName())))
              }
              .height(26)
              .padding({ left: 10, right: 10, top: 3, bottom: 3 })
              .justifyContent(FlexAlign.Center)
              .alignItems(VerticalAlign.Center)
              .borderRadius(13)
              .backgroundColor(this.getLanguageBadgeFillColor(this.getLanguageTag(this.getCurrentSubtitleName())))
            }

            Text(this.getCurrentSubtitleName())
              .fontSize(18)
              .fontColor('#FBFDFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            if (this.videoController.activeSubtitleIndex >= 0) {
              Text('✓')
                .fontSize(20)
                .fontColor('#4ADE80')
            }
          }
          .width('100%')
          .height(68)
          .padding({ left: 16, right: 16 })
          .justifyContent(FlexAlign.SpaceBetween)
          .alignItems(VerticalAlign.Center)
          .backgroundColor('rgba(255, 255, 255, 0.12)')
          .borderRadius(16)
          .border({
            width: this.videoController.activeSubtitleIndex >= 0 ? 2 : 1,
            color: this.videoController.activeSubtitleIndex >= 0 ? '#FFFEFE' : 'rgba(255, 255, 255, 0.19)'
          })

          Row({ space: 12 }) {
            Row() {
              Text('关闭字幕')
                .fontSize(18)
                .fontColor('#DDE4EE')
            }
            .height(48)
            .padding({ left: 18, right: 18 })
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .backgroundColor('rgba(255, 255, 255, 0.07)')
            .borderRadius(24)
            .border({ width: 1, color: 'rgba(255, 255, 255, 0.19)' })
            .focusable(true)
            .onClick(() => {
              this.videoController.switchSubtitleTrack(-1)
            })

            Row() {
              Text('⏱ 时间调整')
                .fontSize(18)
                .fontColor('#DDE4EE')
            }
            .height(48)
            .padding({ left: 18, right: 18 })
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .backgroundColor('rgba(255, 255, 255, 0.07)')
            .borderRadius(24)
            .border({ width: 1, color: 'rgba(255, 255, 255, 0.19)' })
          }
          .width('100%')

          Divider()
            .strokeWidth(1)
            .color('rgba(255, 255, 255, 0.15)')

          Column({ space: 8 }) {
            Text(`其他可用字幕 (${this.getAvailableSubtitleCount()})`)
              .fontSize(17)
              .fontColor('#97A9CD')

            Scroll() {
              Column({ space: 8 }) {
                ForEach(this.videoController.allSubtitleTracks, (item: SubtitleTrackItem, index: number) => {
                  if (index !== this.videoController.activeSubtitleIndex) {
                    Row({ space: 10 }) {
                      Row() {
                        Text(this.getLanguageTag(item.displayName))
                          .fontSize(13)
                          .fontWeight(600)
                          .fontColor(this.getLanguageBadgeTextColor(this.getLanguageTag(item.displayName)))
                      }
                      .height(24)
                      .padding({ left: 9, right: 9, top: 3, bottom: 3 })
                      .justifyContent(FlexAlign.Center)
                      .alignItems(VerticalAlign.Center)
                      .borderRadius(12)
                      .backgroundColor(this.getLanguageBadgeFillColor(this.getLanguageTag(item.displayName)))

                      Text(item.displayName)
                        .fontSize(17)
                        .fontColor('#EAF0F7')
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)

                      if (item.kind === 'external') {
                        Text(`↓ ${this.getExternalSubtitleDownloadCount(index)}`)
                          .fontSize(13)
                          .fontColor('#97A9CD')
                      }
                    }
                    .width('100%')
                    .height(62)
                    .padding({ top: 12, bottom: 12, left: 14, right: 14 })
                    .alignItems(VerticalAlign.Center)
                    .backgroundColor('rgba(255, 255, 255, 0.05)')
                    .borderRadius(14)
                    .focusable(true)
                    .onClick(() => {
                      this.videoController.switchSubtitleTrack(index)
                    })
                  }
                })

                Row({ space: 10 }) {
                  Text('无字幕')
                    .fontSize(17)
                    .fontColor('#97A9CD')
                }
                .width('100%')
                .height(50)
                .padding({ top: 12, bottom: 12, left: 14, right: 14 })
                .alignItems(VerticalAlign.Center)
                .backgroundColor('rgba(255, 255, 255, 0.03)')
                .borderRadius(14)
                .focusable(true)
                .onClick(() => {
                  this.videoController.switchSubtitleTrack(-1)
                })
              }
              .width('100%')
            }
            .align(Alignment.Top)
            .scrollBar(BarState.Off)
            .nestedScroll({ scrollForward: NestedScrollMode.SELF_ONLY, scrollBackward: NestedScrollMode.SELF_ONLY })
            .width('100%')
            .layoutWeight(1)
          }
          .width('100%')
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          // ── 在线搜索字幕入口按钮（Task 6.1）──
          Row({ space: 10 }) {
            Text('🔍')
              .fontSize(18)
              .fontColor('#B0C4DE')
            Text('在线搜索字幕')
              .fontSize(18)
              .fontColor('#B0C4DE')
          }
          .width('100%')
          .height(52)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .backgroundColor('rgba(255, 255, 255, 0.03)')
          .borderRadius(26)
          .border({ width: 1, color: 'rgba(255, 255, 255, 0.15)' })
          .focusable(true)
          .onClick(() => {
            this.startSearch().catch(() => {})
          })
        } else {
          // ── 搜索结果视图（Task 6.2）──
          if (this.isSearching) {
            // 加载中状态
            Column({ space: 16 }) {
              LoadingProgress()
                .width(48)
                .height(48)
                .color('#6B9EE0')
              Text('正在搜索字幕...')
                .fontSize(16)
                .fontColor('#97A9CD')
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else if (this.searchNoResults) {
            // 无结果状态
            Column({ space: 12 }) {
              Text('未找到字幕')
                .fontSize(18)
                .fontColor('#97A9CD')
              Text('请尝试在设置页调整字幕语言偏好')
                .fontSize(14)
                .fontColor('rgba(151, 169, 205, 0.6)')
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else {
            // 结果列表（Task 6.2）
            Column({ space: 8 }) {
              Text(`搜索结果 (${this.searchResults.length})`)
                .fontSize(17)
                .fontColor('#97A9CD')

              Scroll() {
                Column({ space: 8 }) {
                  ForEach(this.searchResults, (result: SubtitleSearchResult, index: number) => {
                    Row({ space: 10 }) {
                      Row() {
                        Text(this.getResultLanguageTag(result.languageCode))
                          .fontSize(13)
                          .fontWeight(600)
                          .fontColor(this.getResultBadgeTextColor(this.getResultLanguageTag(result.languageCode)))
                      }
                      .height(24)
                      .padding({ left: 9, right: 9, top: 3, bottom: 3 })
                      .justifyContent(FlexAlign.Center)
                      .alignItems(VerticalAlign.Center)
                      .borderRadius(12)
                      .backgroundColor(this.getResultBadgeFillColor(this.getResultLanguageTag(result.languageCode)))

                      Row() {
                        Text(this.getSourceLabel(result.source))
                          .fontSize(12)
                          .fontWeight(600)
                          .fontColor(this.getSourceChipTextColor(result.source))
                      }
                      .height(24)
                      .padding({ left: 9, right: 9, top: 3, bottom: 3 })
                      .justifyContent(FlexAlign.Center)
                      .alignItems(VerticalAlign.Center)
                      .borderRadius(12)
                      .backgroundColor(this.getSourceChipFillColor(result.source))

                      Column({ space: 4 }) {
                        Text(result.fileName)
                          .fontSize(16)
                          .fontColor('#EAF0F7')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                        Text(`${result.languageCode}  ↓ ${this.formatDownloadCount(result.downloadCount)}`)
                          .fontSize(13)
                          .fontColor('#97A9CD')
                          .maxLines(1)
                          .width('100%')
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)

                      if (this.isDownloading && this.downloadingSubtitleId === result.subtitleId) {
                        LoadingProgress()
                          .width(24)
                          .height(24)
                          .color('#6B9EE0')
                      } else {
                        Row() {
                          Text('下载')
                            .fontSize(14)
                            .fontColor('#F3F6FB')
                        }
                        .height(32)
                        .padding({ left: 14, right: 14 })
                        .justifyContent(FlexAlign.Center)
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor('rgba(107, 158, 224, 0.18)')
                        .borderRadius(16)
                        .border({ width: 1, color: 'rgba(107, 158, 224, 0.4)' })
                        .focusable(true)
                        .onClick(() => {
                          this.downloadSubtitle(result).catch(() => {})
                        })
                      }
                    }
                    .width('100%')
                    .padding({ top: 12, bottom: 12, left: 14, right: 14 })
                    .alignItems(VerticalAlign.Center)
                    .backgroundColor('rgba(255, 255, 255, 0.05)')
                    .borderRadius(14)
                    .defaultFocus(index === 0)
                    .focusable(true)
                    .enabled(!this.isDownloading)
                    .onClick(() => {
                      this.downloadSubtitle(result).catch(() => {})
                    })
                  }, (result: SubtitleSearchResult) => result.subtitleId)
                }
                .width('100%')
              }
              .align(Alignment.Top)
              .scrollBar(BarState.Off)
              .nestedScroll({ scrollForward: NestedScrollMode.SELF_ONLY, scrollBackward: NestedScrollMode.SELF_ONLY })
              .width('100%')
              .layoutWeight(1)
            }
            .width('100%')
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
        }
      }
      .width('33.33%')
      .height('100%')
      .padding(32)
      .backgroundColor('rgba(5, 10, 20, 0.91)')
      .offset({ x: this.panelOffsetX })
      .opacity(this.panelOpacity)
    }
    .width('100%')
    .height('100%')
  }
}
