import { media } from "@kit.MediaKit";
import fs from "@ohos.file.fs";
import { AVPlayerState, PlayerEvents, VideoDataType } from "./Constants";
import { VideoData } from "./VideoData";
import { BusinessError, emitter } from "@kit.BasicServicesKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { CommonConstants } from "../../../common/constants/CommonConstants";
import { millisecondsToTime } from "../../../utils/TimeUtil";

const TAG = '[VideoPlayerController]';

@ObservedV2
export class VideoPlayerController {
  private avPlayer?: media.AVPlayer
  @Trace surfaceId: string = ''
  @Trace duration = 0
  @Trace isPlaying = false
  @Trace isReady = false
  @Trace currentTime = 0
  @Trace currentBufferTime = 0
  @Trace isLoading = false
  @Trace progress = 0
  seekTimer = 0

  async initAVPlayer(videoData: VideoData, surfaceId: string, player?: media.AVPlayer) {
    try {
      let avPlayer = player || await media.createAVPlayer()
      this.avPlayer = avPlayer
      this.surfaceId = surfaceId

      avPlayer.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT

      this.setAVPlayerCallbacks(avPlayer)

      if (videoData.type === VideoDataType.URL) {
        // avPlayer.url = videoData.videoSrc

        // {
        //   'Authorization': 'Basic eWFvOnlzMTk4NzU2',
        // // 'Authorization': 'Basic Y2RrZDpkYXJ0dmpoeA==',
        // "User-Agent": "VidALL/1.0.0",
        // }

        // 设置播放策略，设置缓冲区数据量为3s。
        let playbackStrategy : media.PlaybackStrategy =
          {preferredWidth: 1, preferredHeight: 2, preferredBufferDuration: 3, preferredHdr: false};
        const mediaSource =
          media.createMediaSourceWithUrl(videoData.videoSrc, videoData.httpHeader)
        avPlayer.setMediaSource(mediaSource, playbackStrategy)
      }

      if (videoData.type === VideoDataType.FILE_URI) {
        let file = fs.openSync(videoData.videoSrc, fs.OpenMode.READ_ONLY)
        avPlayer.fdSrc = {
          fd: file.fd
        }
      }

      this.setAVPlayerStateChangeCallback(avPlayer)
    } catch (error) {
      if (error) {
        console.error(`Video Player creation error: ${error}`)
        return
      }
    }
  }

  async play() {
    await this.avPlayer?.play().catch((err: BusinessError) => {
      hilog.error(CommonConstants.LOG_DOMAIN, TAG,
        `play failed, code is ${err.code}, message is ${err.message}`);
    })
  }

  async pause() {
    if (this.avPlayer?.state === AVPlayerState.PLAYING) {
      await this.avPlayer?.pause().catch((err: BusinessError) => {
        hilog.error(CommonConstants.LOG_DOMAIN, TAG,
          `play failed, code is ${err.code}, message is ${err.message}`);
      })
    }
  }

  async toggle() {
    if (this.avPlayer) {
      if (this.avPlayer.state === AVPlayerState.PLAYING) {
        await this.pause()
      } else {
        await this.play()
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

  async seek(time: number) {
    clearTimeout(this.seekTimer)
    if (this.avPlayer) {
      await this.pause()
      this.avPlayer.seek(time)
      this.seekTimer = setTimeout(async () => {
        await this.avPlayer?.play()
      }, 500)
    }
  }

  async forward(milliseconds: number) {
    this.seek(this.currentTime + milliseconds)
  }

  async backward(milliseconds: number) {
    this.seek(this.currentTime - milliseconds)
  }

  private setAVPlayerStateChangeCallback(avPlayer: media.AVPlayer) {
    avPlayer.on('stateChange', (state) => {
      switch (state) {
        case AVPlayerState.IDLE:
          break
        case AVPlayerState.INITIALIZED:
          avPlayer.surfaceId = this.surfaceId
          avPlayer.prepare().catch((err: BusinessError) => {
            hilog.error(CommonConstants.LOG_DOMAIN, TAG,
              `prepare failed, code is ${err.code}, message is ${err.message}`);
          })
          break
        case AVPlayerState.PREPARED:
          this.duration = avPlayer.duration
          this.currentTime = avPlayer.currentTime
          this.isReady = true
          emitter.emit(PlayerEvents.PREPARED)
          break
        case AVPlayerState.PLAYING:
          this.isPlaying = true
          emitter.emit(PlayerEvents.PLAYING)
          break
        case AVPlayerState.PAUSED:
          this.isPlaying = false
          break
        case AVPlayerState.COMPLETED:
          this.isPlaying = false
          break
        case AVPlayerState.STOPPED:
          this.isPlaying = false
          break
        case AVPlayerState.ERROR:
          this.isPlaying = false
          break
        default:
          break
      }
    })
  }

  private setAVPlayerCallbacks(avPlayer: media.AVPlayer) {
    avPlayer.on("timeUpdate", () => {
      this.currentTime = avPlayer.currentTime
      this.progress = this.currentTime / this.duration
    })

    avPlayer.on('error', (error: Error) => {
      console.error('AVPlayer error:', JSON.stringify(error));
      this.isLoading = false;
    });
  }

  @Computed
  get durationDisplay(): string {
    return millisecondsToTime(this.duration)
  }

  @Computed
  get currentTimeDisplay(): string {
    return millisecondsToTime(this.currentTime)
  }
}