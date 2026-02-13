import { debounce } from "@ibestservices/ibest-ui"
import { VideoPlayerController } from "./VideoPlayerController"
import { LengthMetrics } from "@kit.ArkUI"

@ComponentV2
struct VideoControls {
  @Require @Param videoController: VideoPlayerController
  @Require @Param dialogController: CustomDialogController
  closeTimer?: number
  seekTimer?: number
  private AUTO_CLOSE_TIMEOUT = 5000

  build() {
    RelativeContainer() {
      Flex({
        justifyContent: FlexAlign.SpaceBetween,
        alignItems: ItemAlign.Start
      }) {
        Text(this.videoController.name)
          .fontSize($r('app.float.font_h8_title_secondary'))
        Text("功能区")
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
            .onChange((value) => {
              this.videoController.seek(value)
            })
            .flexGrow(1)
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
      if (this.videoController.isPlaying) {
        clearTimeout(this.closeTimer)
        this.closeTimer = setTimeout(() => {
          this.dialogController.close()
        }, this.AUTO_CLOSE_TIMEOUT)
      } else {
        clearTimeout(this.closeTimer)
      }
    })
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