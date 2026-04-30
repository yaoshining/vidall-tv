import { debounce } from "@ibestservices/ibest-ui"
import { VideoPlayerController, SubtitleTrackItem, AudioTrackItem, PlayerBackend, AspectRatioMode } from "./VideoPlayerController"
import { VpeQualityLevel } from "../../../utils/VpeEnhancerUtil"
import { hilog } from "@kit.PerformanceAnalysisKit"
import { LengthMetrics } from "@kit.ArkUI"
import { media } from "@kit.MediaKit"
import { EpisodeListPanel } from './EpisodeListPanel'
import { PlaybackContextItem, MediaLibraryContext } from './PlaybackContext'
import {
  loadEpisodeAutoplaySettings,
  saveEpisodeAutoplayCountdownSeconds,
  saveEpisodeAutoplayEnabled
} from './EpisodeAutoplayPreferences'

@ComponentV2
struct VideoControls {
  @Require @Param videoController: VideoPlayerController
  @Require @Param dialogController: CustomDialogController
  @Require @Param openSettings: () => void
  closeTimer?: number
  seekTimer?: number
  private AUTO_CLOSE_TIMEOUT = 5000
  @Local showSubtitleMenu: boolean = false
  @Local showAudioMenu: boolean = false
  @Local audioButtonFocused: boolean = false
  @Local subtitleButtonFocused: boolean = false
  @Local settingButtonFocused: boolean = false
  @Local sliderHovered: boolean = false
  @Local sliderFocused: boolean = false
  // ── 进度条 hover tooltip ──
  @Local hoverTimeMs: number = 0      // hover/焦点位置对应的时间（ms）
  @Local sliderWidth: number = 0      // Slider 组件实际宽度（vp）

  /** 将毫秒格式化为 HH:MM:SS 或 MM:SS */
  private formatTime(ms: number): string {
    const totalSec = Math.floor(ms / 1000)
    const h = Math.floor(totalSec / 3600)
    const m = Math.floor((totalSec % 3600) / 60)
    const s = totalSec % 60
    const mm = m < 10 ? `0${m}` : `${m}`
    const ss = s < 10 ? `0${s}` : `${s}`
    if (h > 0) {
      const hh = h < 10 ? `0${h}` : `${h}`
      return `${hh}:${mm}:${ss}`
    }
    return `${mm}:${ss}`
  }

  /** tooltip 宽度（vp）：时长 ≥ 1 小时时使用 136 以容纳 hh:mm:ss，否则 100 */
  private tooltipWidthVp(): number {
    return this.videoController.duration >= 3600000 ? 136 : 100
  }

  @Builder
  SliderTooltip() {
    Text(this.formatTime(this.hoverTimeMs))
      .fontSize(20)
      .fontColor(Color.White)
      .fontWeight(FontWeight.Medium)
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .backgroundColor('#CC000000')
      .borderRadius(8)
      .width(this.tooltipWidthVp())
      .position({ x: this.getTooltipOffsetX(), y: 0 })
  }

  /** 计算 tooltip 左边距：按当前时间比例居中对齐，并限制不超出两端 */
  private getTooltipOffsetX(): number {
    const TOOLTIP_W = this.tooltipWidthVp()
    if (this.sliderWidth <= 0 || this.videoController.duration <= 0) {
      return 0
    }
    const ratio = this.hoverTimeMs / this.videoController.duration
    const center = ratio * this.sliderWidth
    const raw = center - TOOLTIP_W / 2
    if (raw < 0) return 0
    if (raw + TOOLTIP_W > this.sliderWidth) return this.sliderWidth - TOOLTIP_W
    return raw
  }

