import { PlaybackContextItem, PlaybackContext } from './PlaybackContext'
import { KeyCode } from '@kit.InputKit'

const EPISODE_GROUP_SIZE: number = 6
const EPISODE_SECTION_TITLE_FONT_SIZE: number = 32
const EPISODE_SECTION_TITLE_LEFT_MARGIN: number = 0
const EPISODE_SECTION_TITLE_BOTTOM_MARGIN: number = 12
const EPISODE_CARD_WIDTH: number = 200
const EPISODE_CARD_HEIGHT: number = 130
const EPISODE_CARD_RADIUS: number = 20
const EPISODE_CARD_THUMBNAIL_WIDTH: number = 184
const EPISODE_CARD_THUMBNAIL_HEIGHT: number = 84
const EPISODE_CARD_THUMBNAIL_RADIUS: number = 16
const EPISODE_CARD_CONTENT_GAP: number = 10
const EPISODE_CARD_HORIZONTAL_PADDING: number = 8
const EPISODE_CARD_RIGHT_PADDING: number = 8
const EPISODE_CARD_VERTICAL_PADDING: number = 8
const EPISODE_CARD_LABEL_FONT_SIZE: number = 20
const EPISODE_CARD_SCALE_FOCUSED: number = 1.04
const EPISODE_TAB_SCALE_FOCUSED: number = 1.04
const EPISODE_PAGE_TAB_HORIZONTAL_PADDING: number = 16
const EPISODE_PAGE_TAB_VERTICAL_PADDING: number = 8
const EPISODE_PAGE_TAB_RADIUS: number = 20
const EPISODE_PAGE_TAB_FONT_SIZE: number = 18
const EPISODE_WAVE_BAR_COUNT: number = 3
const EPISODE_WAVE_FRAMES: number[][] = [
  [8, 14, 10],
  [13, 9, 15],
  [9, 16, 11],
  [14, 10, 12]
]

export interface EpisodeAnchorRange {
  groupIndex: number
  startIndex: number
  endIndexExclusive: number
  label: string
}

export interface EpisodeScrollRequest {
  index: number
  smooth: boolean
  align: ScrollAlign
}

export interface EpisodeCardStyleState {
  isFocused: boolean
  isHovered: boolean
  isCurrent: boolean
  useVerticalLayout: boolean
  showFocusOutline: boolean
  showCurrentOutline: boolean
  showLegacyFocusRing: boolean
  showWaveIcon: boolean
  waveBarCount: number
  scale: number
  shadowRadius: number
  shadowColor: string
  backgroundColor: string
  labelColor: string
  focusOutlineWidth: number
  focusOutlineColor: string
  currentOutlineWidth: number
  currentOutlineColor: string
  focusBorderWidth: number
  currentBorderWidth: number
  layoutWidth: number
  layoutHeight: number
  borderRadius: number
  thumbnailWidth: number
  thumbnailHeight: number
  thumbnailRadius: number
  contentGap: number
  horizontalPadding: number
  rightPadding: number
  verticalPadding: number
  labelFontSize: number
}

export interface EpisodeSectionTitleStyleState {
  fontSize: number
  leftMargin: number
  bottomMargin: number
}

export interface EpisodePageTabStyleState {
  isFocused: boolean
  isHovered: boolean
  isCurrentAnchor: boolean
  showFocusPill: boolean
  showFocusBackground: boolean
  showCurrentUnderline: boolean
  labelColor: string
  backgroundColor: string
  focusPillBackgroundColor: string
  focusPillBorderColor: string
  focusPillBorderWidth: number
  focusBorderWidth: number
  scale: number
  horizontalPadding: number
  verticalPadding: number
  borderRadius: number
  fontSize: number
  shadowRadius: number
  shadowColor: string
}

export function buildEpisodeAnchorRanges(totalCount: number): EpisodeAnchorRange[] {
  const result: EpisodeAnchorRange[] = []
  if (totalCount <= 0) {
    return result
  }

  const groupCount = Math.ceil(totalCount / EPISODE_GROUP_SIZE)
  for (let groupIndex = 0; groupIndex < groupCount; groupIndex++) {
    const startIndex = groupIndex * EPISODE_GROUP_SIZE
    const endIndexExclusive = Math.min(startIndex + EPISODE_GROUP_SIZE, totalCount)
    const range: EpisodeAnchorRange = {
      groupIndex,
      startIndex,
      endIndexExclusive,
      label: `${startIndex + 1}-${endIndexExclusive}`
    }
    result.push(range)
  }

  return result
}

