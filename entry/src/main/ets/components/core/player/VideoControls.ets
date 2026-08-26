import { VideoPlayerController, SubtitleTrackItem, AudioTrackItem } from "./VideoPlayerController"
import { LengthMetrics } from "@kit.ArkUI"
import { common } from '@kit.AbilityKit'
import {
  defaultSubtitleAcquisitionService as subtitleService
} from '../../../services/subtitleAcquisition/SubtitleAcquisitionService'
import {
  CachedSubtitleEntry
} from '../../../services/subtitleAcquisition/SubtitleAcquisitionTypes'

@ComponentV2
struct VideoControls {
  @Require @Param videoController: VideoPlayerController
  @Require @Param dialogController: CustomDialogController
  @Require @Param openSettings: () => void
  @Param onOpenSubtitleSelector: () => void = () => {}
  @Param onRemoteKey: (event: KeyEvent) => void = (_event: KeyEvent) => {}
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

  /**
   * 播放状态变化时刷新「自动隐藏」定时器：
   * 仅在开始播放（isPlaying → true）时启动定时器。
   * 暂停（isPlaying → false）时不在这里清定时器——切音轨会先 pause 再 play，
   * 若在 pause 时清掉 forceStart 的定时器、又因 play 事件时序错过重启，控件就永不隐藏；
   * 暂停态的清理由各交互入口的显式 clearTimeout/enableAutoHide 负责。
   */
  @Monitor('videoController.isPlaying')
  onPlayingChange(): void {
    if (this.videoController.isPlaying) {
      this.enableAutoHide()
    }
  }

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
              // 打开菜单时保持可见（取消自动隐藏）；关闭菜单时恢复倒计时
              if (this.showAudioMenu) {
                clearTimeout(this.closeTimer)
              } else {
                this.enableAutoHide()
              }
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
              // 菜单打开：保持可见，取消自动隐藏
              clearTimeout(this.closeTimer)
            } else {
              // 菜单关闭：恢复倒计时（播放中重置为完整 5 秒）
              this.enableAutoHide()
            }
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
                  // 开始拖动：暂停并取消自动隐藏，避免拖动期间控件消失
                  clearTimeout(this.closeTimer)
                  this.videoController.pause()
                  this.videoController.currentTime = value
                  this.videoController.seek(value)
                } else if (mode === SliderChangeMode.Moving) {
                  // 拖动过程中持续重置倒计时：播放中重置为完整 5 秒，暂停中仅保持可见
                  this.videoController.currentTime = value
                  this.enableAutoHide()
                } else if (mode === SliderChangeMode.Click) {
                  // 点按轨道同样重置倒计时，避免点按后控件中途隐藏
                  this.enableAutoHide()
                } else if (mode === SliderChangeMode.End) {
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
    .onKeyEvent((event: KeyEvent) => {
      this.onRemoteKey(event)
    })
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
  onRemoteKey: (event: KeyEvent) => void = (_event: KeyEvent) => {}
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
      onOpenSubtitleSelector: this.onOpenSubtitleSelector,
      onRemoteKey: this.onRemoteKey
    })
      .opacity(this.opacityValue)
  }
}
