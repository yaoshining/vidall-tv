import { VideoPlayerController, AspectRatioMode } from "./VideoPlayerController"
import { VpeQualityLevel } from "../../../utils/VpeEnhancerUtil"
import { hilog } from "@kit.PerformanceAnalysisKit"
import { EpisodeListPanel } from './EpisodeListPanel'
import { PlaybackContextItem, MediaLibraryContext, PlaybackContext } from './PlaybackContext'
import {
  loadEpisodeAutoplaySettings,
  saveEpisodeAutoplayCountdownSeconds,
  saveEpisodeAutoplayEnabled
} from './EpisodeAutoplayPreferences'

interface AspectRatioOption {
  label: string;
  mode: AspectRatioMode;
}

interface SpeedOption {
  label: string;
  speed: number;
}

interface AutoplayToggleOption {
  label: string;
  enabled: boolean;
}

interface AutoplayCountdownOption {
  label: string;
  seconds: number;
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

const PLAYER_SETTINGS_AUTOPLAY_TOGGLE_OPTIONS: AutoplayToggleOption[] = [
  { label: '开启', enabled: true },
  { label: '关闭', enabled: false },
]

const PLAYER_SETTINGS_AUTOPLAY_COUNTDOWN_OPTIONS: AutoplayCountdownOption[] = [
  { label: '3s', seconds: 3 },
  { label: '5s', seconds: 5 },
  { label: '8s', seconds: 8 },
  { label: '10s', seconds: 10 },
]

const PLAYER_SETTINGS_CHIP_HEIGHT: number = 68
const PLAYER_SETTINGS_CHIP_RADIUS: number = 22
const PLAYER_SETTINGS_CHIP_FONT_SIZE: number = 18
const PLAYER_SETTINGS_CHIP_HORIZONTAL_PADDING: number = 18
const PLAYER_SETTINGS_CHIP_VERTICAL_PADDING: number = 10
const PLAYER_SETTINGS_CHIP_GAP: number = 10
const PLAYER_SETTINGS_CHIP_SCALE_FOCUSED: number = 1.04
const DEFAULT_PLAYBACK_RATE_INDEX: number = 2
const PLAYER_SETTINGS_DIAGNOSTIC_PREFIX: string = '[#player-settings]'
const PLAYER_SETTINGS_DIAGNOSTIC_TAG: string = 'PlayerSettingsDialog'
const PLAYER_SETTINGS_DIAGNOSTIC_LOG_ENABLED: boolean = false

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

export interface PlayerSettingsAutoplayToggleChipRenderModel {
  label: string
  enabled: boolean
  styleState: PlayerSettingsChipStyleState
}

export interface PlayerSettingsAutoplayCountdownChipRenderModel {
  label: string
  seconds: number
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

function getPlayerSettingsAutoplayChipStyleState(
  isFocused: boolean,
  isSelected: boolean,
  isHovered: boolean = false
): PlayerSettingsChipStyleState {
  if (isSelected) {
    return getPlayerSettingsValueChipStyleState(isFocused, true, isHovered)
  }
  if (isFocused || isHovered) {
    return getPlayerSettingsChipStyleState(isFocused, false, isHovered)
  }
  return getPlayerSettingsValueChipStyleState(false, false, false)
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

export function buildAutoplayToggleChipRenderModels(
  autoplayEnabled: boolean,
  focusedIndex: number = -1,
  hoveredIndex: number = -1
): PlayerSettingsAutoplayToggleChipRenderModel[] {
  const renderModels: PlayerSettingsAutoplayToggleChipRenderModel[] = []
  for (let idx = 0; idx < PLAYER_SETTINGS_AUTOPLAY_TOGGLE_OPTIONS.length; idx++) {
    const option = PLAYER_SETTINGS_AUTOPLAY_TOGGLE_OPTIONS[idx]
    const styleState = getPlayerSettingsAutoplayChipStyleState(
      focusedIndex === idx,
      autoplayEnabled === option.enabled,
      hoveredIndex === idx
    )
    const renderModel: PlayerSettingsAutoplayToggleChipRenderModel = {
      label: option.label,
      enabled: option.enabled,
      styleState
    }
    renderModels.push(renderModel)
  }
  return renderModels
}

export function buildAutoplayCountdownChipRenderModels(
  autoplayCountdownSeconds: number,
  focusedIndex: number = -1,
  hoveredIndex: number = -1
): PlayerSettingsAutoplayCountdownChipRenderModel[] {
  const renderModels: PlayerSettingsAutoplayCountdownChipRenderModel[] = []
  for (let idx = 0; idx < PLAYER_SETTINGS_AUTOPLAY_COUNTDOWN_OPTIONS.length; idx++) {
    const option = PLAYER_SETTINGS_AUTOPLAY_COUNTDOWN_OPTIONS[idx]
    const styleState = getPlayerSettingsAutoplayChipStyleState(
      focusedIndex === idx,
      autoplayCountdownSeconds === option.seconds,
      hoveredIndex === idx
    )
    const renderModel: PlayerSettingsAutoplayCountdownChipRenderModel = {
      label: option.label,
      seconds: option.seconds,
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

  private logPlayerSettingsDiagnostic(scope: string, detail: string): void {
    if (!PLAYER_SETTINGS_DIAGNOSTIC_LOG_ENABLED) {
      return
    }
    hilog.debug(0x0000, PLAYER_SETTINGS_DIAGNOSTIC_TAG, formatPlayerSettingsDiagnosticLog(scope, detail))
  }

  private resolveAspectRatioSelectedIndex(mode: AspectRatioMode): number {
    for (let idx = 0; idx < this.aspectRatioOptions.length; idx++) {
      if (isAspectRatioOptionSelected(mode, this.aspectRatioOptions[idx].mode)) {
        return idx
      }
    }
    return -1
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

  private getSpeedChipRenderModels(): PlayerSettingsSpeedChipRenderModel[] {
    return buildPlaybackSpeedChipRenderModels(
      this.mirroredPlaybackSpeed,
      this.speedFocusedIndex,
      this.speedHoveredIndex
    )
  }

  private getAspectRatioChipRenderModels(): PlayerSettingsAspectRatioChipRenderModel[] {
    return buildAspectRatioChipRenderModels(
      this.mirroredAspectRatioMode,
      this.arFocusedIndex,
      this.arHoveredIndex
    )
  }

  private getAutoplayToggleChipStyleState(idx: number): PlayerSettingsChipStyleState {
    return getPlayerSettingsAutoplayChipStyleState(
      this.autoplayToggleFocusedIndex === idx,
      this.autoplayEnabled === this.autoplayToggleOptions[idx],
      this.autoplayToggleHoveredIndex === idx
    )
  }

  private getAutoplayCountdownChipStyleState(idx: number): PlayerSettingsChipStyleState {
    return getPlayerSettingsAutoplayChipStyleState(
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
          // ── 选集/文件列表区域（有播放上下文时显示）────────────────────────
          if (this.videoController.playbackContext !== undefined) {
            EpisodeListPanel({
              context: this.videoController.playbackContext as PlaybackContext,
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

            if (this.videoController.playbackContext !== undefined) {
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
