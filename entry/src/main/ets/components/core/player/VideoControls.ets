import { debounce } from "@ibestservices/ibest-ui"
import { VideoPlayerController, SubtitleTrackItem, AudioTrackItem, AspectRatioMode } from "./VideoPlayerController"
import { VpeQualityLevel } from "../../../utils/VpeEnhancerUtil"
import { hilog } from "@kit.PerformanceAnalysisKit"
import { LengthMetrics } from "@kit.ArkUI"
import { media } from "@kit.MediaKit"
import { EpisodeListPanel } from './EpisodeListPanel'
import { PlaybackContextItem, MediaLibraryContext, PlaybackContext } from './PlaybackContext'
import {
  loadEpisodeAutoplaySettings,
  saveEpisodeAutoplayCountdownSeconds,
  saveEpisodeAutoplayEnabled
} from './EpisodeAutoplayPreferences'
import { common } from '@kit.AbilityKit'
// Module 3 收口：原 `OpenSubtitlesClient` / `SubtitleDownloader` / `SubtitleCacheManager`
// + 4 个具体 Error 类的 import 已删除，全部通过 SubtitleAcquisitionService 编排。
import { SubtitleSearchResult } from '../../../services/subtitleAcquisition/SubtitleAcquisitionTypes'
import { parseFileName, buildSearchTitles } from '../../../lib/ScrapeClient'
import { loadSubtitleSearchPreferenceSnapshot } from '../../../subtitle/SubtitleLanguagePreference'
import {
  defaultSubtitleAcquisitionService as subtitleService
} from '../../../services/subtitleAcquisition/SubtitleAcquisitionService'
import {
  SubtitleAcquisitionError,
  CachedSubtitleEntry
} from '../../../services/subtitleAcquisition/SubtitleAcquisitionTypes'

@ComponentV2
struct VideoControls {
  @Require @Param videoController: VideoPlayerController
  @Require @Param dialogController: CustomDialogController
  @Require @Param openSettings: () => void
  @Param onOpenSubtitleSelector: () => void = () => {}
  closeTimer?: number
  seekTimer?: number
  private AUTO_CLOSE_TIMEOUT = 5000
  @Local showSubtitleMenu: boolean = false
  @Local showAudioMenu: boolean = false
  @Local audioButtonFocused: boolean = false
  @Local subtitleButtonFocused: boolean = false
  @Local settingButtonFocused: boolean = false
  @Local sliderHovered: boolean = false
  @Local sliderFocused: boolean = false
  // ── 进度条 hover tooltip ──
  @Local hoverTimeMs: number = 0      // hover/焦点位置对应的时间（ms）
  @Local sliderWidth: number = 0      // Slider 组件实际宽度（vp）
  /**
   * 已下载字幕缓存列表（来自 SubtitleCacheManager.metadata.json）。
   * 用户主动关闭字幕后仍可在"字幕"菜单看到，供重新启用。
   * 加载时通过 `videoController.stableVideoSrcForCache` 拿稳定 key，
   * 避免 SMB 代理 URL 端口漂移导致缓存目录 hash 不一致。
   */
  @Local cachedSubtitles: CachedSubtitleEntry[] = []
  /**
   * 过滤后的缓存字幕列表（剔除 `allSubtitleTracks` 中已展示的）。
   * 避免菜单同一字幕在两个分组中重复出现。
   */
  @Local visibleCachedSubtitles: CachedSubtitleEntry[] = []

  /** 将毫秒格式化为 HH:MM:SS 或 MM:SS */
  private formatTime(ms: number): string {
    const totalSec = Math.floor(ms / 1000)
    const h = Math.floor(totalSec / 3600)
    const m = Math.floor((totalSec % 3600) / 60)
    const s = totalSec % 60
    const mm = m < 10 ? `0${m}` : `${m}`
    const ss = s < 10 ? `0${s}` : `${s}`
    if (h > 0) {
      const hh = h < 10 ? `0${h}` : `${h}`
      return `${hh}:${mm}:${ss}`
    }
    return `${mm}:${ss}`
  }

  /** tooltip 宽度（vp）：时长 ≥ 1 小时时使用 136 以容纳 hh:mm:ss，否则 100 */
  private tooltipWidthVp(): number {
    return this.videoController.duration >= 3600000 ? 136 : 100
  }

  @Builder
  SliderTooltip() {
    Text(this.formatTime(this.hoverTimeMs))
      .fontSize(20)
      .fontColor(Color.White)
      .fontWeight(FontWeight.Medium)
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .backgroundColor('#CC000000')
      .borderRadius(8)
      .width(this.tooltipWidthVp())
      .position({ x: this.getTooltipOffsetX(), y: 0 })
  }

  /** 计算 tooltip 左边距：按当前时间比例居中对齐，并限制不超出两端 */
  private getTooltipOffsetX(): number {
    const TOOLTIP_W = this.tooltipWidthVp()
    if (this.sliderWidth <= 0 || this.videoController.duration <= 0) {
      return 0
    }
    const ratio = this.hoverTimeMs / this.videoController.duration
    const center = ratio * this.sliderWidth
    const raw = center - TOOLTIP_W / 2
    if (raw < 0) return 0
    if (raw + TOOLTIP_W > this.sliderWidth) return this.sliderWidth - TOOLTIP_W
    return raw
  }

  @Builder
  SubtitleMenu() {
    Column() {
      List() {
        // 关闭字幕
        ListItem() {
          Row() {
            Text('关闭字幕')
              .fontSize(16)
              .fontColor(Color.White)
            if (this.videoController.activeSubtitleIndex === -1) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontColor([Color.White])
                .fontSize(20)
            }
          }
          .width('100%')
          .height(50)
          .justifyContent(FlexAlign.SpaceBetween)
          .padding({ left: 20, right: 20 })
        }
        .onClick(() => {
          this.videoController.switchSubtitleTrack(-1)
          this.showSubtitleMenu = false
          this.enableAutoHide()
        })

        // 所有字幕轨道（内嵌 + 外部）
        ForEach(this.videoController.allSubtitleTracks, (item: SubtitleTrackItem, index: number) => {
          ListItem() {
            Row() {
              Column({ space: 2 }) {
                Text(item.displayName)
                  .fontSize(16)
                  .fontColor(Color.White)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (item.kind === 'external') {
                  Text('外部文件')
                    .fontSize(11)
                    .fontColor('#FFA500')
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              if (this.videoController.activeSubtitleIndex === index) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontColor([Color.White])
                  .fontSize(20)
              }
            }
            .width('100%')
            .height(item.kind === 'external' ? 60 : 50)
            .justifyContent(FlexAlign.SpaceBetween)
            .padding({ left: 20, right: 20 })
          }
          .onClick(() => {
            this.videoController.switchSubtitleTrack(index)
            this.showSubtitleMenu = false
            this.enableAutoHide()
          })
        })

        // 已下载字幕（来自 SubtitleCacheManager.metadata.json）
        // 用户主动关闭字幕后仍可在此分组重新启用；
        // 同时按 fileName 后缀对 allSubtitleTracks 做去重，避免双列。
        //
        // 不加"已下载字幕"标题：标题出现的时机（lastUsed 自动应用时无，禁用时有时无）会让用户感知到分组语义变化；
        // 不带标题的列表与上方"关闭字幕 + allSubtitleTracks"组视觉一致，列表项内的副标题（"已下载 · 语言"）已能传达来源。
        if (this.visibleCachedSubtitles.length > 0) {
          ForEach(this.visibleCachedSubtitles, (entry: CachedSubtitleEntry) => {
            ListItem() {
              Row() {
                Column({ space: 2 }) {
                  Text(entry.fileName)
                    .fontSize(16)
                    .fontColor(Color.White)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text('已下载 · ' + (entry.language.length > 0 ? entry.language : '未知语言'))
                    .fontSize(11)
                    .fontColor('#FFA500')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .height(60)
              .justifyContent(FlexAlign.SpaceBetween)
              .padding({ left: 20, right: 20 })
            }
            .onClick(() => {
              this.enableCachedSubtitle(entry).catch(() => {})
              this.showSubtitleMenu = false
              this.enableAutoHide()
            })
          }, (entry: CachedSubtitleEntry): string => entry.fileName)
        }

        // 字幕延迟调整（仅在外部 SRT 字幕激活时显示；内嵌轨由播放器原生渲染，延迟不适用）
        if (this.videoController.activeSubtitleIndex >= 0 && this.videoController.hasSrtSubtitle) {
          ListItem() {
            Column({ space: 8 }) {
              Text('字幕延迟')
                .fontSize(13)
                .fontColor('rgba(255,255,255,0.6)')
                .alignSelf(ItemAlign.Start)
                .padding({ left: 20 })
              Row({ space: 8 }) {
                Button('-500ms')
                  .fontSize(13)
                  .fontColor(Color.White)
                  .backgroundColor('rgba(255,255,255,0.15)')
                  .borderRadius(6)
                  .height(36)
                  .onClick(() => {
                    this.videoController.adjustSubtitleDelay(-500)
                  })
                Button('-100ms')
                  .fontSize(13)
                  .fontColor(Color.White)
                  .backgroundColor('rgba(255,255,255,0.15)')
                  .borderRadius(6)
                  .height(36)
                  .onClick(() => {
                    this.videoController.adjustSubtitleDelay(-100)
                  })
                Text(this.getDelayLabel())
                  .fontSize(13)
                  .fontColor(this.videoController.subtitleDelayMs === 0 ? 'rgba(255,255,255,0.6)' : '#FFD700')
                  .width(80)
                  .textAlign(TextAlign.Center)
                Button('+100ms')
                  .fontSize(13)
                  .fontColor(Color.White)
                  .backgroundColor('rgba(255,255,255,0.15)')
                  .borderRadius(6)
                  .height(36)
                  .onClick(() => {
                    this.videoController.adjustSubtitleDelay(100)
                  })
                Button('+500ms')
                  .fontSize(13)
                  .fontColor(Color.White)
                  .backgroundColor('rgba(255,255,255,0.15)')
                  .borderRadius(6)
                  .height(36)
                  .onClick(() => {
                    this.videoController.adjustSubtitleDelay(500)
                  })
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ left: 12, right: 12 })
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })
          }
        }

        ListItem() {
          Row({ space: 10 }) {
            Text('🔍')
              .fontSize(16)
              .fontColor(Color.White)
            Text('更多字幕配置')
              .fontSize(16)
              .fontColor(Color.White)
          }
          .width('100%')
          .height(50)
          .justifyContent(FlexAlign.Start)
          .padding({ left: 20, right: 20 })
        }
        .onClick(() => {
          this.showSubtitleMenu = false
          this.onOpenSubtitleSelector()
        })
      }
      .width('100%')
      .backgroundColor('rgba(0, 0, 0, 0.8)')
      .borderRadius(8)
    }
    .padding(10)
  }

