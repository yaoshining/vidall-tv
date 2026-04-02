import http from '@ohos.net.http';
import fs from '@ohos.file.fs';
import { AppPreferences, PrefKey } from '../../utils/AppPreferences';
import { MovieDetailPage } from './MovieDetailPage';
import { MediaItem } from '../../db/models/MediaEntity';

export interface CastDetailPageParam {
  personId: number;
  name: string;
}

interface TmdbSearchPersonResult {
  results?: TmdbPersonBrief[];
}

interface TmdbPersonBrief {
  id?: number;
  name?: string;
}

interface TmdbPersonDetail {
  id?: number;
  name?: string;
  biography?: string;
  birthday?: string;
  place_of_birth?: string;
  profile_path?: string;
  known_for_department?: string;
}

interface TmdbCreditItem {
  id?: number;
  title?: string;
  name?: string;
  media_type?: string;
  character?: string;
  job?: string;
  poster_path?: string;
  release_date?: string;
  first_air_date?: string;
  vote_average?: number;
}

interface CastCache {
  detail: TmdbPersonDetail;
  credits: TmdbCreditItem[];
}

interface TmdbCombinedCredits {
  cast?: TmdbCreditItem[];
  crew?: TmdbCreditItem[];
}

function tmdbImg(path: string | undefined, width: string): string {
  if (!path || path.length === 0) { return ''; }
  return 'https://image.tmdb.org/t/p/' + width + path;
}

function getYear(date: string | undefined): string {
  if (!date || date.length < 4) { return ''; }
  return date.substring(0, 4);
}

@ComponentV2
export struct CastDetailPage {
  static readonly PAGE_NAME: string = 'castDetail';

  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();

  @Local personId: number = 0;
  @Local displayName: string = '';
  @Local detail: TmdbPersonDetail | null = null;
  @Local credits: TmdbCreditItem[] = [];
  @Local loading: boolean = true;
  @Local bioExpanded: boolean = false;

  private getCacheDir(): string {
    return getContext().cacheDir + '/cast';
  }

  private getCachePath(): string {
    return this.getCacheDir() + '/' + this.personId.toString() + '.json';
  }

