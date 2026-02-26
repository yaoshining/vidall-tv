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
          Slider({
            value: this.videoController.currentTime,
            min: 0,
            max: this.videoController.duration,
            style: SliderStyle.OutSet
          })
            .blockSize({ width: this.sliderHovered ? 20 : 12, height: this.sliderHovered ? 20 : 12 })
            .trackThickness(this.sliderHovered ? 8 : 4)
            .onChange((value, mode) => {
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
            .onHover((isHover: boolean) => {
              this.sliderHovered = isHover
            })
            .flexGrow(1)
            .animation({
              duration: 200,
              curve: Curve.EaseInOut
            })
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