export function buildEpisodeContinuousListItems(items: PlaybackContextItem[], currentIndex: number = -1): PlaybackContextItem[] {
  if (currentIndex < 0 || currentIndex >= items.length) {
    return items
  }
  const currentSeasonNumber = items[currentIndex].seasonNumber
  if (currentSeasonNumber === undefined) {
    return items
  }
  return items.filter((item: PlaybackContextItem): boolean => item.seasonNumber === currentSeasonNumber)
}

export function getEpisodeItemRenderKey(item: PlaybackContextItem): string {
  if (item.videoPath.length > 0) {
    return item.videoPath
  }
  return item.index.toString()
}

export function getEpisodeAnchorIndexForItem(currentIndex: number, totalCount: number): number {
  const ranges = buildEpisodeAnchorRanges(totalCount)
  for (let i = 0; i < ranges.length; i++) {
    const range = ranges[i]
    if (currentIndex >= range.startIndex && currentIndex < range.endIndexExclusive) {
      return range.groupIndex
    }
  }
  return 0
}

export function buildEpisodeAnchorScrollRequest(groupIndex: number, totalCount: number): EpisodeScrollRequest {
  const ranges = buildEpisodeAnchorRanges(totalCount)
  const targetGroupIndex = Math.max(0, Math.min(groupIndex, ranges.length - 1))
  const targetIndex = ranges.length > 0 ? ranges[targetGroupIndex].startIndex : 0
  const request: EpisodeScrollRequest = {
    index: targetIndex,
    smooth: true,
    align: ScrollAlign.START
  }
  return request
}

export function buildEpisodeInitialScrollRequest(currentIndex: number, totalCount: number): EpisodeScrollRequest {
  const maxIndex = Math.max(0, totalCount - 1)
  const request: EpisodeScrollRequest = {
    index: Math.max(0, Math.min(currentIndex, maxIndex)),
    smooth: false,
    align: ScrollAlign.START
  }
  return request
}

export function getEpisodeCardStyleState(isFocused: boolean, isCurrent: boolean, isHovered: boolean = false): EpisodeCardStyleState {
  const isEmphasized = isFocused || isHovered
  const styleState: EpisodeCardStyleState = {
    isFocused,
    isHovered,
    isCurrent,
    useVerticalLayout: true,
    showFocusOutline: false,
    showCurrentOutline: false,
    showLegacyFocusRing: false,
    showWaveIcon: isCurrent,
    waveBarCount: EPISODE_WAVE_BAR_COUNT,
    scale: isEmphasized ? EPISODE_CARD_SCALE_FOCUSED : 1,
    shadowRadius: isEmphasized ? 12 : 0,
    shadowColor: isEmphasized ? '#386EA8E0' : '#00000000',
    backgroundColor: isCurrent ? 'rgba(255, 255, 255, 0.28)' : 'rgba(255, 255, 255, 0.12)',
    labelColor: isCurrent ? '#F9FCFF' : '#E8EDF5',
    focusOutlineWidth: 0,
    focusOutlineColor: '#00000000',
    currentOutlineWidth: 0,
    currentOutlineColor: '#00000000',
    focusBorderWidth: 0,
    currentBorderWidth: 0,
    layoutWidth: EPISODE_CARD_WIDTH,
    layoutHeight: EPISODE_CARD_HEIGHT,
    borderRadius: EPISODE_CARD_RADIUS,
    thumbnailWidth: EPISODE_CARD_THUMBNAIL_WIDTH,
    thumbnailHeight: EPISODE_CARD_THUMBNAIL_HEIGHT,
    thumbnailRadius: EPISODE_CARD_THUMBNAIL_RADIUS,
    contentGap: EPISODE_CARD_CONTENT_GAP,
    horizontalPadding: EPISODE_CARD_HORIZONTAL_PADDING,
    rightPadding: EPISODE_CARD_RIGHT_PADDING,
    verticalPadding: EPISODE_CARD_VERTICAL_PADDING,
    labelFontSize: EPISODE_CARD_LABEL_FONT_SIZE
  }
  return styleState
}

