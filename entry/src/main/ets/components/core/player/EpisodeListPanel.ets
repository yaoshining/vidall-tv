import { PlaybackContextItem, MediaLibraryContext } from './PlaybackContext'
import { KeyCode } from '@kit.InputKit'

const FIRST_PAGE_SIZE: number = 6
const EPISODE_CARD_WIDTH: number = 220
const EPISODE_CARD_HEIGHT: number = 140
const EPISODE_CARD_RADIUS: number = 26
const EPISODE_CARD_INNER_OUTLINE_INSET: number = 10

export interface EpisodePageRange {
  pageIndex: number
  startIndex: number
  endIndexExclusive: number
  label: string
}

export interface EpisodeCardStyleState {
  isFocused: boolean
  isCurrent: boolean
  showFocusOutline: boolean
  showCurrentOutline: boolean
  showLegacyFocusRing: boolean
  scale: number
  shadowRadius: number
  shadowColor: string
  focusOutlineWidth: number
  focusOutlineColor: string
  currentOutlineWidth: number
  currentOutlineColor: string
  layoutWidth: number
  layoutHeight: number
  borderRadius: number
  currentInnerOutlineInset: number
}

export interface EpisodePageTabStyleState {
  isFocused: boolean
  isCurrentPage: boolean
  showFocusPill: boolean
  showCurrentUnderline: boolean
  labelColor: string
  focusPillBackgroundColor: string
  focusPillBorderColor: string
  focusPillBorderWidth: number
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

export function getEpisodeCardStyleState(isFocused: boolean, isCurrent: boolean): EpisodeCardStyleState {
  const styleState: EpisodeCardStyleState = {
    isFocused,
    isCurrent,
    showFocusOutline: isFocused,
    showCurrentOutline: isCurrent,
    showLegacyFocusRing: false,
    scale: isFocused ? 1.03 : 1,
    shadowRadius: isFocused ? 18 : 0,
    shadowColor: isFocused ? '#33000000' : '#00000000',
    focusOutlineWidth: isFocused ? 2 : 0,
    focusOutlineColor: isFocused ? '#FFFFFF' : '#00000000',
    currentOutlineWidth: isCurrent ? 2 : 0,
    currentOutlineColor: isCurrent ? '#A9F4FF' : '#00000000',
    layoutWidth: EPISODE_CARD_WIDTH,
    layoutHeight: EPISODE_CARD_HEIGHT,
    borderRadius: EPISODE_CARD_RADIUS,
    currentInnerOutlineInset: isFocused && isCurrent ? EPISODE_CARD_INNER_OUTLINE_INSET : 0
  }
  return styleState
}

export function getEpisodePageTabStyleState(isFocused: boolean, isCurrentPage: boolean): EpisodePageTabStyleState {
  const styleState: EpisodePageTabStyleState = {
    isFocused,
    isCurrentPage,
    showFocusPill: isFocused,
    showCurrentUnderline: isCurrentPage,
    labelColor: isCurrentPage ? '#F3F7FB' : '#D5DDE8',
    focusPillBackgroundColor: isFocused ? '#FFFFFF33' : '#00000000',
    focusPillBorderColor: isFocused ? '#FFFFFFCC' : '#00000000',
    focusPillBorderWidth: isFocused ? 2 : 0
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
  @State private isPageBarFocused: boolean = false
  @State private pageBarFocusedIndex: number = 0

  aboutToAppear(): void {
    const currentIdx = this.context.currentIndex
    this.currentPage = getEpisodePageIndex(currentIdx, this.context.items.length)
    this.focusedCardIndex = getEpisodeFocusIndex(currentIdx, this.context.items.length)
    this.pageBarFocusedIndex = this.currentPage
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
    return getEpisodeCardStyleState(this.focusedCardIndex === index && !this.isPageBarFocused, this.isCurrentItem(item))
  }

  private getPageTabStyleState(pageIdx: number): EpisodePageTabStyleState {
    return getEpisodePageTabStyleState(this.isPageBarFocused && this.pageBarFocusedIndex === pageIdx, this.currentPage === pageIdx)
  }

  // ── 卡片 Builder ──────────────────────────────────────────────────────────

  @Builder
  EpisodeCard(item: PlaybackContextItem, index: number) {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.Center }) {
        Image(item.thumbnailUrl ? item.thumbnailUrl : $r('app.media.empty_folder'))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)

        if (this.getCardStyleState(item, index).showCurrentOutline && this.getCardStyleState(item, index).showFocusOutline) {
          Row()
            .width(this.getCardStyleState(item, index).layoutWidth - this.getCardStyleState(item, index).currentInnerOutlineInset * 2)
            .height(this.getCardStyleState(item, index).layoutHeight - this.getCardStyleState(item, index).currentInnerOutlineInset * 2)
            .borderRadius(this.getCardStyleState(item, index).borderRadius - this.getCardStyleState(item, index).currentInnerOutlineInset / 2)
            .border({
              width: this.getCardStyleState(item, index).currentOutlineWidth,
              color: this.getCardStyleState(item, index).currentOutlineColor,
              style: BorderStyle.Solid
            })
        }
      }
      .width(this.getCardStyleState(item, index).layoutWidth)
      .height(this.getCardStyleState(item, index).layoutHeight)
      .borderRadius(this.getCardStyleState(item, index).borderRadius)
      .border({
        width: this.getCardStyleState(item, index).showFocusOutline
          ? this.getCardStyleState(item, index).focusOutlineWidth
          : this.getCardStyleState(item, index).currentOutlineWidth,
        color: this.getCardStyleState(item, index).showFocusOutline
          ? this.getCardStyleState(item, index).focusOutlineColor
          : this.getCardStyleState(item, index).currentOutlineColor,
        style: BorderStyle.Solid
      })
      .clip(true)
      .scale({ x: this.getCardStyleState(item, index).scale, y: this.getCardStyleState(item, index).scale })
      .shadow({
        radius: this.getCardStyleState(item, index).shadowRadius,
        color: this.getCardStyleState(item, index).shadowColor,
        offsetX: 0,
        offsetY: 8
      })
      .focusable(true)
      .onFocus(() => {
        this.focusedCardIndex = index
        this.isPageBarFocused = false
      })
      .onClick(() => {
        this.onSelect(item)
      })