  @Builder
  SubtitleMenu() {
    Column() {
      List() {
        // 关闭字幕
        ListItem() {
          Row() {
            Text('关闭字幕')
              .fontSize(16)
              .fontColor(Color.White)
            if (this.videoController.activeSubtitleIndex === -1) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontColor([Color.White])
                .fontSize(20)
            }
          }
          .width('100%')
          .height(50)
          .justifyContent(FlexAlign.SpaceBetween)
          .padding({ left: 20, right: 20 })
        }
        .onClick(() => {
          this.videoController.switchSubtitleTrack(-1)
          this.showSubtitleMenu = false
          this.enableAutoHide()
        })

        // 所有字幕轨道（内嵌 + 外部）
        ForEach(this.videoController.allSubtitleTracks, (item: SubtitleTrackItem, index: number) => {
          ListItem() {
            Row() {
              Column({ space: 2 }) {
                Text(item.displayName)
                  .fontSize(16)
                  .fontColor(Color.White)
                if (item.kind === 'external') {
                  Text('外部文件')
                    .fontSize(11)
                    .fontColor('#FFA500')
                }
              }
              .alignItems(HorizontalAlign.Start)

              if (this.videoController.activeSubtitleIndex === index) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontColor([Color.White])
                  .fontSize(20)
              }
            }
            .width('100%')
            .height(item.kind === 'external' ? 60 : 50)
            .justifyContent(FlexAlign.SpaceBetween)
            .padding({ left: 20, right: 20 })
          }
          .onClick(() => {
            this.videoController.switchSubtitleTrack(index)
            this.showSubtitleMenu = false
            this.enableAutoHide()
          })
        })

        // 字幕延迟调整（仅在外部 SRT 字幕激活时显示；内嵌轨由播放器原生渲染，延迟不适用）
        if (this.videoController.activeSubtitleIndex >= 0 && this.videoController.hasSrtSubtitle) {
          ListItem() {
            Column({ space: 8 }) {
              Text('字幕延迟')
                .fontSize(13)
                .fontColor('rgba(255,255,255,0.6)')
                .alignSelf(ItemAlign.Start)
                .padding({ left: 20 })
              Row({ space: 8 }) {
                Button('-500ms')
                  .fontSize(13)
                  .fontColor(Color.White)
                  .backgroundColor('rgba(255,255,255,0.15)')
                  .borderRadius(6)
                  .height(36)
                  .onClick(() => {
                    this.videoController.adjustSubtitleDelay(-500)
                  })
                Button('-100ms')
                  .fontSize(13)
                  .fontColor(Color.White)
                  .backgroundColor('rgba(255,255,255,0.15)')
                  .borderRadius(6)
                  .height(36)
                  .onClick(() => {
                    this.videoController.adjustSubtitleDelay(-100)
                  })
                Text(this.getDelayLabel())
                  .fontSize(13)
                  .fontColor(this.videoController.subtitleDelayMs === 0 ? 'rgba(255,255,255,0.6)' : '#FFD700')
                  .width(80)
                  .textAlign(TextAlign.Center)
                Button('+100ms')
                  .fontSize(13)
                  .fontColor(Color.White)
                  .backgroundColor('rgba(255,255,255,0.15)')
                  .borderRadius(6)
                  .height(36)
                  .onClick(() => {
                    this.videoController.adjustSubtitleDelay(100)
                  })
                Button('+500ms')
                  .fontSize(13)
                  .fontColor(Color.White)
                  .backgroundColor('rgba(255,255,255,0.15)')
                  .borderRadius(6)
                  .height(36)
                  .onClick(() => {
                    this.videoController.adjustSubtitleDelay(500)
                  })
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ left: 12, right: 12 })
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })
          }
        }
      }
      .width('100%')
      .backgroundColor('rgba(0, 0, 0, 0.8)')
      .borderRadius(8)
    }
    .padding(10)
  }

  @Builder
  AudioMenu() {
    Column() {
      List() {
        ForEach(this.videoController.audioTracks, (item: AudioTrackItem, index: number) => {
          ListItem() {
            Row() {
              Text(item.displayName)
                .fontSize(16)
                .fontColor(Color.White)
              if (this.videoController.activeAudioIndex === index) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontColor([Color.White])
                  .fontSize(20)
              }
            }
            .width('100%')
            .height(50)
            .justifyContent(FlexAlign.SpaceBetween)
            .padding({ left: 20, right: 20 })
          }
          .onClick(() => {
            this.dispatchAudioTrackSwitch(index)
            this.showAudioMenu = false
            // forceStart=true：切换后不管当前 isPlaying 状态（switchAudioTrack 内部会 pause）
            // 都强制启动自动隐藏定时器，seekDone 恢复播放后控件会正常隐藏
            this.enableAutoHide(true)
          })
        })
      }
      .width('100%')
      .backgroundColor('rgba(0, 0, 0, 0.8)')
      .borderRadius(8)
    }
    .padding(10)
  }

  build() {
    RelativeContainer() {
      // ── 顶部栏：标题 + 音轨按钮 + 字幕按钮 ──
      Flex({
        justifyContent: FlexAlign.SpaceBetween,
        alignItems: ItemAlign.Start
      }) {
        Text(this.videoController.name)
          .fontSize($r('app.float.font_h8_title_secondary'))
          .fontColor(Color.White)
          .textShadow({ radius: 3, offsetX: 3, offsetY: 3, color: Color.Black })
          .width("60%")
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // 音轨按钮 + 字幕按钮
        Flex({ direction: FlexDirection.Row, justifyContent: FlexAlign.End, alignItems: ItemAlign.Center }) {
          // 音轨按钮
          if (this.videoController.audioTracks.length > 0) {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.folder'))
                .fontColor([Color.White])
                .fontSize(24)
              Text(this.getActiveAudioName())
                .fontSize(14)
                .fontColor(Color.White)
            }
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor(this.audioButtonFocused ? 'rgba(27, 120, 242, 0.35)' : 'rgba(0, 0, 0, 0.5)')
            .borderRadius(20)
            .border({ width: this.audioButtonFocused ? 2 : 1, color: this.audioButtonFocused ? '#66A9D8FF' : 'rgba(255, 255, 255, 0.18)' })
            .focusable(true)
            .onFocus(() => { this.audioButtonFocused = true })
            .onBlur(() => { this.audioButtonFocused = false })
            .onClick(() => {
              this.showAudioMenu = !this.showAudioMenu
              clearTimeout(this.closeTimer)
            })
          }

          // 字幕按钮
          if (this.videoController.allSubtitleTracks.length > 0) {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.text_bubble_left_2'))
                .fontColor([this.videoController.activeSubtitleIndex >= 0 ? Color.White : Color.Gray])
                .fontSize(24)
              Text(this.getActiveSubtitleName())
                .fontSize(14)
                .fontColor(this.videoController.activeSubtitleIndex >= 0 ? Color.White : Color.Gray)
            }
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor(this.subtitleButtonFocused ? 'rgba(27, 120, 242, 0.35)' : 'rgba(0, 0, 0, 0.5)')
            .borderRadius(20)
            .border({ width: this.subtitleButtonFocused ? 2 : 1, color: this.subtitleButtonFocused ? '#66A9D8FF' : 'rgba(255, 255, 255, 0.18)' })
            .focusable(true)
            .onFocus(() => { this.subtitleButtonFocused = true })
            .onBlur(() => { this.subtitleButtonFocused = false })
            .onClick(() => {
              this.showSubtitleMenu = !this.showSubtitleMenu
              clearTimeout(this.closeTimer)
            })
          }

          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.gearshape'))
              .fontColor([Color.White])
              .fontSize(22)
            Text('设置')
              .fontSize(16)
              .fontColor(Color.White)
          }
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(this.settingButtonFocused ? 'rgba(27, 120, 242, 0.35)' : 'rgba(0, 0, 0, 0.5)')
          .borderRadius(20)
          .border({ width: this.settingButtonFocused ? 2 : 1, color: this.settingButtonFocused ? '#66A9D8FF' : 'rgba(255, 255, 255, 0.18)' })
          .focusable(true)
          .onFocus(() => { this.settingButtonFocused = true })
          .onBlur(() => { this.settingButtonFocused = false })
          .onClick(() => {
            this.showSubtitleMenu = false
            this.showAudioMenu = false
            clearTimeout(this.closeTimer)
            this.openSettings()
          })
        }
        .width("40%")
        .margin({ right: 8 })
      }
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [['rgba(0, 0, 0, 0.58)', 0.0], ['rgba(0, 0, 0, 0)', 1.0]]
      })
      .alignRules({
        left: { anchor: '__container__', align: HorizontalAlign.Start },
        top: { anchor: '__container__', align: VerticalAlign.Top }
      })
      .height("22%")
      .padding(20)

      // ── 播放暂停居中按钮 ──
      if (!this.videoController.isPlaying) {
        Column() {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontColor([Color.White])
            .fontSize(48)
        }
        .alignRules({
          center: { anchor: '__container__', align: VerticalAlign.Center },
          middle: { anchor: '__container__', align: HorizontalAlign.Center }
        })
        .backgroundColor('rgba(200, 200, 200, 0.2)')
        .backdropBlur(40)
        .padding(20)
        .borderRadius(99)
        .border({ width: 1, color: 'rgba(255, 255, 255, 0.2)' })
        .shadow({ radius: 20, color: 'rgba(0, 0, 0, 0.4)' })
      }

      // ── 底部进度条 ──
      Flex({ alignItems: ItemAlign.End }) {
        Flex({
          alignItems: ItemAlign.Center,
          justifyContent: FlexAlign.SpaceBetween,
          space: { main: LengthMetrics.vp(6) }
        }) {
          Text(`${this.videoController.currentTimeDisplay}`)
            .flexShrink(0)
          // Slider + hover tooltip
          Stack({ alignContent: Alignment.Bottom }) {
            // tooltip 层
            Row() {
              this.SliderTooltip()
            }
            .width('100%')
            .height(44)
            .hitTestBehavior(HitTestMode.Transparent)
            .offset({ y: -42 })
            .visibility(this.sliderHovered ? Visibility.Visible : Visibility.Hidden)

            Slider({
              value: this.videoController.currentTime,
              min: 0,
              max: this.videoController.duration,
              style: SliderStyle.OutSet
            })
              .blockSize({ width: (this.sliderHovered || this.sliderFocused) ? 20 : 12, height: (this.sliderHovered || this.sliderFocused) ? 20 : 12 })
              .trackThickness((this.sliderHovered || this.sliderFocused) ? 8 : 4)
              .focusable(true)
              .onChange((value, mode) => {
                this.hoverTimeMs = value
                if (mode === SliderChangeMode.Begin) {
                  clearTimeout(this.closeTimer)
                  this.videoController.pause()
                  this.videoController.currentTime = value
                  this.videoController.seek(value)
                }
                if (mode === SliderChangeMode.Moving) {
                  this.videoController.currentTime = value
                }
                if (mode === SliderChangeMode.End) {
                  this.videoController.seek(value)
                  this.videoController.play().then(() => {
                    this.enableAutoHide(true)
                  })
                }
              })
              .onHover((isHover: boolean, event: HoverEvent) => {
                this.sliderHovered = isHover
                if (isHover && event.x !== undefined) {
                  const x: number = event.x
                  if (this.sliderWidth > 0 && this.videoController.duration > 0) {
                    const ratio = Math.max(0, Math.min(1, x / this.sliderWidth))
                    this.hoverTimeMs = ratio * this.videoController.duration
                  }
                }
              })
              .onMouse((event: MouseEvent) => {
                if (event.action === MouseAction.Move && event.x !== undefined) {
                  this.sliderHovered = true
                  const x: number = event.x
                  if (this.sliderWidth > 0 && this.videoController.duration > 0) {
                    const ratio = Math.max(0, Math.min(1, x / this.sliderWidth))
                    this.hoverTimeMs = ratio * this.videoController.duration
                  }
                }
              })
              .onFocus(() => {
                this.sliderFocused = true
                this.sliderHovered = true
                this.hoverTimeMs = this.videoController.currentTime
              })
              .onBlur(() => {
                this.sliderFocused = false
                this.sliderHovered = false
              })
              .onAreaChange((_oldVal, newVal) => {
                this.sliderWidth = newVal.width as number
              })
              .width('100%')
              .animation({ duration: 200, curve: Curve.EaseInOut })
          }
          .flexGrow(1)
          .alignContent(Alignment.Bottom)
          Text(`${this.videoController.durationDisplay}`)
            .flexShrink(0)
        }
      }
      .alignRules({
        bottom: { anchor: '__container__', align: VerticalAlign.Bottom }
      })
      .linearGradient({
        direction: GradientDirection.Top,
        colors: [['rgba(0, 0, 0, 0.5)', 0.0], ['rgba(0, 0, 0, 0)', 1.0]]
      })
      .height("20%")
      .padding(20)

      // ── 字幕菜单：必须在进度条之后声明，层叠在进度条之上 ──
      if (this.showSubtitleMenu) {
        Column() {
          this.SubtitleMenu()
        }
        .alignRules({
          top: { anchor: '__container__', align: VerticalAlign.Top },
          right: { anchor: '__container__', align: HorizontalAlign.End }
        })
        .margin({ top: 80, right: 20 })
        .width('300vp')
        .onClick(() => {
          // 阻止事件冒泡
        })
      }

      // ── 音轨菜单 ──
      if (this.showAudioMenu) {
        Column() {
          this.AudioMenu()
        }
        .alignRules({
          top: { anchor: '__container__', align: VerticalAlign.Top },
          right: { anchor: '__container__', align: HorizontalAlign.End }
        })
        .margin({ top: 80, right: this.videoController.allSubtitleTracks.length > 0 ? 380 : 20 })
        .width('300vp')
        .onClick(() => {
          // 阻止事件冒泡
        })
      }
    }
    .hitTestBehavior(HitTestMode.Transparent)
    .onClick(async () => {
      await this.videoController.toggle()
      this.enableAutoHide()
    })
  }

  private getActiveSubtitleName(): string {
    const idx = this.videoController.activeSubtitleIndex;
    if (idx < 0) {
      return '字幕';
    }
    const tracks = this.videoController.allSubtitleTracks;
    if (idx < tracks.length) {
      return tracks[idx].displayName;
    }
    return '字幕';
  }

  /** 格式化字幕延迟偏移显示文本，如 "+500ms"、"0ms"、"-100ms" */
  private getDelayLabel(): string {
    const d = this.videoController.subtitleDelayMs;
    if (d === 0) { return '0ms'; }
    return d > 0 ? `+${d}ms` : `${d}ms`;
  }

  private getActiveAudioName(): string {
    const idx = this.videoController.activeAudioIndex;
    if (idx >= 0 && idx < this.videoController.audioTracks.length) {
      const audioTrack = this.videoController.audioTracks[idx];
      // 截断长名称，最多显示 12 个字符
      if (audioTrack.displayName.length > 12) {
        return audioTrack.displayName.substring(0, 12) + '...';
      }
      return audioTrack.displayName;
    }
    return '音轨';
  }

  private dispatchAudioTrackSwitch(index: number): void {
    setTimeout(() => {
      this.videoController.switchAudioTrack(index)
    }, 0)
  }

  private enableAutoHide(forceStart: boolean = false): void {
    clearTimeout(this.closeTimer)
    if (forceStart || this.videoController.isPlaying) {
      this.closeTimer = setTimeout(() => {
        this.dialogController.close()
      }, this.AUTO_CLOSE_TIMEOUT)
    }
  }

  aboutToAppear(): void {
    this.enableAutoHide()
  }

  aboutToDisappear(): void {
    clearTimeout(this.closeTimer)
    clearTimeout(this.seekTimer)
  }
}

