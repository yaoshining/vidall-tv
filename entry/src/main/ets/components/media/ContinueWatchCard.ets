/**
 * 「继续播放」宽卡片组件
 *
 * 规格：宽 320vp，16:9（高 180vp），圆角 8vp
 * 层次（底→顶）：
 *   1. 封面图（backdrop 优先）/ 渐变占位
 *   2. 底部 55% 渐变遮罩
 *   3. 剧集集号标签（left-top）
 *   4. 底部信息区（标题 + 进度文字 + 百分比）
 *   5. 进度条（bottom，高 4/5vp）
 *   6. 聚焦遮罩
 *
 * 点击：异步构建 PlayerPageParam，直接跳播放器（startPositionMs 传入，不弹续播弹窗）
 */

import { ContinueWatchingItem } from '../../db/models/MediaEntity';
import { PlayerPageParam, PlayerPage } from '../../pages/player/index';
import { FileSourceDatabase } from '../../db/files/FileSourceDatabase';
import { MediaLibraryContext } from '../core/player/PlaybackContext';
import { PresetAudioTrack, PresetSubtitleTrack } from '../core/player/VideoData';
import { FileSourceTypeLabels } from '../../db/models/FileSourceEntity';
import { defaultSourceAdapterService as sourceAdapter, identityToPlayerPageParams } from '../../services/sourceAdapter/SourceAdapterService';
import promptAction from '@ohos.promptAction';
import { resolvePlaybackTrackPresetFromDb } from '../../utils/PlaybackTrackPresetHelper';

export interface ContinueWatchPlayerParamInput {
  item: ContinueWatchingItem
  fullUrl: string
  httpHeader: Record<string, string>
  title: string
  durationHintMs?: number
  presetAudioTracks?: PresetAudioTrack[]
  presetSubtitleTracks?: PresetSubtitleTrack[]
  /**
   * 稳定 source identity（来自 SourceAdapterService），用于字幕缓存分桶。
   * 视频/剧集不传时保持 undefined，行为与历史实现一致。
   */
  fileSourceType?: string
  fileSourceId?: string
}

export function buildContinueWatchPlayerParam(input: ContinueWatchPlayerParamInput): PlayerPageParam {
  const param: PlayerPageParam = {
    videoId: input.item.videoId,
    url: input.fullUrl,
    httpHeader: input.httpHeader,
    title: input.title,
    durationHintMs: input.durationHintMs,
    mediaKey: input.item.mediaKey,
    startPositionMs: input.item.startPositionMs,
    seriesProviderId: input.item.seriesProviderId,
    seasonNumber: input.item.seasonNumber,
    episodeNumber: input.item.episodeNumber,
    presetAudioTracks: input.presetAudioTracks,
    presetSubtitleTracks: input.presetSubtitleTracks
  };
  if (input.fileSourceType !== undefined) {
    param.fileSourceType = input.fileSourceType;
  }
  if (input.fileSourceId !== undefined) {
    param.fileSourceId = input.fileSourceId;
  }
  // 透传封面字段，供系统媒体中心（AVSession）展示海报
  const item = input.item;
  if (item.backdropLocalPath !== undefined && item.backdropLocalPath.length > 0) {
    param.backdropLocalPath = item.backdropLocalPath;
  }
  if (item.posterLocalPath !== undefined && item.posterLocalPath.length > 0) {
    param.posterLocalPath = item.posterLocalPath;
  }
  if (item.backdropUrl !== undefined && item.backdropUrl.length > 0) {
    param.backdropUrl = item.backdropUrl;
  }
  if (item.posterUrl !== undefined && item.posterUrl.length > 0) {
    param.posterUrl = item.posterUrl;
  }
  return param;
}

// ─── 卡片尺寸常量 ────────────────────────────────
const CARD_W = 320;
const CARD_H = 180;
const CARD_RADIUS = 8;

@ComponentV2
export struct ContinueWatchCard {
  @Require @Param item: ContinueWatchingItem
  @Local isFocused: boolean = false
  @Local isHovered: boolean = false
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack()

  // ── 私有计算辅助方法 ────────────────────────────

  private getProgressColor(): string {
    if (this.item.progressRatio >= 0.70) {
      return '#66DD88';
    }
    if (this.item.progressRatio >= 0.30) {
      return '#FFA500';
    }
    return '#FF6B35';
  }