  @Builder
  AudioMenu() {
    Column() {
      List() {
        ForEach(this.videoController.audioTracks, (item: AudioTrackItem, index: number) => {
          ListItem() {
            Row() {
              Text(item.displayName)
                .fontSize(16)
                .fontColor(Color.White)
              if (this.videoController.activeAudioIndex === index) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontColor([Color.White])
                  .fontSize(20)
              }
            }
            .width('100%')
            .height(50)
            .justifyContent(FlexAlign.SpaceBetween)
            .padding({ left: 20, right: 20 })
          }
          .onClick(() => {
            this.dispatchAudioTrackSwitch(index)
            this.showAudioMenu = false
            // forceStart=true：切换后不管当前 isPlaying 状态（switchAudioTrack 内部会 pause）
            // 都强制启动自动隐藏定时器，seekDone 恢复播放后控件会正常隐藏
            this.enableAutoHide(true)
          })
        })
      }
      .width('100%')
      .backgroundColor('rgba(0, 0, 0, 0.8)')
      .borderRadius(8)
    }
    .padding(10)
  }

  build() {
    RelativeContainer() {
      // ── 顶部栏：标题 + 音轨按钮 + 字幕按钮 ──
      Flex({
        justifyContent: FlexAlign.SpaceBetween,
        alignItems: ItemAlign.Start
      }) {
        Text(this.videoController.name)
          .fontSize($r('app.float.font_h8_title_secondary'))
          .fontColor(Color.White)
          .textShadow({ radius: 3, offsetX: 3, offsetY: 3, color: Color.Black })
          .width("60%")
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // 音轨按钮 + 字幕按钮
        Flex({ direction: FlexDirection.Row, justifyContent: FlexAlign.End, alignItems: ItemAlign.Center }) {
          // 音轨按钮
          if (this.videoController.audioTracks.length > 0) {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.folder'))
                .fontColor([Color.White])
                .fontSize(24)
              Text(this.getActiveAudioName())
                .fontSize(14)
                .fontColor(Color.White)
            }
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor(this.audioButtonFocused ? 'rgba(27, 120, 242, 0.35)' : 'rgba(0, 0, 0, 0.5)')
            .borderRadius(20)
            .border({ width: this.audioButtonFocused ? 2 : 1, color: this.audioButtonFocused ? '#66A9D8FF' : 'rgba(255, 255, 255, 0.18)' })
            .focusable(true)
            .onFocus(() => { this.audioButtonFocused = true })
            .onBlur(() => { this.audioButtonFocused = false })
            .onClick(() => {
              this.showAudioMenu = !this.showAudioMenu
              clearTimeout(this.closeTimer)
            })
          }

          // 字幕按钮
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.text_bubble_left_2'))
              .fontColor([this.videoController.activeSubtitleIndex >= 0 ? Color.White : Color.Gray])
              .fontSize(24)
            Text(this.getActiveSubtitleName())
              .fontSize(14)
              .fontColor(this.videoController.activeSubtitleIndex >= 0 ? Color.White : Color.Gray)
          }
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(this.subtitleButtonFocused ? 'rgba(27, 120, 242, 0.35)' : 'rgba(0, 0, 0, 0.5)')
          .borderRadius(20)
          .border({ width: this.subtitleButtonFocused ? 2 : 1, color: this.subtitleButtonFocused ? '#66A9D8FF' : 'rgba(255, 255, 255, 0.18)' })
          .focusable(true)
          .onFocus(() => { this.subtitleButtonFocused = true })
          .onBlur(() => { this.subtitleButtonFocused = false })
          .onClick(() => {
            this.showSubtitleMenu = !this.showSubtitleMenu
            // 打开字幕菜单时刷新"已下载"列表（dialog 打开后异步加载完成时也会触发重渲染）
            if (this.showSubtitleMenu) {
              this.visibleCachedSubtitles = this.filterVisibleCached(this.cachedSubtitles);
            }
            clearTimeout(this.closeTimer)
          })

          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.gearshape'))
              .fontColor([Color.White])
              .fontSize(22)
            Text('设置')
              .fontSize(16)
              .fontColor(Color.White)
          }
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(this.settingButtonFocused ? 'rgba(27, 120, 242, 0.35)' : 'rgba(0, 0, 0, 0.5)')
          .borderRadius(20)
          .border({ width: this.settingButtonFocused ? 2 : 1, color: this.settingButtonFocused ? '#66A9D8FF' : 'rgba(255, 255, 255, 0.18)' })
          .focusable(true)
          .onFocus(() => { this.settingButtonFocused = true })
          .onBlur(() => { this.settingButtonFocused = false })
          .onClick(() => {
            this.showSubtitleMenu = false
            this.showAudioMenu = false
            clearTimeout(this.closeTimer)
            this.openSettings()
          })
        }
        .width("40%")
        .margin({ right: 8 })
      }
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [['rgba(0, 0, 0, 0.58)', 0.0], ['rgba(0, 0, 0, 0)', 1.0]]
      })
      .alignRules({
        left: { anchor: '__container__', align: HorizontalAlign.Start },
        top: { anchor: '__container__', align: VerticalAlign.Top }
      })
      .height("22%")
      .padding(20)

      // ── 播放暂停居中按钮 ──
      if (!this.videoController.isPlaying) {
        Column() {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontColor([Color.White])
            .fontSize(48)
        }
        .alignRules({
          center: { anchor: '__container__', align: VerticalAlign.Center },
          middle: { anchor: '__container__', align: HorizontalAlign.Center }
        })
        .backgroundColor('rgba(200, 200, 200, 0.2)')
        .backdropBlur(40)
        .padding(20)
        .borderRadius(99)
        .border({ width: 1, color: 'rgba(255, 255, 255, 0.2)' })
        .shadow({ radius: 20, color: 'rgba(0, 0, 0, 0.4)' })
      }

      // ── 底部进度条 ──
      Flex({ alignItems: ItemAlign.End }) {
        Flex({
          alignItems: ItemAlign.Center,
          justifyContent: FlexAlign.SpaceBetween,
          space: { main: LengthMetrics.vp(6) }
        }) {
          Text(`${this.videoController.currentTimeDisplay}`)
            .flexShrink(0)
          // Slider + hover tooltip
          Stack({ alignContent: Alignment.Bottom }) {
            // tooltip 层
            Row() {
              this.SliderTooltip()
            }
            .width('100%')
            .height(44)
            .hitTestBehavior(HitTestMode.Transparent)
            .offset({ y: -42 })
            .visibility(this.sliderHovered ? Visibility.Visible : Visibility.Hidden)

            Slider({
              value: this.videoController.currentTime,
              min: 0,
              max: this.videoController.duration,
              style: SliderStyle.OutSet
            })
              .blockSize({ width: (this.sliderHovered || this.sliderFocused) ? 20 : 12, height: (this.sliderHovered || this.sliderFocused) ? 20 : 12 })
              .trackThickness((this.sliderHovered || this.sliderFocused) ? 8 : 4)
              .focusable(true)
              .onChange((value, mode) => {
                this.hoverTimeMs = value
                if (mode === SliderChangeMode.Begin) {
                  clearTimeout(this.closeTimer)
                  this.videoController.pause()
                  this.videoController.currentTime = value
                  this.videoController.seek(value)
                }
                if (mode === SliderChangeMode.Moving) {
                  this.videoController.currentTime = value
                }
                if (mode === SliderChangeMode.End) {
                  this.videoController.seek(value)
                  this.videoController.play().then(() => {
                    this.enableAutoHide(true)
                  })
                }
              })
              .onHover((isHover: boolean, event: HoverEvent) => {
                this.sliderHovered = isHover
                if (isHover && event.x !== undefined) {
                  const x: number = event.x
                  if (this.sliderWidth > 0 && this.videoController.duration > 0) {
                    const ratio = Math.max(0, Math.min(1, x / this.sliderWidth))
                    this.hoverTimeMs = ratio * this.videoController.duration
                  }
                }
              })
              .onMouse((event: MouseEvent) => {
                if (event.action === MouseAction.Move && event.x !== undefined) {
                  this.sliderHovered = true
                  const x: number = event.x
                  if (this.sliderWidth > 0 && this.videoController.duration > 0) {
                    const ratio = Math.max(0, Math.min(1, x / this.sliderWidth))
                    this.hoverTimeMs = ratio * this.videoController.duration
                  }
                }
              })
              .onFocus(() => {
                this.sliderFocused = true
                this.sliderHovered = true
                this.hoverTimeMs = this.videoController.currentTime
              })
              .onBlur(() => {
                this.sliderFocused = false
                this.sliderHovered = false
              })
              .onAreaChange((_oldVal, newVal) => {
                this.sliderWidth = newVal.width as number
              })
              .width('100%')
              .animation({ duration: 200, curve: Curve.EaseInOut })
          }
          .flexGrow(1)
          .alignContent(Alignment.Bottom)
          Text(`${this.videoController.durationDisplay}`)
            .flexShrink(0)
        }
      }
      .alignRules({
        bottom: { anchor: '__container__', align: VerticalAlign.Bottom }
      })
      .linearGradient({
        direction: GradientDirection.Top,
        colors: [['rgba(0, 0, 0, 0.5)', 0.0], ['rgba(0, 0, 0, 0)', 1.0]]
      })
      .height("20%")
      .padding(20)

      // ── 字幕菜单：必须在进度条之后声明，层叠在进度条之上 ──
      if (this.showSubtitleMenu) {
        Column() {
          this.SubtitleMenu()
        }
        .alignRules({
          top: { anchor: '__container__', align: VerticalAlign.Top },
          right: { anchor: '__container__', align: HorizontalAlign.End }
        })
        .margin({ top: 80, right: 20 })
        .width('300vp')
        .onClick(() => {
          // 阻止事件冒泡
        })
      }

      // ── 音轨菜单 ──
      if (this.showAudioMenu) {
        Column() {
          this.AudioMenu()
        }
        .alignRules({
          top: { anchor: '__container__', align: VerticalAlign.Top },
          right: { anchor: '__container__', align: HorizontalAlign.End }
        })
        .margin({ top: 80, right: this.videoController.allSubtitleTracks.length > 0 ? 380 : 20 })
        .width('300vp')
        .onClick(() => {
          // 阻止事件冒泡
        })
      }
    }
    .hitTestBehavior(HitTestMode.Transparent)
    .onClick(async () => {
      await this.videoController.toggle()
      this.enableAutoHide()
    })
  }

  private getActiveSubtitleName(): string {
    const idx = this.videoController.activeSubtitleIndex;
    if (idx < 0) {
      return '字幕';
    }
    const tracks = this.videoController.allSubtitleTracks;
    if (idx < tracks.length) {
      return tracks[idx].displayName;
    }
    return '字幕';
  }

  /** 格式化字幕延迟偏移显示文本，如 "+500ms"、"0ms"、"-100ms" */
  private getDelayLabel(): string {
    const d = this.videoController.subtitleDelayMs;
    if (d === 0) { return '0ms'; }
    return d > 0 ? `+${d}ms` : `${d}ms`;
  }

  private getActiveAudioName(): string {
    const idx = this.videoController.activeAudioIndex;
    if (idx >= 0 && idx < this.videoController.audioTracks.length) {
      const audioTrack = this.videoController.audioTracks[idx];
      // 截断长名称，最多显示 12 个字符
      if (audioTrack.displayName.length > 12) {
        return audioTrack.displayName.substring(0, 12) + '...';
      }
      return audioTrack.displayName;
    }
    return '音轨';
  }

  private dispatchAudioTrackSwitch(index: number): void {
    setTimeout(() => {
      this.videoController.switchAudioTrack(index, true)
    }, 0)
  }

  private enableAutoHide(forceStart: boolean = false): void {
    clearTimeout(this.closeTimer)
    if (forceStart || this.videoController.isPlaying) {
      this.closeTimer = setTimeout(() => {
        this.dialogController.close()
      }, this.AUTO_CLOSE_TIMEOUT)
    }
  }

  aboutToAppear(): void {
    this.enableAutoHide()
    // 加载已下载字幕缓存列表（fire-and-forget，菜单分组仅在 visibleCachedSubtitles.length > 0 时显示）
    this.loadCachedSubtitles()
  }

  aboutToDisappear(): void {
    clearTimeout(this.closeTimer)
    clearTimeout(this.seekTimer)
  }

  private async loadCachedSubtitles(): Promise<void> {
    try {
      const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const filesDir: string = hostCtx.filesDir;
      // SMB 源必须用 stableVideoSrcForCache 避免代理 URL 端口漂移导致 hash 不一致
      const stableVideoSrc = this.videoController.stableVideoSrcForCache;
      this.cachedSubtitles = await subtitleService.listCached({
        filesDir,
        stableVideoSrc,
        sourceType: this.videoController.subtitleSourceType,
        sourceId: this.videoController.subtitleSourceId
      });
      this.visibleCachedSubtitles = this.filterVisibleCached(this.cachedSubtitles);
    } catch {
      this.cachedSubtitles = [];
      this.visibleCachedSubtitles = [];
    }
  }

  /**
   * 剔除 `allSubtitleTracks` 中已展示的缓存条目，避免菜单重复。
   * 匹配规则：缓存条目的 fileName 是否为任一轨道 URL 的后缀（与 SubtitleDispatcher 步骤 4 一致）。
   */
  private filterVisibleCached(cached: CachedSubtitleEntry[]): CachedSubtitleEntry[] {
    const tracks = this.videoController.allSubtitleTracks;
    const filtered: CachedSubtitleEntry[] = [];
    for (let i = 0; i < cached.length; i++) {
      const entry = cached[i];
      const fileName = entry.fileName;
      let existsInTracks = false;
      for (let j = 0; j < tracks.length; j++) {
        const trackUrl = tracks[j].url ?? '';
        if (trackUrl.length > 0 && trackUrl.endsWith(fileName)) {
          existsInTracks = true;
          break;
        }
      }
      if (!existsInTracks) {
        filtered.push(entry);
      }
    }
    return filtered;
  }

  /**
   * 用户点击"已下载字幕"分组中的某条缓存条目。
   *
   * 编排：
   * 1. `subtitleService.enableCached()` 计算本地路径（保持 Module 3 收口）
   * 2. `videoController.addExternalSubtitle()` 挂载
   * 3. `videoController.switchSubtitleTrack()` 自动切换到新轨道
   * 4. `subtitleService.markLastUsed()` 异步写入 lastUsed + 覆盖 disabled binding
   */
  private async enableCachedSubtitle(entry: CachedSubtitleEntry): Promise<void> {
    try {
      const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const filesDir: string = hostCtx.filesDir;
      const stableVideoSrc = this.videoController.stableVideoSrcForCache;
      const sourceType = this.videoController.subtitleSourceType;
      const sourceId = this.videoController.subtitleSourceId;
      const outcome = await subtitleService.enableCached({
        filesDir,
        stableVideoSrc,
        sourceType,
        sourceId,
        fileName: entry.fileName
      });
      const trackCountBeforeAppend = this.videoController.allSubtitleTracks.length;
      await this.videoController.addExternalSubtitle(outcome.localPath);
      if (this.videoController.allSubtitleTracks.length <= trackCountBeforeAppend) {
        throw new Error('缓存字幕未能追加到轨道列表');
      }
      const newIndex = this.videoController.allSubtitleTracks.length - 1;
      await this.videoController.switchSubtitleTrack(newIndex);
      // markLastUsed 写 metadata.lastUsed，fire-and-forget。
      // 关键：覆盖 disabled 标记 → 下次进入同视频，resolveSubtitle 步骤 1 命中 enabled binding 而非 disabled。
      subtitleService.markLastUsed({
        fileName: entry.fileName,
        stableVideoSrc,
        sourceType,
        sourceId,
        filesDir
      }).catch(() => {});
      // addExternalSubtitle 把这条字幕加到了 allSubtitleTracks 末尾，
      // 重算过滤列表让"已下载"分组不再重复展示
      this.visibleCachedSubtitles = this.filterVisibleCached(this.cachedSubtitles);
    } catch (e) {
      const errMsg = (e as Record<string, string>)['message'] ?? JSON.stringify(e);
      console.error(`[SubtitleCache] 启用已下载字幕失败: ${errMsg}`);
    }
  }
}