      // 集名
      Text('第' + (item.episodeNumber ?? (item.index + 1)).toString() + '集')
        .fontSize(22)
        .fontColor('#F0F4F9')
        .textAlign(TextAlign.Center)
        .width(this.getCardStyleState(item, index).layoutWidth)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Center)
  }

  // ── build ─────────────────────────────────────────────────────────────────

  build() {
    Column({ space: 0 }) {
      // 标题行
      Text('选集')
        .fontSize(56)
        .fontWeight(FontWeight.Bold)
        .fontColor('#F3F6FB')
        .margin({ bottom: 32 })
        .alignSelf(ItemAlign.Start)

      // 集数卡片横向列表
      List({ space: 48 }) {
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
      .height(200)
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
        Row({ space: 58 }) {
          ForEach(
            this.buildPageRange(),
            (pageIdx: number) => {
              Stack() {
                if (this.getPageTabStyleState(pageIdx).showFocusPill) {
                  Row()
                    .width(76)
                    .height(34)
                    .borderRadius(18)
                    .backgroundColor(this.getPageTabStyleState(pageIdx).focusPillBackgroundColor)
                    .border({
                      width: this.getPageTabStyleState(pageIdx).focusPillBorderWidth,
                      color: this.getPageTabStyleState(pageIdx).focusPillBorderColor,
                      style: BorderStyle.Solid
                    })
                }

                // 分页标签 + 激活下划线
                Column({ space: 6 }) {
                  Text(this.getPageLabel(pageIdx))
                    .fontSize(22)
                    .fontColor(this.getPageTabStyleState(pageIdx).labelColor)
                    .fontWeight(FontWeight.Bold)

                  if (this.getPageTabStyleState(pageIdx).showCurrentUnderline) {
                    Row()
                      .width(84)
                      .height(3)
                      .backgroundColor('#F5F8FC')
                      .borderRadius(2)
                  }
                }
              }
              .focusable(true)
              .onFocus(() => {
                this.isPageBarFocused = true
                this.pageBarFocusedIndex = pageIdx
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
        .margin({ top: 32 })
        .alignSelf(ItemAlign.Start)
      }
    }
    .backgroundColor(Color.Transparent)
    .width('100%')
    .padding({ top: 40, bottom: 40, left: 84 })
    .alignItems(HorizontalAlign.Start)
  }
}