@CustomDialog
export struct VideoControlsDialog {
  controller: CustomDialogController
  @Require videoController: VideoPlayerController
  @Require onOpenSettings: () => void
  @State opacityValue: number = 0;

  aboutToAppear(): void {
    this.getUIContext().animateTo({ duration: 300 }, () => {
      this.opacityValue = 1;
    });
  }

  aboutToDisappear(): void {
    this.controller.close()
  }

  build() {
    VideoControls({
      videoController: this.videoController,
      dialogController: this.controller,
      openSettings: this.onOpenSettings
    })
      .opacity(this.opacityValue)
  }
}

interface AspectRatioOption {
  label: string;
  mode: AspectRatioMode;
}

interface SpeedOption {
  label: string;
  speed: number;
}

const PLAYER_SETTINGS_ASPECT_RATIO_OPTIONS: AspectRatioOption[] = [
  { label: '适应', mode: AspectRatioMode.FIT },
  { label: '填充', mode: AspectRatioMode.FILL },
  { label: '拉伸', mode: AspectRatioMode.STRETCH },
]

const PLAYER_SETTINGS_SPEED_OPTIONS: SpeedOption[] = [
  { label: '0.5x', speed: 0.5 },
  { label: '0.75x', speed: 0.75 },
  { label: '1.0x', speed: 1.0 },
  { label: '1.25x', speed: 1.25 },
  { label: '1.5x', speed: 1.5 },
  { label: '2.0x', speed: 2.0 },
]

const PLAYER_SETTINGS_CHIP_HEIGHT: number = 68
const PLAYER_SETTINGS_CHIP_RADIUS: number = 22
const PLAYER_SETTINGS_CHIP_FONT_SIZE: number = 18
const PLAYER_SETTINGS_CHIP_HORIZONTAL_PADDING: number = 18
const PLAYER_SETTINGS_CHIP_VERTICAL_PADDING: number = 10
const PLAYER_SETTINGS_CHIP_GAP: number = 10
const PLAYER_SETTINGS_CHIP_SCALE_FOCUSED: number = 1.04
const DEFAULT_PLAYBACK_RATE_INDEX: number = 2
const PLAYER_SETTINGS_DIAGNOSTIC_PREFIX: string = '[#180-settings]'
const PLAYER_SETTINGS_DIAGNOSTIC_TAG: string = 'PlayerSettingsDialog'

export interface PlayerSettingsChipStyleState {
  isFocused: boolean
  isHovered: boolean
  isSelected: boolean
  // 兼容保留：沿用旧的 outline 语义字段，供已有测试/样式语义判断继续读取。
  // 当前值芯片真实渲染已改为 borderWidth / borderColor，这组字段不再直接驱动 SelectionOptionChip 的边框。
  showFocusOutline: boolean
  showSelectedOutline: boolean
  showWaveIcon: boolean
  scale: number
  shadowRadius: number
  shadowColor: string
  backgroundColor: string
  labelColor: string
  focusBorderWidth: number
  selectedBorderWidth: number
  height: number
  borderRadius: number
  labelFontSize: number
  horizontalPadding: number
  verticalPadding: number
  groupGap: number
  // 当前实际渲染来源：SelectionOptionChip 通过这组真实边框字段输出 UI。
  borderWidth: number
  borderColor: string
}

export interface PlayerSettingsSpeedChipRenderModel {
  label: string
  speed: number
  styleState: PlayerSettingsChipStyleState
}

export interface PlayerSettingsAspectRatioChipRenderModel {
  label: string
  mode: AspectRatioMode
  styleState: PlayerSettingsChipStyleState
}

export interface PlayerSettingsDiagnosticVisualSnapshot {
  idx: number
  label: string
  roles: string
  styleState: PlayerSettingsChipStyleState
}

export function buildPlayerSettingsSelectionChipKey(optionKey: string, label: string): string {
  return `${optionKey}:${label}`
}

export function buildPlayerSettingsSelectionStateKey(optionKey: string, isSelected: boolean): string {
  return `${optionKey}:${isSelected ? 'selected' : 'not-selected'}`
}

export function getPlayerSettingsChipStyleState(
  isFocused: boolean,
  isSelected: boolean,
  isHovered: boolean = false
): PlayerSettingsChipStyleState {
  const isEmphasized = isFocused || isHovered
  const styleState: PlayerSettingsChipStyleState = {
    isFocused,
    isHovered,
    isSelected,
    showFocusOutline: false,
    showSelectedOutline: false,
    showWaveIcon: false,
    scale: isEmphasized ? PLAYER_SETTINGS_CHIP_SCALE_FOCUSED : 1,
    shadowRadius: isEmphasized ? 12 : 0,
    shadowColor: isEmphasized ? '#386EA8E0' : '#00000000',
    backgroundColor: isSelected ? 'rgba(255, 255, 255, 0.28)' :
      isEmphasized ? 'rgba(255, 255, 255, 0.22)' : 'rgba(255, 255, 255, 0.12)',
    labelColor: isSelected ? '#F9FCFF' : isEmphasized ? '#F3F7FF' : '#E8EDF5',
    focusBorderWidth: 0,
    selectedBorderWidth: 0,
    height: PLAYER_SETTINGS_CHIP_HEIGHT,
    borderRadius: PLAYER_SETTINGS_CHIP_RADIUS,
    labelFontSize: PLAYER_SETTINGS_CHIP_FONT_SIZE,
    horizontalPadding: PLAYER_SETTINGS_CHIP_HORIZONTAL_PADDING,
    verticalPadding: PLAYER_SETTINGS_CHIP_VERTICAL_PADDING,
    groupGap: PLAYER_SETTINGS_CHIP_GAP,
    borderWidth: 0,
    borderColor: '#00000000'
  }
  return styleState
}

export function getPlayerSettingsValueChipStyleState(
  isFocused: boolean,
  isSelected: boolean,
  isHovered: boolean = false
): PlayerSettingsChipStyleState {
  const isEmphasized = isFocused || isHovered
  const scale = isSelected ? 1.05 :
    isFocused ? PLAYER_SETTINGS_CHIP_SCALE_FOCUSED :
    isHovered ? 1.02 : 1
  const borderWidth = isSelected || isEmphasized ? 2 : 1
  const shadowRadius = isSelected ? 14 : isFocused ? 12 : isHovered ? 8 : 0
  const shadowColor = isSelected ? '#33597FB8' :
    isFocused ? '#386EA8E0' :
    isHovered ? '#2A6EA8E0' : '#00000000'
  const styleState: PlayerSettingsChipStyleState = {
    isFocused,
    isHovered,
    isSelected,
    showFocusOutline: false,
    showSelectedOutline: false,
    showWaveIcon: false,
    scale,
    shadowRadius,
    shadowColor,
    backgroundColor: isSelected ? 'rgba(255, 255, 255, 0.45)' :
      isEmphasized ? 'rgba(255, 255, 255, 0.18)' : 'rgba(255, 255, 255, 0.1)',
    labelColor: isSelected ? '#F3F7FF' : isEmphasized ? '#EFF2FB' : '#D7DCE7',
    // 兼容保留：旧测试和语义判断仍读取 focusBorderWidth / selectedBorderWidth。
    // 当前值芯片的真实边框渲染以下方 borderWidth / borderColor 为准。
    focusBorderWidth: isSelected ? 0 : isEmphasized ? 2 : 0,
    selectedBorderWidth: isSelected ? 2 : 0,
    height: PLAYER_SETTINGS_CHIP_HEIGHT,
    borderRadius: PLAYER_SETTINGS_CHIP_RADIUS,
    labelFontSize: PLAYER_SETTINGS_CHIP_FONT_SIZE,
    horizontalPadding: PLAYER_SETTINGS_CHIP_HORIZONTAL_PADDING,
    verticalPadding: PLAYER_SETTINGS_CHIP_VERTICAL_PADDING,
    groupGap: PLAYER_SETTINGS_CHIP_GAP,
    borderWidth,
    borderColor: isSelected ? '#fffefe' : isEmphasized ? '#66A9D8FF' : '#45ffffff'
  }
  return styleState
}