  private getProgressBarHeight(): number {
    return this.isFocused ? 5 : 4;
  }

  private getBorderColor(): string {
    return (this.isFocused || this.isHovered) ? 'rgba(255,255,255,0.38)' : '#00FFFFFF';
  }

  private getOverlayColor(): string {
    return this.isFocused ? 'rgba(0,0,0,0.14)' : '#00000000';
  }

  private getSeriesLabel(): string {
    if (this.item.kind !== 'series') {
      return '';
    }
    return `第${this.item.seasonNumber}季 第${this.item.episodeNumber}集`;
  }

  private buildPlayerTitle(): string {
    if (this.item.kind !== 'series') {
      return this.item.title;
    }
    const sn = this.item.seasonNumber;
    const en = this.item.episodeNumber;
    const chineseNums = ['零','一','二','三','四','五','六','七','八','九','十',
      '十一','十二','十三','十四','十五','十六','十七','十八','十九','二十'];
    const seasonLabel = sn <= 0 ? '特别篇'
      : (sn < chineseNums.length ? `第${chineseNums[sn]}季` : `第${sn}季`);
    const code = `S${sn}:E${en}`;
    const epName = (this.item.episodeTitle ?? '').trim();
    if (epName.length > 0) {
      return `${this.item.title} ${seasonLabel}-${code}-${epName}`;
    }
    return `${this.item.title} ${seasonLabel}-${code}`;
  }

  private getSubtitle(): string {
    return `${this.item.positionFormatted} / ${this.item.durationFormatted}`;
  }

  private getProgressPercent(): string {
    const pct = Math.floor(this.item.progressRatio * 100);
    return `${pct}%`;
  }

  private hasCoverImage(): boolean {
    return (this.item.backdropLocalPath.length > 0)
      || (this.item.backdropUrl.length > 0)
      || (this.item.posterLocalPath.length > 0)
      || (this.item.posterUrl.length > 0);
  }

  private getCoverSrc(): string {
    if (this.item.backdropLocalPath.length > 0) {
      return this.item.backdropLocalPath;
    }
    if (this.item.backdropUrl.length > 0) {
      return this.item.backdropUrl;
    }
    if (this.item.posterLocalPath.length > 0) {
      return this.item.posterLocalPath;
    }
    return this.item.posterUrl;
  }

  private getProgressFillWidth(): string {
    const ratio = this.item.progressRatio < 0 ? 0 : (this.item.progressRatio > 1 ? 1 : this.item.progressRatio);
    return `${ratio * 100}%`;
  }

  // ── 点击处理（异步构建 URL → 跳播放器） ─────────────

  private onCardClick(): void {
    this.buildAndPlay().catch(() => {});
  }

  private async buildAndPlay(): Promise<void> {
    try {
      const db = FileSourceDatabase.getInstance();
      const fileSource = await db.getFileSourceById(this.item.sourceId);
      if (fileSource === null) {
        console.warn('[ContinueWatchCard] 找不到文件源 sourceId=' + this.item.sourceId.toString());
        return;
      }
      // 协议拼装与 DB 落库元数据已统一收口到 SourceAdapterService。
      const resolved = await sourceAdapter.resolveFromFileSource(fileSource, this.item.filePath, this.item.videoId ?? 0);
      if (resolved === null) {
        const typeName = FileSourceTypeLabels.getLabel(fileSource.type);
        console.warn('[ContinueWatchCard] 不支持的文件源类型: ' + fileSource.type.toString());
        this.getUIContext().getPromptAction().showToast({ message: typeName + ' 暂不支持继续播放' });
        return;
      }
      const identityParams = identityToPlayerPageParams(resolved.sourceIdentity);
      const fileSourceType = identityParams.fileSourceType;
      const fileSourceId = identityParams.fileSourceId;
      const fullUrl: string = resolved.url;
      const httpHeader: Record<string, string> = resolved.httpHeader;

      const presetResult = await resolvePlaybackTrackPresetFromDb(
        this.item.filePath,
        this.item.durationMs,
        async (filePath: string) => db.getVideoByPath(filePath)
      );
      const param = buildContinueWatchPlayerParam({
        item: this.item,
        fullUrl,
        httpHeader,
        title: this.buildPlayerTitle(),
        durationHintMs: presetResult.durationHintMs,
        presetAudioTracks: presetResult.presetAudioTracks,
        presetSubtitleTracks: presetResult.presetSubtitleTracks,
        fileSourceType,
        fileSourceId
      });
      if (this.item.kind === 'series' && this.item.tvSeriesId > 0 && this.item.seasonNumber > 0) {
        try {
          const playbackCtx = await MediaLibraryContext.build(
            db,
            this.item.tvSeriesId,
            this.item.seasonNumber,
            this.item.filePath
          );
          param.playbackContext = playbackCtx;
        } catch (e) {
          // 构建失败不阻断播放，playbackContext 保持 undefined
          console.warn('[ContinueWatchCard] 构建 playbackContext 失败');
        }
      }
      // 继续播放入口无详情页承载，失效媒体提示与同步在播放页内就地处理
      param.missingMediaSyncLocally = true;
      this.pageStack.pushPathByName(PlayerPage.PAGE_NAME, param);
    } catch (e) {
      console.error('[ContinueWatchCard] buildAndPlay 失败', JSON.stringify(e));
    }
  }

