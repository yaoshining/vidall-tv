import { PlaybackContextItem, MediaLibraryContext } from './PlaybackContext'
import { KeyCode } from '@kit.InputKit'

const FIRST_PAGE_SIZE: number = 6

export interface EpisodePageRange {
  pageIndex: number
  startIndex: number
  endIndexExclusive: number
  label: string
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

  private isFocusRingVisible(index: number): boolean {
    return this.focusedCardIndex === index && !this.isPageBarFocused
  }

  // ── 卡片 Builder ──────────────────────────────────────────────────────────

  @Builder
  EpisodeCard(item: PlaybackContextItem, index: number) {
    Column({ space: 8 }) {
      // 海报卡片主体
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(item.thumbnailUrl ? item.thumbnailUrl : $r('app.media.empty_folder'))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)

        // 焦点环：叠加在右下角，仅当前焦点卡片显示
        if (this.isFocusRingVisible(index)) {
          Ellipse()
            .width(42)
            .height(42)
            .stroke('#FFFFFF')
            .strokeWidth(5)
            .fill(Color.Transparent)
            .margin({ right: 6, bottom: 6 })
        }
      }
      .width(220)
      .height(140)
      .borderRadius(26)
      .border(
        this.isCurrentItem(item)
          ? { width: 4, color: '#A9F4FF', style: BorderStyle.Solid }
          : { width: 0, color: Color.Transparent, style: BorderStyle.Solid }
      )
      .clip(true)
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
        .width(220)
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
                // pagerPill 胶囊：焦点在分页条时显示
                if (this.isPageBarFocused && this.pageBarFocusedIndex === pageIdx) {
                  Row()
                    .width(76)
                    .height(34)
                    .borderRadius(18)
                    .backgroundColor('#FFFFFF26')
                    .border({ width: 2, color: '#FFFFFF66', style: BorderStyle.Solid })
                }

                // 分页标签 + 激活下划线
                Column({ space: 6 }) {
                  Text(this.getPageLabel(pageIdx))
                    .fontSize(22)
                    .fontColor(this.currentPage === pageIdx ? '#F3F7FB' : '#D5DDE8')
                    .fontWeight(FontWeight.Bold)

                  if (this.currentPage === pageIdx) {
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
