import { VideoControlsDialog, PlayerSettingsDialog, SubtitleSelectorDrawerDialog } from "./VideoControls"
import { VideoData } from "./VideoData"
import { VideoPlayerController, type PlayerBackend, AspectRatioMode } from "./VideoPlayerController"
import { emitter } from "@kit.BasicServicesKit"
import { PlayerEvents } from "./Constants"
import { SubtitleParserFactory, ParsedSubtitle, SubtitleSegment } from "./SubtitleRenderer"
import { millisecondsToTime } from "../../../utils/TimeUtil"

@ComponentV2
export struct VideoPlayer {
  private xComponentController = new XComponentController()
  private surfaceId: string = ''
  private initMode: string = ''
  private ijkInitTimer?: number
  @Require @Param controller: VideoPlayerController
  @Require @Param data: VideoData
  @Local controlsOpened: boolean = false
  @Param autoPlay: boolean = false
  /** 镜像 controller.backend，用于驱动多后端分支重建 */
  @Local backendMode: PlayerBackend = 'avplayer'
  /** 镜像 controller.aspectRatioMode，用于驱动 renderFit 响应式更新 */
  @Local aspectRatioMode: AspectRatioMode = AspectRatioMode.FIT

  // ASS 解析结果缓存：相同 raw 文本不重复解析（#17 AC）
  private _lastRawText: string = ''
  private _lastParsedSubtitle: ParsedSubtitle | null = null

  @Monitor('controller.backend')
  onBackendChange(): void {
    this.clearIjkInitTimer()
    this.backendMode = this.controller.backend
    // backend 切换后允许新分支重新初始化。
    this.initMode = ''
    console.info(`[VideoPlayer] backend 变更 → ${this.backendMode}`)
  }

  @Monitor('controller.aspectRatioMode')
  onAspectRatioModeChange(): void {
    this.aspectRatioMode = this.controller.aspectRatioMode
    console.info(`[VideoPlayer] 画面比例变更 → mode=${this.aspectRatioMode}, renderFit=${this.toRenderFit(this.aspectRatioMode)}`)
  }

  /** 将画面比例模式映射到 XComponent.renderFit */
  private toRenderFit(mode: AspectRatioMode): RenderFit {
    if (mode === AspectRatioMode.FILL) {
      return RenderFit.RESIZE_COVER
    }
    if (mode === AspectRatioMode.STRETCH) {
      return RenderFit.RESIZE_FILL
    }
    return RenderFit.RESIZE_CONTAIN
  }

  private tryMarkInit(mode: string): boolean {
    if (this.initMode === mode) {
      console.warn(`[VideoPlayer] 忽略重复初始化: ${mode}`)
      return false
    }
    this.initMode = mode
    return true
  }

  private resetInitMode(): void {
    this.initMode = ''
  }

  private clearIjkInitTimer(): void {
    if (this.ijkInitTimer !== undefined) {
      clearTimeout(this.ijkInitTimer)
      this.ijkInitTimer = undefined
    }
  }

  private isPlaybackCompletedState(): boolean {
    const duration = this.controller.duration
    const current = this.controller.currentTime
    if (duration <= 0) {
      return false
    }
    return current >= duration
  }