export function buildPlaybackSpeedChipRenderModels(
  playbackSpeed: number,
  focusedIndex: number = -1,
  hoveredIndex: number = -1
): PlayerSettingsSpeedChipRenderModel[] {
  const renderModels: PlayerSettingsSpeedChipRenderModel[] = []
  const selectedIndex = resolveSelectedPlaybackRateIndex(playbackSpeed)
  for (let idx = 0; idx < PLAYER_SETTINGS_SPEED_OPTIONS.length; idx++) {
    const option = PLAYER_SETTINGS_SPEED_OPTIONS[idx]
    const isSelected = selectedIndex === idx
    const styleState = getPlayerSettingsValueChipStyleState(
      focusedIndex === idx,
      isSelected,
      hoveredIndex === idx
    )
    const renderModel: PlayerSettingsSpeedChipRenderModel = {
      label: option.label,
      speed: option.speed,
      styleState
    }
    renderModels.push(renderModel)
  }
  return renderModels
}

export function buildAspectRatioChipRenderModels(
  currentMode: AspectRatioMode,
  focusedIndex: number = -1,
  hoveredIndex: number = -1
): PlayerSettingsAspectRatioChipRenderModel[] {
  const renderModels: PlayerSettingsAspectRatioChipRenderModel[] = []
  for (let idx = 0; idx < PLAYER_SETTINGS_ASPECT_RATIO_OPTIONS.length; idx++) {
    const option = PLAYER_SETTINGS_ASPECT_RATIO_OPTIONS[idx]
    const isSelected = isAspectRatioOptionSelected(currentMode, option.mode)
    const styleState = getPlayerSettingsValueChipStyleState(
      focusedIndex === idx,
      isSelected,
      hoveredIndex === idx
    )
    const renderModel: PlayerSettingsAspectRatioChipRenderModel = {
      label: option.label,
      mode: option.mode,
      styleState
    }
    renderModels.push(renderModel)
  }
  return renderModels
}

export function resolveSelectedPlaybackRateIndex(playbackSpeed: number): number {
  switch (playbackSpeed) {
    case 0.5:
      return 0
    case 0.75:
      return 1
    case 1.0:
      return 2
    case 1.25:
      return 3
    case 1.5:
      return 4
    case 2.0:
      return 5
    default:
      return DEFAULT_PLAYBACK_RATE_INDEX
  }
}

export function isAspectRatioOptionSelected(
  currentMode: AspectRatioMode,
  optionMode: AspectRatioMode
): boolean {
  return currentMode === optionMode
}

export interface PlayerSettingsSelectionMirrorState {
  playbackSpeed: number
  aspectRatioMode: AspectRatioMode
}

export function createPlayerSettingsSelectionMirrorState(
  playbackSpeed: number,
  aspectRatioMode: AspectRatioMode
): PlayerSettingsSelectionMirrorState {
  const mirrorState: PlayerSettingsSelectionMirrorState = {
    playbackSpeed,
    aspectRatioMode
  }
  return mirrorState
}

export function syncPlayerSettingsSelectionMirrorState(
  currentState: PlayerSettingsSelectionMirrorState,
  playbackSpeed: number,
  aspectRatioMode: AspectRatioMode
): PlayerSettingsSelectionMirrorState {
  if (currentState.playbackSpeed === playbackSpeed && currentState.aspectRatioMode === aspectRatioMode) {
    return currentState
  }
  const nextState: PlayerSettingsSelectionMirrorState = {
    playbackSpeed,
    aspectRatioMode
  }
  return nextState
}

export function shouldApplyEpisodeAutoplaySettingsLoad(
  requestToken: number,
  currentToken: number,
  isDirty: boolean
): boolean {
  return requestToken === currentToken && !isDirty
}

export function formatPlayerSettingsDiagnosticLog(scope: string, detail: string): string {
  return `${PLAYER_SETTINGS_DIAGNOSTIC_PREFIX} ${scope}: ${detail}`
}

export function formatPlayerSettingsVisualSnapshotDetail(
  group: string,
  snapshot: PlayerSettingsDiagnosticVisualSnapshot
): string {
  return `group=${group} idx=${snapshot.idx} label=${snapshot.label} roles=${snapshot.roles} ` +
    `isSelected=${snapshot.styleState.isSelected} isHovered=${snapshot.styleState.isHovered} ` +
    `isFocused=${snapshot.styleState.isFocused} backgroundColor=${snapshot.styleState.backgroundColor} ` +
    `borderWidth=${snapshot.styleState.borderWidth} borderColor=${snapshot.styleState.borderColor} ` +
    `shadowRadius=${snapshot.styleState.shadowRadius} shadowColor=${snapshot.styleState.shadowColor} ` +
    `scale=${snapshot.styleState.scale} labelColor=${snapshot.styleState.labelColor}`
}

export function buildPlayerSettingsVisualSnapshotSummary(
  group: string,
  snapshots: Array<PlayerSettingsDiagnosticVisualSnapshot>
): string {
  const details: Array<string> = []
  for (let idx = 0; idx < snapshots.length; idx++) {
    details.push(formatPlayerSettingsVisualSnapshotDetail(group, snapshots[idx]))
  }
  return details.join(' || ')
}

export function formatPlayerSettingsEventSequenceDetail(
  eventType: string,
  idx: number,
  label: string,
  nextState: string,
  focusedIndex: number,
  hoveredIndex: number,
  selectedIndex: number
): string {
  return `eventType=${eventType} idx=${idx} label=${label} next=${nextState} ` +
    `focusedIndex=${focusedIndex} hoveredIndex=${hoveredIndex} selectedIndex=${selectedIndex}`
}

@CustomDialog
export struct PlayerSettingsDialog {
  controller: CustomDialogController
  @Require videoController: VideoPlayerController
  @Require onOpenSubtitleSelector: () => void
  @Require onEpisodeSelect: (item: PlaybackContextItem) => Promise<boolean>
  @State private mirroredPlaybackSpeed: number = 1.0
  @State private mirroredAspectRatioMode: AspectRatioMode = AspectRatioMode.FIT
  @State private arFocusedIndex: number = -1
  @State private speedFocusedIndex: number = -1
  @State private arHoveredIndex: number = -1
  @State private speedHoveredIndex: number = -1
  private readonly aspectRatioOptions: AspectRatioOption[] = PLAYER_SETTINGS_ASPECT_RATIO_OPTIONS
  private readonly speedOptions: SpeedOption[] = PLAYER_SETTINGS_SPEED_OPTIONS
  @State private aiEnhanceOn: boolean = true
  @State private aiEnhanceQuality: VpeQualityLevel = 'medium'
  @State private autoplayEnabled: boolean = true
  @State private autoplayCountdownSeconds: number = 8
  @State private autoplayToggleFocusedIndex: number = -1
  @State private autoplayCountdownFocusedIndex: number = -1
  @State private autoplayToggleHoveredIndex: number = -1
  @State private autoplayCountdownHoveredIndex: number = -1
  private readonly autoplayToggleOptions: Array<boolean> = [true, false]
  private readonly autoplayCountdownOptions: Array<number> = [3, 5, 8, 10]
  private autoplaySettingsLoadToken: number = 0
  private autoplaySettingsDirty: boolean = false
  private lastSpeedRenderSummary: string = ''
  private lastAspectRatioRenderSummary: string = ''

  private logPlayerSettingsDiagnostic(scope: string, detail: string): void {
    hilog.info(0x0000, PLAYER_SETTINGS_DIAGNOSTIC_TAG, formatPlayerSettingsDiagnosticLog(scope, detail))
  }

  private resolveAspectRatioSelectedIndex(mode: AspectRatioMode): number {
    for (let idx = 0; idx < this.aspectRatioOptions.length; idx++) {
      if (isAspectRatioOptionSelected(mode, this.aspectRatioOptions[idx].mode)) {
        return idx
      }
    }
    return -1
  }

  private appendVisualSnapshot(
    snapshots: Array<PlayerSettingsDiagnosticVisualSnapshot>,
    idx: number,
    role: string,
    label: string,
    styleState: PlayerSettingsChipStyleState
  ): void {
    for (let snapshotIdx = 0; snapshotIdx < snapshots.length; snapshotIdx++) {
      if (snapshots[snapshotIdx].idx === idx) {
        if (snapshots[snapshotIdx].roles.indexOf(role) < 0) {
          snapshots[snapshotIdx].roles = `${snapshots[snapshotIdx].roles}|${role}`
        }
        return
      }
    }
    const snapshot: PlayerSettingsDiagnosticVisualSnapshot = {
      idx,
      label,
      roles: role,
      styleState
    }
    snapshots.push(snapshot)
  }

  private buildSpeedVisualSnapshotSummary(renderModels: Array<PlayerSettingsSpeedChipRenderModel>): string {
    const snapshots: Array<PlayerSettingsDiagnosticVisualSnapshot> = []
    const selectedIndex = resolveSelectedPlaybackRateIndex(this.mirroredPlaybackSpeed)
    if (selectedIndex >= 0 && selectedIndex < renderModels.length) {
      this.appendVisualSnapshot(
        snapshots,
        selectedIndex,
        'selected',
        renderModels[selectedIndex].label,
        renderModels[selectedIndex].styleState
      )
    }
    if (this.speedHoveredIndex >= 0 && this.speedHoveredIndex < renderModels.length) {
      this.appendVisualSnapshot(
        snapshots,
        this.speedHoveredIndex,
        'hovered',
        renderModels[this.speedHoveredIndex].label,
        renderModels[this.speedHoveredIndex].styleState
      )
    }
    if (this.speedFocusedIndex >= 0 && this.speedFocusedIndex < renderModels.length) {
      this.appendVisualSnapshot(
        snapshots,
        this.speedFocusedIndex,
        'focused',
        renderModels[this.speedFocusedIndex].label,
        renderModels[this.speedFocusedIndex].styleState
      )
    }
    return buildPlayerSettingsVisualSnapshotSummary('speed', snapshots)
  }

