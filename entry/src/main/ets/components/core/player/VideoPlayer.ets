import { VideoControlsDialog } from "./VideoControls"
import { VideoData } from "./VideoData"
import { VideoPlayerController } from "./VideoPlayerController"
import { emitter } from "@kit.BasicServicesKit"
import { PlayerEvents } from "./Constants"
import { SubtitleParserFactory, ParsedSubtitle, SubtitleSegment } from "./SubtitleRenderer"

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

  /**
   * 计算属性：自动解析字幕
   * 当 subtitleUpdateCounter 或 currentSubtitleText 变化时自动重新计算
   */
  @Computed
  get parsedSubtitle(): ParsedSubtitle | null {
    const counter = this.controller.subtitleUpdateCounter
    const text = this.controller.currentSubtitleText

    if (!text || text.trim().length === 0) {
      return null
    }

    let pureText: string
    if (this.controller.hasSrtSubtitle) {
      // 外部 SRT：currentSubtitleText 已是纯文本，直接用
      pureText = text
    } else {
      // 内嵌字幕（ASS Dialogue 行）：截取第 8 个逗号后的内容
      pureText = this.extractSubtitleText(text)
    }

    if (pureText.trim().length === 0) {
      return null
    }

    const parsed = SubtitleParserFactory.parse(pureText)
    this.convertFontSize(parsed)
    console.log(`[VideoPlayer] counter=${counter} lines=${parsed.lines.length} srt=${this.controller.hasSrtSubtitle}`)
    return parsed
  }


  /**
   * 提取纯字幕文本
   */
  private extractSubtitleText(raw: string): string {
    let lastCommaIndex = -1
    let commaCount = 0

    for (let i = 0; i < raw.length; i++) {
      if (raw[i] === ',') {
        commaCount++
        if (commaCount >= 8) {
          lastCommaIndex = i
          break
        }
      }
    }

    if (lastCommaIndex !== -1 && lastCommaIndex < raw.length - 1) {
      return raw.substring(lastCommaIndex + 1)
    }

    return raw
  }

  /**
   * 转换字号：pt -> fp
   */
  private convertFontSize(parsed: ParsedSubtitle): void {
    const PT_TO_FP_SCALE = 0.25

    for (let i = 0; i < parsed.lines.length; i++) {
      const line = parsed.lines[i]
      for (let j = 0; j < line.length; j++) {
        const segment = line[j]
        if (segment.fontSize !== undefined && segment.fontSize > 0) {
          segment.fontSize = segment.fontSize * PT_TO_FP_SCALE
        }
      }
    }
  }

  /**
   * 字幕渲染器 - 纯 UI 渲染
   */
  @Builder
  SubtitleRenderer() {
    if (this.parsedSubtitle && this.parsedSubtitle.lines.length > 0) {
      Column({ space: 2 }) {
        ForEach(this.parsedSubtitle.lines, (line: SubtitleSegment[], lineIndex: number) => {
          Row({ space: 2 }) {
            ForEach(line, (segment: SubtitleSegment, segmentIndex: number) => {
              Text(segment.text)
                // .fontSize(segment.fontSize || 20)
                .fontSize(30)
                .fontColor(segment.fontColor || Color.White)
                .fontWeight(segment.bold ? FontWeight.Bold : FontWeight.Normal)
                .fontStyle(segment.italic ? FontStyle.Italic : FontStyle.Normal)
                .decoration({
                  type: segment.underline ? TextDecorationType.Underline : TextDecorationType.None,
                  color: segment.fontColor || Color.White
                })
                .textShadow({
                  radius: 3,
                  offsetX: 3,
                  offsetY: 3,
                  color: Color.Black
                })
            }, (segment: SubtitleSegment, index: number) => `segment-${lineIndex}-${index}-${this.controller.subtitleUpdateCounter}`)
          }
          .justifyContent(FlexAlign.Center)
        }, (line: SubtitleSegment[], index: number) => `line-${index}-${this.controller.subtitleUpdateCounter}`)
      }
      .padding({ left: 20, right: 20, top: 8, bottom: 8 })
    }
  }

  build() {
    Stack() {
      XComponent({
        id: 'playerXComponent',
        type: XComponentType.SURFACE,
        controller: this.xComponentController
      })
        .onLoad(() => {
          this.surfaceId = this.xComponentController.getXComponentSurfaceId()
          this.controller.initAVPlayer(this.data, this.surfaceId)
          emitter.once(PlayerEvents.PREPARED, () => {
            if (this.autoPlay) {
              this.controller.play()
            } else {
              this.controlsDialogController.open()
            }
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
        .renderFit(RenderFit.RESIZE_CONTAIN)

      // 字幕显示层 - 使用字幕渲染器支持多种格式
      Row() {
        this.SubtitleRenderer()
      }
      .width('100%')
      .height('100%')
      .padding({ left: 40, right: 40, bottom: 80 })
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Bottom)
      .hitTestBehavior(HitTestMode.Transparent)
    }
  }
}
