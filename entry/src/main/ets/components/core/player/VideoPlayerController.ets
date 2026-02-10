import { media } from "@kit.MediaKit";
import fs from "@ohos.file.fs";
import { VideoDataType } from "./Constants";
import { VideoData } from "./VideoData";

export class VideoPlayerController {
  private avPlayer?: media.AVPlayer
  private surfaceId: string = ''

  async initAVPlayer(videoData: VideoData, surfaceId: string) {
    try {
      let avPlayer = await media.createAVPlayer()
      this.avPlayer = avPlayer
      avPlayer.surfaceId = surfaceId
      if (videoData.type === VideoDataType.URL) {
        avPlayer.url = videoData.videoSrc
      }

      if (videoData.type === VideoDataType.FILE_URI) {
        let file = fs.openSync(videoData.videoSrc, fs.OpenMode.READ_ONLY)
        avPlayer.fdSrc = {
          fd: file.fd
        }
      }

      avPlayer.on('stateChange', (state) => {
        switch (state) {
          case 'idle':
            break
          case 'initialized':
            avPlayer.surfaceId = surfaceId
            avPlayer.prepare().catch(() => {
              // TODO: Implement error handling.
            })
            break
          case 'prepared':
            avPlayer.url = 'https://vjs.zencdn.net/v/oceans.mp4'
            avPlayer.play()
            break
          default:
            break
        }
      })
      await avPlayer.prepare()
      await avPlayer.play()
    } catch (error) {
      if (error) {
        console.error(`Video Player creation error: ${error}`)
        return
      }
    }
  }

  async release() {
    if (this.avPlayer) {
      try {
        await this.avPlayer.release()
      } catch (error) {
        // TODO: Implement error handling.
      }
    }
  }
}