  controlsDialogController = new CustomDialogController({
    builder: VideoControlsDialog({
      videoController: this.controller,
      onOpenSettings: () => {
        this.controlsDialogController.close()
        this.settingsDialogController.open()
      }
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
        // 仅暂停态关闭控件后恢复播放；播放结束态关闭控件不自动续播。
        if (!this.controller.isPlaying && !this.isPlaybackCompletedState()) {
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

  settingsDialogController = new CustomDialogController({
    builder: PlayerSettingsDialog({
      videoController: this.controller,
      onOpenSubtitleSelector: () => {
        this.settingsDialogController.close()
        this.subtitleSelectorDialogController.open()
      }
    }),
    customStyle: true,
    backgroundColor: Color.Transparent,
    maskColor: '#0000004D',
    width: '100%',
    height: '100%',
    cornerRadius: 0,
    onWillDismiss: () => {
      this.settingsDialogController.close()
    },
    openAnimation: {
      duration: 0
    },
    closeAnimation: {
      duration: 0
    }
  })

  subtitleSelectorDialogController = new CustomDialogController({
    builder: SubtitleSelectorDrawerDialog({
      videoController: this.controller
    }),
    customStyle: true,
    backgroundColor: Color.Transparent,
    maskColor: Color.Transparent,
    width: '100%',
    height: '100%',
    cornerRadius: 0,
    onWillDismiss: () => {
      this.subtitleSelectorDialogController.close()
    },
    openAnimation: {
      duration: 0
    },
    closeAnimation: {
      duration: 0
    }
  })

  /**
   * 字幕解析：监听 subtitleUpdateCounter 变化，解析后写入 controller.parsedSubtitle
   * 供播放器页独立渲染层（RelativeContainer 顶层）直接读取，
   * 避免与 XComponent renderFit GPU 合成层共享同一 Stack Surface。
   */
  @Monitor('controller.subtitleUpdateCounter')
  onSubtitleUpdate(): void {
    const text = this.controller.currentSubtitleText

    if (!text || text.trim().length === 0) {
      this.controller.parsedSubtitle = null
      return
    }

    // 相同 raw 文本命中缓存，跳过重复解析（ASS 回调高频时的 CPU 优化）
    if (text === this._lastRawText && this._lastParsedSubtitle !== null) {
      this.controller.parsedSubtitle = this._lastParsedSubtitle
      return
    }

    const pureText = this.extractSubtitleText(text)

    if (pureText.trim().length === 0) {
      this._lastRawText = text
      this._lastParsedSubtitle = null
      this.controller.parsedSubtitle = null
      return
    }

    const counter = this.controller.subtitleUpdateCounter
    const parsed = SubtitleParserFactory.parse(pureText)
    this.convertFontSize(parsed)
    console.log(`[VideoPlayer] counter=${counter} lines=${parsed.lines.length}`)
    this._lastRawText = text
    this._lastParsedSubtitle = parsed
    this.controller.parsedSubtitle = parsed
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

  private mergeSubtitleLineText(line: SubtitleSegment[]): string {
    let merged = ''
    for (let i = 0; i < line.length; i++) {
      merged += line[i].text
    }
    return merged
  }

  /**
   * 字幕渲染器 - 纯 UI 渲染（保留供备用；主渲染路径已移至播放器页独立层）
   */
  @Builder
  SubtitleRenderer() {
    if (this.controller.parsedSubtitle && this.controller.parsedSubtitle.lines.length > 0) {
      Column({ space: 6 }) {
        ForEach(this.controller.parsedSubtitle.lines, (line: SubtitleSegment[], lineIndex: number) => {
          Text(this.mergeSubtitleLineText(line))
            .fontSize(30)
            .lineHeight(34)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Normal)
            .textAlign(TextAlign.Center)
            .textShadow({
              radius: 3,
              offsetX: 3,
              offsetY: 3,
              color: Color.Black
            })
        }, (line: SubtitleSegment[], index: number) => `line-${index}-${this.controller.subtitleUpdateCounter}`)
      }
      .padding({ left: 20, right: 20, top: 8, bottom: 8 })
    }
  }

  build() {
    Stack() {
      if (this.backendMode === 'avplayer') {
        // AVPlayer 内核：使用 XComponentController 获取 surfaceId
        XComponent({
          id: 'playerXComponent',
          type: XComponentType.SURFACE,
          controller: this.xComponentController
        })
          .onLoad(() => {
            if (!this.tryMarkInit('avplayer')) {
              return
            }
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
          .renderFit(this.toRenderFit(this.aspectRatioMode))
          .backgroundColor(Color.Black)
      } else if (this.backendMode === 'ijkplayer') {
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
              if (!this.tryMarkInit('ijkplayer')) {
                return
              }
              // ⚠️ 必须先注册 PREPARED 监听，再触发 init！
              emitter.once(PlayerEvents.PREPARED, () => {
                if (this.autoPlay) {
                  this.controller.play()
                } else {
                  this.controlsDialogController.open()
                }
              })
              // ⚠️ 用 setTimeout 延迟，确保 XComponent Surface 的 native 层已完全 ready
              this.clearIjkInitTimer()
              this.ijkInitTimer = setTimeout(() => {
                this.ijkInitTimer = undefined
                if (this.controller.backend !== 'ijkplayer' || this.initMode !== 'ijkplayer') {
                  this.resetInitMode()
                  return
                }
                this.surfaceId = 'ijkPlayerXComponent'
                this.controller.initPlayer(this.data, this.surfaceId).then(() => {
                  this.controller.setIjkContext(context, 'ijkPlayerXComponent')
                }).catch((err: Error) => {
                  console.error(`[VideoPlayer] ijk init 异常: ${err.message}`)
                  this.resetInitMode()
                  this.backendMode = 'avplayer'
                })
              }, 100)
            })
            .width("100%")
            .height("100%")
            .renderFit(this.toRenderFit(this.aspectRatioMode))
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
      } else if (this.backendMode === 'native') {
        Stack() {
          XComponent({
            id: 'nativePlayerXComponent',
            type: XComponentType.SURFACE,
            libraryname: 'vidall_core_player_napi'
          })
            .onLoad((context: object) => {
              if (!this.tryMarkInit('native')) {
                return
              }
              emitter.once(PlayerEvents.PREPARED, () => {
                if (this.autoPlay) {
                  this.controller.play()
                } else {
                  this.controlsDialogController.open()
                }
              })
              this.clearIjkInitTimer()
              this.ijkInitTimer = setTimeout(() => {
                this.ijkInitTimer = undefined
                if (this.controller.backend !== 'native' || this.initMode !== 'native') {
                  this.resetInitMode()
                  return
                }
                this.surfaceId = 'nativePlayerXComponent'
                this.controller.initPlayer(this.data, this.surfaceId).then(() => {
                  this.controller.setNativeContext(context, 'nativePlayerXComponent')
                }).catch((err: Error) => {
                  console.error(`[VideoPlayer] native init 异常: ${err.message}`)
                  this.resetInitMode()
                  this.backendMode = 'avplayer'
                })
              }, 100)
            })
            .width("100%")
            .height("100%")
            .renderFit(this.toRenderFit(this.aspectRatioMode))
            .backgroundColor(Color.Black)

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
      } else {
        Column({ space: 12 }) {
          Text('FFmpeg 实验后端已下线')
            .fontSize(24)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Medium)
          Text('当前版本已恢复到 AVPlayer / IjkPlayer 主播放方案。')
            .fontSize(16)
            .fontColor('#B3FFFFFF')
          Text('FFmpeg 相关代码已保留，但不再进入主路径。')
            .fontSize(14)
            .fontColor('#80FFFFFF')
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .width("100%")
        .height("100%")
        .backgroundColor(Color.Black)
        .onAppear(() => {
          this.resetInitMode()
          this.controller.backend = 'ijkplayer'
          this.backendMode = 'ijkplayer'
        })
      }

      // 字幕显示层已移至播放器页 RelativeContainer 顶层（独立于 XComponent GPU 合成层）

    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }

  aboutToAppear(): void {
    this.backendMode = this.controller.backend
    this.aspectRatioMode = this.controller.aspectRatioMode
    this.initMode = ''
    emitter.on(PlayerEvents.COMPLETED, () => {
      this.clearIjkInitTimer()
      this.controlsDialogController.open()
    })
  }

  aboutToDisappear(): void {
    this.clearIjkInitTimer()
    emitter.off(PlayerEvents.COMPLETED.eventId)
  }
}