@CustomDialog
export struct VideoControlsDialog {
  controller: CustomDialogController
  @Require videoController: VideoPlayerController
  @Require onOpenSettings: () => void
  onOpenSubtitleSelector: () => void = () => {}
  @State opacityValue: number = 0;

  aboutToAppear(): void {
    this.getUIContext().animateTo({ duration: 300 }, () => {
      this.opacityValue = 1;
    });
  }

  aboutToDisappear(): void {
    this.controller.close()
  }

  build() {
    VideoControls({
      videoController: this.videoController,
      dialogController: this.controller,
      openSettings: this.onOpenSettings,
      onOpenSubtitleSelector: this.onOpenSubtitleSelector
    })
      .opacity(this.opacityValue)
  }
}

interface AspectRatioOption {
  label: string;
  mode: AspectRatioMode;
}

interface SpeedOption {
  label: string;
  speed: number;
}

interface AutoplayToggleOption {
  label: string;
  enabled: boolean;
}

interface AutoplayCountdownOption {
  label: string;
  seconds: number;
}

const PLAYER_SETTINGS_ASPECT_RATIO_OPTIONS: AspectRatioOption[] = [
  { label: '适应', mode: AspectRatioMode.FIT },
  { label: '填充', mode: AspectRatioMode.FILL },
  { label: '拉伸', mode: AspectRatioMode.STRETCH },
]