export function getEpisodeSectionTitleStyleState(): EpisodeSectionTitleStyleState {
  const styleState: EpisodeSectionTitleStyleState = {
    fontSize: EPISODE_SECTION_TITLE_FONT_SIZE,
    leftMargin: EPISODE_SECTION_TITLE_LEFT_MARGIN,
    bottomMargin: EPISODE_SECTION_TITLE_BOTTOM_MARGIN
  }
  return styleState
}

export function getEpisodePageTabStyleState(isFocused: boolean, isCurrentAnchor: boolean, isHovered: boolean = false): EpisodePageTabStyleState {
  const isEmphasized = isFocused || isHovered
  const styleState: EpisodePageTabStyleState = {
    isFocused,
    isHovered,
    isCurrentAnchor,
    showFocusPill: false,
    showFocusBackground: isEmphasized,
    showCurrentUnderline: false,
    labelColor: '#D5DDE8',
    backgroundColor: isEmphasized ? 'rgba(255, 255, 255, 0.22)' : '#00000000',
    focusPillBackgroundColor: '#00000000',
    focusPillBorderColor: '#00000000',
    focusPillBorderWidth: 0,
    focusBorderWidth: 0,
    scale: isEmphasized ? EPISODE_TAB_SCALE_FOCUSED : 1,
    horizontalPadding: EPISODE_PAGE_TAB_HORIZONTAL_PADDING,
    verticalPadding: EPISODE_PAGE_TAB_VERTICAL_PADDING,
    borderRadius: EPISODE_PAGE_TAB_RADIUS,
    fontSize: EPISODE_PAGE_TAB_FONT_SIZE,
    shadowRadius: isFocused ? 8 : 0,
    shadowColor: isFocused ? '#264C77A8' : '#00000000'
  }
  return styleState
}

// ── EpisodeListPanel ────────────────────────────────────────────────────────

@Component
export struct EpisodeListPanel {
  @Require context: PlaybackContext
  onSelect: (item: PlaybackContextItem) => void = () => {}

  @State private focusedCardIndex: number = 0
  @State private hoveredCardIndex: number = -1
  @State private isPageBarFocused: boolean = false
  @State private pageBarFocusedIndex: number = 0
  @State private hoveredPageBarIndex: number = -1
  @State private waveFrameIndex: number = 0
  private scroller: ListScroller = new ListScroller()
  private waveTimerId: number | undefined = undefined

  aboutToAppear(): void {
    const currentIdx = this.getCurrentListIndex()
    this.focusedCardIndex = Math.max(0, Math.min(currentIdx, this.getListItems().length - 1))
    this.pageBarFocusedIndex = getEpisodeAnchorIndexForItem(currentIdx, this.getListItems().length)
    this.startWaveAnimation()
  }

  aboutToDisappear(): void {
    this.stopWaveAnimation()
  }

  // ── 数据辅助方法 ───────────────────────────────────────────────────────────

  private getAnchorRanges(): EpisodeAnchorRange[] {
    return buildEpisodeAnchorRanges(this.getListItems().length)
  }

  private getTotalAnchors(): number {
    return this.getAnchorRanges().length
  }

  private getListItems(): PlaybackContextItem[] {
    return buildEpisodeContinuousListItems(this.context.items, this.context.currentIndex)
  }

  private getCurrentListIndex(): number {
    const items = this.getListItems()
    if (this.context.currentIndex < 0 || this.context.currentIndex >= this.context.items.length) {
      return -1
    }
    const currentItem = this.context.items[this.context.currentIndex]
    return items.indexOf(currentItem)
  }

  private scrollToAnchor(groupIndex: number): void {
    if (this.getListItems().length === 0) {
      return
    }
    const total = this.getTotalAnchors()
    if (groupIndex < 0 || groupIndex >= total) {
      return
    }
    const request = buildEpisodeAnchorScrollRequest(groupIndex, this.getListItems().length)
    this.scroller.scrollToIndex(request.index, request.smooth, request.align)
    this.focusedCardIndex = request.index
    this.pageBarFocusedIndex = groupIndex
  }

  private scrollToCurrentItem(): void {
    if (this.getListItems().length === 0) {
      return
    }
    const request = buildEpisodeInitialScrollRequest(this.getCurrentListIndex(), this.getListItems().length)
    this.scroller.scrollToIndex(request.index, request.smooth, request.align)
  }

