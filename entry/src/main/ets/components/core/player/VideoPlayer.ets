import { VideoData } from "./VideoData"
import { VideoPlayerController } from "./VideoPlayerController"

@ComponentV2
export struct VideoPlayer {
  private xComponentController = new XComponentController()
  private surfaceId: string = ''
  @Require @Param controller: VideoPlayerController
  @Require @Param data: VideoData

  build() {
    XComponent({
      id: 'playerXComponent',
      type: XComponentType.SURFACE,
      controller: this.xComponentController
    })
      .onLoad(() => {
        this.surfaceId = this.xComponentController.getXComponentSurfaceId()
        this.controller.initAVPlayer(this.data, this.surfaceId)
      })
      .width("100%")
      .height("100%")
  }
}