const PLAYER_SETTINGS_SPEED_OPTIONS: SpeedOption[] = [
  { label: '0.5x', speed: 0.5 },
  { label: '0.75x', speed: 0.75 },
  { label: '1.0x', speed: 1.0 },
  { label: '1.25x', speed: 1.25 },
  { label: '1.5x', speed: 1.5 },
  { label: '2.0x', speed: 2.0 },
]

const PLAYER_SETTINGS_AUTOPLAY_TOGGLE_OPTIONS: AutoplayToggleOption[] = [
  { label: '开启', enabled: true },
  { label: '关闭', enabled: false },
]

const PLAYER_SETTINGS_AUTOPLAY_COUNTDOWN_OPTIONS: AutoplayCountdownOption[] = [
  { label: '3s', seconds: 3 },
  { label: '5s', seconds: 5 },
  { label: '8s', seconds: 8 },
  { label: '10s', seconds: 10 },
]

const PLAYER_SETTINGS_CHIP_HEIGHT: number = 68
const PLAYER_SETTINGS_CHIP_RADIUS: number = 22
const PLAYER_SETTINGS_CHIP_FONT_SIZE: number = 18
const PLAYER_SETTINGS_CHIP_HORIZONTAL_PADDING: number = 18
const PLAYER_SETTINGS_CHIP_VERTICAL_PADDING: number = 10
const PLAYER_SETTINGS_CHIP_GAP: number = 10
const PLAYER_SETTINGS_CHIP_SCALE_FOCUSED: number = 1.04
const DEFAULT_PLAYBACK_RATE_INDEX: number = 2
const PLAYER_SETTINGS_DIAGNOSTIC_PREFIX: string = '[#player-settings]'
const PLAYER_SETTINGS_DIAGNOSTIC_TAG: string = 'PlayerSettingsDialog'
const PLAYER_SETTINGS_DIAGNOSTIC_LOG_ENABLED: boolean = false

export interface PlayerSettingsChipStyleState {
  isFocused: boolean
  isHovered: boolean
  isSelected: boolean
  // 兼容保留：沿用旧的 outline 语义字段，供已有测试/样式语义判断继续读取。
  // 当前值芯片真实渲染已改为 borderWidth / borderColor，这组字段不再直接驱动 SelectionOptionChip 的边框。
  showFocusOutline: boolean
  showSelectedOutline: boolean
  showWaveIcon: boolean
  scale: number
  shadowRadius: number
  shadowColor: string
  backgroundColor: string
  labelColor: string
  focusBorderWidth: number
  selectedBorderWidth: number
  height: number
  borderRadius: number
  labelFontSize: number
  horizontalPadding: number
  verticalPadding: number
  groupGap: number
  // 当前实际渲染来源：SelectionOptionChip 通过这组真实边框字段输出 UI。
  borderWidth: number
  borderColor: string
}

export interface PlayerSettingsSpeedChipRenderModel {
  label: string
  speed: number
  styleState: PlayerSettingsChipStyleState
}

export interface PlayerSettingsAspectRatioChipRenderModel {
  label: string
  mode: AspectRatioMode
  styleState: PlayerSettingsChipStyleState
}

export interface PlayerSettingsAutoplayToggleChipRenderModel {
  label: string
  enabled: boolean
  styleState: PlayerSettingsChipStyleState
}

export interface PlayerSettingsAutoplayCountdownChipRenderModel {
  label: string
  seconds: number
  styleState: PlayerSettingsChipStyleState
}

export interface PlayerSettingsDiagnosticVisualSnapshot {
  idx: number
  label: string
  roles: string
  styleState: PlayerSettingsChipStyleState
}

export function buildPlayerSettingsSelectionChipKey(optionKey: string, label: string): string {
  return `${optionKey}:${label}`
}

export function buildPlayerSettingsSelectionStateKey(optionKey: string, isSelected: boolean): string {
  return `${optionKey}:${isSelected ? 'selected' : 'not-selected'}`
}

export function getPlayerSettingsChipStyleState(
  isFocused: boolean,
  isSelected: boolean,
  isHovered: boolean = false
): PlayerSettingsChipStyleState {
  const isEmphasized = isFocused || isHovered
  const styleState: PlayerSettingsChipStyleState = {
    isFocused,
    isHovered,
    isSelected,
    showFocusOutline: false,
    showSelectedOutline: false,
    showWaveIcon: false,
    scale: isEmphasized ? PLAYER_SETTINGS_CHIP_SCALE_FOCUSED : 1,
    shadowRadius: isEmphasized ? 12 : 0,
    shadowColor: isEmphasized ? '#386EA8E0' : '#00000000',
    backgroundColor: isSelected ? 'rgba(255, 255, 255, 0.28)' :
      isEmphasized ? 'rgba(255, 255, 255, 0.22)' : 'rgba(255, 255, 255, 0.12)',
    labelColor: isSelected ? '#F9FCFF' : isEmphasized ? '#F3F7FF' : '#E8EDF5',
    focusBorderWidth: 0,
    selectedBorderWidth: 0,
    height: PLAYER_SETTINGS_CHIP_HEIGHT,
    borderRadius: PLAYER_SETTINGS_CHIP_RADIUS,
    labelFontSize: PLAYER_SETTINGS_CHIP_FONT_SIZE,
    horizontalPadding: PLAYER_SETTINGS_CHIP_HORIZONTAL_PADDING,
    verticalPadding: PLAYER_SETTINGS_CHIP_VERTICAL_PADDING,
    groupGap: PLAYER_SETTINGS_CHIP_GAP,
    borderWidth: 0,
    borderColor: '#00000000'
  }
  return styleState
}

export function getPlayerSettingsValueChipStyleState(
  isFocused: boolean,
  isSelected: boolean,
  isHovered: boolean = false
): PlayerSettingsChipStyleState {
  const isEmphasized = isFocused || isHovered
  const scale = isSelected ? 1.05 :
    isFocused ? PLAYER_SETTINGS_CHIP_SCALE_FOCUSED :
    isHovered ? 1.02 : 1
  const borderWidth = isSelected || isEmphasized ? 2 : 1
  const shadowRadius = isSelected ? 14 : isFocused ? 12 : isHovered ? 8 : 0
  const shadowColor = isSelected ? '#33597FB8' :
    isFocused ? '#386EA8E0' :
    isHovered ? '#2A6EA8E0' : '#00000000'
  const styleState: PlayerSettingsChipStyleState = {
    isFocused,
    isHovered,
    isSelected,
    showFocusOutline: false,
    showSelectedOutline: false,
    showWaveIcon: false,
    scale,
    shadowRadius,
    shadowColor,
    backgroundColor: isSelected ? 'rgba(255, 255, 255, 0.45)' :
      isEmphasized ? 'rgba(255, 255, 255, 0.18)' : 'rgba(255, 255, 255, 0.1)',
    labelColor: isSelected ? '#F3F7FF' : isEmphasized ? '#EFF2FB' : '#D7DCE7',
    // 兼容保留：旧测试和语义判断仍读取 focusBorderWidth / selectedBorderWidth。
    // 当前值芯片的真实边框渲染以下方 borderWidth / borderColor 为准。
    focusBorderWidth: isSelected ? 0 : isEmphasized ? 2 : 0,
    selectedBorderWidth: isSelected ? 2 : 0,
    height: PLAYER_SETTINGS_CHIP_HEIGHT,
    borderRadius: PLAYER_SETTINGS_CHIP_RADIUS,
    labelFontSize: PLAYER_SETTINGS_CHIP_FONT_SIZE,
    horizontalPadding: PLAYER_SETTINGS_CHIP_HORIZONTAL_PADDING,
    verticalPadding: PLAYER_SETTINGS_CHIP_VERTICAL_PADDING,
    groupGap: PLAYER_SETTINGS_CHIP_GAP,
    borderWidth,
    borderColor: isSelected ? '#fffefe' : isEmphasized ? '#66A9D8FF' : '#45ffffff'
  }
  return styleState
}

