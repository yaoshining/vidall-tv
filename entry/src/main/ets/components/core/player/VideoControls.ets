import { debounce } from "@ibestservices/ibest-ui"
import { VideoPlayerController } from "./VideoPlayerController"
import { SubtitleTrackItem } from "./VideoPlayerController"
import { LengthMetrics } from "@kit.ArkUI"
import { media } from "@kit.MediaKit"

@ComponentV2
struct VideoControls {
  @Require @Param videoController: VideoPlayerController
  @Require @Param dialogController: CustomDialogController
  closeTimer?: number
  seekTimer?: number
  private AUTO_CLOSE_TIMEOUT = 5000
  @Local showSubtitleMenu: boolean = false
  @Local sliderHovered: boolean = false
  // ── 进度条 hover tooltip ──
  @Local hoverTimeMs: number = 0      // hover/焦点位置对应的时间（ms）
  @Local sliderWidth: number = 0      // Slider 组件实际宽度（vp）

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

  @Builder
  SliderTooltip() {
    Text(this.formatTime(this.hoverTimeMs))
      .fontSize(20)
      .fontColor(Color.White)
      .fontWeight(FontWeight.Medium)
      .textAlign(TextAlign.Center)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .backgroundColor('#CC000000')
      .borderRadius(8)
      .width(100)
      .position({ x: this.getTooltipOffsetX(), y: 0 })
  }

  /** 计算 tooltip 左边距：按当前时间比例居中对齐，并限制不超出两端 */
  private getTooltipOffsetX(): number {
    const TOOLTIP_W = 100   // 与 SliderTooltip 的 .width(100) 保持一致
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
                if (item.kind === 'external') {
                  Text('外部文件')
                    .fontSize(11)
                    .fontColor('#FFA500')
                }
              }
              .alignItems(HorizontalAlign.Start)

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
      }
      .width('100%')
      .backgroundColor('rgba(0, 0, 0, 0.8)')
      .borderRadius(8)
    }
    .padding(10)
  }

  build() {
    RelativeContainer() {
      Flex({
        justifyContent: FlexAlign.SpaceBetween,
        alignItems: ItemAlign.Start
      }) {
        Text(this.videoController.name)
          .fontSize($r('app.float.font_h8_title_secondary'))
          .textShadow({
            radius: 3,
            offsetX: 3,
            offsetY: 3,
            color: Color.Black
          })
          .width("80%")
          .maxLines(1)
          .textOverflow({
            overflow: TextOverflow.Ellipsis
          })

        // 字幕按钮
        if (this.videoController.allSubtitleTracks.length > 0) {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.text_bubble_left_2'))
              .fontColor([this.videoController.activeSubtitleIndex >= 0 ? Color.White : Color.Gray])
              .fontSize(24)
            Text(this.getActiveSubtitleName())
              .fontSize(14)
              .fontColor(this.videoController.activeSubtitleIndex >= 0 ? Color.White : Color.Gray)
          }
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor('rgba(0, 0, 0, 0.5)')
          .borderRadius(20)
          .onClick(() => {
            this.showSubtitleMenu = !this.showSubtitleMenu
            clearTimeout(this.closeTimer)
          })
        }
      }
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [
          ['rgba(0, 0, 0, 0.3)', 0.0],
          ['rgba(0, 0, 0, 0)', 1.0]
        ]
      })
      .alignRules({
        left: { anchor: '__container__', align: HorizontalAlign.Start },
        top: { anchor: '__container__', align: VerticalAlign.Top }
      })
      .height("20%")
      .padding(20)

      // 字幕选择菜单
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

      if (!this.videoController.isPlaying) {
        // 播放按钮透明毛玻璃效果，带播放图标
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
        .border({
          width: 1,
          color: 'rgba(255, 255, 255, 0.2)'
        })
        .shadow({ radius: 20, color: 'rgba(0, 0, 0, 0.4)' })
      }

      Flex({
        alignItems: ItemAlign.End
      }) {
        Flex({
          alignItems: ItemAlign.Center,
          justifyContent: FlexAlign.SpaceBetween,
          space: {
            main: LengthMetrics.vp(6)
          }
        }) {
          Text(`${this.videoController.currentTimeDisplay}`)
            .flexShrink(0)
          // Slider + hover tooltip
          Stack({ alignContent: Alignment.Bottom }) {
            // tooltip 层：始终渲染，用 visibility 控制显隐，避免 Builder 条件分支失效
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
              .blockSize({ width: this.sliderHovered ? 20 : 12, height: this.sliderHovered ? 20 : 12 })
              .trackThickness(this.sliderHovered ? 8 : 4)
              .onChange((value, mode) => {
                // 始终同步 hoverTimeMs，保证 tooltip 时间正确
                this.hoverTimeMs = value
                if (mode === SliderChangeMode.Begin) {
                  this.videoController.pause()
                  this.videoController.currentTime = value
                  this.videoController.seek(value)
                }
                if (mode === SliderChangeMode.Moving) {
                  this.videoController.currentTime = value
                }
                if (mode === SliderChangeMode.End) {
                  this.videoController.seek(value)
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
                // 方向键焦点：显示 tooltip，初始化为当前播放位置
                this.sliderHovered = true
                this.hoverTimeMs = this.videoController.currentTime
              })
              .onBlur(() => {
                this.sliderHovered = false
              })
              .onAreaChange((_oldVal, newVal) => {
                this.sliderWidth = newVal.width as number
              })
              .width('100%')
              .animation({
                duration: 200,
                curve: Curve.EaseInOut
              })
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
        colors: [
          ['rgba(0, 0, 0, 0.5)', 0.0],
          ['rgba(0, 0, 0, 0)', 1.0]
        ]
      })
      .height("20%")
      .padding(20)
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

  private enableAutoHide(): void {
    if (this.videoController.isPlaying) {
      clearTimeout(this.closeTimer)
      this.closeTimer = setTimeout(() => {
        this.dialogController.close()
      }, this.AUTO_CLOSE_TIMEOUT)
    } else {
      clearTimeout(this.closeTimer)
    }
  }

  aboutToAppear(): void {
    this.enableAutoHide()
  }

  aboutToDisappear(): void {
    clearTimeout(this.closeTimer)
    clearTimeout(this.seekTimer)
  }
}

@CustomDialog
export struct VideoControlsDialog {
  controller: CustomDialogController
  @Require videoController: VideoPlayerController
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
      dialogController: this.controller
    })
      .opacity(this.opacityValue)
  }
}