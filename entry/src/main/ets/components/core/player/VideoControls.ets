import { debounce } from "@ibestservices/ibest-ui"
import { VideoPlayerController } from "./VideoPlayerController"
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
        // 关闭字幕选项
        ListItem() {
          Row() {
            Text('关闭字幕')
              .fontSize(16)
              .fontColor(Color.White)
            if (this.videoController.currentSubtitleTrack === -1) {
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
          this.videoController.selectSubtitleTrack(-1)
          this.showSubtitleMenu = false
          this.enableAutoHide()
        })

        // 字幕轨道列表
        ForEach(this.videoController.subtitleTracks, (track: media.MediaDescription, index: number) => {
          ListItem() {
            Row() {
              Text(this.videoController.getSubtitleTrackName(index))
                .fontSize(16)
                .fontColor(Color.White)
              if (this.videoController.currentSubtitleTrack === index) {
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
            this.videoController.selectSubtitleTrack(index)
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
        if (this.videoController.subtitleTracks.length > 0) {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.text_bubble_left_2'))
              .fontColor([this.videoController.currentSubtitleTrack >= 0 ? Color.White : Color.Gray])
              .fontSize(24)
            Text(this.videoController.getSubtitleTrackName(this.videoController.currentSubtitleTrack))
              .fontSize(14)
              .fontColor(this.videoController.currentSubtitleTrack >= 0 ? Color.White : Color.Gray)
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
            .onChange((value) => {
              this.videoController.seek(value)
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
    .onClick(async () => {
      await this.videoController.toggle()
      this.enableAutoHide()
    })
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