function getPlayerSettingsAutoplayChipStyleState(
  isFocused: boolean,
  isSelected: boolean,
  isHovered: boolean = false
): PlayerSettingsChipStyleState {
  if (isSelected) {
    return getPlayerSettingsValueChipStyleState(isFocused, true, isHovered)
  }
  if (isFocused || isHovered) {
    return getPlayerSettingsChipStyleState(isFocused, false, isHovered)
  }
  return getPlayerSettingsValueChipStyleState(false, false, false)
}

export function buildPlaybackSpeedChipRenderModels(
  playbackSpeed: number,
  focusedIndex: number = -1,
  hoveredIndex: number = -1
): PlayerSettingsSpeedChipRenderModel[] {
  const renderModels: PlayerSettingsSpeedChipRenderModel[] = []
  const selectedIndex = resolveSelectedPlaybackRateIndex(playbackSpeed)
  for (let idx = 0; idx < PLAYER_SETTINGS_SPEED_OPTIONS.length; idx++) {
    const option = PLAYER_SETTINGS_SPEED_OPTIONS[idx]
    const isSelected = selectedIndex === idx
    const styleState = getPlayerSettingsValueChipStyleState(
      focusedIndex === idx,
      isSelected,
      hoveredIndex === idx
    )
    const renderModel: PlayerSettingsSpeedChipRenderModel = {
      label: option.label,
      speed: option.speed,
      styleState
    }
    renderModels.push(renderModel)
  }
  return renderModels
}

export function buildAspectRatioChipRenderModels(
  currentMode: AspectRatioMode,
  focusedIndex: number = -1,
  hoveredIndex: number = -1
): PlayerSettingsAspectRatioChipRenderModel[] {
  const renderModels: PlayerSettingsAspectRatioChipRenderModel[] = []
  for (let idx = 0; idx < PLAYER_SETTINGS_ASPECT_RATIO_OPTIONS.length; idx++) {
    const option = PLAYER_SETTINGS_ASPECT_RATIO_OPTIONS[idx]
    const isSelected = isAspectRatioOptionSelected(currentMode, option.mode)
    const styleState = getPlayerSettingsValueChipStyleState(
      focusedIndex === idx,
      isSelected,
      hoveredIndex === idx
    )
    const renderModel: PlayerSettingsAspectRatioChipRenderModel = {
      label: option.label,
      mode: option.mode,
      styleState
    }
    renderModels.push(renderModel)
  }
  return renderModels
}

export function buildAutoplayToggleChipRenderModels(
  autoplayEnabled: boolean,
  focusedIndex: number = -1,
  hoveredIndex: number = -1
): PlayerSettingsAutoplayToggleChipRenderModel[] {
  const renderModels: PlayerSettingsAutoplayToggleChipRenderModel[] = []
  for (let idx = 0; idx < PLAYER_SETTINGS_AUTOPLAY_TOGGLE_OPTIONS.length; idx++) {
    const option = PLAYER_SETTINGS_AUTOPLAY_TOGGLE_OPTIONS[idx]
    const styleState = getPlayerSettingsAutoplayChipStyleState(
      focusedIndex === idx,
      autoplayEnabled === option.enabled,
      hoveredIndex === idx
    )
    const renderModel: PlayerSettingsAutoplayToggleChipRenderModel = {
      label: option.label,
      enabled: option.enabled,
      styleState
    }
    renderModels.push(renderModel)
  }
  return renderModels
}

export function buildAutoplayCountdownChipRenderModels(
  autoplayCountdownSeconds: number,
  focusedIndex: number = -1,
  hoveredIndex: number = -1
): PlayerSettingsAutoplayCountdownChipRenderModel[] {
  const renderModels: PlayerSettingsAutoplayCountdownChipRenderModel[] = []
  for (let idx = 0; idx < PLAYER_SETTINGS_AUTOPLAY_COUNTDOWN_OPTIONS.length; idx++) {
    const option = PLAYER_SETTINGS_AUTOPLAY_COUNTDOWN_OPTIONS[idx]
    const styleState = getPlayerSettingsAutoplayChipStyleState(
      focusedIndex === idx,
      autoplayCountdownSeconds === option.seconds,
      hoveredIndex === idx
    )
    const renderModel: PlayerSettingsAutoplayCountdownChipRenderModel = {
      label: option.label,
      seconds: option.seconds,
      styleState
    }
    renderModels.push(renderModel)
  }
  return renderModels
}

export function resolveSelectedPlaybackRateIndex(playbackSpeed: number): number {
  switch (playbackSpeed) {
    case 0.5:
      return 0
    case 0.75:
      return 1
    case 1.0:
      return 2
    case 1.25:
      return 3
    case 1.5:
      return 4
    case 2.0:
      return 5
    default:
      return DEFAULT_PLAYBACK_RATE_INDEX
  }
}

export function isAspectRatioOptionSelected(
  currentMode: AspectRatioMode,
  optionMode: AspectRatioMode
): boolean {
  return currentMode === optionMode
}

export interface PlayerSettingsSelectionMirrorState {
  playbackSpeed: number
  aspectRatioMode: AspectRatioMode
}

export function createPlayerSettingsSelectionMirrorState(
  playbackSpeed: number,
  aspectRatioMode: AspectRatioMode
): PlayerSettingsSelectionMirrorState {
  const mirrorState: PlayerSettingsSelectionMirrorState = {
    playbackSpeed,
    aspectRatioMode
  }
  return mirrorState
}

export function syncPlayerSettingsSelectionMirrorState(
  currentState: PlayerSettingsSelectionMirrorState,
  playbackSpeed: number,
  aspectRatioMode: AspectRatioMode
): PlayerSettingsSelectionMirrorState {
  if (currentState.playbackSpeed === playbackSpeed && currentState.aspectRatioMode === aspectRatioMode) {
    return currentState
  }
  const nextState: PlayerSettingsSelectionMirrorState = {
    playbackSpeed,
    aspectRatioMode
  }
  return nextState
}

export function shouldApplyEpisodeAutoplaySettingsLoad(
  requestToken: number,
  currentToken: number,
  isDirty: boolean
): boolean {
  return requestToken === currentToken && !isDirty
}

export function formatPlayerSettingsDiagnosticLog(scope: string, detail: string): string {
  return `${PLAYER_SETTINGS_DIAGNOSTIC_PREFIX} ${scope}: ${detail}`
}

export function formatPlayerSettingsVisualSnapshotDetail(
  group: string,
  snapshot: PlayerSettingsDiagnosticVisualSnapshot
): string {
  return `group=${group} idx=${snapshot.idx} label=${snapshot.label} roles=${snapshot.roles} ` +
    `isSelected=${snapshot.styleState.isSelected} isHovered=${snapshot.styleState.isHovered} ` +
    `isFocused=${snapshot.styleState.isFocused} backgroundColor=${snapshot.styleState.backgroundColor} ` +
    `borderWidth=${snapshot.styleState.borderWidth} borderColor=${snapshot.styleState.borderColor} ` +
    `shadowRadius=${snapshot.styleState.shadowRadius} shadowColor=${snapshot.styleState.shadowColor} ` +
    `scale=${snapshot.styleState.scale} labelColor=${snapshot.styleState.labelColor}`
}

export function buildPlayerSettingsVisualSnapshotSummary(
  group: string,
  snapshots: Array<PlayerSettingsDiagnosticVisualSnapshot>
): string {
  const details: Array<string> = []
  for (let idx = 0; idx < snapshots.length; idx++) {
    details.push(formatPlayerSettingsVisualSnapshotDetail(group, snapshots[idx]))
  }
  return details.join(' || ')
}

export function formatPlayerSettingsEventSequenceDetail(
  eventType: string,
  idx: number,
  label: string,
  nextState: string,
  focusedIndex: number,
  hoveredIndex: number,
  selectedIndex: number
): string {
  return `eventType=${eventType} idx=${idx} label=${label} next=${nextState} ` +
    `focusedIndex=${focusedIndex} hoveredIndex=${hoveredIndex} selectedIndex=${selectedIndex}`
}

