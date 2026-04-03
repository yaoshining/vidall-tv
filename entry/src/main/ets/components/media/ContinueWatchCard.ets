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
import { FileSourceType, SMBSourceConfig } from '../../db/models/FileSourceEntity';
import { WebDAVClient, WebDAVConfig } from '../../lib/WebDAVClient';

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
      const config = JSON.parse(fileSource.configJson) as Record<string, string>;
      let fullUrl: string = '';
      let httpHeader: Record<string, string> = {};

      if (fileSource.type === FileSourceType.SMB) {
        const smbConfig = JSON.parse(fileSource.configJson) as SMBSourceConfig;
        const port = smbConfig.port ?? 445;
        const user = encodeURIComponent(smbConfig.username);
        const pass = encodeURIComponent(smbConfig.password);
        const encodedPath = this.item.filePath.split('/').map((seg: string): string => {
          if (seg.length === 0) {
            return '';
          }
          let decoded: string = seg;
          try {
            decoded = decodeURIComponent(seg);
          } catch {
            decoded = seg;
          }
          return encodeURIComponent(decoded);
        }).join('/');
        fullUrl = 'smb://' + user + ':' + pass + '@' + smbConfig.host + ':' + port.toString() + encodedPath;
        httpHeader = {};
      } else if (fileSource.type === FileSourceType.WEBDAV) {
        const protocol = config['protocol'] ?? 'http';
        const host = config['url'] ?? '';
        const portStr = config['port'] ?? (protocol === 'https' ? '443' : '80');
        const rootPath = (config['rootPath'] ?? '').replace(/\/$/, '');
        const baseUrl = protocol + '://' + host + ':' + portStr + rootPath;
        const webdavConfig: WebDAVConfig = {
          baseUrl,
          username: config['username'] ?? '',
          password: config['password'] ?? '',
          timeout: 30000
        };
        const client = new WebDAVClient(webdavConfig);
        fullUrl = client.getFullUrl(this.item.filePath);
        const authHeader = client.getAuthHeaderPublic();
        httpHeader = authHeader.length > 0 ? { 'Authorization': authHeader } : {};
      } else {
        console.warn('[ContinueWatchCard] 不支持的文件源类型: ' + fileSource.type.toString());
        return;
      }

      const param: PlayerPageParam = {
        videoId: this.item.videoId,
        url: fullUrl,
        httpHeader,
        title: this.item.title,
        durationHintMs: this.item.durationMs > 0 ? this.item.durationMs : undefined,
        mediaKey: this.item.mediaKey,
        startPositionMs: this.item.startPositionMs,
        seriesProviderId: this.item.seriesProviderId,
        seasonNumber: this.item.seasonNumber,
        episodeNumber: this.item.episodeNumber
      };
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
