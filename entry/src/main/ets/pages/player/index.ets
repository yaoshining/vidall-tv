import { VideoPlayer } from "../../components/core/player";
import { VideoDataType } from "../../components/core/player/Constants";
import { VideoData } from "../../components/core/player/VideoData";
import { VideoPlayerController } from "../../components/core/player/VideoPlayerController";

export interface PlayerPageParam {
  fileUrl?: string;
  url?: string;
  httpHeader?: Record<string, string>
}

@ComponentV2
export struct PlayerPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  private videoPlayerController = new VideoPlayerController()
  private videoData?: VideoData
  @Local isBackPressedOnce: boolean = false

  static PAGE_NAME = 'player'

  build() {
    NavDestination() {
      RelativeContainer() {
        if (this.videoData) {
          VideoPlayer({
            controller: this.videoPlayerController,
            data: this.videoData,
            autoPlay: true
          })
            .alignRules({
              center: { anchor: '__container__', align: VerticalAlign.Center },
              middle: { anchor: '__container__', align: HorizontalAlign.Center }
            })
        }

        if (this.isBackPressedOnce) {
          Text("再次按返回键退出播放")
            .margin({ bottom: 40 })
            .fontSize(14)
            .fontColor(Color.White)
            .backgroundColor('#66000000')
            .padding(8)
            .borderRadius(4)
            .animation({
              duration: 200,
              curve: Curve.EaseInOut,
              iterations: 1,
              playMode: PlayMode.Normal
            })
            .alignRules({
              bottom: { anchor: '__container__', align: VerticalAlign.Bottom },
              middle: { anchor: '__container__', align: HorizontalAlign.Center }
            })
        }
      }
      .height('100%')
      .width('100%')
    }
    .onReady((context) => {
      let pageParam = context.pathInfo.param as PlayerPageParam
      if (pageParam) {
        if (pageParam.url) {
          this.videoData = {
            type: VideoDataType.URL,
            videoSrc: pageParam.url,
            httpHeader: pageParam.httpHeader
          }
        } else if (pageParam.fileUrl) {
          this.videoData = {
            type: VideoDataType.FILE_URI,
            videoSrc: pageParam.fileUrl,
            httpHeader: pageParam.httpHeader
          }
        }
      }
    })
    .onBackPressed(() => {
      if (this.isBackPressedOnce) {
        return false
      } else {
        this.isBackPressedOnce = true
        setTimeout(() => {
          this.isBackPressedOnce = false
        }, 2000)
        return true
      }
    })
    .hideTitleBar(true)
  }

  aboutToDisappear(): void {
    this.videoPlayerController.release()
  }
}