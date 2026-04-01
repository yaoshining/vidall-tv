import { MediaItem, PlayProgressEntity, MovieEntity } from '../../db/models/MediaEntity';
import { PlayerPageParam, PlayerPage } from '../player/index';
import { FileSourceDatabase } from '../../db/files/FileSourceDatabase';
import { FileSourceType, SMBSourceConfig } from '../../db/models/FileSourceEntity';
import { WebDAVClient, WebDAVConfig } from '../../lib/WebDAVClient';

// ─────────────────────────────────────────────
// 辅助类型
// ─────────────────────────────────────────────

interface CastPerson {
  name: string;
  character?: string;
  profile_path?: string;
}

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

function parseCastArr(json: string | undefined): CastPerson[] {
  if (!json) {
    return [];
  }
  try {
    return JSON.parse(json) as CastPerson[];
  } catch (e) {
    return [];
  }
}

function parseDirectorsArr(json: string | undefined): string[] {
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
  // Thread 2：续播进度
  @Local progress: PlayProgressEntity | null = null;
  // Thread 3：电影详情（演员/导演）
  @Local movieEntity: MovieEntity | null = null;

  // ── 数据加载 ──

  private loadAuxData(item: MediaItem): void {
    const db = FileSourceDatabase.getInstance();
    // 加载续播进度
    db.getPlayProgress(item.id).then((p: PlayProgressEntity | null) => {
      this.progress = p;
    }).catch(() => {
      this.progress = null;
    });
    // 加载电影详情（演员/导演），仅在已刮削时查询
    const provider = item.provider;
    const providerId = item.providerId;
    if (provider !== undefined && provider.length > 0 &&
        providerId !== undefined && providerId.length > 0) {
      db.getMovieByProviderId(provider, providerId).then((m: MovieEntity | null) => {
        this.movieEntity = m;
      }).catch(() => {
        this.movieEntity = null;
      });
    }
  }

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

  // Thread 3：演员列表，最多5人
  private getCast(): CastPerson[] {
    return parseCastArr(this.movieEntity?.castJson).slice(0, 5);
  }

  // Thread 3：导演列表
  private getDirectors(): string[] {
    return parseDirectorsArr(this.movieEntity?.directorsJson);
  }

  // Thread 2：是否有续播进度（大于5秒才算）
  private hasProgress(): boolean {
    const p = this.progress;
    return p !== null && p.positionMs > 5000;
  }

  private getProgressPercent(): number {
    const p = this.progress;
    if (p === null || p.durationMs <= 0) {
      return 0;
    }
    return Math.min(1, p.positionMs / p.durationMs);
  }

  private getPlayButtonText(): string {
    return this.hasProgress() ? '继续播放' : '立即播放';
  }

  // ── 播放（Thread 1：构建正确的 WebDAV/SMB URL）──

  private async play(): Promise<void> {
    const item = this.item;
    if (item === undefined) {
      return;
    }
    try {
      const db = FileSourceDatabase.getInstance();
      const fileSource = await db.getFileSourceById(item.sourceId);
      if (fileSource === null) {
        console.warn('[MovieDetailPage] 找不到文件源 sourceId=' + item.sourceId.toString());
        return;
      }
      const config = JSON.parse(fileSource.configJson) as Record<string, string>;
      let fullUrl: string;
      let httpHeader: Record<string, string>;

      if (fileSource.type === FileSourceType.SMB) {
        // SMB 源：构建带认证的 smb:// URL
        const smbConfig = JSON.parse(fileSource.configJson) as SMBSourceConfig;
        const port = smbConfig.port ?? 445;
        const user = encodeURIComponent(smbConfig.username);
        const pass = encodeURIComponent(smbConfig.password);
        const encodedPath = item.filePath.split('/').map((seg: string): string => {
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
      } else {
        // WebDAV 源：使用 WebDAVClient 构建完整认证 URL
        const protocol = config['protocol'] ?? 'http';
        const host = config['url'] ?? '';
        const port = config['port'] ?? (protocol === 'https' ? '443' : '80');
        const rootPath = (config['rootPath'] ?? '').replace(/\/$/, '');
        const baseUrl = protocol + '://' + host + ':' + port + rootPath;
        const webdavConfig: WebDAVConfig = {
          baseUrl,
          username: config['username'] ?? '',
          password: config['password'] ?? '',
          timeout: 30000,
        };
        const client = new WebDAVClient(webdavConfig);
        fullUrl = client.getFullUrl(item.filePath);
        const authHeader = client.getAuthHeaderPublic();
        httpHeader = authHeader.length > 0 ? { 'Authorization': authHeader } : {};
      }

      const param: PlayerPageParam = {
        videoId: item.id,
        url: fullUrl,
        httpHeader,
        title: this.getTitle(),
        durationHintMs: item.durationMs,
        seriesProviderId: '',
        seasonNumber: 0,
        episodeNumber: 0,
      };
      this.pageStack.pushPathByName(PlayerPage.PAGE_NAME, param);
    } catch {
      console.error('[MovieDetailPage] play() 构建播放 URL 失败');
    }
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

            // Thread 2：播放按钮（含续播进度）
            Column({ space: 8 }) {
              Button({ type: ButtonType.Normal }) {
                Row({ space: 8 }) {
                  Text('▶')
                    .fontSize(20)
                    .fontColor(Color.White)
                  Text(this.getPlayButtonText())
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

              // Thread 2：续播进度条
              if (this.hasProgress()) {
                Column({ space: 4 }) {
                  Progress({ value: this.getProgressPercent() * 100, total: 100, type: ProgressType.Linear })
                    .width(220)
                    .height(4)
                    .color('#2196F3')
                    .backgroundColor('rgba(255,255,255,0.2)')
                  Text('已观看 ' + Math.round(this.getProgressPercent() * 100).toString() + '%')
                    .fontSize(12)
                    .fontColor('#AAAAAA')
                }
                .alignItems(HorizontalAlign.Start)
              }
            }
            .alignItems(HorizontalAlign.Start)

            // Thread 3：导演信息
            if (this.getDirectors().length > 0) {
              Row({ space: 8 }) {
                Text('导演：')
                  .fontSize(15)
                  .fontColor('#AAAAAA')
                Text(this.getDirectors().join('、'))
                  .fontSize(15)
                  .fontColor('#CCCCCC')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }

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

            // Thread 3：演员列表（最多5人）
            if (this.getCast().length > 0) {
              Column({ space: 8 }) {
                Text('演员')
                  .fontSize(18)
                  .fontColor('#FFFFFF')
                  .fontWeight(FontWeight.Medium)
                Row({ space: 12 }) {
                  ForEach(this.getCast(), (person: CastPerson) => {
                    Column({ space: 4 }) {
                      Text(person.name)
                        .fontSize(13)
                        .fontColor('#CCCCCC')
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width(80)
                        .textAlign(TextAlign.Center)
                      if (person.character !== undefined && person.character.length > 0) {
                        Text(person.character)
                          .fontSize(11)
                          .fontColor('#888888')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width(80)
                          .textAlign(TextAlign.Center)
                      }
                    }
                    .width(80)
                  })
                }
              }
              .alignItems(HorizontalAlign.Start)
              .margin({ top: 8 })
            }
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
        this.loadAuxData(param);
      }
    })
    .hideTitleBar(true)
  }
}
