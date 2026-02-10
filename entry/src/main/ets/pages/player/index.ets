import { VideoPlayer } from "../../components/core/player";
import { VideoDataType } from "../../components/core/player/Constants";
import { VideoData } from "../../components/core/player/VideoData";
import { VideoPlayerController } from "../../components/core/player/VideoPlayerController";

export interface PlayerPageParam {
  fileUrl?: string;
  url?: string;
}

@ComponentV2
export struct PlayerPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  private videoPlayerController = new VideoPlayerController()
  private videoData?: VideoData


  static PAGE_NAME = 'player'

  build() {
    NavDestination() {
      RelativeContainer() {
        if (this.videoData) {
          VideoPlayer({
            controller: this.videoPlayerController,
            data: this.videoData
          })
            .id('TestHelloWorld')
            .alignRules({
              center: { anchor: '__container__', align: VerticalAlign.Center },
              middle: { anchor: '__container__', align: HorizontalAlign.Center }
            })
            .onClick(() => {
              this.pageStack.pop()
            })
        }
      }
      .height('100%')
      .width('100%')
    }
    .onReady((context) => {
      let paramStr = context.pathInfo.param as string
      if (paramStr) {
        let pageParam = JSON.parse(paramStr) as PlayerPageParam
        if (pageParam.url) {
          this.videoData = {
            type: VideoDataType.URL,
            videoSrc: pageParam.url
          }
        } else if (pageParam.fileUrl) {
          this.videoData = {
            type: VideoDataType.FILE_URI,
            videoSrc: pageParam.fileUrl
          }
        }
      }
    })
    .hideTitleBar(true)
  }

  aboutToDisappear(): void {
    this.videoPlayerController.release()
  }
}