  private buildAspectRatioVisualSnapshotSummary(
    renderModels: Array<PlayerSettingsAspectRatioChipRenderModel>
  ): string {
    const snapshots: Array<PlayerSettingsDiagnosticVisualSnapshot> = []
    const selectedIndex = this.resolveAspectRatioSelectedIndex(this.mirroredAspectRatioMode)
    if (selectedIndex >= 0 && selectedIndex < renderModels.length) {
      this.appendVisualSnapshot(
        snapshots,
        selectedIndex,
        'selected',
        renderModels[selectedIndex].label,
        renderModels[selectedIndex].styleState
      )
    }
    if (this.arHoveredIndex >= 0 && this.arHoveredIndex < renderModels.length) {
      this.appendVisualSnapshot(
        snapshots,
        this.arHoveredIndex,
        'hovered',
        renderModels[this.arHoveredIndex].label,
        renderModels[this.arHoveredIndex].styleState
      )
    }
    if (this.arFocusedIndex >= 0 && this.arFocusedIndex < renderModels.length) {
      this.appendVisualSnapshot(
        snapshots,
        this.arFocusedIndex,
        'focused',
        renderModels[this.arFocusedIndex].label,
        renderModels[this.arFocusedIndex].styleState
      )
    }
    return buildPlayerSettingsVisualSnapshotSummary('aspect-ratio', snapshots)
  }

  private logRenderSummaryIfChanged(scope: string, summary: string, visualSnapshotSummary: string = ''): void {
    const summaryKey = visualSnapshotSummary.length > 0 ? `${summary} || ${visualSnapshotSummary}` : summary
    if (scope === 'render/speed') {
      if (this.lastSpeedRenderSummary === summaryKey) {
        return
      }
      this.lastSpeedRenderSummary = summaryKey
    } else if (scope === 'render/aspect-ratio') {
      if (this.lastAspectRatioRenderSummary === summaryKey) {
        return
      }
      this.lastAspectRatioRenderSummary = summaryKey
    }
    this.logPlayerSettingsDiagnostic(scope, summary)
    if (visualSnapshotSummary.length > 0) {
      this.logPlayerSettingsDiagnostic(`${scope}/styleState`, visualSnapshotSummary)
    }
  }

  private logSpeedInteractionEvent(eventType: string, idx: number, label: string, nextState: string): void {
    this.logPlayerSettingsDiagnostic(
      'interaction/speed',
      formatPlayerSettingsEventSequenceDetail(
        eventType,
        idx,
        label,
        nextState,
        this.speedFocusedIndex,
        this.speedHoveredIndex,
        resolveSelectedPlaybackRateIndex(this.mirroredPlaybackSpeed)
      )
    )
  }

  private logAspectRatioInteractionEvent(eventType: string, idx: number, label: string, nextState: string): void {
    this.logPlayerSettingsDiagnostic(
      'interaction/aspect-ratio',
      formatPlayerSettingsEventSequenceDetail(
        eventType,
        idx,
        label,
        nextState,
        this.arFocusedIndex,
        this.arHoveredIndex,
        this.resolveAspectRatioSelectedIndex(this.mirroredAspectRatioMode)
      )
    )
  }

  private applySelectionMirrorState(state: PlayerSettingsSelectionMirrorState): void {
    const beforePlaybackSpeed = this.mirroredPlaybackSpeed
    const beforeAspectRatioMode = this.mirroredAspectRatioMode
    this.logPlayerSettingsDiagnostic(
      'state/applySelectionMirrorState-before',
      `playbackSpeed=${beforePlaybackSpeed} aspectRatioMode=${beforeAspectRatioMode} nextPlaybackSpeed=${state.playbackSpeed} nextAspectRatioMode=${state.aspectRatioMode}`
    )
    this.mirroredPlaybackSpeed = state.playbackSpeed
    this.mirroredAspectRatioMode = state.aspectRatioMode
    this.logPlayerSettingsDiagnostic(
      'state/applySelectionMirrorState-after',
      `playbackSpeed=${this.mirroredPlaybackSpeed} aspectRatioMode=${this.mirroredAspectRatioMode}`
    )
  }

  private syncSelectionMirrorState(): void {
    const currentState: PlayerSettingsSelectionMirrorState = createPlayerSettingsSelectionMirrorState(
      this.mirroredPlaybackSpeed,
      this.mirroredAspectRatioMode
    )
    const nextState: PlayerSettingsSelectionMirrorState = syncPlayerSettingsSelectionMirrorState(
      currentState,
      this.videoController.playbackSpeed,
      this.videoController.aspectRatioMode
    )
    this.applySelectionMirrorState(nextState)
  }

  private updatePlaybackSpeedSelection(speed: number): void {
    this.logPlayerSettingsDiagnostic(
      'state/updatePlaybackSpeedSelection-enter',
      `targetSpeed=${speed} beforePlaybackSpeed=${this.mirroredPlaybackSpeed} beforeAspectRatioMode=${this.mirroredAspectRatioMode}`
    )
    const currentState: PlayerSettingsSelectionMirrorState = createPlayerSettingsSelectionMirrorState(
      this.mirroredPlaybackSpeed,
      this.mirroredAspectRatioMode
    )
    const nextState: PlayerSettingsSelectionMirrorState = syncPlayerSettingsSelectionMirrorState(
      currentState,
      speed,
      this.mirroredAspectRatioMode
    )
    this.applySelectionMirrorState(nextState)
    this.logPlayerSettingsDiagnostic(
      'state/updatePlaybackSpeedSelection-after',
      `afterPlaybackSpeed=${this.mirroredPlaybackSpeed} afterAspectRatioMode=${this.mirroredAspectRatioMode}`
    )
    this.videoController.setPlaybackSpeed(speed)
  }

  private updateAspectRatioSelection(mode: AspectRatioMode): void {
    this.logPlayerSettingsDiagnostic(
      'state/updateAspectRatioSelection-enter',
      `targetAspectRatioMode=${mode} beforePlaybackSpeed=${this.mirroredPlaybackSpeed} beforeAspectRatioMode=${this.mirroredAspectRatioMode}`
    )
    const currentState: PlayerSettingsSelectionMirrorState = createPlayerSettingsSelectionMirrorState(
      this.mirroredPlaybackSpeed,
      this.mirroredAspectRatioMode
    )
    const nextState: PlayerSettingsSelectionMirrorState = syncPlayerSettingsSelectionMirrorState(
      currentState,
      this.mirroredPlaybackSpeed,
      mode
    )
    this.applySelectionMirrorState(nextState)
    this.logPlayerSettingsDiagnostic(
      'state/updateAspectRatioSelection-after',
      `afterPlaybackSpeed=${this.mirroredPlaybackSpeed} afterAspectRatioMode=${this.mirroredAspectRatioMode}`
    )
    this.videoController.setAspectRatioMode(mode)
  }

  aboutToAppear(): void {
    this.syncSelectionMirrorState()
    this.aiEnhanceOn = this.videoController.getResolvedAiEnhanceEnabled();
    this.aiEnhanceQuality = this.videoController.aiEnhanceQuality;
    this.arFocusedIndex = -1;
    this.speedFocusedIndex = -1;
    this.arHoveredIndex = -1;
    this.speedHoveredIndex = -1;
    this.autoplayToggleFocusedIndex = -1;
    this.autoplayCountdownFocusedIndex = -1;
    this.autoplayToggleHoveredIndex = -1;
    this.autoplayCountdownHoveredIndex = -1;
    this.autoplayEnabled = this.videoController.episodeAutoplayEnabled;
    this.autoplayCountdownSeconds = this.videoController.episodeAutoplayCountdownSeconds;
    this.autoplaySettingsDirty = false
    this.autoplaySettingsLoadToken += 1
    const currentLoadToken = this.autoplaySettingsLoadToken
    loadEpisodeAutoplaySettings().then((settings) => {
      if (!shouldApplyEpisodeAutoplaySettingsLoad(
        currentLoadToken,
        this.autoplaySettingsLoadToken,
        this.autoplaySettingsDirty
      )) {
        return
      }
      this.autoplayEnabled = settings.enabled;
      this.autoplayCountdownSeconds = settings.countdownSeconds;
      this.videoController.episodeAutoplayEnabled = settings.enabled;
      this.videoController.episodeAutoplayCountdownSeconds = settings.countdownSeconds;
    }).catch(() => {})
  }

  aboutToDisappear(): void {
    this.arFocusedIndex = -1;
    this.speedFocusedIndex = -1;
    this.arHoveredIndex = -1;
    this.speedHoveredIndex = -1;
    this.autoplayToggleFocusedIndex = -1;
    this.autoplayCountdownFocusedIndex = -1;
    this.autoplayToggleHoveredIndex = -1;
    this.autoplayCountdownHoveredIndex = -1;
  }