  private async loadData(): Promise<void> {
    // 若没有 personId，先通过名字搜索 TMDB
    if (this.personId === 0 && this.displayName.length > 0) {
      const apiKey = await AppPreferences.get(PrefKey.TMDB_API_KEY, '');
      if (apiKey.length > 0) {
        const searchReq = http.createHttp();
        try {
          const encodedName = encodeURIComponent(this.displayName);
          const searchRes = await searchReq.request(
            `https://api.themoviedb.org/3/search/person?api_key=${apiKey}&language=zh-CN&query=${encodedName}`,
            { method: http.RequestMethod.GET, connectTimeout: 5000, readTimeout: 10000 }
          );
          if (searchRes.responseCode === 200) {
            const searchData = JSON.parse(searchRes.result as string) as TmdbSearchPersonResult;
            if (searchData.results != null && searchData.results.length > 0) {
              const firstResult = searchData.results[0];
              if (firstResult.id != null) {
                this.personId = firstResult.id;
              }
            }
          }
        } finally {
          searchReq.destroy();
        }
      }
      // 若仍为 0 则无 TMDB 数据，直接退出
      if (this.personId === 0) {
        this.loading = false;
        return;
      }
    }

    const cachePath = this.getCachePath();
    // Thread 4: 同步 readTextSync → 异步 readText
    try {
      const text = await fs.readText(cachePath);
      const cached = JSON.parse(text) as CastCache;
      this.detail = cached.detail;
      this.credits = (cached.credits ?? []).slice(0, 20);
      this.loading = false;
      return;
    } catch (e) {
      // 缓存不存在或解析失败，走 API
    }

    const apiKey = await AppPreferences.get(PrefKey.TMDB_API_KEY, '');
    if (apiKey.length === 0) {
      this.loading = false;
      return;
    }

    const base = 'https://api.themoviedb.org/3';
    const lang = 'zh-CN';
    const pid = this.personId.toString();

    try {
      // Thread 3: req1 用 try/finally 保证 destroy()
      const req1 = http.createHttp();
      let d: TmdbPersonDetail = {};
      try {
        const res1 = await req1.request(
          `${base}/person/${pid}?api_key=${apiKey}&language=${lang}`,
          { method: http.RequestMethod.GET, connectTimeout: 5000, readTimeout: 10000 }
        );
        if (res1.responseCode === 200) {
          d = JSON.parse(res1.result as string) as TmdbPersonDetail;
        }
      } finally {
        req1.destroy();
      }
      this.detail = d;

      // Thread 3: req2 用 try/finally 保证 destroy()
      const req2 = http.createHttp();
      let cr: TmdbCombinedCredits = {};
      try {
        const res2 = await req2.request(
          `${base}/person/${pid}/combined_credits?api_key=${apiKey}&language=${lang}`,
          { method: http.RequestMethod.GET, connectTimeout: 5000, readTimeout: 10000 }
        );
        if (res2.responseCode === 200) {
          cr = JSON.parse(res2.result as string) as TmdbCombinedCredits;
        }
      } finally {
        req2.destroy();
      }
      const allCredits: TmdbCreditItem[] = [...(cr.cast ?? []), ...(cr.crew ?? [])];
      // 按 vote_average 降序，取前 20
      allCredits.sort((a, b) => (b.vote_average ?? 0) - (a.vote_average ?? 0));
      this.credits = allCredits.slice(0, 20);

      // Thread 4: 同步 mkdirSync/openSync/writeSync/closeSync → 异步版本
      try {
        try { await fs.mkdir(this.getCacheDir()); } catch (e) { /* 已存在 */ }
        const cache: CastCache = { detail: d, credits: this.credits };
        const cacheFile = await fs.open(this.getCachePath(), fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        await fs.write(cacheFile.fd, JSON.stringify(cache));
        await fs.close(cacheFile.fd);
      } catch (e) {
        // 缓存写入失败，忽略
      }
    } catch (e) {
      // API 请求失败，忽略
    }
    this.loading = false;
  }

  private getInitial(): string {
    const raw = this.detail?.name ?? this.displayName;
    // 防御性转换：displayName 在运行时可能为 null，String() 确保不会调用 null.charAt
    const n: string = (raw != null) ? String(raw) : '';
    if (n.length === 0) { return '?'; }
    return n[0].toUpperCase();
  }

  private getCreditsTitle(item: TmdbCreditItem): string {
    return item.title ?? item.name ?? '未知';
  }

  private getCreditsYear(item: TmdbCreditItem): string {
    return getYear(item.release_date ?? item.first_air_date);
  }

  private navigateToCredit(item: TmdbCreditItem): void {
    // TV 类型暂不支持跳转（SeriesDetailPage 需要 tvSeriesId，无法从 TMDB 直接构造）
    if (item.media_type === 'tv') { return; }
    const mediaItem: MediaItem = {
      id: 0,
      sourceId: 0,
      directoryPath: '',
      filePath: '',
      fileName: this.getCreditsTitle(item),
      scannedAt: 0,
      title: this.getCreditsTitle(item),
      provider: 'tmdb',
      providerId: item.id != null ? item.id.toString() : '',
      posterUrl: tmdbImg(item.poster_path, 'w342'),
      mediaType: 'movie',
    };
    this.pageStack.pushPathByName(MovieDetailPage.PAGE_NAME, mediaItem);
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 背景
        Column()
          .width('100%').height('100%')
          .backgroundColor('#111111')

        if (this.loading) {
          Column() {
            Text('加载中…').fontSize(16).fontColor('#888888')
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else {
          Scroll() {
            Column({ space: 0 }) {
              // Hero 区
              Row({ space: 24 }) {
                // 左：照片
                if (this.detail?.profile_path != null && this.detail.profile_path.length > 0) {
                  Image(tmdbImg(this.detail.profile_path, 'w185'))
                    .width(120).height(180)
                    .borderRadius(8)
                    .objectFit(ImageFit.Cover)
                } else {
                  Column() {
                    Text(this.getInitial())
                      .fontSize(48).fontColor(Color.White).fontWeight(FontWeight.Bold)
                  }
                  .width(120).height(180)
                  .backgroundColor('#333333').borderRadius(8)
                  .justifyContent(FlexAlign.Center)
                  .alignItems(HorizontalAlign.Center)
                }

                // 右：信息
                Column({ space: 8 }) {
                  Text(this.detail?.name ?? this.displayName)
                    .fontSize(28).fontColor(Color.White).fontWeight(FontWeight.Bold)
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })

                  if (this.detail?.known_for_department != null && this.detail.known_for_department.length > 0) {
                    Text(this.detail.known_for_department)
                      .fontSize(14).fontColor('#1B78F2')
                  }

                  if (this.detail?.birthday != null && this.detail.birthday.length > 0) {
                    Text('生日：' + this.detail.birthday)
                      .fontSize(13).fontColor('#AAAAAA')
                  }

                  if (this.detail?.place_of_birth != null && this.detail.place_of_birth.length > 0) {
                    Text('出生地：' + this.detail.place_of_birth)
                      .fontSize(13).fontColor('#AAAAAA')
                      .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding({ left: 40, right: 40, top: 80, bottom: 24 })
              .alignItems(VerticalAlign.Top)

              // Biography
              if (this.detail?.biography != null && this.detail.biography.length > 0) {
                Column({ space: 8 }) {
                  Text('简介')
                    .fontSize(16).fontColor('#CCCCCC').fontWeight(FontWeight.Bold)

                  Text(this.detail.biography)
                    .fontSize(14).fontColor('#AAAAAA').lineHeight(22)
                    .maxLines(this.bioExpanded ? 100 : 4)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  if (this.detail.biography.length > 200) {
                    Text(this.bioExpanded ? '收起' : '展开')
                      .fontSize(13).fontColor('#1B78F2')
                      .focusable(true)
                      .onClick(() => { this.bioExpanded = !this.bioExpanded; })
                  }
                }
                .width('100%')
                .padding({ left: 40, right: 40, bottom: 24 })
                .alignItems(HorizontalAlign.Start)
              }

              // 作品列表
              if (this.credits.length > 0) {
                Column({ space: 12 }) {
                  Text('参演作品')
                    .fontSize(16).fontColor('#CCCCCC').fontWeight(FontWeight.Bold)
                    .padding({ left: 40 })

                  Scroll() {
                    Row({ space: 12 }) {
                      ForEach(this.credits, (item: TmdbCreditItem) => {
                        Column({ space: 6 }) {
                          if (item.poster_path != null && item.poster_path.length > 0) {
                            Image(tmdbImg(item.poster_path, 'w185'))
                              .width(100).height(150)
                              .borderRadius(6).objectFit(ImageFit.Cover)
                          } else {
                            Column() {
                              Text('🎬').fontSize(24)
                            }
                            .width(100).height(150)
                            .backgroundColor('#222222').borderRadius(6)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                          }

                          Column() {
                            Text(this.getCreditsTitle(item))
                              .fontSize(12).fontColor('#CCCCCC')
                              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                              .width(100).textAlign(TextAlign.Center)
                          }
                          .width(100)
                          .height(36)
                          .justifyContent(FlexAlign.Start)

                          Text(this.getCreditsYear(item))
                            .fontSize(11).fontColor('#888888')

                          if ((item.character != null && item.character.length > 0) || (item.job != null && item.job.length > 0)) {
                            Text(item.character != null && item.character.length > 0 ? item.character : (item.job ?? ''))
                              .fontSize(11).fontColor('#666666')
                              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                              .width(100).textAlign(TextAlign.Center)
                          }
                        }
                        .focusable(true)
                        .onClick(() => { this.navigateToCredit(item); })
                      }, (item: TmdbCreditItem) => {
                        const k: string = (item.media_type ?? 'x') + '-' + (item.id != null ? item.id.toString() : '0') + '-' + (item.title ?? item.name ?? '');
                        return k;
                      })
                    }
                    .padding({ left: 40, right: 40 })
                  }
                  .scrollable(ScrollDirection.Horizontal)
                  .scrollBar(BarState.Off)
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding({ bottom: 40 })
              }
            }
          }
          .width('100%').height('100%')
          .scrollBar(BarState.Off)
        }
      }
      .width('100%').height('100%')
    }
    .onReady((context: NavDestinationContext) => {
      const p = context.pathInfo.param as CastDetailPageParam;
      this.personId = p.personId;
      this.displayName = p.name;
      this.loadData().catch(() => {});
    })
  }
}
