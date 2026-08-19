/**
 * 详情页公用展示组件（数据源无关）。
 * 文件源与影视服务器详情页共用同一套展示，避免样式多处维护。
 */
import { toOpaqueColor } from '../../utils/MediaFormatUtil'

export interface DetailCastMember {
  name: string;
  role: string;
  imageUrl: string;
  /** 人物 ID（文件源 TMDB personId），为空则不可点击 */
  personId: string;
}

export interface DetailSeason {
  id: string;
  label: string;
  posterUrl: string;
}

export interface DetailEpisode {
  id: string;
  label: string;
  overview: string;
  stillUrl: string;
  durationText: string;
  ratingText: string;
  progressPercent: number;
  /** 是否已看完（≥95%），显示「✓ 已看」徽标 */
  watched: boolean;
  /** 无缩略图时的占位文案（通常是集号） */
  placeholderText: string;
}

export function formatDetailDurationMs(durationMs: number): string {
  if (durationMs <= 0) {
    return '';
  }
  const totalSeconds = Math.floor(durationMs / 1000);
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const mm = m.toString().padStart(2, '0');
  const ss = (totalSeconds % 60).toString().padStart(2, '0');
  if (h > 0) {
    return h.toString() + ':' + mm + ':' + ss;
  }
  return '0:' + mm + ':' + ss;
}

/** 演职人员横向滚动列表 */
@ComponentV2
export struct DetailCastSection {
  @Require @Param members: DetailCastMember[]
  @Event onCastClick: (member: DetailCastMember) => void = () => {}