  /** 当 playbackContext 是媒体库上下文时返回，否则返回 undefined */
  private getMediaLibraryContext(): MediaLibraryContext | undefined {
    const ctx = this.videoController.playbackContext
    if (ctx !== undefined && ctx.contextType === 'media_library') {
      return ctx as MediaLibraryContext
    }
    return undefined
  }

  @Builder
  private SettingsChip(label: string, selected: boolean) {
    Text(label)
      .fontSize(26)
      .fontColor(selected ? '#F3F7FF' : '#D7DCE7')
      .padding({ left: 20, right: 20, top: 10, bottom: 10 })
      .backgroundColor(selected ? 'rgba(255, 255, 255, 0.45)' : 'rgba(255, 255, 255, 0.1)')
      .borderRadius("50%")
      .border({ width: selected ? 2 : 1, color: selected ? '#fffefe' : '#45ffffff' })
      .shadow({ radius: selected ? 8 : 0, color: selected ? '#33597FB8' : '#00ffffff' })
  }

  @Builder
  private SelectionOptionChip(label: string, styleState: PlayerSettingsChipStyleState) {
    Row() {
      Text(label)
        .fontSize(styleState.labelFontSize)
        .fontColor(styleState.labelColor)
        .fontWeight(styleState.isSelected ? FontWeight.Medium : FontWeight.Regular)
        .maxLines(1)
    }
    .height(styleState.height)
    .padding({ left: styleState.horizontalPadding, right: styleState.horizontalPadding })
    .justifyContent(FlexAlign.Center)
    .backgroundColor(styleState.backgroundColor)
    .border({ width: styleState.borderWidth, color: styleState.borderColor })
    .borderRadius(styleState.borderRadius)
    .shadow({ radius: styleState.shadowRadius, color: styleState.shadowColor })
    .scale({ x: styleState.scale, y: styleState.scale })
    .animation({ duration: 180, curve: Curve.EaseInOut })
  }

  private getSpeedChipStyleState(idx: number): PlayerSettingsChipStyleState {
    return getPlayerSettingsValueChipStyleState(
      this.speedFocusedIndex === idx,
      resolveSelectedPlaybackRateIndex(this.mirroredPlaybackSpeed) === idx,
      this.speedHoveredIndex === idx
    )
  }

  private getAspectRatioChipStyleState(idx: number): PlayerSettingsChipStyleState {
    return getPlayerSettingsValueChipStyleState(
      this.arFocusedIndex === idx,
      isAspectRatioOptionSelected(this.mirroredAspectRatioMode, this.aspectRatioOptions[idx].mode),
      this.arHoveredIndex === idx
    )
  }

  private getSpeedChipRenderModels(): PlayerSettingsSpeedChipRenderModel[] {
    const renderModels = buildPlaybackSpeedChipRenderModels(
      this.mirroredPlaybackSpeed,
      this.speedFocusedIndex,
      this.speedHoveredIndex
    )
    const selectedIndex = resolveSelectedPlaybackRateIndex(this.mirroredPlaybackSpeed)
    const visualSnapshotSummary = this.buildSpeedVisualSnapshotSummary(renderModels)
    this.logRenderSummaryIfChanged(
      'render/speed',
      `activePlaybackSpeed=${this.mirroredPlaybackSpeed} focusedIndex=${this.speedFocusedIndex} hoveredIndex=${this.speedHoveredIndex} selectedIndex=${selectedIndex} selectedLabel=${renderModels[selectedIndex].label}`,
      visualSnapshotSummary
    )
    return renderModels
  }

  private getAspectRatioChipRenderModels(): PlayerSettingsAspectRatioChipRenderModel[] {
    const renderModels = buildAspectRatioChipRenderModels(
      this.mirroredAspectRatioMode,
      this.arFocusedIndex,
      this.arHoveredIndex
    )
    const selectedIndex = this.resolveAspectRatioSelectedIndex(this.mirroredAspectRatioMode)
    const selectedLabel = selectedIndex >= 0 ? renderModels[selectedIndex].label : 'none'
    const visualSnapshotSummary = this.buildAspectRatioVisualSnapshotSummary(renderModels)
    this.logRenderSummaryIfChanged(
      'render/aspect-ratio',
      `activeAspectRatioMode=${this.mirroredAspectRatioMode} focusedIndex=${this.arFocusedIndex} hoveredIndex=${this.arHoveredIndex} selectedIndex=${selectedIndex} selectedLabel=${selectedLabel}`,
      visualSnapshotSummary
    )
    return renderModels
  }

  private getAutoplayToggleChipStyleState(idx: number): PlayerSettingsChipStyleState {
    return getPlayerSettingsChipStyleState(
      this.autoplayToggleFocusedIndex === idx,
      this.autoplayEnabled === this.autoplayToggleOptions[idx],
      this.autoplayToggleHoveredIndex === idx
    )
  }

  private getAutoplayCountdownChipStyleState(idx: number): PlayerSettingsChipStyleState {
    return getPlayerSettingsChipStyleState(
      this.autoplayCountdownFocusedIndex === idx,
      this.autoplayCountdownSeconds === this.autoplayCountdownOptions[idx],
      this.autoplayCountdownHoveredIndex === idx
    )
  }

  private updateEpisodeAutoplayEnabled(enabled: boolean): void {
    this.autoplaySettingsDirty = true
    this.autoplayEnabled = enabled
    this.videoController.episodeAutoplayEnabled = enabled
    saveEpisodeAutoplayEnabled(enabled).catch(() => {})
  }

  private updateEpisodeAutoplayCountdownSeconds(seconds: number): void {
    this.autoplaySettingsDirty = true
    this.autoplayCountdownSeconds = seconds
    this.videoController.episodeAutoplayCountdownSeconds = seconds
    saveEpisodeAutoplayCountdownSeconds(seconds).catch(() => {})
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)