  private getAnchorLabel(groupIndex: number): string {
    const ranges = this.getAnchorRanges()
    if (groupIndex < 0 || groupIndex >= ranges.length) {
      return ''
    }
    return ranges[groupIndex].label
  }

  private isCurrentItem(item: PlaybackContextItem): boolean {
    if (this.context.currentIndex < 0 || this.context.currentIndex >= this.context.items.length) {
      return false
    }
    return item === this.context.items[this.context.currentIndex]
  }

  private buildAnchorIndexRange(): number[] {
    const total = this.getAnchorRanges().length
    const result: number[] = []
    for (let i = 0; i < total; i++) {
      result.push(i)
    }
    return result
  }

  private getCardStyleState(item: PlaybackContextItem, index: number): EpisodeCardStyleState {
    return getEpisodeCardStyleState(
      this.focusedCardIndex === index && !this.isPageBarFocused,
      this.isCurrentItem(item),
      this.hoveredCardIndex === index
    )
  }

  private getPageTabStyleState(pageIdx: number): EpisodePageTabStyleState {
    return getEpisodePageTabStyleState(
      this.isPageBarFocused && this.pageBarFocusedIndex === pageIdx,
      getEpisodeAnchorIndexForItem(this.getCurrentListIndex(), this.getListItems().length) === pageIdx,
      this.hoveredPageBarIndex === pageIdx
    )
  }

  private startWaveAnimation(): void {
    if (this.waveTimerId !== undefined) {
      return
    }
    this.waveTimerId = setInterval(() => {
      this.waveFrameIndex = (this.waveFrameIndex + 1) % EPISODE_WAVE_FRAMES.length
    }, 240)
  }

  private stopWaveAnimation(): void {
    if (this.waveTimerId === undefined) {
      return
    }
    clearInterval(this.waveTimerId)
    this.waveTimerId = undefined
  }

  private getWaveBarHeights(): number[] {
    return EPISODE_WAVE_FRAMES[this.waveFrameIndex % EPISODE_WAVE_FRAMES.length]
  }

  private getPanelTitle(): string {
    return this.context.contextType === 'file_explorer' ? '文件列表' : '选集'
  }

  private getFileItemBgColor(item: PlaybackContextItem, index: number): string {
    const isFocused = this.focusedCardIndex === index && !this.isPageBarFocused
    const isCurrent = this.isCurrentItem(item)
    const isHovered = this.hoveredCardIndex === index
    if (isCurrent) {
      return 'rgba(169, 244, 255, 0.18)'
    }
    if (isFocused || isHovered) {
      return 'rgba(255, 255, 255, 0.16)'
    }
    return 'rgba(255, 255, 255, 0.06)'
  }

  private getFileItemFontColor(item: PlaybackContextItem): string {
    return this.isCurrentItem(item) ? '#A9F4FF' : '#EFF2FB'
  }

  private getFileItemBorderWidth(item: PlaybackContextItem): number {
    return this.isCurrentItem(item) ? 2 : 0
  }

  private getFileItemScale(index: number): number {
    return this.focusedCardIndex === index && !this.isPageBarFocused ? EPISODE_CARD_SCALE_FOCUSED : 1.0
  }

  // ── 卡片 Builder ──────────────────────────────────────────────────────────

