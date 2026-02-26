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

    // 自动检测：是否是 ASS Dialogue 行（有 9 个以上逗号且前段是数字/空字符串）
    // 如果是，截取第 9 个逗号后的纯文本；否则直接当纯文本渲染
    const pureText = this.extractSubtitleText(text)

    if (pureText.trim().length === 0) {
      return null
    }

    const parsed = SubtitleParserFactory.parse(pureText)
    this.convertFontSize(parsed)
    console.log(`[VideoPlayer] counter=${counter} lines=${parsed.lines.length}`)
    return parsed
  }

  /**
   * 智能提取字幕文本：
   * - 检测是否为 ASS Dialogue 格式（至少 8 个逗号且第 1 字段是数字），是则截取第 8 个逗号后的内容
   * - 否则原文返回（SRT/纯文本）
   *
   * subtitleUpdate 回调格式（已验证，非标准 Dialogue 格式）：
   *   序号,?,Style,?,?,?,?,?,Text
   *   0    1 2     3 4 5 6 7 8
   * 共 9 字段，8 个逗号，Text 在第 9 字段
   *
   * 示例：98,0,Subtitle,,0,0,0,,我真不该把她留在那儿
   */
  private extractSubtitleText(raw: string): string {
    // 快速检测：找前 8 个逗号
    let commaCount = 0
    let eighthCommaIdx = -1
    for (let i = 0; i < raw.length; i++) {
      if (raw[i] === ',') {
        commaCount++
        if (commaCount === 8) {
          eighthCommaIdx = i
          break
        }
      }
    }

    // 不足 8 个逗号，不是 ASS Dialogue 格式，原文返回
    if (eighthCommaIdx < 0) {
      return raw
    }

    // 检验第一个字段是否为数字（ASS Dialogue 的序号/Layer 总是数字）
    const firstCommaIdx = raw.indexOf(',')
    if (firstCommaIdx > 0) {
      const firstField = raw.substring(0, firstCommaIdx).trim()
      if (firstField.length === 0) {
        // 第一字段为空，不是 ASS Dialogue
        return raw
      }
      let isNum = true
      for (let i = 0; i < firstField.length; i++) {
        const c = firstField[i]
        if (c < '0' || c > '9') {
          isNum = false
          break
        }
      }
      if (!isNum) {
        // 第一字段不是纯数字，不是 ASS Dialogue，原文返回
        return raw
      }
    } else {
      // 没有逗号或第一个逗号在开头，不是 ASS Dialogue
      return raw
    }

    // 确认是 ASS Dialogue，截取第 8 个逗号后的内容（Text 字段）
    const assText = raw.substring(eighthCommaIdx + 1)
    console.log(`[VideoPlayer] 检测到 ASS Dialogue 格式（8逗号），原文前80字符: ${raw.substring(0, 80)}`)
    console.log(`[VideoPlayer] 截取第8个逗号后: ${assText.substring(0, 60)}`)
    // 去掉 ASS 样式标签 {xxx}
    const cleaned = this.stripAssTags(assText)
    console.log(`[VideoPlayer] 剥除样式标签后: ${cleaned.substring(0, 60)}`)
    return cleaned
  }

  /** 剥除 ASS 样式标签，参照 libass 规范 */
  private stripAssTags(text: string): string {
    let result = ''
    let i = 0
    while (i < text.length) {
      const ch = text[i]
      // 转义序列
      if (ch === '\\' && i + 1 < text.length) {
        const next = text[i + 1]
        if (next === 'N' || next === 'n') {
          result += '\n'
          i += 2
          continue
        }
        if (next === 'h') {
          result += '\u00A0'
          i += 2
          continue
        }
        if (next === '{' || next === '}') {
          result += next
          i += 2
          continue
        }
        if (next === 'q' && i + 2 < text.length) {
          const qn = text[i + 2]
          if (qn >= '0' && qn <= '3') {
            i += 3
            continue
          }
        }
        result += ch
        i++
        continue
      }
      // {tags} 块：跳过到 }
      if (ch === '{') {
        const end = text.indexOf('}', i + 1)
        if (end >= 0) {
          i = end + 1
        } else {
          // 未闭合 {：忽略到末尾
          i = text.length
        }
        continue
      }
      result += ch
      i++
    }
    return result.trim()
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
      // AVPlayer 内核：使用 XComponentController 获取 surfaceId
      if (this.controller.backend === 'avplayer') {
        XComponent({
          id: 'playerXComponent',
          type: XComponentType.SURFACE,
          controller: this.xComponentController
        })
          .onLoad(() => {
            this.surfaceId = this.xComponentController.getXComponentSurfaceId()
            // ⚠️ 先注册 PREPARED 监听再触发 init，避免快速回调时事件丢失
            emitter.once(PlayerEvents.PREPARED, () => {
              if (this.autoPlay) {
                this.controller.play()
              } else {
                this.controlsDialogController.open()
              }
            })
            this.controller.initPlayer(this.data, this.surfaceId)
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
          .backgroundColor(Color.Black)
      } else {
        // IjkPlayer 内核：必须用 libraryname 模式，不能用 XComponentController
        // ⚠️ libraryname 模式的 XComponent 原生层会抢占触摸事件，onClick/gesture 无效，
        //    需要在上方叠加透明触摸层来拦截交互。
        Stack() {
          XComponent({
            id: 'ijkPlayerXComponent',
            type: XComponentType.SURFACE,
            libraryname: 'ijkplayer_napi'
          })
            .onLoad((context: object) => {
              // ⚠️ 必须先注册 PREPARED 监听，再触发 init！
              emitter.once(PlayerEvents.PREPARED, () => {
                if (this.autoPlay) {
                  this.controller.play()
                } else {
                  this.controlsDialogController.open()
                }
              })
              // ⚠️ 用 setTimeout 延迟，确保 XComponent Surface 的 native 层已完全 ready
              setTimeout(() => {
                this.surfaceId = 'ijkPlayerXComponent'
                this.controller.initPlayer(this.data, this.surfaceId).then(() => {
                  this.controller.setIjkContext(context, 'ijkPlayerXComponent')
                })
              }, 100)
            })
            .width("100%")
            .height("100%")
            .renderFit(RenderFit.RESIZE_CONTAIN)
            .backgroundColor(Color.Black)

          // 透明触摸拦截层：专门处理点击和手势，解决 libraryname 模式事件不透传问题
          Stack()
            .width("100%")
            .height("100%")
            .backgroundColor(Color.Transparent)
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
        }
        .width("100%")
        .height("100%")
      }

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
    .backgroundColor(Color.Black)
  }
}