      Scroll() {
        Column({ space: 0 }) {
          // ── 选集区域（仅 MediaLibraryContext 时显示）────────────────────────
          if (this.getMediaLibraryContext() !== undefined) {
            EpisodeListPanel({
              context: this.getMediaLibraryContext() as MediaLibraryContext,
              onSelect: (item: PlaybackContextItem) => {
                this.onEpisodeSelect(item).then((didSwitch: boolean) => {
                  if (didSwitch) {
                    this.controller.close()
                  }
                }).catch(() => {})
              }
            })
          }

          // ── 倍速播放 & 其他设置 ─────────────────────────────────────────────
          Column({ space: 28 }) {
            Column({ space: 12 }) {
              Text('倍速播放')
                .fontSize(32)
                .fontColor('#EFF2FB')
                .fontWeight(FontWeight.Medium)
                .alignSelf(ItemAlign.Start)

              Row({ space: PLAYER_SETTINGS_CHIP_GAP }) {
                ForEach(this.getSpeedChipRenderModels(), (model: PlayerSettingsSpeedChipRenderModel, idx: number) => {
                  Row() {
                    Text(model.label)
                      .fontSize(model.styleState.labelFontSize)
                      .fontColor(model.styleState.labelColor)
                      .fontWeight(model.styleState.isSelected ? FontWeight.Medium : FontWeight.Regular)
                      .maxLines(1)
                  }
                    .height(model.styleState.height)
                    .padding({
                      left: model.styleState.horizontalPadding,
                      right: model.styleState.horizontalPadding
                    })
                    .justifyContent(FlexAlign.Center)
                    .backgroundColor(model.styleState.backgroundColor)
                    .border({ width: model.styleState.borderWidth, color: model.styleState.borderColor })
                    .borderRadius(model.styleState.borderRadius)
                    .shadow({ radius: model.styleState.shadowRadius, color: model.styleState.shadowColor })
                    .scale({ x: model.styleState.scale, y: model.styleState.scale })
                    .animation({ duration: 180, curve: Curve.EaseInOut })
                    .focusable(true)
                    .onFocus(() => {
                      this.speedFocusedIndex = idx
                      this.logSpeedInteractionEvent('focus', idx, model.label, `focusedIndex=${idx}`)
                    })
                    .onBlur(() => {
                      this.speedFocusedIndex = -1
                      this.logSpeedInteractionEvent('blur', idx, model.label, 'focusedIndex=-1')
                    })
                    .onHover((isHover: boolean) => {
                      this.speedHoveredIndex = isHover ? idx : -1
                      this.logSpeedInteractionEvent(
                        'hover',
                        idx,
                        model.label,
                        `hoveredIndex=${this.speedHoveredIndex}`
                      )
                    })
                     .onClick(() => {
                       this.logSpeedInteractionEvent('click', idx, model.label, `requestedSpeed=${model.speed}`)
                       this.updatePlaybackSpeedSelection(model.speed)
                     })
                }, (model: PlayerSettingsSpeedChipRenderModel) =>
                  buildPlayerSettingsSelectionStateKey(model.speed.toString(), model.styleState.isSelected))
              }
               .justifyContent(FlexAlign.Start)
               .width('100%')
              }


            Column({ space: 12 }) {
              Text('画面比例')
                .fontSize(32)
                .fontColor('#EFF2FB')
                .fontWeight(FontWeight.Medium)
                .alignSelf(ItemAlign.Start)

              Row({ space: PLAYER_SETTINGS_CHIP_GAP }) {
                ForEach(this.getAspectRatioChipRenderModels(), (model: PlayerSettingsAspectRatioChipRenderModel, idx: number) => {
                  Row() {
                    Text(model.label)
                      .fontSize(model.styleState.labelFontSize)
                      .fontColor(model.styleState.labelColor)
                      .fontWeight(model.styleState.isSelected ? FontWeight.Medium : FontWeight.Regular)
                      .maxLines(1)
                  }
                    .height(model.styleState.height)
                    .padding({
                      left: model.styleState.horizontalPadding,
                      right: model.styleState.horizontalPadding
                    })
                    .justifyContent(FlexAlign.Center)
                    .backgroundColor(model.styleState.backgroundColor)
                    .border({ width: model.styleState.borderWidth, color: model.styleState.borderColor })
                    .borderRadius(model.styleState.borderRadius)
                    .shadow({ radius: model.styleState.shadowRadius, color: model.styleState.shadowColor })
                    .scale({ x: model.styleState.scale, y: model.styleState.scale })
                    .animation({ duration: 180, curve: Curve.EaseInOut })
                    .focusable(true)
                    .onFocus(() => {
                      this.arFocusedIndex = idx
                      this.logAspectRatioInteractionEvent('focus', idx, model.label, `focusedIndex=${idx}`)
                    })
                    .onBlur(() => {
                      this.arFocusedIndex = -1
                      this.logAspectRatioInteractionEvent('blur', idx, model.label, 'focusedIndex=-1')
                    })
                    .onHover((isHover: boolean) => {
                      this.arHoveredIndex = isHover ? idx : -1
                      this.logAspectRatioInteractionEvent(
                        'hover',
                        idx,
                        model.label,
                        `hoveredIndex=${this.arHoveredIndex}`
                      )
                    })
                     .onClick(() => {
                       this.logAspectRatioInteractionEvent(
                         'click',
                         idx,
                         model.label,
                        `requestedAspectRatioMode=${model.mode}`
                       )
                       this.updateAspectRatioSelection(model.mode)
                     })
                }, (model: PlayerSettingsAspectRatioChipRenderModel) =>
                  buildPlayerSettingsSelectionStateKey(model.mode.toString(), model.styleState.isSelected))
              }
               .justifyContent(FlexAlign.Start)
               .width('100%')
              }

            Column({ space: 12 }) {
              Text('字幕管理')
                .fontSize(32)
                .fontColor('#EFF2FB')
                .fontWeight(FontWeight.Medium)
                .alignSelf(ItemAlign.Start)

              Row() {
                this.SettingsChip('选择字幕', this.videoController.activeSubtitleIndex >= 0)
              }
              .onClick(() => {
                this.onOpenSubtitleSelector()
              })
            }

            if (this.getMediaLibraryContext() !== undefined) {
              Column({ space: 12 }) {
                Text('自动下一集')
                  .fontSize(32)
                  .fontColor('#EFF2FB')
                  .fontWeight(FontWeight.Medium)
                  .alignSelf(ItemAlign.Start)

                Row({ space: PLAYER_SETTINGS_CHIP_GAP }) {
                  ForEach(this.autoplayToggleOptions, (enabled: boolean, idx: number) => {
                    Row() {
                      this.SelectionOptionChip(enabled ? '开启' : '关闭', this.getAutoplayToggleChipStyleState(idx))
                    }
                    .focusable(true)
                    .onFocus(() => { this.autoplayToggleFocusedIndex = idx })
                    .onBlur(() => { this.autoplayToggleFocusedIndex = -1 })
                    .onHover((isHover: boolean) => {
                      this.autoplayToggleHoveredIndex = isHover ? idx : -1
                    })
                    .onClick(() => {
                      this.updateEpisodeAutoplayEnabled(enabled)
                    })
                  }, (enabled: boolean) => buildPlayerSettingsSelectionStateKey(
                    enabled ? 'enabled' : 'disabled',
                    this.autoplayEnabled === enabled
                  ))
                }
                .justifyContent(FlexAlign.Start)
                .width('100%')
              }

              Column({ space: 12 }) {
                Text('倒计时秒数')
                  .fontSize(32)
                  .fontColor('#EFF2FB')
                  .fontWeight(FontWeight.Medium)
                  .alignSelf(ItemAlign.Start)

                Row({ space: PLAYER_SETTINGS_CHIP_GAP }) {
                  ForEach(this.autoplayCountdownOptions, (seconds: number, idx: number) => {
                    Row() {
                      this.SelectionOptionChip(`${seconds}s`, this.getAutoplayCountdownChipStyleState(idx))
                    }
                    .focusable(true)
                    .onFocus(() => { this.autoplayCountdownFocusedIndex = idx })
                    .onBlur(() => { this.autoplayCountdownFocusedIndex = -1 })
                    .onHover((isHover: boolean) => {
                      this.autoplayCountdownHoveredIndex = isHover ? idx : -1
                    })
                    .onClick(() => {
                      this.updateEpisodeAutoplayCountdownSeconds(seconds)
                    })
                  }, (seconds: number) => buildPlayerSettingsSelectionStateKey(
                    seconds.toString(),
                    this.autoplayCountdownSeconds === seconds
                  ))
                }
                .justifyContent(FlexAlign.Start)
                .width('100%')
              }
            }

            if (this.videoController.shouldShowAiEnhanceSettings()) {
              Column({ space: 12 }) {
                Text('画质增强')
                  .fontSize(32)
                  .fontColor('#EFF2FB')
                  .fontWeight(FontWeight.Medium)
                  .alignSelf(ItemAlign.Start)

                Row({ space: 12 }) {
                  // 直接内联 Text + onClick，绕过 @CustomDialog @Builder 参数不刷新问题
                  Text('关闭')
                    .fontSize(26)
                    .fontColor(!this.aiEnhanceOn ? '#F3F7FF' : '#D7DCE7')
                    .padding({ left: 20, right: 20, top: 10, bottom: 10 })
                    .backgroundColor(!this.aiEnhanceOn ? 'rgba(255, 255, 255, 0.45)' : 'rgba(255, 255, 255, 0.1)')
                    .borderRadius(99)
                    .border({ width: !this.aiEnhanceOn ? 2 : 1, color: !this.aiEnhanceOn ? '#fffefe' : '#45ffffff' })
                    .onClick(() => {
                      hilog.info(0x0000, 'PlayerSettingsDialog', '画质增强: 点击关闭');
                      this.aiEnhanceOn = false;
                      this.videoController.disableAiEnhance();
                    })

                  Text('低')
                    .fontSize(26)
                    .fontColor(this.aiEnhanceOn && this.aiEnhanceQuality === 'low' ? '#F3F7FF' : '#D7DCE7')
                    .padding({ left: 20, right: 20, top: 10, bottom: 10 })
                    .backgroundColor(this.aiEnhanceOn && this.aiEnhanceQuality === 'low' ? 'rgba(255, 255, 255, 0.45)' : 'rgba(255, 255, 255, 0.1)')
                    .borderRadius(99)
                    .border({ width: this.aiEnhanceOn && this.aiEnhanceQuality === 'low' ? 2 : 1, color: this.aiEnhanceOn && this.aiEnhanceQuality === 'low' ? '#fffefe' : '#45ffffff' })
                    .onClick(() => {
                      hilog.info(0x0000, 'PlayerSettingsDialog', '画质增强: 点击低');
                      this.aiEnhanceOn = true;
                      this.aiEnhanceQuality = 'low';
                      this.videoController.setAiEnhance('low');
                    })

                  Text('中')
                    .fontSize(26)
                    .fontColor(this.aiEnhanceOn && this.aiEnhanceQuality === 'medium' ? '#F3F7FF' : '#D7DCE7')
                    .padding({ left: 20, right: 20, top: 10, bottom: 10 })
                    .backgroundColor(this.aiEnhanceOn && this.aiEnhanceQuality === 'medium' ? 'rgba(255, 255, 255, 0.45)' : 'rgba(255, 255, 255, 0.1)')
                    .borderRadius(99)
                    .border({ width: this.aiEnhanceOn && this.aiEnhanceQuality === 'medium' ? 2 : 1, color: this.aiEnhanceOn && this.aiEnhanceQuality === 'medium' ? '#fffefe' : '#45ffffff' })
                    .onClick(() => {
                      hilog.info(0x0000, 'PlayerSettingsDialog', '画质增强: 点击中');
                      this.aiEnhanceOn = true;
                      this.aiEnhanceQuality = 'medium';
                      this.videoController.setAiEnhance('medium');
                    })

                  Text('高')
                    .fontSize(26)
                    .fontColor(this.aiEnhanceOn && this.aiEnhanceQuality === 'high' ? '#F3F7FF' : '#D7DCE7')
                    .padding({ left: 20, right: 20, top: 10, bottom: 10 })
                    .backgroundColor(this.aiEnhanceOn && this.aiEnhanceQuality === 'high' ? 'rgba(255, 255, 255, 0.45)' : 'rgba(255, 255, 255, 0.1)')
                    .borderRadius(99)
                    .border({ width: this.aiEnhanceOn && this.aiEnhanceQuality === 'high' ? 2 : 1, color: this.aiEnhanceOn && this.aiEnhanceQuality === 'high' ? '#fffefe' : '#45ffffff' })
                    .onClick(() => {
                      hilog.info(0x0000, 'PlayerSettingsDialog', '画质增强: 点击高');
                      this.aiEnhanceOn = true;
                      this.aiEnhanceQuality = 'high';
                      this.videoController.setAiEnhance('high');
                    })
                }
                .justifyContent(FlexAlign.Start)
                .width('100%')
              }
            }
          }
          .padding({ left: 26, right: 26, top: 18, bottom: 28 })
          .alignItems(HorizontalAlign.Start)
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('55%')
      .backgroundColor(Color.Transparent)
      .borderRadius({ topLeft: 24, topRight: 24 })
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_ONLY, scrollBackward: NestedScrollMode.SELF_ONLY })
    }
    .width('100%')
    .height('100%')
  }
}