  @Builder
  private PlayingWaveIcon() {
    Row({ space: 3 }) {
      ForEach(this.getWaveBarHeights(), (barHeight: number, index: number) => {
        Row()
          .width(3)
          .height(barHeight)
          .borderRadius(2)
          .backgroundColor('#A9F4FF')
      }, (barHeight: number, index: number): string => index.toString())
    }
    .height(16)
    .alignItems(VerticalAlign.Bottom)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  FileItem(item: PlaybackContextItem, index: number) {
    Column({ space: 8 }) {
      if (this.isCurrentItem(item)) {
        this.PlayingWaveIcon()
      }
      Text(item.title)
        .fontSize(18)
        .fontColor(this.getFileItemFontColor(item))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width(180)
        .wordBreak(WordBreak.BREAK_ALL)
    }
    .width(200)
    .height(114)
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(EPISODE_CARD_RADIUS)
    .backgroundColor(this.getFileItemBgColor(item, index))
    .border({ width: this.getFileItemBorderWidth(item), color: '#A9F4FF' })
    .scale({ x: this.getFileItemScale(index), y: this.getFileItemScale(index) })
    .shadow({
      radius: this.getFileItemScale(index) > 1.0 ? 12 : 0,
      color: '#334C77A8',
      offsetX: 0,
      offsetY: 6
    })
    .animation({ duration: 180, curve: Curve.EaseInOut })
    .focusable(true)
    .onFocus(() => {
      this.focusedCardIndex = index
      this.isPageBarFocused = false
    })
    .onHover((isHover: boolean) => {
      this.hoveredCardIndex = isHover ? index : -1
    })
    .onClick(() => {
      this.onSelect(item)
    })
  }

  @Builder
  EpisodeCard(item: PlaybackContextItem, index: number) {
    Column({ space: this.getCardStyleState(item, index).contentGap }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(item.thumbnailUrl ? item.thumbnailUrl : $r('app.media.empty_folder'))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)

        if (this.getCardStyleState(item, index).showWaveIcon) {
          Row() {
            this.PlayingWaveIcon()
          }
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          .backgroundColor('rgba(6, 14, 24, 0.58)')
          .borderRadius(12)
          .margin({ right: 8, bottom: 8 })
        }
      }
      .width(this.getCardStyleState(item, index).thumbnailWidth)
      .height(this.getCardStyleState(item, index).thumbnailHeight)
      .borderRadius(this.getCardStyleState(item, index).thumbnailRadius)
      .clip(true)
      .shadow({
        radius: this.isCurrentItem(item) ? 4 : 0,
        color: this.isCurrentItem(item) ? '#2CA9F4FF' : '#00000000',
        offsetX: 0,
        offsetY: 2
      })

      Text('第' + (item.episodeNumber ?? (item.index + 1)).toString() + '集')
        .fontSize(this.getCardStyleState(item, index).labelFontSize)
        .fontWeight(this.isCurrentItem(item) ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.getCardStyleState(item, index).labelColor)
        .textAlign(TextAlign.Center)
        .width(this.getCardStyleState(item, index).thumbnailWidth)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width(this.getCardStyleState(item, index).layoutWidth)
    .height(this.getCardStyleState(item, index).layoutHeight)
    .padding({
      left: this.getCardStyleState(item, index).horizontalPadding,
      right: this.getCardStyleState(item, index).rightPadding,
      top: this.getCardStyleState(item, index).verticalPadding,
      bottom: this.getCardStyleState(item, index).verticalPadding
    })
    .borderRadius(this.getCardStyleState(item, index).borderRadius)
    .backgroundColor(this.getCardStyleState(item, index).backgroundColor)
    .scale({ x: this.getCardStyleState(item, index).scale, y: this.getCardStyleState(item, index).scale })
    .shadow({
      radius: this.getCardStyleState(item, index).shadowRadius,
      color: this.getCardStyleState(item, index).shadowColor,
      offsetX: 0,
      offsetY: 6
    })
    .focusable(true)
    .onFocus(() => {
      this.focusedCardIndex = index
      this.isPageBarFocused = false
    })
    .onHover((isHover: boolean) => {
      this.hoveredCardIndex = isHover ? index : -1
    })
    .onClick(() => {
      this.onSelect(item)
    })
    .alignItems(HorizontalAlign.Center)
  }

  // ── build ─────────────────────────────────────────────────────────────────

