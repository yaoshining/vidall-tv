import { VideoControlsDialog } from "./VideoControls"
import { PlayerSettingsDialog } from "./PlayerSettingsDialog"
import { SubtitleSelectorDrawerDialog } from "./SubtitleSelectorDrawerDialog"
import { VideoData } from "./VideoData"
import { VideoPlayerController, type PlayerBackend, AspectRatioMode } from "./VideoPlayerController"
import { BusinessError, emitter } from "@kit.BasicServicesKit"
import { PlayerEvents, VideoDataType } from "./Constants"
import { SubtitleParserFactory, ParsedSubtitle, SubtitleSegment } from "./SubtitleRenderer"
import { millisecondsToTime } from "../../../utils/TimeUtil"
import { PlaybackContextItem } from "./PlaybackContext"
import { resolveRenderFitForAspectRatioMode } from "./VideoPlayerLayoutUtil"

@ComponentV2
export struct VideoPlayer {
  private xComponentController = new XComponentController()
  private surfaceId: string = ''
  private initMode: string = ''
  @Require @Param controller: VideoPlayerController
  @Require @Param data: VideoData
  @Require @Param onEpisodeSelect: (item: PlaybackContextItem) => Promise<boolean>
  @Local controlsOpened: boolean = false
  @Param autoPlay: boolean = false
  /** 镜像 controller.backend，用于驱动多后端分支重建 */
  @Local backendMode: PlayerBackend = 'avplayer'
  /** 镜像 controller.aspectRatioMode，用于驱动 renderFit 响应式更新 */
  @Local aspectRatioMode: AspectRatioMode = AspectRatioMode.FIT
  /**
   * 字幕选择器抽屉「退出搜索结果」回调。
   * 由 SubtitleSelectorDrawerDialog.aboutToAppear 注册；
   * onWillDismiss 拦截返回键时调用：若处于搜索结果视图则退回轨道列表（返回 true），否则返回 false。
   */
  private subtitleTryHideSearch: (() => boolean) | undefined = undefined

  // ASS 解析结果缓存：相同 raw 文本不重复解析（#17 AC）
  private _lastRawText: string = ''
  private _lastParsedSubtitle: ParsedSubtitle | null = null

  private handleMpvInitError(error: BusinessError): void {
    console.error(`[VideoPlayer] mpv init 异常: code=${error.code} msg=${error.message}`)
    this.resetInitMode()
  }