  // ── build ──────────────────────────────────────────

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ① 封面图 / 渐变占位
      if (this.hasCoverImage()) {
        Image(this.getCoverSrc())
          .width(CARD_W)
          .height(CARD_H)
          .objectFit(ImageFit.Cover)
      } else {
        Column()
          .width(CARD_W)
          .height(CARD_H)
          .linearGradient({
            angle: 135,
            colors: [['#1A1A2E', 0.0], ['#2D2D44', 1.0]]
          })
      }

      // ② 底部 55% 渐变遮罩
      Column()
        .width(CARD_W)
        .height('55%')
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.0], ['#E6000000', 1.0]]
        })
        .position({ left: 0, bottom: 0 })

      // ③ 剧集标签（仅 series 显示）
      if (this.item.kind === 'series') {
        Text(this.getSeriesLabel())
          .fontSize(10)
          .fontColor('#FFFFFF')
          .backgroundColor('#66000000')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(4)
          .position({ left: 8, top: 8 })
      }

      // ④ 底部信息区（标题 + 进度文字 + 百分比）
      Row() {
        Column({ space: 2 }) {
          Text(this.item.title)
            .fontSize(14)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width(220)
          Text(this.getSubtitle())
            .fontSize(11)
            .fontColor('#BBBBBB')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width(220)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.getProgressPercent())
          .fontSize(12)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Bold)
          .backgroundColor('#44000000')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(4)
      }
      .width(CARD_W)
      .padding({ left: 10, right: 10, bottom: 20 })
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Bottom)
      .position({ left: 0, bottom: 0 })

      // ⑤ 进度条（轨道 + 填充）
      Stack({ alignContent: Alignment.BottomStart }) {
        // 轨道
        Column()
          .width(CARD_W)
          .height(this.getProgressBarHeight())
          .backgroundColor('rgba(255,255,255,0.20)')
        // 填充（颜色随进度变化）
        Column()
          .width(this.getProgressFillWidth())
          .height(this.getProgressBarHeight())
          .backgroundColor(this.getProgressColor())
      }
      .width(CARD_W)
      .height(this.getProgressBarHeight())
      .position({ left: 0, bottom: 0 })

      // ⑥ 聚焦遮罩
      Column()
        .width(CARD_W)
        .height(CARD_H)
        .backgroundColor(this.getOverlayColor())
        .position({ left: 0, top: 0 })
        .hitTestBehavior(HitTestMode.Transparent)
    }
    .width(CARD_W)
    .height(CARD_H)
    .borderRadius(CARD_RADIUS)
    .clip(true)
    .border({ width: 2, color: this.getBorderColor() })
    .shadow({
      radius: this.isFocused ? 14 : 6,
      color: 'rgba(0,0,0,0.36)',
      offsetX: 0,
      offsetY: 2
    })
    .scale({ x: this.isFocused ? 1.04 : 1.0, y: this.isFocused ? 1.04 : 1.0 })
    .animation({ duration: 140, curve: Curve.EaseInOut })
    .focusable(true)
    .onFocus(() => { this.isFocused = true; })
    .onBlur(() => { this.isFocused = false; })
    .onHover((h: boolean) => { this.isHovered = h; })
    .onClick(() => { this.onCardClick(); })
  }
}