@CustomDialog
export struct PlayerSettingsDialog {
  controller: CustomDialogController
  @Require videoController: VideoPlayerController
  @Require onOpenSubtitleSelector: () => void
  @Require onEpisodeSelect: (item: PlaybackContextItem) => Promise<boolean>
  @State private mirroredPlaybackSpeed: number = 1.0
  @State private mirroredAspectRatioMode: AspectRatioMode = AspectRatioMode.FIT
  @State private arFocusedIndex: number = -1
  @State private speedFocusedIndex: number = -1
  @State private arHoveredIndex: number = -1
  @State private speedHoveredIndex: number = -1
  private readonly aspectRatioOptions: AspectRatioOption[] = PLAYER_SETTINGS_ASPECT_RATIO_OPTIONS
  @State private aiEnhanceOn: boolean = true
  @State private aiEnhanceQuality: VpeQualityLevel = 'medium'
  @State private autoplayEnabled: boolean = true
  @State private autoplayCountdownSeconds: number = 8
  @State private autoplayToggleFocusedIndex: number = -1
  @State private autoplayCountdownFocusedIndex: number = -1
  @State private autoplayToggleHoveredIndex: number = -1
  @State private autoplayCountdownHoveredIndex: number = -1
  private readonly autoplayToggleOptions: Array<boolean> = [true, false]
  private readonly autoplayCountdownOptions: Array<number> = [3, 5, 8, 10]
  private autoplaySettingsLoadToken: number = 0
  private autoplaySettingsDirty: boolean = false

  private logPlayerSettingsDiagnostic(scope: string, detail: string): void {
    if (!PLAYER_SETTINGS_DIAGNOSTIC_LOG_ENABLED) {
      return
    }
    hilog.debug(0x0000, PLAYER_SETTINGS_DIAGNOSTIC_TAG, formatPlayerSettingsDiagnosticLog(scope, detail))
  }

  private resolveAspectRatioSelectedIndex(mode: AspectRatioMode): number {
    for (let idx = 0; idx < this.aspectRatioOptions.length; idx++) {
      if (isAspectRatioOptionSelected(mode, this.aspectRatioOptions[idx].mode)) {
        return idx
      }
    }
    return -1
  }

  private logSpeedInteractionEvent(eventType: string, idx: number, label: string, nextState: string): void {
    this.logPlayerSettingsDiagnostic(
      'interaction/speed',
      formatPlayerSettingsEventSequenceDetail(
        eventType,
        idx,
        label,
        nextState,
        this.speedFocusedIndex,
        this.speedHoveredIndex,
        resolveSelectedPlaybackRateIndex(this.mirroredPlaybackSpeed)
      )
    )
  }

  private logAspectRatioInteractionEvent(eventType: string, idx: number, label: string, nextState: string): void {
    this.logPlayerSettingsDiagnostic(
      'interaction/aspect-ratio',
      formatPlayerSettingsEventSequenceDetail(
        eventType,
        idx,
        label,
        nextState,
        this.arFocusedIndex,
        this.arHoveredIndex,
        this.resolveAspectRatioSelectedIndex(this.mirroredAspectRatioMode)
      )
    )
  }

  private applySelectionMirrorState(state: PlayerSettingsSelectionMirrorState): void {
    const beforePlaybackSpeed = this.mirroredPlaybackSpeed
    const beforeAspectRatioMode = this.mirroredAspectRatioMode
    this.logPlayerSettingsDiagnostic(
      'state/applySelectionMirrorState-before',
      `playbackSpeed=${beforePlaybackSpeed} aspectRatioMode=${beforeAspectRatioMode} nextPlaybackSpeed=${state.playbackSpeed} nextAspectRatioMode=${state.aspectRatioMode}`
    )
    this.mirroredPlaybackSpeed = state.playbackSpeed
    this.mirroredAspectRatioMode = state.aspectRatioMode
    this.logPlayerSettingsDiagnostic(
      'state/applySelectionMirrorState-after',
      `playbackSpeed=${this.mirroredPlaybackSpeed} aspectRatioMode=${this.mirroredAspectRatioMode}`
    )
  }

  private syncSelectionMirrorState(): void {
    const currentState: PlayerSettingsSelectionMirrorState = createPlayerSettingsSelectionMirrorState(
      this.mirroredPlaybackSpeed,
      this.mirroredAspectRatioMode
    )
    const nextState: PlayerSettingsSelectionMirrorState = syncPlayerSettingsSelectionMirrorState(
      currentState,
      this.videoController.playbackSpeed,
      this.videoController.aspectRatioMode
    )
    this.applySelectionMirrorState(nextState)
  }

  private updatePlaybackSpeedSelection(speed: number): void {
    this.logPlayerSettingsDiagnostic(
      'state/updatePlaybackSpeedSelection-enter',
      `targetSpeed=${speed} beforePlaybackSpeed=${this.mirroredPlaybackSpeed} beforeAspectRatioMode=${this.mirroredAspectRatioMode}`
    )
    const currentState: PlayerSettingsSelectionMirrorState = createPlayerSettingsSelectionMirrorState(
      this.mirroredPlaybackSpeed,
      this.mirroredAspectRatioMode
    )
    const nextState: PlayerSettingsSelectionMirrorState = syncPlayerSettingsSelectionMirrorState(
      currentState,
      speed,
      this.mirroredAspectRatioMode
    )
    this.applySelectionMirrorState(nextState)
    this.logPlayerSettingsDiagnostic(
      'state/updatePlaybackSpeedSelection-after',
      `afterPlaybackSpeed=${this.mirroredPlaybackSpeed} afterAspectRatioMode=${this.mirroredAspectRatioMode}`
    )
    this.videoController.setPlaybackSpeed(speed)
  }

  private updateAspectRatioSelection(mode: AspectRatioMode): void {
    this.logPlayerSettingsDiagnostic(
      'state/updateAspectRatioSelection-enter',
      `targetAspectRatioMode=${mode} beforePlaybackSpeed=${this.mirroredPlaybackSpeed} beforeAspectRatioMode=${this.mirroredAspectRatioMode}`
    )
    const currentState: PlayerSettingsSelectionMirrorState = createPlayerSettingsSelectionMirrorState(
      this.mirroredPlaybackSpeed,
      this.mirroredAspectRatioMode
    )
    const nextState: PlayerSettingsSelectionMirrorState = syncPlayerSettingsSelectionMirrorState(
      currentState,
      this.mirroredPlaybackSpeed,
      mode
    )
    this.applySelectionMirrorState(nextState)
    this.logPlayerSettingsDiagnostic(
      'state/updateAspectRatioSelection-after',
      `afterPlaybackSpeed=${this.mirroredPlaybackSpeed} afterAspectRatioMode=${this.mirroredAspectRatioMode}`
    )
    this.videoController.setAspectRatioMode(mode)
  }

  aboutToAppear(): void {
    this.syncSelectionMirrorState()
    this.aiEnhanceOn = this.videoController.getResolvedAiEnhanceEnabled();
    this.aiEnhanceQuality = this.videoController.aiEnhanceQuality;
    this.arFocusedIndex = -1;
    this.speedFocusedIndex = -1;
    this.arHoveredIndex = -1;
    this.speedHoveredIndex = -1;
    this.autoplayToggleFocusedIndex = -1;
    this.autoplayCountdownFocusedIndex = -1;
    this.autoplayToggleHoveredIndex = -1;
    this.autoplayCountdownHoveredIndex = -1;
    this.autoplayEnabled = this.videoController.episodeAutoplayEnabled;
    this.autoplayCountdownSeconds = this.videoController.episodeAutoplayCountdownSeconds;
    this.autoplaySettingsDirty = false
    this.autoplaySettingsLoadToken += 1
    const currentLoadToken = this.autoplaySettingsLoadToken
    loadEpisodeAutoplaySettings().then((settings) => {
      if (!shouldApplyEpisodeAutoplaySettingsLoad(
        currentLoadToken,
        this.autoplaySettingsLoadToken,
        this.autoplaySettingsDirty
      )) {
        return
      }
      this.autoplayEnabled = settings.enabled;
      this.autoplayCountdownSeconds = settings.countdownSeconds;
      this.videoController.episodeAutoplayEnabled = settings.enabled;
      this.videoController.episodeAutoplayCountdownSeconds = settings.countdownSeconds;
    }).catch(() => {})
  }

  aboutToDisappear(): void {
    this.arFocusedIndex = -1;
    this.speedFocusedIndex = -1;
    this.arHoveredIndex = -1;
    this.speedHoveredIndex = -1;
    this.autoplayToggleFocusedIndex = -1;
    this.autoplayCountdownFocusedIndex = -1;
    this.autoplayToggleHoveredIndex = -1;
    this.autoplayCountdownHoveredIndex = -1;
  }

  /** 当 playbackContext 是媒体库上下文时返回，否则返回 undefined */
  private getMediaLibraryContext(): MediaLibraryContext | undefined {
    const ctx = this.videoController.playbackContext
    if (ctx !== undefined && ctx.contextType === 'media_library') {
      return ctx as MediaLibraryContext
    }
    return undefined
  }

  @Builder
  private SettingsChip(label: string, selected: boolean) {
    Text(label)
      .fontSize(26)
      .fontColor(selected ? '#F3F7FF' : '#D7DCE7')
      .padding({ left: 20, right: 20, top: 10, bottom: 10 })
      .backgroundColor(selected ? 'rgba(255, 255, 255, 0.45)' : 'rgba(255, 255, 255, 0.1)')
      .borderRadius("50%")
      .border({ width: selected ? 2 : 1, color: selected ? '#fffefe' : '#45ffffff' })
      .shadow({ radius: selected ? 8 : 0, color: selected ? '#33597FB8' : '#00ffffff' })
  }

