import { VideoControlsDialog } from "./VideoControls"
import { VideoData } from "./VideoData"
import { VideoPlayerController } from "./VideoPlayerController"
import { emitter } from "@kit.BasicServicesKit"
import { PlayerEvents } from "./Constants"
import { SubtitleParserFactory, ParsedSubtitle, SubtitleSegment } from "./SubtitleRenderer"

/**
 * 字幕渲染组件
 * 独立组件，避免在 Builder 中执行解析逻辑
 */
@Component
struct SubtitleRenderer {
  @Prop @Watch('onSubtitleTextChange') subtitleText: string = ''
  @State parsedSubtitle: ParsedSubtitle | null = null

  aboutToAppear(): void {
    this.parseSubtitle()
  }

  /**
   * 监听字幕文本变化
   */
  onSubtitleTextChange(): void {
    this.parseSubtitle()
  }

  /**
   * 解析字幕文本
   */
  private parseSubtitle(): void {
    if (this.subtitleText && this.subtitleText.trim().length > 0) {
      // 提取纯字幕内容（去除时间戳等格式信息）
      const pureText = this.extractSubtitleText(this.subtitleText)
      if (pureText.length > 0) {
        this.parsedSubtitle = SubtitleParserFactory.parse(pureText)
        // 转换字号：ASS 格式使用 pt，需要转换为 fp
        this.convertFontSize(this.parsedSubtitle)
      } else {
        this.parsedSubtitle = null
      }
    } else {
      this.parsedSubtitle = null
    }
  }

  /**
   * 转换字号：pt -> fp
   * ASS 格式中的字号单位是 pt（点），需要转换为 HarmonyOS 的 fp
   * 转换规则：
   * - 1pt ≈ 1.33px
   * - ASS 字号通常较大（如 85pt），需要缩放到合适的显示大小
   * - 缩放比例：pt * 0.25 ≈ 合适的 fp 值（可根据实际效果调整）
   */
  private convertFontSize(parsed: ParsedSubtitle | null): void {
    if (!parsed) {
      return
    }

    const PT_TO_FP_SCALE = 0.25  // ASS 字号缩放比例，可根据实际效果调整

    for (let i = 0; i < parsed.lines.length; i++) {
      const line = parsed.lines[i]
      for (let j = 0; j < line.length; j++) {
        const segment = line[j]
        if (segment.fontSize !== undefined && segment.fontSize > 0) {
          // 将 pt 转换为 fp，并应用缩放
          segment.fontSize = segment.fontSize * PT_TO_FP_SCALE
        }
      }
    }
  }

  /**
   * 提取纯字幕文本
   * 格式示例: "20,0,subtitle,,0,0,0,,给你最后一次机会\N{\fs85.545}I won't say it again."
   * 需要提取最后的字幕文本部分
   */
  private extractSubtitleText(raw: string): string {
    // ASS 格式：逗号分隔的字段，最后一个字段是字幕文本
    // 格式: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

    // 查找最后一个逗号后的内容
    let lastCommaIndex = -1
    let commaCount = 0

    for (let i = 0; i < raw.length; i++) {
      if (raw[i] === ',') {
        commaCount++
        // ASS 格式通常有 9 个逗号，第 9 个逗号后是文本
        if (commaCount >= 8) {
          lastCommaIndex = i
          break
        }
      }
    }

    if (lastCommaIndex !== -1 && lastCommaIndex < raw.length - 1) {
      return raw.substring(lastCommaIndex + 1)
    }

    // 如果没有找到逗号，可能是纯字幕文本，直接返回
    return raw
  }

  build() {
    if (this.parsedSubtitle && this.parsedSubtitle.lines.length > 0) {
      Column({ space: 4 }) {
        ForEach(this.parsedSubtitle.lines, (line: SubtitleSegment[], lineIndex: number) => {
          Row({ space: 2 }) {
            ForEach(line, (segment: SubtitleSegment, segmentIndex: number) => {
              Text(segment.text)
                .fontSize(segment.fontSize || 20)
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
            }, (segment: SubtitleSegment, index: number) => `segment-${lineIndex}-${index}`)
          }
          .justifyContent(FlexAlign.Center)
        }, (line: SubtitleSegment[], index: number) => `line-${index}`)
      }
    }
  }
}

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
   * 字幕渲染器
   * 支持多种字幕格式（ASS/SSA、纯文本等）
   */
  @Builder
  SubtitleRenderer() {
    if (this.controller.currentSubtitleText) {
      Column({ space: 4 }) {
        this.RenderSubtitleLines(this.controller.currentSubtitleText)
      }
      .padding({ left: 20, right: 20, top: 8, bottom: 8 })
      // .backgroundColor('rgba(0, 0, 0, 0.7)')
      // .borderRadius(4)
      // .shadow({
      //   radius: 8,
      //   color: 'rgba(0, 0, 0, 0.8)',
      //   offsetX: 0,
      //   offsetY: 2
      // })
    }
  }

  /**
   * 渲染字幕行（接收字幕文本作为参数）
   */
  @Builder
  RenderSubtitleLines(subtitleText: string) {
    // 在这里解析并渲染
    SubtitleRenderer({ subtitleText: subtitleText })
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
