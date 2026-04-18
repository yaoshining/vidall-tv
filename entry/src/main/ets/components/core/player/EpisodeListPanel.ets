import { PlaybackContextItem, MediaLibraryContext } from './PlaybackContext'
import { KeyCode } from '@kit.InputKit'

// ── LazyForEach DataSource ──────────────────────────────────────────────────

class EpisodeDataSource implements IDataSource {
  private dataArray: PlaybackContextItem[] = []
  private listeners: DataChangeListener[] = []

  constructor(items: PlaybackContextItem[]) {
    this.dataArray = items
  }

  totalCount(): number {
    return this.dataArray.length
  }

  getData(index: number): Object {
    return this.dataArray[index]
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    this.listeners.push(listener)
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos = this.listeners.indexOf(listener)
    if (pos >= 0) {
      this.listeners.splice(pos, 1)
    }
  }
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
  @State private dataSource: EpisodeDataSource = new EpisodeDataSource([])

  private readonly PAGE_SIZE: number = 6

  aboutToAppear(): void {
    // 定位到当前播放集所在分页
    const currentIdx = this.context.currentIndex
    this.currentPage = Math.floor(currentIdx / this.PAGE_SIZE)
    this.focusedCardIndex = currentIdx % this.PAGE_SIZE
    this.dataSource = new EpisodeDataSource(this.getPageItems())
  }

  // ── 数据辅助方法 ───────────────────────────────────────────────────────────

  private getTotalPages(): number {
    return Math.max(1, Math.ceil(this.context.items.length / this.PAGE_SIZE))
  }

  private getPageItems(): PlaybackContextItem[] {
    const start = this.currentPage * this.PAGE_SIZE
    const end = Math.min(start + this.PAGE_SIZE, this.context.items.length)
    const result: PlaybackContextItem[] = []
    for (let i = start; i < end; i++) {
      result.push(this.context.items[i])
    }
    return result
  }

  private goToPage(page: number): void {
    const total = this.getTotalPages()
    if (page < 0 || page >= total) {
      return
    }
    this.currentPage = page
    this.focusedCardIndex = 0
    this.dataSource = new EpisodeDataSource(this.getPageItems())
  }

  private getPageLabel(page: number): string {
    const start = page * this.PAGE_SIZE + 1
    const end = Math.min((page + 1) * this.PAGE_SIZE, this.context.items.length)
    return `${start}-${end}`
  }

  private isCurrentItem(item: PlaybackContextItem): boolean {
    return item.index === this.context.currentIndex
  }

  private buildPageRange(): number[] {
    const total = this.getTotalPages()
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
        Image(item.posterPath ? item.posterPath : $r('app.media.empty_folder'))
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

      // 集数卡片横向列表（LazyForEach + 遥控器键盘处理）
      List({ space: 48 }) {
        LazyForEach(
          this.dataSource,
          (item: Object, index: number) => {
            ListItem() {
              this.EpisodeCard(item as PlaybackContextItem, index)
            }
          },
          (item: Object, index: number) => index.toString()
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
                  this.pageBarFocusedIndex = this.pageBarFocusedIndex - 1
                  this.goToPage(this.pageBarFocusedIndex)
                } else if (event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT && this.pageBarFocusedIndex < this.getTotalPages() - 1) {
                  this.pageBarFocusedIndex = this.pageBarFocusedIndex + 1
                  this.goToPage(this.pageBarFocusedIndex)
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