  build() {
    if (this.members.length > 0) {
      Column({ space: 0 }) {
        Text('演职人员')
          .fontSize(26).fontColor(Color.White).fontWeight(FontWeight.Bold)
          .padding({ left: 80, top: 36, bottom: 20 })

        Scroll() {
          Row({ space: 24 }) {
            ForEach(this.members.slice(0, 15), (c: DetailCastMember) => {
              Column({ space: 8 }) {
                if (c.imageUrl.length > 0) {
                  Image(c.imageUrl)
                    .width(110).aspectRatio(2 / 3)
                    .objectFit(ImageFit.Cover).borderRadius(6)
                    .hoverEffect(HoverEffect.Scale)
                } else {
                  Column() {
                    Text((c.name.length > 0) ? c.name.substring(0, 1) : '?')
                      .fontSize(30).fontColor(Color.White).fontWeight(FontWeight.Bold)
                  }
                  .width(110).aspectRatio(2 / 3).borderRadius(6)
                  .backgroundColor('#2A2A2A')
                  .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                  .hoverEffect(HoverEffect.Scale)
                }
                Text(c.name)
                  .fontSize(14).fontColor(Color.White)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width(110).textAlign(TextAlign.Center)
                if (c.role.length > 0) {
                  Text(c.role)
                    .fontSize(12).fontColor('#777777')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width(110).textAlign(TextAlign.Center)
                }
              }
              .width(110).alignItems(HorizontalAlign.Center)
              .focusable(c.personId.length > 0)
              .onClick(() => {
                if (c.personId.length > 0) {
                  this.onCastClick(c)
                }
              })
            }, (c: DetailCastMember, idx: number) => c.name + '_' + c.role + '_' + idx.toString())
          }
          .padding({ left: 80, right: 80 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)

        Column().height(36)
      }
      .width('100%').alignItems(HorizontalAlign.Start)
    }
  }
}

/** 季列表（横向滚动） */
@ComponentV2
export struct DetailSeasonsSection {
  @Require @Param seasons: DetailSeason[]
  @Event onSeasonClick: (season: DetailSeason) => void = () => {}

  build() {
    if (this.seasons.length > 0) {
      Column({ space: 0 }) {
        Text('季')
          .fontSize(26).fontColor(Color.White).fontWeight(FontWeight.Bold)
          .padding({ left: 80, top: 36, bottom: 20 })

        Scroll() {
          Row({ space: 16 }) {
            ForEach(this.seasons, (s: DetailSeason) => {
              Column({ space: 8 }) {
                Stack({ alignContent: Alignment.Bottom }) {
                  if (s.posterUrl.length > 0) {
                    Image(s.posterUrl)
                      .width(140).aspectRatio(2 / 3)
                      .objectFit(ImageFit.Cover).borderRadius(6)
                      .hoverEffect(HoverEffect.Scale)
                  } else {
                    Column() {
                      Text(s.label)
                        .fontSize(14).fontColor('#CCCCCC')
                        .textAlign(TextAlign.Center)
                    }
                    .width(140).aspectRatio(2 / 3)
                    .backgroundColor('#2A2A2A').borderRadius(6)
                    .justifyContent(FlexAlign.Center)
                    .hoverEffect(HoverEffect.Scale)
                  }
                }
                .width(140).aspectRatio(2 / 3)
                .borderRadius(6).clip(true)

                Text(s.label)
                  .fontSize(14)
                  .fontColor('#CCCCCC')
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width(140).textAlign(TextAlign.Center)
              }
              .width(140).alignItems(HorizontalAlign.Start)
              .onClick(() => { this.onSeasonClick(s) })
            }, (s: DetailSeason) => s.id + '_' + s.label)
          }
          .padding({ left: 80, right: 80 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)

        Column().height(36)
      }
      .width('100%').alignItems(HorizontalAlign.Start)
    }
  }
}

/** 集列表（含 hover/focus 状态与操作按钮，与文件源一致） */
@ComponentV2
export struct DetailEpisodesSection {
  @Require @Param episodes: DetailEpisode[]
  @Event onEpisodeClick: (episode: DetailEpisode) => void = () => {}
  @Local focusedRowId: string = ''
  @Local hoveredRowId: string = ''
  @Local focusedActionKey: string = ''
  @Local hoveredActionKey: string = ''

  private buildActionKey(ep: DetailEpisode, action: string): string { return `${ep.id}-${action}`; }
  private isRowFocused(ep: DetailEpisode): boolean { return this.focusedRowId === ep.id; }
  private isRowHovered(ep: DetailEpisode): boolean { return this.hoveredRowId === ep.id; }
  private isActionFocused(ep: DetailEpisode, action: string): boolean { return this.focusedActionKey === this.buildActionKey(ep, action); }
  private isActionHovered(ep: DetailEpisode, action: string): boolean { return this.hoveredActionKey === this.buildActionKey(ep, action); }
  private clearRowFocusIfMatches(ep: DetailEpisode): void { if (this.focusedRowId === ep.id) { this.focusedRowId = ''; } }
  private clearRowHoverIfMatches(ep: DetailEpisode): void { if (this.hoveredRowId === ep.id) { this.hoveredRowId = ''; } }
  private clearActionFocusIfMatches(ep: DetailEpisode, action: string): void {
    const k = this.buildActionKey(ep, action);
    if (this.focusedActionKey === k) { this.focusedActionKey = ''; }
  }
  private clearActionHoverIfMatches(ep: DetailEpisode, action: string): void {
    const k = this.buildActionKey(ep, action);
    if (this.hoveredActionKey === k) { this.hoveredActionKey = ''; }
  }
  private rowBgColor(ep: DetailEpisode): string {
    if (this.isRowFocused(ep)) { return 'rgba(255, 255, 255, 0.10)'; }
    if (this.isRowHovered(ep)) { return 'rgba(255, 255, 255, 0.06)'; }
    return '#00000000';
  }
  private rowBorderColor(ep: DetailEpisode): string {
    if (this.isRowFocused(ep)) { return '#66A9D8FF'; }
    if (this.isRowHovered(ep)) { return 'rgba(255, 255, 255, 0.32)'; }
    return '#00FFFFFF';
  }
  private actionCircleBg(ep: DetailEpisode, action: string): string {
    if (this.isActionFocused(ep, action)) { return 'rgba(27, 120, 242, 0.36)'; }
    if (this.isActionHovered(ep, action)) { return 'rgba(255, 255, 255, 0.20)'; }
    return '#662C2F33';
  }
  private actionCircleBorder(ep: DetailEpisode, action: string): string {
    if (this.isActionFocused(ep, action)) { return '#66A9D8FF'; }
    if (this.isActionHovered(ep, action)) { return 'rgba(255, 255, 255, 0.38)'; }
    return 'rgba(255, 255, 255, 0.18)';
  }

  @Builder
  ActionButton(ep: DetailEpisode, action: string, glyph: string) {
    Text(glyph)
      .fontSize(18).fontColor('#B5BBC4')
      .width(44).height(44)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.actionCircleBg(ep, action)).borderRadius(22)
      .border({ width: this.isActionFocused(ep, action) ? 2 : 1, color: this.actionCircleBorder(ep, action) })
      .onHover((isHover: boolean) => {
        if (isHover) {
          this.hoveredActionKey = this.buildActionKey(ep, action);
        } else {
          this.clearActionHoverIfMatches(ep, action);
        }
      })
  }

  build() {
    if (this.episodes.length > 0) {
      Column({ space: 0 }) {
        Row() {
          Text('集')
            .fontSize(26).fontColor(Color.White).fontWeight(FontWeight.Bold)
          Blank()
          Row({ space: 8 }) {
            Text('‹')
              .fontSize(22).fontColor('#CCCCCC')
              .width(36).height(36)
              .textAlign(TextAlign.Center)
              .backgroundColor('#662C2F33').borderRadius(18)
            Text('›')
              .fontSize(22).fontColor('#CCCCCC')
              .width(36).height(36)
              .textAlign(TextAlign.Center)
              .backgroundColor('#662C2F33').borderRadius(18)
          }
        }
        .width('100%')
        .padding({ left: 80, right: 80, top: 36, bottom: 20 })
        .alignItems(VerticalAlign.Center)

        ForEach(this.episodes, (ep: DetailEpisode, idx: number) => {
          Column({ space: 0 }) {
            if (idx > 0) {
              Divider().color('#24282D').strokeWidth(1)
            }
            Row({ space: 28 }) {
              Stack({ alignContent: Alignment.Center }) {
                if (ep.stillUrl.length > 0) {
                  Image(ep.stillUrl)
                    .width(310).height(174)
                    .borderRadius(6).objectFit(ImageFit.Cover)
                } else {
                  Column() {
                    Text(ep.placeholderText)
                      .fontSize(28).fontColor('#555555').fontWeight(FontWeight.Bold)
                  }
                  .width(310).height(174)
                  .backgroundColor('#1E1E1E').borderRadius(6)
                  .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                }
                Column() {
                  SymbolGlyph($r('sys.symbol.play_fill'))
                    .fontColor([Color.White])
                    .fontSize(28)
                }
                .backgroundColor('rgba(200, 200, 200, 0.2)')
                .backdropBlur(40)
                .padding(14)
                .borderRadius(99)
                .border({ width: 1, color: 'rgba(255, 255, 255, 0.2)' })
                .shadow({ radius: 20, color: 'rgba(0, 0, 0, 0.4)' })
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .hitTestBehavior(HitTestMode.Transparent)

                if (ep.progressPercent > 0) {
                  Column() {
                    Column()
                      .width(Math.round(ep.progressPercent * 100).toString() + '%')
                      .height('100%')
                      .backgroundColor('#1B78F2').borderRadius(2)
                      .alignSelf(ItemAlign.Start)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .width(310).height(4)
                  .backgroundColor('#2E2E2E').borderRadius(2)
                  .position({ left: 0, bottom: 0 })
                  .hitTestBehavior(HitTestMode.Transparent)
                }
              }
              .width(310).height(174)
              .borderRadius(6).clip(true)
              .onClick(() => { this.onEpisodeClick(ep) })

              Column({ space: 12 }) {
                Text(ep.label)
                  .fontSize(20).fontColor(Color.White).fontWeight(FontWeight.Bold)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })

                Row({ space: 16 }) {
                  if (ep.durationText.length > 0) {
                    Text(ep.durationText)
                      .fontSize(15).fontColor('#888888')
                  }
                  if (ep.ratingText.length > 0) {
                    Row({ space: 4 }) {
                      Text('★').fontSize(14).fontColor('#F5B942')
                      Text(ep.ratingText)
                        .fontSize(15).fontColor('#CCCCCC').fontWeight(FontWeight.Medium)
                    }
                  }
                  if (ep.watched) {
                    Text('✓ 已看')
                      .fontSize(13).fontColor('#1B78F2')
                      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                      .backgroundColor('#192840').borderRadius(3)
                  }
                }
                .alignItems(VerticalAlign.Center)

                if (ep.overview.length > 0) {
                  Text(ep.overview)
                    .fontSize(15).fontColor('#AAAAAA').lineHeight(24)
                    .height(96)
                    .maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .justifyContent(FlexAlign.Start)
              .onClick(() => { this.onEpisodeClick(ep) })

              Row({ space: 8 }) {
                this.ActionButton(ep, 'info', 'ⓘ')
                this.ActionButton(ep, 'check', '✓')
                this.ActionButton(ep, 'heart', '♥')
                this.ActionButton(ep, 'more', '⋮')
              }
              .alignSelf(ItemAlign.Center)
            }
            .width('100%')
            .padding({ left: 80, right: 80, top: 20, bottom: 20 })
            .backgroundColor(this.rowBgColor(ep))
            .borderRadius(8)
            .border({ width: 2, color: this.rowBorderColor(ep) })
            .alignItems(VerticalAlign.Top)
            .focusable(true)
            .onClick(() => { this.onEpisodeClick(ep) })
            .onFocus(() => { this.focusedRowId = ep.id; })
            .onBlur(() => { this.clearRowFocusIfMatches(ep); })
            .onHover((isHover: boolean) => {
              if (isHover) {
                this.hoveredRowId = ep.id;
              } else {
                this.clearRowHoverIfMatches(ep);
              }
            })
            .animation({ duration: 140, curve: Curve.EaseInOut })
          }
          .width('100%')
        }, (ep: DetailEpisode) => ep.id)

        Column().height(36)
      }
      .width('100%').alignItems(HorizontalAlign.Start)
    }
  }
}

/** 简介全文弹窗（双面板：封面 + 元数据 | 全文） */
@ComponentV2
export struct DetailOverviewDialog {
  @Require @Param visible: boolean
  @Require @Param title: string
  @Require @Param posterUrl: string
  @Require @Param overview: string
  @Param genresText: string = ''
  @Param runtimeText: string = ''
  @Param year: string = ''
  @Event onClose: () => void = () => {}

  build() {
    if (this.visible) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%').height('100%')
          .backgroundColor('#BB000000')
          .onClick(() => { this.onClose() })

        Column() {
          Row() {
            Text('简介')
              .fontSize(26).fontColor('#F0F0F0').fontWeight(FontWeight.Bold)
              .layoutWeight(1).textAlign(TextAlign.Center)
            Text('✕')
              .fontSize(20).fontColor('#888892')
              .width(48).height(48)
              .textAlign(TextAlign.Center)
              .borderRadius(24)
              .backgroundColor('#2A2A2E')
              .onClick(() => { this.onClose() })
          }
          .alignItems(VerticalAlign.Center)
          .padding({ left: 24, right: 24 })
          .height(80)
          .width('100%')
          .backgroundColor('#1E1E22')

          Divider().color('#2E2E34').strokeWidth(1)

          Row() {
            Column({ space: 20 }) {
              if (this.posterUrl.length > 0) {
                Image(this.posterUrl)
                  .width(124).height(174)
                  .borderRadius(6)
                  .objectFit(ImageFit.Cover)
                  .backgroundColor('#2A2A2E')
              } else {
                Column()
                  .width(124).height(174)
                  .borderRadius(6)
                  .backgroundColor('#2A2A2E')
              }

              Text(this.title)
                .fontSize(22).fontWeight(FontWeight.Bold).fontColor('#F0F0F0')
                .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
                .lineHeight(32)
                .width('100%')

              Column({ space: 8 }) {
                if (this.genresText.length > 0) {
                  Text('风格：' + this.genresText)
                    .fontSize(18).fontColor('#AAAAAA')
                }
                if (this.runtimeText.length > 0) {
                  Text('片长：' + this.runtimeText)
                    .fontSize(18).fontColor('#AAAAAA')
                }
                if (this.year.length > 0) {
                  Text(this.year)
                    .fontSize(18).fontColor('#AAAAAA')
                }
              }
              .alignItems(HorizontalAlign.Start).width('100%')
            }
            .width('28%')
            .padding({ left: 48, right: 32, top: 48, bottom: 48 })
            .alignItems(HorizontalAlign.Start)

            Divider().vertical(true).color('#2A2A2E').strokeWidth(1).height('100%')

            Scroll() {
              Text(this.overview)
                .fontSize(20).fontColor('#C8C8D0').lineHeight(36)
                .width('100%')
            }
            .scrollable(ScrollDirection.Vertical)
            .scrollBar(BarState.Auto)
            .scrollBarColor('#555560')
            .layoutWeight(1)
            .padding({ left: 40, right: 40, top: 48, bottom: 48 })
          }
          .alignItems(VerticalAlign.Top)
          .layoutWeight(1)
        }
        .width('85%').height('88%')
        .backgroundColor('#18181C')
        .borderRadius(16)
        .border({ width: 1, color: '#2A2A2E' })
        .clip(true)
      }
      .width('100%').height('100%')
    }
  }
}

/**
 * 详情页顶部 Hero 区（数据源无关）。
 * 文件源季详情页与影视服务器季详情页共用，统一标题/年份/评分/集数/类别/简介/操作按钮。
 */
export interface DetailHeroData {
  backdropUrl: string;
  /** 页面主色调（不透明，用于渐变遮罩） */
  dominantBgColor: string;
  /** 剧名副标题（小字，可空） */
  supertitle: string;
  /** 主标题（季标题/大标题） */
  title: string;
  year: string;
  ratingText: string;
  /** 集数徽标文案，如「12 集」，空则不显示 */
  countText: string;
  genres: string[];
  overview: string;
  playLabel: string;
  onPlayClick: () => void;
  /** 跨季次级入口文案，空则隐藏该入口 */
  crossSeasonLabel: string;
  crossSeasonMetaLabel: string;
  onCrossSeasonClick: () => void;
  onShowOverview: () => void;
}

@ComponentV2
export struct DetailHeroSection {
  @Require @Param data: DetailHeroData
  @Local focusedKey: string = ''
  @Local hoveredKey: string = ''

  private isFocused(action: string): boolean { return this.focusedKey === action; }
  private isHovered(action: string): boolean { return this.hoveredKey === action; }
  private isActive(action: string): boolean { return this.isFocused(action) || this.isHovered(action); }
  private clearFocusIfMatches(action: string): void { if (this.focusedKey === action) { this.focusedKey = ''; } }
  private clearHoverIfMatches(action: string): void { if (this.hoveredKey === action) { this.hoveredKey = ''; } }

  private playBgColor(): string {
    if (this.isFocused('play')) { return '#3C8FF6'; }
    if (this.isHovered('play')) { return '#2E82EA'; }
    return '#1B78F2';
  }
  private playShadowColor(): string {
    if (this.isFocused('play')) { return 'rgba(27, 120, 242, 0.46)'; }
    if (this.isHovered('play')) { return 'rgba(27, 120, 242, 0.30)'; }
    return 'rgba(27, 120, 242, 0.20)';
  }
  private playBorderColor(): string {
    if (this.isFocused('play')) { return '#66A9D8FF'; }
    if (this.isHovered('play')) { return '#7FB7F4'; }
    return '#00FFFFFF';
  }
  private playScale(): number { return this.isActive('play') ? 1.03 : 1.0; }
  private secondaryBgColor(action: string): string {
    if (this.isFocused(action)) { return 'rgba(27, 120, 242, 0.26)'; }
    if (this.isHovered(action)) { return 'rgba(255, 255, 255, 0.14)'; }
    return 'rgba(33, 37, 43, 0.90)';
  }
  private secondaryBorderColor(action: string): string {
    if (this.isFocused(action)) { return '#66A9D8FF'; }
    if (this.isHovered(action)) { return 'rgba(255, 255, 255, 0.38)'; }
    return '#00FFFFFF';
  }
  private secondaryShadowColor(action: string): string {
    if (this.isFocused(action)) { return 'rgba(102, 169, 216, 0.24)'; }
    if (this.isHovered(action)) { return 'rgba(0, 0, 0, 0.26)'; }
    return 'rgba(0, 0, 0, 0.18)';
  }
  private secondaryTitleColor(action: string): string {
    return this.isActive(action) ? '#FFFFFF' : '#DDE3EB';
  }
  private secondaryMetaColor(action: string): string {
    if (this.isFocused(action)) { return '#D3E7FF'; }
    if (this.isHovered(action)) { return '#C7CDD6'; }
    return '#9AA3AF';
  }
  private secondaryScale(action: string): number { return this.isActive(action) ? 1.02 : 1.0; }

  private overviewLong(): boolean { return this.data.overview.length > 100; }
  private overviewShort(): string { return this.data.overview.substring(0, 100) + '...'; }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.data.backdropUrl.length > 0) {
        Image(this.data.backdropUrl)
          .width('100%').height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        Column()
          .width('100%').height('100%')
          .linearGradient({ angle: 135, colors: [['#1A1A2E', 0.0], ['#16213E', 0.5], ['#0F3460', 1.0]] })
      }

      Column()
        .width('100%').height('68%')
        .linearGradient({ angle: 180, colors: [['#00000000', 0.0], [toOpaqueColor(this.data.dominantBgColor), 1.0]] })
        .position({ left: 0, bottom: 0 })

      Column()
        .width('55%').height('100%')
        .linearGradient({ angle: 90, colors: [[toOpaqueColor(this.data.dominantBgColor), 0.0], ['#00000000', 1.0]] })
        .position({ left: 0, top: 0 })

      Column({ space: 14 }) {
        if (this.data.supertitle.length > 0) {
          Text(this.data.supertitle)
            .fontSize(18).fontColor('#BBBBBB').fontWeight(FontWeight.Medium)
        }

        Text(this.data.title)
          .fontSize(52).fontColor(Color.White).fontWeight(FontWeight.Bold)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .textShadow({ radius: 8, color: '#88000000', offsetX: 2, offsetY: 2 })
          .constraintSize({ maxWidth: 720 })

        Row({ space: 12 }) {
          if (this.data.year.length > 0) {
            Text(this.data.year)
              .fontSize(18).fontColor('#CCCCCC').fontWeight(FontWeight.Medium)
          }
          if (this.data.ratingText.length > 0) {
            Row({ space: 4 }) {
              Text('★').fontSize(16).fontColor('#FFA500')
              Text(this.data.ratingText)
                .fontSize(18).fontColor('#FFA500').fontWeight(FontWeight.Bold)
            }
          }
          if (this.data.countText.length > 0) {
            Text(this.data.countText)
              .fontSize(14).fontColor('#CCCCCC')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(4).border({ width: 1, color: '#55FFFFFF' })
          }
          ForEach(this.data.genres.slice(0, 2), (genre: string) => {
            Text(genre)
              .fontSize(14).fontColor('#CCCCCC')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(4).border({ width: 1, color: '#55FFFFFF' })
          }, (genre: string) => genre)
        }
        .alignItems(VerticalAlign.Center)

        if (this.data.overview.length > 0) {
          if (this.overviewLong()) {
            Text() {
              Span(this.overviewShort())
                .fontSize(16).fontColor('#BBBBBB').lineHeight(26)
              Span('更多')
                .fontSize(16).fontColor('#1B78F2').fontWeight(FontWeight.Medium)
                .focusable(true)
                .onClick(() => { this.data.onShowOverview() })
            }
            .constraintSize({ maxWidth: 700 })
          } else {
            Text(this.data.overview)
              .fontSize(16).fontColor('#BBBBBB').lineHeight(26)
              .constraintSize({ maxWidth: 700 })
          }
        }

        Column({ space: 12 }) {
          Row({ space: 14 }) {
            Row({ space: 10 }) {
              Text('▶').fontSize(16).fontColor(Color.White).fontWeight(FontWeight.Bold)
              Text(this.data.playLabel).fontSize(17).fontColor(Color.White).fontWeight(FontWeight.Bold)
            }
            .height(64)
            .padding({ left: 26, right: 26, top: 14, bottom: 14 })
            .backgroundColor(this.playBgColor()).borderRadius(10)
            .border({ width: 2, color: this.playBorderColor() })
            .shadow({ radius: 18, color: this.playShadowColor(), offsetX: 0, offsetY: 10 })
            .scale({ x: this.playScale(), y: this.playScale() })
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .focusable(true)
            .onFocus(() => { this.focusedKey = 'play'; })
            .onBlur(() => { this.clearFocusIfMatches('play'); })
            .onHover((isHover: boolean) => {
              if (isHover) { this.hoveredKey = 'play'; } else { this.clearHoverIfMatches('play'); }
            })
            .onClick(() => { this.data.onPlayClick() })

            if (this.data.crossSeasonLabel.length > 0) {
              Column({ space: 4 }) {
                Row({ space: 8 }) {
                  Text('↩').fontSize(14).fontColor(this.secondaryTitleColor('cross'))
                  Text(this.data.crossSeasonLabel)
                    .fontSize(14).fontColor(this.secondaryTitleColor('cross')).fontWeight(FontWeight.Bold)
                }
                .alignItems(VerticalAlign.Center)

                Text(this.data.crossSeasonMetaLabel)
                  .fontSize(12).fontColor(this.secondaryMetaColor('cross'))
              }
              .alignItems(HorizontalAlign.Start)
              .height(64)
              .padding({ left: 18, right: 18, top: 12, bottom: 12 })
              .backgroundColor(this.secondaryBgColor('cross')).borderRadius(10)
              .border({ width: 2, color: this.secondaryBorderColor('cross') })
              .shadow({ radius: 14, color: this.secondaryShadowColor('cross'), offsetX: 0, offsetY: 8 })
              .scale({ x: this.secondaryScale('cross'), y: this.secondaryScale('cross') })
              .justifyContent(FlexAlign.Center)
              .focusable(true)
              .onFocus(() => { this.focusedKey = 'cross'; })
              .onBlur(() => { this.clearFocusIfMatches('cross'); })
              .onHover((isHover: boolean) => {
                if (isHover) { this.hoveredKey = 'cross'; } else { this.clearHoverIfMatches('cross'); }
              })
              .onClick(() => { this.data.onCrossSeasonClick() })
            }
          }
          .alignItems(VerticalAlign.Center)
          .alignSelf(ItemAlign.Start)

          Row({ space: 12 }) {
            Row({ space: 8 }) {
              Text('✓').fontSize(16).fontColor(this.secondaryTitleColor('wish'))
              Text('想看').fontSize(14).fontColor(this.secondaryTitleColor('wish')).fontWeight(FontWeight.Medium)
            }
            .height(44)
            .padding({ left: 18, right: 18, top: 10, bottom: 10 })
            .backgroundColor(this.secondaryBgColor('wish')).borderRadius(8)
            .border({ width: 2, color: this.secondaryBorderColor('wish') })
            .shadow({ radius: 12, color: this.secondaryShadowColor('wish'), offsetX: 0, offsetY: 6 })
            .scale({ x: this.secondaryScale('wish'), y: this.secondaryScale('wish') })
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .focusable(true)
            .onFocus(() => { this.focusedKey = 'wish'; })
            .onBlur(() => { this.clearFocusIfMatches('wish'); })
            .onHover((isHover: boolean) => {
              if (isHover) { this.hoveredKey = 'wish'; } else { this.clearHoverIfMatches('wish'); }
            })

            Row({ space: 8 }) {
              Text('♥').fontSize(16).fontColor(this.secondaryTitleColor('favorite'))
              Text('收藏').fontSize(14).fontColor(this.secondaryTitleColor('favorite')).fontWeight(FontWeight.Medium)
            }
            .height(44)
            .padding({ left: 18, right: 18, top: 10, bottom: 10 })
            .backgroundColor(this.secondaryBgColor('favorite')).borderRadius(8)
            .border({ width: 2, color: this.secondaryBorderColor('favorite') })
            .shadow({ radius: 12, color: this.secondaryShadowColor('favorite'), offsetX: 0, offsetY: 6 })
            .scale({ x: this.secondaryScale('favorite'), y: this.secondaryScale('favorite') })
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .focusable(true)
            .onFocus(() => { this.focusedKey = 'favorite'; })
            .onBlur(() => { this.clearFocusIfMatches('favorite'); })
            .onHover((isHover: boolean) => {
              if (isHover) { this.hoveredKey = 'favorite'; } else { this.clearHoverIfMatches('favorite'); }
            })
          }
          .alignItems(VerticalAlign.Center)
          .alignSelf(ItemAlign.Start)
        }
        .alignItems(HorizontalAlign.Start)
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 80, right: 80, bottom: 52 })
      .width('65%')
    }
    .width('100%').aspectRatio(1.778)
  }
}