@CustomDialog
export struct SubtitleSelectorDrawerDialog {
  controller: CustomDialogController
  @Require videoController: VideoPlayerController
  @State panelOffsetX: number = 72
  @State panelOpacity: number = 0

  aboutToAppear(): void {
    this.panelOffsetX = 72
    this.panelOpacity = 0
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.panelOffsetX = 0
      this.panelOpacity = 1
    })
  }

  private getCurrentSubtitleName(): string {
    const activeIdx = this.videoController.activeSubtitleIndex
    if (activeIdx < 0) {
      return '已关闭字幕'
    }
    if (activeIdx < this.videoController.allSubtitleTracks.length) {
      return this.videoController.allSubtitleTracks[activeIdx].displayName
    }
    return '未选择字幕'
  }

  private getExternalSubtitleDownloadCount(trackIndex: number): string {
    let externalOrder = 0
    for (let i = 0; i <= trackIndex && i < this.videoController.allSubtitleTracks.length; i++) {
      if (this.videoController.allSubtitleTracks[i].kind === 'external') {
        externalOrder++
      }
    }

    if (externalOrder === 1) {
      return '12.4k'
    }
    if (externalOrder === 2) {
      return '3.1k'
    }
    return '1.2k'
  }

  private getLanguageTag(name: string): string {
    const lower = name.toLowerCase()
    if (lower.includes('中文') || lower.includes('chs') || lower.includes('cht') || lower.includes('chinese')) {
      return '中文'
    }
    if (lower.includes('日文') || lower.includes('jpn') || lower.includes('japanese') || lower.includes('日本')) {
      return '日文'
    }
    if (lower.includes('英文') || lower.includes('eng') || lower.includes('english')) {
      return 'EN'
    }
    return 'EN'
  }

  private getLanguageBadgeTextColor(tag: string): string {
    if (tag === '中文') {
      return '#93C5FD'
    }
    if (tag === '日文') {
      return '#FCD34D'
    }
    return '#93C5FD'
  }

  private getLanguageBadgeFillColor(tag: string): string {
    if (tag === '中文') {
      return 'rgba(29, 78, 216, 0.25)'
    }
    if (tag === '日文') {
      return 'rgba(120, 53, 15, 0.25)'
    }
    return 'rgba(29, 78, 216, 0.31)'
  }

  private getAvailableSubtitleCount(): number {
    const base = this.videoController.allSubtitleTracks.length - (this.videoController.activeSubtitleIndex >= 0 ? 1 : 0)
    return base + 1
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.controller.close()
        })

      Column({ space: 16 }) {
        Row() {
          Text('字幕')
            .fontSize(34)
            .fontColor('#F3F6FB')
            .fontWeight(FontWeight.Bold)
        }
        .height(48)
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text('当前字幕')
          .fontSize(17)
          .fontColor('#97A9CD')

        Row({ space: 12 }) {
          if (this.videoController.activeSubtitleIndex >= 0) {
            Row() {
              Text(this.getLanguageTag(this.getCurrentSubtitleName()))
                .fontSize(13)
                .fontWeight(600)
                .fontColor(this.getLanguageBadgeTextColor(this.getLanguageTag(this.getCurrentSubtitleName())))
            }
            .height(26)
            .padding({ left: 10, right: 10, top: 3, bottom: 3 })
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .borderRadius(13)
            .backgroundColor(this.getLanguageBadgeFillColor(this.getLanguageTag(this.getCurrentSubtitleName())))
          }

          Text(this.getCurrentSubtitleName())
            .fontSize(18)
            .fontColor('#FBFDFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          if (this.videoController.activeSubtitleIndex >= 0) {
            Text('✓')
              .fontSize(20)
              .fontColor('#4ADE80')
          }
        }
        .width('100%')
        .height(68)
        .padding({ left: 16, right: 16 })
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .backgroundColor('rgba(255, 255, 255, 0.12)')
        .borderRadius(16)
        .border({
          width: this.videoController.activeSubtitleIndex >= 0 ? 2 : 1,
          color: this.videoController.activeSubtitleIndex >= 0 ? '#FFFEFE' : 'rgba(255, 255, 255, 0.19)'
        })

        Row({ space: 12 }) {
          Row() {
            Text('关闭字幕')
              .fontSize(18)
              .fontColor('#DDE4EE')
          }
          .height(48)
          .padding({ left: 18, right: 18 })
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .backgroundColor('rgba(255, 255, 255, 0.07)')
          .borderRadius(24)
          .border({ width: 1, color: 'rgba(255, 255, 255, 0.19)' })
          .onClick(() => {
            this.videoController.switchSubtitleTrack(-1)
          })

          Row() {
            Text('⏱ 时间调整')
              .fontSize(18)
              .fontColor('#DDE4EE')
          }
          .height(48)
          .padding({ left: 18, right: 18 })
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .backgroundColor('rgba(255, 255, 255, 0.07)')
          .borderRadius(24)
          .border({ width: 1, color: 'rgba(255, 255, 255, 0.19)' })
        }
        .width('100%')

        Divider()
          .strokeWidth(1)
          .color('rgba(255, 255, 255, 0.15)')

        Column({ space: 8 }) {
          Text(`其他可用字幕 (${this.getAvailableSubtitleCount()})`)
            .fontSize(17)
            .fontColor('#97A9CD')

          Scroll() {
            Column({ space: 8 }) {
              ForEach(this.videoController.allSubtitleTracks, (item: SubtitleTrackItem, index: number) => {
                if (index !== this.videoController.activeSubtitleIndex) {
                  Row({ space: 10 }) {
                    Row() {
                      Text(this.getLanguageTag(item.displayName))
                        .fontSize(13)
                        .fontWeight(600)
                        .fontColor(this.getLanguageBadgeTextColor(this.getLanguageTag(item.displayName)))
                    }
                    .height(24)
                    .padding({ left: 9, right: 9, top: 3, bottom: 3 })
                    .justifyContent(FlexAlign.Center)
                    .alignItems(VerticalAlign.Center)
                    .borderRadius(12)
                    .backgroundColor(this.getLanguageBadgeFillColor(this.getLanguageTag(item.displayName)))

                    Text(item.displayName)
                      .fontSize(17)
                      .fontColor('#EAF0F7')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)

                    if (item.kind === 'external') {
                      Text(`↓ ${this.getExternalSubtitleDownloadCount(index)}`)
                        .fontSize(13)
                        .fontColor('#97A9CD')
                    }
                  }
                  .width('100%')
                  .height(62)
                  .padding({ top: 12, bottom: 12, left: 14, right: 14 })
                  .alignItems(VerticalAlign.Center)
                  .backgroundColor('rgba(255, 255, 255, 0.05)')
                  .borderRadius(14)
                  .onClick(() => {
                    this.videoController.switchSubtitleTrack(index)
                  })
                }
              })

              Row({ space: 10 }) {
                Text('无字幕')
                  .fontSize(17)
                  .fontColor('#97A9CD')
              }
              .width('100%')
              .height(50)
              .padding({ top: 12, bottom: 12, left: 14, right: 14 })
              .alignItems(VerticalAlign.Center)
              .backgroundColor('rgba(255, 255, 255, 0.03)')
              .borderRadius(14)
              .onClick(() => {
                this.videoController.switchSubtitleTrack(-1)
              })
            }
            .width('100%')
          }
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .nestedScroll({ scrollForward: NestedScrollMode.SELF_ONLY, scrollBackward: NestedScrollMode.SELF_ONLY })
          .width('100%')
          .layoutWeight(1)
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Row({ space: 8 }) {
          Text('搜索更多字幕')
            .fontSize(18)
            .fontColor('#B0C4DE')
          Text('→')
            .fontSize(18)
            .fontColor('#B0C4DE')
        }
        .width('100%')
        .height(52)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor('rgba(255, 255, 255, 0.03)')
        .borderRadius(26)
        .border({ width: 1, color: 'rgba(255, 255, 255, 0.15)' })
      }
      .width('33.33%')
      .height('100%')
      .padding(32)
      .backgroundColor('rgba(5, 10, 20, 0.91)')
      .offset({ x: this.panelOffsetX })
      .opacity(this.panelOpacity)
    }
    .width('100%')
    .height('100%')
  }
}
