import { PlaybackContextItem, MediaLibraryContext } from './PlaybackContext'
import { KeyCode } from '@kit.InputKit'

const FIRST_PAGE_SIZE: number = 6
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

export interface EpisodePageRange {
  pageIndex: number
  startIndex: number
  endIndexExclusive: number
  label: string
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
  isCurrentPage: boolean
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

export function buildEpisodePageRanges(totalCount: number): EpisodePageRange[] {
  const result: EpisodePageRange[] = []
  if (totalCount <= 0) {
    return result
  }

  const firstPageEnd = Math.min(FIRST_PAGE_SIZE, totalCount)
  const firstRange: EpisodePageRange = {
    pageIndex: 0,
    startIndex: 0,
    endIndexExclusive: firstPageEnd,
    label: `1-${firstPageEnd}`
  }
  result.push(firstRange)

  if (totalCount > FIRST_PAGE_SIZE) {
    const secondRange: EpisodePageRange = {
      pageIndex: 1,
      startIndex: FIRST_PAGE_SIZE,
      endIndexExclusive: totalCount,
      label: `${FIRST_PAGE_SIZE + 1}-${totalCount}`
    }
    result.push(secondRange)
  }

  return result
}

export function getEpisodePageItems(items: PlaybackContextItem[], page: number): PlaybackContextItem[] {
  const ranges = buildEpisodePageRanges(items.length)
  if (page < 0 || page >= ranges.length) {
    return []
  }
  const range = ranges[page]
  return items.slice(range.startIndex, range.endIndexExclusive)
}

export function getEpisodeItemRenderKey(item: PlaybackContextItem): string {
  if (item.videoPath.length > 0) {
    return item.videoPath
  }
  return item.index.toString()
}

function getEpisodePageIndex(currentIndex: number, totalCount: number): number {
  const ranges = buildEpisodePageRanges(totalCount)
  for (let i = 0; i < ranges.length; i++) {
    const range = ranges[i]
    if (currentIndex >= range.startIndex && currentIndex < range.endIndexExclusive) {
      return range.pageIndex
    }
  }
  return 0
}

function getEpisodeFocusIndex(currentIndex: number, totalCount: number): number {
  const ranges = buildEpisodePageRanges(totalCount)
  const pageIndex = getEpisodePageIndex(currentIndex, totalCount)
  if (pageIndex < 0 || pageIndex >= ranges.length) {
    return 0
  }
  const range = ranges[pageIndex]
  return currentIndex - range.startIndex
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

export function getEpisodePageTabStyleState(isFocused: boolean, isCurrentPage: boolean, isHovered: boolean = false): EpisodePageTabStyleState {
  const isEmphasized = isFocused || isHovered
  const styleState: EpisodePageTabStyleState = {
    isFocused,
    isHovered,
    isCurrentPage,
    showFocusPill: false,
    showFocusBackground: isEmphasized || isCurrentPage,
    showCurrentUnderline: isCurrentPage,
    labelColor: isCurrentPage ? '#F3F7FB' : '#D5DDE8',
    backgroundColor: isEmphasized ? 'rgba(255, 255, 255, 0.22)' :
      isCurrentPage ? 'rgba(255, 255, 255, 0.12)' : '#00000000',
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
  @Require context: MediaLibraryContext
  onSelect: (item: PlaybackContextItem) => void = () => {}

  @State private currentPage: number = 0
  @State private focusedCardIndex: number = 0
  @State private hoveredCardIndex: number = -1
  @State private isPageBarFocused: boolean = false
  @State private pageBarFocusedIndex: number = 0
  @State private hoveredPageBarIndex: number = -1
  @State private waveFrameIndex: number = 0
  private waveTimerId: number | undefined = undefined

  aboutToAppear(): void {
    const currentIdx = this.context.currentIndex
    this.currentPage = getEpisodePageIndex(currentIdx, this.context.items.length)
    this.focusedCardIndex = getEpisodeFocusIndex(currentIdx, this.context.items.length)
    this.pageBarFocusedIndex = this.currentPage
    this.startWaveAnimation()
  }

  aboutToDisappear(): void {
    this.stopWaveAnimation()
  }

  // ── 数据辅助方法 ───────────────────────────────────────────────────────────

  private getPageRanges(): EpisodePageRange[] {
    return buildEpisodePageRanges(this.context.items.length)
  }

  private getTotalPages(): number {
    return Math.max(1, this.getPageRanges().length)
  }

  private getPageItems(): PlaybackContextItem[] {
    return getEpisodePageItems(this.context.items, this.currentPage)
  }

  private goToPage(page: number): void {
    const total = this.getTotalPages()
    if (page < 0 || page >= total) {
      return
    }
    this.currentPage = page
    this.focusedCardIndex = 0
    this.pageBarFocusedIndex = page
  }

  private getPageLabel(page: number): string {
    const ranges = this.getPageRanges()
    if (page < 0 || page >= ranges.length) {
      return ''
    }
    return ranges[page].label
  }

  private isCurrentItem(item: PlaybackContextItem): boolean {
    return item.index === this.context.currentIndex
  }

  private buildPageRange(): number[] {
    const total = this.getPageRanges().length
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
      this.currentPage === pageIdx,
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
      Text('选集')
        .fontSize(getEpisodeSectionTitleStyleState().fontSize)
        .fontWeight(FontWeight.Medium)
        .fontColor('#EFF2FB')
        .margin({
          left: getEpisodeSectionTitleStyleState().leftMargin,
          bottom: getEpisodeSectionTitleStyleState().bottomMargin
        })
        .alignSelf(ItemAlign.Start)

      // 集数卡片横向列表
      List({ space: 18 }) {
        ForEach(
          this.getPageItems(),
          (item: PlaybackContextItem, index: number) => {
            ListItem() {
              this.EpisodeCard(item, index)
            }
          },
          (item: PlaybackContextItem): string => getEpisodeItemRenderKey(item)
        )
      }
      .listDirection(Axis.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(154)
      .onKeyEvent((event: KeyEvent) => {
        if (event.type !== KeyType.Down) {
          return
        }
        const pageItems = this.getPageItems()
        if (event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT) {
          // 到达当前页最后一张时翻页
          if (this.focusedCardIndex >= pageItems.length - 1) {
            this.goToPage(this.currentPage + 1)
          }
        } else if (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT) {
          // 到达当前页第一张时翻页
          if (this.focusedCardIndex <= 0) {
            this.goToPage(this.currentPage - 1)
          }
        } else if (event.keyCode === KeyCode.KEYCODE_DPAD_DOWN) {
          // 向下进入分页范围条
          this.isPageBarFocused = true
        }
      })

      // 分页范围条（多页时才显示）
      if (this.getTotalPages() > 1) {
        Row({ space: 12 }) {
          ForEach(
            this.buildPageRange(),
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

                // 分页标签 + 激活下划线
                Column({ space: 6 }) {
                  Text(this.getPageLabel(pageIdx))
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
                this.goToPage(pageIdx)
              })
              .onKeyEvent((event: KeyEvent) => {
                if (event.type !== KeyType.Down) {
                  return
                }
                if (event.keyCode === KeyCode.KEYCODE_ENTER || event.keyCode === KeyCode.KEYCODE_DPAD_CENTER) {
                  this.goToPage(pageIdx)
                } else if (event.keyCode === KeyCode.KEYCODE_DPAD_UP) {
                  this.isPageBarFocused = false
                } else if (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT && this.pageBarFocusedIndex > 0) {
                  this.goToPage(pageIdx - 1)
                } else if (event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT && this.pageBarFocusedIndex < this.getTotalPages() - 1) {
                  this.goToPage(pageIdx + 1)
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
    .padding({ top: 40, bottom: 40, left: 84 })
    .alignItems(HorizontalAlign.Start)
  }
}
