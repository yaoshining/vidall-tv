import { VideoControlsDialog } from "./VideoControls"
import { VideoData } from "./VideoData"
import { VideoPlayerController } from "./VideoPlayerController"
import { emitter } from "@kit.BasicServicesKit"
import { PlayerEvents } from "./Constants"

@ComponentV2
export struct VideoPlayer {
  private xComponentController = new XComponentController()
  private surfaceId: string = ''
  @Require @Param controller: VideoPlayerController
  @Require @Param data: VideoData
  @Local controlsOpened: boolean = false
  @Param autoPlay: boolean = false

  controlsDialogController = new CustomDialogController({
    builder: VideoControlsDialog({
      videoController: this.controller
    }),
    customStyle: true,
    backgroundColor: Color.Transparent,
    maskColor: Color.Transparent,
    width: '100%',
    height: '100%',
    cornerRadius: 0,
    onDidAppear: () => {
      this.controlsOpened = true
    },
    onDidDisappear: () => {
      this.controlsOpened = false
    },
    onWillDismiss: (action) => {
      if (action.reason === DismissReason.PRESS_BACK) {
        if (!this.controller.isPlaying) {
          this.controller.play()
        }
      }
      this.controlsDialogController.close()
    },
    openAnimation: {
      duration: 0
    },
    closeAnimation: {
      duration: 0
    }
  })

  build() {
    XComponent({
      id: 'playerXComponent',
      type: XComponentType.SURFACE,
      controller: this.xComponentController
    })
      .onLoad(() => {
        this.surfaceId = this.xComponentController.getXComponentSurfaceId()
        this.controller.initAVPlayer(this.data, this.surfaceId)
        emitter.once(PlayerEvents.PREPARED, () => {
          this.controller.play()
        })
      })
      .onClick(async () => {
        await this.controller.pause()
        this.controlsDialogController.open()
      })
      .gesture(
        SwipeGesture()
          .onAction((event: SwipeGestureEvent) => {
            if (!this.controlsOpened) {
              this.controlsDialogController.open()
            } else {
              console.log('swipe direction: ' + JSON.stringify(event))
            }
          })
      )
      .width("100%")
      .height("100%")
  }
}