  build() {
    Column({ space: 0 }) {
      // 标题行
      Text(this.getPanelTitle())
        .fontSize(getEpisodeSectionTitleStyleState().fontSize)
        .fontWeight(FontWeight.Medium)
        .fontColor('#EFF2FB')
        .margin({
          left: getEpisodeSectionTitleStyleState().leftMargin,
          bottom: getEpisodeSectionTitleStyleState().bottomMargin
        })
        .alignSelf(ItemAlign.Start)

      // 集数卡片连续横向列表
      List({ space: 18, scroller: this.scroller }) {
        ForEach(
          this.getListItems(),
          (item: PlaybackContextItem, index: number) => {
            ListItem() {
              if (this.context.contextType === 'file_explorer') {
                this.FileItem(item, index)
              } else {
                this.EpisodeCard(item, index)
              }
            }
          },
          (item: PlaybackContextItem): string => getEpisodeItemRenderKey(item)
        )
      }
      .listDirection(Axis.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(154)
      .onAppear(() => {
        this.scrollToCurrentItem()
      })
      .onKeyEvent((event: KeyEvent) => {
        if (event.type !== KeyType.Down) {
          return
        }
        if (event.keyCode === KeyCode.KEYCODE_DPAD_DOWN) {
          // 向下进入分组锚点条
          this.isPageBarFocused = true
        }
      })

      // 分组锚点条（多组时才显示）
      if (this.getTotalAnchors() > 1) {
        Row({ space: 12 }) {
          ForEach(
            this.buildAnchorIndexRange(),
            (pageIdx: number) => {
              Stack() {
                if (this.getPageTabStyleState(pageIdx).showFocusBackground) {
                  Row()
                    .padding({
                      left: this.getPageTabStyleState(pageIdx).horizontalPadding,
                      right: this.getPageTabStyleState(pageIdx).horizontalPadding,
                      top: this.getPageTabStyleState(pageIdx).verticalPadding,
                      bottom: this.getPageTabStyleState(pageIdx).verticalPadding
                    })
                    .borderRadius(this.getPageTabStyleState(pageIdx).borderRadius)
                    .backgroundColor(this.getPageTabStyleState(pageIdx).backgroundColor)
                }

                // 分组锚点标签 + 当前组下划线
                Column({ space: 6 }) {
                  Text(this.getAnchorLabel(pageIdx))
                    .fontSize(this.getPageTabStyleState(pageIdx).fontSize)
                    .fontColor(this.getPageTabStyleState(pageIdx).labelColor)
                    .fontWeight(FontWeight.Bold)
                    .padding({
                      left: this.getPageTabStyleState(pageIdx).horizontalPadding,
                      right: this.getPageTabStyleState(pageIdx).horizontalPadding,
                      top: this.getPageTabStyleState(pageIdx).verticalPadding,
                      bottom: this.getPageTabStyleState(pageIdx).verticalPadding
                    })
                    .backgroundColor(this.getPageTabStyleState(pageIdx).backgroundColor)
                    .borderRadius(this.getPageTabStyleState(pageIdx).borderRadius)

                  if (this.getPageTabStyleState(pageIdx).showCurrentUnderline) {
                    Row()
                      .width(38)
                      .height(3)
                      .backgroundColor('#F5F8FC')
                      .borderRadius(2)
                  }
                }
              }
              .scale({ x: this.getPageTabStyleState(pageIdx).scale, y: this.getPageTabStyleState(pageIdx).scale })
              .shadow({
                radius: this.getPageTabStyleState(pageIdx).shadowRadius,
                color: this.getPageTabStyleState(pageIdx).shadowColor,
                offsetX: 0,
                offsetY: 6
              })
              .focusable(true)
              .onFocus(() => {
                this.isPageBarFocused = true
                this.pageBarFocusedIndex = pageIdx
              })
              .onHover((isHover: boolean) => {
                this.hoveredPageBarIndex = isHover ? pageIdx : -1
              })
              .onBlur(() => {
                this.isPageBarFocused = false
              })
              .onClick(() => {
                this.scrollToAnchor(pageIdx)
              })
              .onKeyEvent((event: KeyEvent) => {
                if (event.type !== KeyType.Down) {
                  return
                }
                if (event.keyCode === KeyCode.KEYCODE_ENTER || event.keyCode === KeyCode.KEYCODE_DPAD_CENTER) {
                  this.scrollToAnchor(pageIdx)
                } else if (event.keyCode === KeyCode.KEYCODE_DPAD_UP) {
                  this.isPageBarFocused = false
                } else if (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT && this.pageBarFocusedIndex > 0) {
                  this.scrollToAnchor(pageIdx - 1)
                } else if (event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT && this.pageBarFocusedIndex < this.getTotalAnchors() - 1) {
                  this.scrollToAnchor(pageIdx + 1)
                }
              })
            },
            (pageIdx: number) => pageIdx.toString()
          )
        }
        .margin({ top: 18 })
        .alignSelf(ItemAlign.Start)
      }
    }
    .backgroundColor(Color.Transparent)
    .width('100%')
    .padding({ top: 40, bottom: 40, left: 26 })
    .alignItems(HorizontalAlign.Start)
  }
}
