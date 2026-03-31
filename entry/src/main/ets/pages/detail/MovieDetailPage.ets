import { MediaItem } from '../../db/models/MediaEntity';
import { PlayerPageParam, PlayerPage } from '../player/index';

// ─────────────────────────────────────────────
// 工具函数
// ─────────────────────────────────────────────

function formatRuntime(ms: number | undefined): string {
  if (ms === undefined || ms <= 0) {
    return '未知';
  }
  const totalSeconds = Math.floor(ms / 1000);
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  if (h > 0) {
    return h.toString() + ' 小时 ' + m.toString() + ' 分';
  }
  return m.toString() + ' 分钟';
}

function formatYear(date: string | undefined): string {
  if (!date || date.length < 4) {
    return '';
  }
  return date.substring(0, 4);
}

function parseGenresArr(json: string | undefined): string[] {
  if (!json) {
    return [];
  }
  try {
    return JSON.parse(json) as string[];
  } catch (e) {
    return [];
  }
}

// ─────────────────────────────────────────────
// 电影详情页
// ─────────────────────────────────────────────

@ComponentV2
export struct MovieDetailPage {
  static readonly PAGE_NAME: string = 'movieDetail';

  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();

  @Local item: MediaItem | undefined = undefined;
  @Local isHovered: boolean = false;

  // ── 计算属性 ──

  private getTitle(): string {
    return this.item?.title ?? this.item?.fileName ?? '未知影片';
  }

  private getPoster(): string {
    return this.item?.posterLocalPath ?? this.item?.posterUrl ?? '';
  }

  private hasPoster(): boolean {
    const p = this.getPoster();
    return p.length > 0;
  }

  private getYear(): string {
    return formatYear(this.item?.releaseDate);
  }

  private getRating(): string {
    const r = this.item?.rating;
    if (r === undefined) {
      return '';
    }
    return r.toFixed(1) + ' 分';
  }

  private getRuntime(): string {
    return formatRuntime(this.item?.durationMs);
  }

  private getOverview(): string {
    const ov = this.item?.overview;
    if (!ov || ov.length === 0) {
      return '暂无简介';
    }
    return ov;
  }

  private getGenres(): string[] {
    return parseGenresArr(this.item?.genresJson);
  }

  // ── 播放 ──

  private play(): void {
    if (this.item === undefined) {
      return;
    }
    const param: PlayerPageParam = {
      videoId: this.item.id,
      url: this.item.filePath,
      title: this.getTitle(),
      durationHintMs: this.item.durationMs,
    };
    this.pageStack.pushPathByName(PlayerPage.PAGE_NAME, param);
  }

  // ── 构建 ──

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 背景：模糊横幅（若无海报则纯色）
        if (this.hasPoster()) {
          Image(this.getPoster())
            .width('100%')
            .height('50%')
            .objectFit(ImageFit.Cover)
            .blur(30)
            .opacity(0.35)
        }

        // 顶部渐变遮罩
        Column()
          .width('100%')
          .height('50%')
          .linearGradient({
            angle: 180,
            colors: [['#00000000', 0.0], ['#FF1A1A1A', 1.0]]
          })
          .hitTestBehavior(HitTestMode.Transparent)

        // 主体内容
        Row({ space: 40 }) {
          // 海报列
          Column() {
            if (this.hasPoster()) {
              Image(this.getPoster())
                .width(200)
                .height(300)
                .objectFit(ImageFit.Cover)
                .borderRadius(8)
                .shadow({ radius: 20, color: 'rgba(0,0,0,0.5)', offsetX: 0, offsetY: 8 })
            } else {
              Column() {
                Text(this.getTitle())
                  .fontSize(14)
                  .fontColor('#CCCCCC')
                  .textAlign(TextAlign.Center)
                  .maxLines(4)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .padding(12)
              }
              .width(200)
              .height(300)
              .backgroundColor('#2A2A2A')
              .borderRadius(8)
              .justifyContent(FlexAlign.Center)
            }
          }
          .margin({ top: 60 })

          // 信息列
          Column({ space: 16 }) {
            // 标题
            Text(this.getTitle())
              .fontSize(36)
              .fontColor(Color.White)
              .fontWeight(FontWeight.Bold)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            // 元数据行（年份 / 时长 / 评分）
            Row({ space: 16 }) {
              if (this.getYear().length > 0) {
                Text(this.getYear())
                  .fontSize(16)
                  .fontColor('#AAAAAA')
              }
              if (this.getRuntime() !== '未知') {
                Text(this.getRuntime())
                  .fontSize(16)
                  .fontColor('#AAAAAA')
              }
              if (this.getRating().length > 0) {
                Text('★ ' + this.getRating())
                  .fontSize(16)
                  .fontColor('#FFA500')
                  .fontWeight(FontWeight.Medium)
              }
            }

            // 类型标签
            if (this.getGenres().length > 0) {
              Row({ space: 8 }) {
                ForEach(this.getGenres(), (genre: string) => {
                  Text(genre)
                    .fontSize(13)
                    .fontColor('#CCCCCC')
                    .backgroundColor('rgba(255,255,255,0.12)')
                    .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                    .borderRadius(4)
                })
              }
            }

            // 播放按钮
            Button({ type: ButtonType.Normal }) {
              Row({ space: 8 }) {
                Text('▶')
                  .fontSize(20)
                  .fontColor(Color.White)
                Text('立即播放')
                  .fontSize(22)
                  .fontColor(Color.White)
                  .fontWeight(FontWeight.Medium)
              }
              .padding({ left: 8, right: 8 })
            }
            .width(220)
            .height(60)
            .backgroundColor('#2196F3')
            .borderRadius(8)
            .focusable(true)
            .onClick(() => { this.play(); })

            // 简介
            Column({ space: 8 }) {
              Text('简介')
                .fontSize(18)
                .fontColor('#FFFFFF')
                .fontWeight(FontWeight.Medium)
              Text(this.getOverview())
                .fontSize(16)
                .fontColor('#BBBBBB')
                .lineHeight(26)
                .maxLines(6)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .margin({ top: 8 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 60 })
        }
        .width('100%')
        .padding({ left: 60, right: 60, bottom: 40 })
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#1A1A1A')
    }
    .onReady((context: NavDestinationContext) => {
      const param = context.pathInfo.param as MediaItem;
      if (param !== undefined && param !== null) {
        this.item = param;
      }
    })
    .hideTitleBar(true)
  }
}
