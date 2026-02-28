import { VideoPlayer } from "../../components/core/player";
import { VideoDataType } from "../../components/core/player/Constants";
import { VideoData } from "../../components/core/player/VideoData";
import { VideoPlayerController } from "../../components/core/player/VideoPlayerController";
import { promptAction } from "@kit.ArkUI";

export interface PlayerPageParam {
  fileUrl?: string;
  url?: string;
  httpHeader?: Record<string, string>;
  title?: string;
  videoId?: number;  // 视频数据库ID
}

@ComponentV2
export struct PlayerPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()
  private videoPlayerController = new VideoPlayerController()
  private videoData?: VideoData
  @Local isBackPressedOnce: boolean = false
  @Local showResumeDialog: boolean = false
  private savedPosition: number = 0  // 保存的播放位置
  private shouldAutoPlay: boolean = true  // 是否自动播放

  static PAGE_NAME = 'player'

  build() {
    NavDestination() {
      RelativeContainer() {
        if (this.videoData) {
          VideoPlayer({
            controller: this.videoPlayerController,
            data: this.videoData,
            autoPlay: this.shouldAutoPlay
          })
            .alignRules({
              center: { anchor: '__container__', align: VerticalAlign.Center },
              middle: { anchor: '__container__', align: HorizontalAlign.Center }
            })
        }

        if (this.isBackPressedOnce) {
          Text("再次按返回键退出播放")
            .margin({ bottom: 100 })
            .fontSize($r('app.float.font_h7_title_small'))
            .fontColor(Color.White)
            .backgroundColor('#99000000')
            .padding(8)
            .borderRadius(4)
            .backdropBlur(0.8)
            .shadow({
              radius: 8,
              color: '#66000000',
              offsetX: 2,
              offsetY: 2,
            })
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

        // 续播提示对话框
        if (this.showResumeDialog) {
          Column() {
            Text("发现播放记录")
              .fontSize(20)
              .fontColor(Color.White)
              .fontWeight(FontWeight.Bold)
              .margin({ bottom: 16 })

            Text(`上次观看到 ${this.formatTime(this.savedPosition)}`)
              .fontSize(14)
              .fontColor('#CCCCCC')
              .margin({ bottom: 24 })

            Row({ space: 16 }) {
              Button("重头播放")
                .fontSize(14)
                .width(120)
                .height(40)
                .buttonStyle(ButtonStyleMode.NORMAL)
                .onClick(() => {
                  this.showResumeDialog = false
                  this.shouldAutoPlay = true
                  // 重头播放，不需要恢复进度
                })

              Button("继续播放")
                .fontSize(14)
                .width(120)
                .height(40)
                .buttonStyle(ButtonStyleMode.EMPHASIZED)
                .onClick(async () => {
                  this.showResumeDialog = false
                  this.shouldAutoPlay = true
                  // 恢复到上次播放位置
                  await this.videoPlayerController.seek(this.savedPosition)
                })
            }
            .justifyContent(FlexAlign.Center)
          }
          .backgroundColor('#DD000000')
          .padding(32)
          .borderRadius(12)
          .shadow({
            radius: 16,
            color: '#66000000',
            offsetX: 0,
            offsetY: 4,
          })
          .alignRules({
            center: { anchor: '__container__', align: VerticalAlign.Center },
            middle: { anchor: '__container__', align: HorizontalAlign.Center }
          })
        }
      }
      .height('100%')
      .width('100%')
    }
    .onReady(async (context) => {
      let pageParam = context.pathInfo.param as PlayerPageParam
      if (pageParam) {
        if (pageParam.url) {
          this.videoData = {
            type: VideoDataType.URL,
            videoSrc: pageParam.url,
            videoId: pageParam.videoId
          }
        } else if (pageParam.fileUrl) {
          this.videoData = {
            type: VideoDataType.FILE_URI,
            videoSrc: pageParam.fileUrl,
            videoId: pageParam.videoId
          }
        }
        if (this.videoData) {
          this.videoData.httpHeader = pageParam.httpHeader
          this.videoData.name = pageParam.title

          // 检查是否有播放历史
          if (pageParam.videoId !== undefined) {
            const history = await this.videoPlayerController.loadPlayHistory()
            if (history !== undefined && history > 5000) {  // 只有播放超过5秒才提示续播
              this.savedPosition = history
              this.showResumeDialog = true
              this.shouldAutoPlay = false  // 暂停自动播放，等待用户选择
            }
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

  /**
   * 格式化时间（毫秒 -> HH:MM:SS 或 MM:SS）
   */
  private formatTime(ms: number): string {
    const seconds = Math.floor(ms / 1000)
    const hours = Math.floor(seconds / 3600)
    const minutes = Math.floor((seconds % 3600) / 60)
    const secs = seconds % 60

    if (hours > 0) {
      return `${hours}:${this.pad(minutes)}:${this.pad(secs)}`
    }
    return `${minutes}:${this.pad(secs)}`
  }

  private pad(num: number): string {
    return num < 10 ? '0' + num : num.toString()
  }
}