  @Builder
  private SelectionOptionChip(label: string, styleState: PlayerSettingsChipStyleState) {
    Row() {
      Text(label)
        .fontSize(styleState.labelFontSize)
        .fontColor(styleState.labelColor)
        .fontWeight(styleState.isSelected ? FontWeight.Medium : FontWeight.Regular)
        .maxLines(1)
    }
    .height(styleState.height)
    .padding({ left: styleState.horizontalPadding, right: styleState.horizontalPadding })
    .justifyContent(FlexAlign.Center)
    .backgroundColor(styleState.backgroundColor)
    .border({ width: styleState.borderWidth, color: styleState.borderColor })
    .borderRadius(styleState.borderRadius)
    .shadow({ radius: styleState.shadowRadius, color: styleState.shadowColor })
    .scale({ x: styleState.scale, y: styleState.scale })
    .animation({ duration: 180, curve: Curve.EaseInOut })
  }

  private getSpeedChipRenderModels(): PlayerSettingsSpeedChipRenderModel[] {
    return buildPlaybackSpeedChipRenderModels(
      this.mirroredPlaybackSpeed,
      this.speedFocusedIndex,
      this.speedHoveredIndex
    )
  }

  private getAspectRatioChipRenderModels(): PlayerSettingsAspectRatioChipRenderModel[] {
    return buildAspectRatioChipRenderModels(
      this.mirroredAspectRatioMode,
      this.arFocusedIndex,
      this.arHoveredIndex
    )
  }

  private getAutoplayToggleChipStyleState(idx: number): PlayerSettingsChipStyleState {
    return getPlayerSettingsAutoplayChipStyleState(
      this.autoplayToggleFocusedIndex === idx,
      this.autoplayEnabled === this.autoplayToggleOptions[idx],
      this.autoplayToggleHoveredIndex === idx
    )
  }

  private getAutoplayCountdownChipStyleState(idx: number): PlayerSettingsChipStyleState {
    return getPlayerSettingsAutoplayChipStyleState(
      this.autoplayCountdownFocusedIndex === idx,
      this.autoplayCountdownSeconds === this.autoplayCountdownOptions[idx],
      this.autoplayCountdownHoveredIndex === idx
    )
  }

  private updateEpisodeAutoplayEnabled(enabled: boolean): void {
    this.autoplaySettingsDirty = true
    this.autoplayEnabled = enabled
    this.videoController.episodeAutoplayEnabled = enabled
    saveEpisodeAutoplayEnabled(enabled).catch(() => {})
  }

  private updateEpisodeAutoplayCountdownSeconds(seconds: number): void {
    this.autoplaySettingsDirty = true
    this.autoplayCountdownSeconds = seconds
    this.videoController.episodeAutoplayCountdownSeconds = seconds
    saveEpisodeAutoplayCountdownSeconds(seconds).catch(() => {})
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)