  @Monitor('controller.backend')
  onBackendChange(): void {
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
    return resolveRenderFitForAspectRatioMode(mode)
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

  private isPlaybackCompletedState(): boolean {
    const duration = this.controller.duration
    const current = this.controller.currentTime
    if (duration <= 0) {
      return false
    }
    return current >= duration
  }

  /** 从 VideoData 推断字幕存储用的 sourceType 字符串 */
  private resolveSubtitleSourceType(): string {
    if (this.data.fileSourceType) {
      return this.data.fileSourceType
    }
    if (this.data.type === VideoDataType.FILE_URI) {
      return 'local'
    }
    return 'network'
  }

  /** 提取 VideoData.name 的字符串形式（ResourceStr → string），供字幕面板展示中文标题。 */
  private resolveDisplayTitle(): string {
    const name = this.data.name;
    if (name === undefined) {
      return ''
    }
    if (typeof name === 'string') {
      return name
    }
    return ''
  }

  controlsDialogController = new CustomDialogController({
    builder: VideoControlsDialog({
      videoController: this.controller,
      onOpenSettings: () => {
        this.controlsDialogController.close()
        this.settingsDialogController.open()
      },
      onOpenSubtitleSelector: () => {
        this.controlsDialogController.close()
        this.subtitleSelectorDialogController.open()
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
      },
      onEpisodeSelect: (item: PlaybackContextItem) => this.onEpisodeSelect(item)
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
      videoController: this.controller,
      videoPath: this.data.videoSrc,
      sourceType: this.resolveSubtitleSourceType(),
      sourceId: this.data.fileSourceId ?? '0',
      scrapeOriginalTitle: this.data.scrapeOriginalTitle,
      tmdbId: this.data.tmdbId,
      imdbId: this.data.imdbId,
      seasonNumber: this.data.seasonNumber,
      episodeNumber: this.data.episodeNumber,
      displayTitle: this.resolveDisplayTitle(),
      // 注册回调：onWillDismiss 拦截返回键时，先调用此函数尝试退出搜索结果视图
      onRegisterResetSearch: (fn: () => boolean) => {
        this.subtitleTryHideSearch = fn
      }
    }),
    customStyle: true,
    backgroundColor: Color.Transparent,
    maskColor: Color.Transparent,
    width: '100%',
    height: '100%',
    cornerRadius: 0,
    onWillDismiss: (action: DismissDialogAction) => {
      // 若处于搜索结果视图，退回轨道列表而不关闭 Dialog
      if (this.subtitleTryHideSearch?.()) {
        // subtitleTryHideSearch 已将 showSearchResults 置 false，不调用 action.dismiss()
        return
      }
      action.dismiss()
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

    // 不足 8 个逗号，不是 ASS Dialogue 格式
    if (eighthCommaIdx < 0) {
      // 剥离 HTML 标签（AVPlayer onSubtitleUpdate 可能包含 <font size="85.545"></font> 等）
      return this.stripHtmlTags(raw)
    }

    // 检验第一个字段是否为数字（ASS Dialogue 的序号/Layer 总是数字）
    const firstCommaIdx = raw.indexOf(',')
    if (firstCommaIdx > 0) {
      const firstField = raw.substring(0, firstCommaIdx).trim()
      if (firstField.length === 0) {
        // 第一字段为空，不是 ASS Dialogue
        return this.stripHtmlTags(raw)
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
        // 第一字段不是纯数字，不是 ASS Dialogue
        return this.stripHtmlTags(raw)
      }
    } else {
      // 没有逗号或第一个逗号在开头，不是 ASS Dialogue
      return this.stripHtmlTags(raw)
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
       * 剥离 HTML 标签（如 AVPlayer onSubtitleUpdate 中出现的
       * `<font size="85.545"></font>`、`<b>`、`<i>` 等）。
       * 保留标签间的文本内容，仅移除 <...> 标记本身。
       */
      private stripHtmlTags(text: string): string {
   let result = ''
   let i = 0
   while (i < text.length) {
     if (text[i] === '<') {
       // 跳过到 >，移除整个标签
       const end = text.indexOf('>', i + 1)
       if (end >= 0) {
         i = end + 1
       } else {
         // 未闭合 <：保留原字符
         result += text[i]
         i++
       }
     } else {
       result += text[i]
       i++
     }
   }
   return result
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
            this.controller.initPlayerForSurface(this.data, this.surfaceId)
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
      } else if (this.backendMode === 'mpv') {
        // MPV 内核：使用 XComponentController 模式（与 avplayer 相同），通过 surfaceId 绑定
        XComponent({
          id: 'mpvPlayerXComponent',
          type: XComponentType.SURFACE,
          controller: this.xComponentController
        })
          .onLoad(() => {
            if (!this.tryMarkInit('mpv')) {
              return
            }
            this.surfaceId = this.xComponentController.getXComponentSurfaceId()
            emitter.once(PlayerEvents.PREPARED, () => {
              if (this.autoPlay) {
                this.controller.play()
              } else {
                this.controlsDialogController.open()
              }
            })
            // 先 initPlayer（创建 MpvPlayerAdapter），等 onAreaChange 拿到有效宽高后再 setMpvSurface
            this.controller.initPlayerForSurface(this.data, this.surfaceId).catch((error: BusinessError) => {
              this.handleMpvInitError(error)
            })
          })
          .onAreaChange((_oldValue: Area, newValue: Area) => {
            // MPV 需要 onAreaChange 拿到有效宽高后再绑定 surface
            // onAreaChange 返回的是 VP（虚拟像素），VidAll_Player 需要物理像素
            if (this.controller.backend === 'mpv') {
              const vpW = typeof newValue.width === 'number' ? newValue.width : 0
              const vpH = typeof newValue.height === 'number' ? newValue.height : 0
              const uiCtx = this.getUIContext()
              const w = uiCtx.vp2px(vpW)
              const h = uiCtx.vp2px(vpH)
              console.info(`[VideoPlayer] mpv onAreaChange: vp=${vpW}x${vpH} px=${w}x${h} surfaceId=${this.surfaceId.substring(0, 8)}... bound=${this.controller.isMpvSurfaceBound}`)
              if (w > 0 && h > 0 && this.surfaceId.length > 0) {
                // 无论播放器是否就绪都上报；Controller 会缓存 surface 并在 MPV adapter 创建后绑定。
                this.controller.setMpvSurface(this.surfaceId, w, h)
              }
            }
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
        this.controlsDialogController.open()
    })
  }

  aboutToDisappear(): void {
    emitter.off(PlayerEvents.COMPLETED.eventId)
  }

}