      Scroll() {
        Column({ space: 0 }) {
          // ── 选集/文件列表区域（有播放上下文时显示）────────────────────────
          if (this.videoController.playbackContext !== undefined) {
            EpisodeListPanel({
              context: this.videoController.playbackContext as PlaybackContext,
              onSelect: (item: PlaybackContextItem) => {
                this.onEpisodeSelect(item).then((didSwitch: boolean) => {
                  if (didSwitch) {
                    this.controller.close()
                  }
                }).catch(() => {})
              }
            })
          }

          // ── 倍速播放 & 其他设置 ─────────────────────────────────────────────
          Column({ space: 28 }) {
            Column({ space: 12 }) {
              Text('倍速播放')
                .fontSize(32)
                .fontColor('#EFF2FB')
                .fontWeight(FontWeight.Medium)
                .alignSelf(ItemAlign.Start)

              Row({ space: PLAYER_SETTINGS_CHIP_GAP }) {
                ForEach(this.getSpeedChipRenderModels(), (model: PlayerSettingsSpeedChipRenderModel, idx: number) => {
                  Row() {
                    Text(model.label)
                      .fontSize(model.styleState.labelFontSize)
                      .fontColor(model.styleState.labelColor)
                      .fontWeight(model.styleState.isSelected ? FontWeight.Medium : FontWeight.Regular)
                      .maxLines(1)
                  }
                    .height(model.styleState.height)
                    .padding({
                      left: model.styleState.horizontalPadding,
                      right: model.styleState.horizontalPadding
                    })
                    .justifyContent(FlexAlign.Center)
                    .backgroundColor(model.styleState.backgroundColor)
                    .border({ width: model.styleState.borderWidth, color: model.styleState.borderColor })
                    .borderRadius(model.styleState.borderRadius)
                    .shadow({ radius: model.styleState.shadowRadius, color: model.styleState.shadowColor })
                    .scale({ x: model.styleState.scale, y: model.styleState.scale })
                    .animation({ duration: 180, curve: Curve.EaseInOut })
                    .focusable(true)
                    .onFocus(() => {
                      this.speedFocusedIndex = idx
                      this.logSpeedInteractionEvent('focus', idx, model.label, `focusedIndex=${idx}`)
                    })
                    .onBlur(() => {
                      this.speedFocusedIndex = -1
                      this.logSpeedInteractionEvent('blur', idx, model.label, 'focusedIndex=-1')
                    })
                    .onHover((isHover: boolean) => {
                      this.speedHoveredIndex = isHover ? idx : -1
                      this.logSpeedInteractionEvent(
                        'hover',
                        idx,
                        model.label,
                        `hoveredIndex=${this.speedHoveredIndex}`
                      )
                    })
                     .onClick(() => {
                       this.logSpeedInteractionEvent('click', idx, model.label, `requestedSpeed=${model.speed}`)
                       this.updatePlaybackSpeedSelection(model.speed)
                     })
                }, (model: PlayerSettingsSpeedChipRenderModel) =>
                  buildPlayerSettingsSelectionStateKey(model.speed.toString(), model.styleState.isSelected))
              }
               .justifyContent(FlexAlign.Start)
               .width('100%')
              }


            Column({ space: 12 }) {
              Text('画面比例')
                .fontSize(32)
                .fontColor('#EFF2FB')
                .fontWeight(FontWeight.Medium)
                .alignSelf(ItemAlign.Start)

              Row({ space: PLAYER_SETTINGS_CHIP_GAP }) {
                ForEach(this.getAspectRatioChipRenderModels(), (model: PlayerSettingsAspectRatioChipRenderModel, idx: number) => {
                  Row() {
                    Text(model.label)
                      .fontSize(model.styleState.labelFontSize)
                      .fontColor(model.styleState.labelColor)
                      .fontWeight(model.styleState.isSelected ? FontWeight.Medium : FontWeight.Regular)
                      .maxLines(1)
                  }
                    .height(model.styleState.height)
                    .padding({
                      left: model.styleState.horizontalPadding,
                      right: model.styleState.horizontalPadding
                    })
                    .justifyContent(FlexAlign.Center)
                    .backgroundColor(model.styleState.backgroundColor)
                    .border({ width: model.styleState.borderWidth, color: model.styleState.borderColor })
                    .borderRadius(model.styleState.borderRadius)
                    .shadow({ radius: model.styleState.shadowRadius, color: model.styleState.shadowColor })
                    .scale({ x: model.styleState.scale, y: model.styleState.scale })
                    .animation({ duration: 180, curve: Curve.EaseInOut })
                    .focusable(true)
                    .onFocus(() => {
                      this.arFocusedIndex = idx
                      this.logAspectRatioInteractionEvent('focus', idx, model.label, `focusedIndex=${idx}`)
                    })
                    .onBlur(() => {
                      this.arFocusedIndex = -1
                      this.logAspectRatioInteractionEvent('blur', idx, model.label, 'focusedIndex=-1')
                    })
                    .onHover((isHover: boolean) => {
                      this.arHoveredIndex = isHover ? idx : -1
                      this.logAspectRatioInteractionEvent(
                        'hover',
                        idx,
                        model.label,
                        `hoveredIndex=${this.arHoveredIndex}`
                      )
                    })
                     .onClick(() => {
                       this.logAspectRatioInteractionEvent(
                         'click',
                         idx,
                         model.label,
                        `requestedAspectRatioMode=${model.mode}`
                       )
                       this.updateAspectRatioSelection(model.mode)
                     })
                }, (model: PlayerSettingsAspectRatioChipRenderModel) =>
                  buildPlayerSettingsSelectionStateKey(model.mode.toString(), model.styleState.isSelected))
              }
               .justifyContent(FlexAlign.Start)
               .width('100%')
              }

            Column({ space: 12 }) {
              Text('字幕管理')
                .fontSize(32)
                .fontColor('#EFF2FB')
                .fontWeight(FontWeight.Medium)
                .alignSelf(ItemAlign.Start)

              Row() {
                this.SettingsChip('选择字幕', this.videoController.activeSubtitleIndex >= 0)
              }
              .onClick(() => {
                this.onOpenSubtitleSelector()
              })
            }

            if (this.videoController.playbackContext !== undefined) {
              Column({ space: 12 }) {
                Text('自动下一集')
                  .fontSize(32)
                  .fontColor('#EFF2FB')
                  .fontWeight(FontWeight.Medium)
                  .alignSelf(ItemAlign.Start)

                Row({ space: PLAYER_SETTINGS_CHIP_GAP }) {
                  ForEach(this.autoplayToggleOptions, (enabled: boolean, idx: number) => {
                    Row() {
                      this.SelectionOptionChip(enabled ? '开启' : '关闭', this.getAutoplayToggleChipStyleState(idx))
                    }
                    .focusable(true)
                    .onFocus(() => { this.autoplayToggleFocusedIndex = idx })
                    .onBlur(() => { this.autoplayToggleFocusedIndex = -1 })
                    .onHover((isHover: boolean) => {
                      this.autoplayToggleHoveredIndex = isHover ? idx : -1
                    })
                    .onClick(() => {
                      this.updateEpisodeAutoplayEnabled(enabled)
                    })
                  }, (enabled: boolean) => buildPlayerSettingsSelectionStateKey(
                    enabled ? 'enabled' : 'disabled',
                    this.autoplayEnabled === enabled
                  ))
                }
                .justifyContent(FlexAlign.Start)
                .width('100%')
              }

              Column({ space: 12 }) {
                Text('倒计时秒数')
                  .fontSize(32)
                  .fontColor('#EFF2FB')
                  .fontWeight(FontWeight.Medium)
                  .alignSelf(ItemAlign.Start)

                Row({ space: PLAYER_SETTINGS_CHIP_GAP }) {
                  ForEach(this.autoplayCountdownOptions, (seconds: number, idx: number) => {
                    Row() {
                      this.SelectionOptionChip(`${seconds}s`, this.getAutoplayCountdownChipStyleState(idx))
                    }
                    .focusable(true)
                    .onFocus(() => { this.autoplayCountdownFocusedIndex = idx })
                    .onBlur(() => { this.autoplayCountdownFocusedIndex = -1 })
                    .onHover((isHover: boolean) => {
                      this.autoplayCountdownHoveredIndex = isHover ? idx : -1
                    })
                    .onClick(() => {
                      this.updateEpisodeAutoplayCountdownSeconds(seconds)
                    })
                  }, (seconds: number) => buildPlayerSettingsSelectionStateKey(
                    seconds.toString(),
                    this.autoplayCountdownSeconds === seconds
                  ))
                }
                .justifyContent(FlexAlign.Start)
                .width('100%')
              }
            }

            if (this.videoController.shouldShowAiEnhanceSettings()) {
              Column({ space: 12 }) {
                Text('画质增强')
                  .fontSize(32)
                  .fontColor('#EFF2FB')
                  .fontWeight(FontWeight.Medium)
                  .alignSelf(ItemAlign.Start)

                Row({ space: 12 }) {
                  // 直接内联 Text + onClick，绕过 @CustomDialog @Builder 参数不刷新问题
                  Text('关闭')
                    .fontSize(26)
                    .fontColor(!this.aiEnhanceOn ? '#F3F7FF' : '#D7DCE7')
                    .padding({ left: 20, right: 20, top: 10, bottom: 10 })
                    .backgroundColor(!this.aiEnhanceOn ? 'rgba(255, 255, 255, 0.45)' : 'rgba(255, 255, 255, 0.1)')
                    .borderRadius(99)
                    .border({ width: !this.aiEnhanceOn ? 2 : 1, color: !this.aiEnhanceOn ? '#fffefe' : '#45ffffff' })
                    .onClick(() => {
                      hilog.info(0x0000, 'PlayerSettingsDialog', '画质增强: 点击关闭');
                      this.aiEnhanceOn = false;
                      this.videoController.disableAiEnhance();
                    })

                  Text('低')
                    .fontSize(26)
                    .fontColor(this.aiEnhanceOn && this.aiEnhanceQuality === 'low' ? '#F3F7FF' : '#D7DCE7')
                    .padding({ left: 20, right: 20, top: 10, bottom: 10 })
                    .backgroundColor(this.aiEnhanceOn && this.aiEnhanceQuality === 'low' ? 'rgba(255, 255, 255, 0.45)' : 'rgba(255, 255, 255, 0.1)')
                    .borderRadius(99)
                    .border({ width: this.aiEnhanceOn && this.aiEnhanceQuality === 'low' ? 2 : 1, color: this.aiEnhanceOn && this.aiEnhanceQuality === 'low' ? '#fffefe' : '#45ffffff' })
                    .onClick(() => {
                      hilog.info(0x0000, 'PlayerSettingsDialog', '画质增强: 点击低');
                      this.aiEnhanceOn = true;
                      this.aiEnhanceQuality = 'low';
                      this.videoController.setAiEnhance('low');
                    })

                  Text('中')
                    .fontSize(26)
                    .fontColor(this.aiEnhanceOn && this.aiEnhanceQuality === 'medium' ? '#F3F7FF' : '#D7DCE7')
                    .padding({ left: 20, right: 20, top: 10, bottom: 10 })
                    .backgroundColor(this.aiEnhanceOn && this.aiEnhanceQuality === 'medium' ? 'rgba(255, 255, 255, 0.45)' : 'rgba(255, 255, 255, 0.1)')
                    .borderRadius(99)
                    .border({ width: this.aiEnhanceOn && this.aiEnhanceQuality === 'medium' ? 2 : 1, color: this.aiEnhanceOn && this.aiEnhanceQuality === 'medium' ? '#fffefe' : '#45ffffff' })
                    .onClick(() => {
                      hilog.info(0x0000, 'PlayerSettingsDialog', '画质增强: 点击中');
                      this.aiEnhanceOn = true;
                      this.aiEnhanceQuality = 'medium';
                      this.videoController.setAiEnhance('medium');
                    })

                  Text('高')
                    .fontSize(26)
                    .fontColor(this.aiEnhanceOn && this.aiEnhanceQuality === 'high' ? '#F3F7FF' : '#D7DCE7')
                    .padding({ left: 20, right: 20, top: 10, bottom: 10 })
                    .backgroundColor(this.aiEnhanceOn && this.aiEnhanceQuality === 'high' ? 'rgba(255, 255, 255, 0.45)' : 'rgba(255, 255, 255, 0.1)')
                    .borderRadius(99)
                    .border({ width: this.aiEnhanceOn && this.aiEnhanceQuality === 'high' ? 2 : 1, color: this.aiEnhanceOn && this.aiEnhanceQuality === 'high' ? '#fffefe' : '#45ffffff' })
                    .onClick(() => {
                      hilog.info(0x0000, 'PlayerSettingsDialog', '画质增强: 点击高');
                      this.aiEnhanceOn = true;
                      this.aiEnhanceQuality = 'high';
                      this.videoController.setAiEnhance('high');
                    })
                }
                .justifyContent(FlexAlign.Start)
                .width('100%')
              }
            }
          }
          .padding({ left: 26, right: 26, top: 18, bottom: 28 })
          .alignItems(HorizontalAlign.Start)
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('55%')
      .backgroundColor(Color.Transparent)
      .borderRadius({ topLeft: 24, topRight: 24 })
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_ONLY, scrollBackward: NestedScrollMode.SELF_ONLY })
    }
    .width('100%')
    .height('100%')
  }
}

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
  /** 正在下载的条目 fileId（用于 UI 高亮） */
  @State downloadingFileId: number = -1

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

  /** 显示 Toast 提示 */
  private showSearchToast(message: string, duration: number): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: duration })
    } catch (_e) {}
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

      const snapshot = await loadSubtitleSearchPreferenceSnapshot()
      const languages = snapshot.languagesParam

      console.info(`[SubtitleSearch] 搜索词: "${query}", 语言: "${languages}", 年份: ${searchYear}, 季: ${searchSeason}, 集: ${searchEpisode}, tmdbId: ${searchTmdbId ?? 'none'}`)

      // 搜索词构造仍属 UI 编排（刮削优先 vs 文件名回退），实际检索委托给 service。
      const results = await subtitleService.search({
        query,
        languages,
        year: searchYear,
        seasonNumber: searchSeason,
        episodeNumber: searchEpisode,
        mediaType: searchMediaType,
        tmdbId: searchTmdbId
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
    this.downloadingFileId = result.fileId

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

      this.showSearchToast('字幕下载成功', 2000)
      console.info(`[SubtitleSearch] 字幕已写入: ${downloadOutcome.localPath}`)

      const trackCountBeforeAppend = this.videoController.allSubtitleTracks.length
      await this.videoController.addExternalSubtitle(downloadOutcome.localPath)
      if (this.videoController.allSubtitleTracks.length <= trackCountBeforeAppend) {
        throw new Error('下载字幕未能追加到轨道列表')
      }

      // 下载成功后自动切换到新追加的字幕轨道。
      const newSubtitleIndex = this.videoController.allSubtitleTracks.length - 1
      await this.videoController.switchSubtitleTrack(newSubtitleIndex)

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
      this.downloadingFileId = -1
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

                      if (this.isDownloading && this.downloadingFileId === result.fileId) {
                        LoadingProgress()
                          .width(24)
                          .height(24)
                          .color('#6B9EE0')
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
