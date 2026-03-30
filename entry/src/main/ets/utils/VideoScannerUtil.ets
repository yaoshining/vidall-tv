import { Context } from '@ohos.abilityAccessCtrl';
import { FileSource, FileSourceDirectory, FileSourceType, SMBSourceConfig } from '../db/models/FileSourceEntity';
import { SMBClient } from '../lib/SMBClient';
import { FileSourceDatabase } from '../db/files/FileSourceDatabase';
import { WebDAVClient, WebDAVConfig, WebDAVResource } from '../lib/WebDAVClient';
import { FfprobeUtil, FfprobeTrack } from './FfprobeUtil';
import { ScrapeClient, parseFileName, TvSeriesScrapeResult } from '../lib/ScrapeClient';
import { VideoEntity, ScrapeInfoEntity, MovieEntity, TvSeriesEntity, TvSeasonEntity, TvEpisodeEntity } from '../db/models/MediaEntity';

// ─────────────────────────────────────────────
// 数据结构
// ─────────────────────────────────────────────

/** 扫描到的单个视频文件信息 */
export interface VideoFileInfo {
  sourceId: number;
  sourceName: string;
  sourceType: FileSourceType;
  directoryPath: string;
  filePath: string;
  fileName: string;
  fileSize?: number;
  lastModified?: string;
  contentType?: string;
  wasProcessed?: boolean;
}

export interface SourceScanStat {
  sourceId: number;
  sourceName: string;
  sourceType: FileSourceType;
  directoriesScanned: number;
  videosFound: number;
}

export interface ScanResult {
  totalDirectories: number;
  totalVideos: number;
  processedVideos: number;
  skippedVideos: number;
  perSourceStats: SourceScanStat[];
  elapsedMs: number;
  videos: VideoFileInfo[];
}

export interface ScanOptions {
  maxDepth: number;
  incremental: boolean;
}

const DEFAULT_SCAN_OPTIONS: ScanOptions = { maxDepth: 5, incremental: false };

// ─────────────────────────────────────────────
// 视频扩展名白名单
// ─────────────────────────────────────────────

const VIDEO_EXTENSIONS: Set<string> = new Set([
  'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv',
  'ts', 'm2ts', 'mts', 'rmvb', 'rm', 'webm',
  'm4v', 'mpeg', 'mpg', '3gp', 'ogv', 'vob',
  'divx', 'xvid', 'hevc', 'h264', 'h265'
]);

function isVideoFile(fileName: string, contentType?: string): boolean {
  if (contentType && contentType.toLowerCase().startsWith('video/')) {
    return true;
  }
  const dotIndex = fileName.lastIndexOf('.');
  if (dotIndex !== -1) {
    const ext = fileName.substring(dotIndex + 1).toLowerCase();
    if (VIDEO_EXTENSIONS.has(ext)) {
      return true;
    }
  }
  return false;
}

// ─────────────────────────────────────────────
// 适配器接口
// ─────────────────────────────────────────────

export interface ISourceAdapter {
  scan(directoryPath: string, options: ScanOptions): Promise<VideoFileInfo[]>;
}

// ─────────────────────────────────────────────
// WebDAV 适配器
// ─────────────────────────────────────────────

export class WebDAVAdapter implements ISourceAdapter {
  private client: WebDAVClient;
  private fileSource: FileSource;
  private basePath: string;
  private scrapeClient?: ScrapeClient;

  constructor(fileSource: FileSource, scrapeClient?: ScrapeClient) {
    this.fileSource = fileSource;
    this.scrapeClient = scrapeClient;

    const config = JSON.parse(fileSource.configJson) as Record<string, string>;
    const protocol = config['protocol'] ?? 'http';
    const host = config['url'] ?? '';
    const port = config['port'] ?? (protocol === 'https' ? '443' : '80');
    const rootPath = config['rootPath'] ?? '';
    const normalizedRoot = rootPath && !rootPath.startsWith('/') ? '/' + rootPath : rootPath;
    this.basePath = normalizedRoot.replace(/\/$/, '');
    const baseUrl = `${protocol}://${host}:${port}${normalizedRoot}`;

    console.info(
      `[VideoScanner][WebDAV] 解析配置 — url="${host}" username="${config['username'] ?? ''}" rootPath="${normalizedRoot}"`
    );
    const webdavConfig: WebDAVConfig = {
      baseUrl: baseUrl,
      username: config['username'] ?? '',
      password: config['password'] ?? '',
      timeout: 30000,
      tlsCertPolicy: config['tlsCertPolicy'] === 'strict' ? 'strict' : 'allow_self_signed'
    };
    try {
      this.client = new WebDAVClient(webdavConfig);
      console.info(`[VideoScanner][WebDAV] WebDAVClient 构造成功`);
    } catch (err) {
      const msg = `WebDAVClient 构造失败: ${JSON.stringify(err)}`;
      console.error(`[VideoScanner][ERROR] ${msg}`);
      throw new Error(msg);
    }
  }

  async scan(directoryPath: string, options: ScanOptions): Promise<VideoFileInfo[]> {
    console.info(`[VideoScanner][WebDAV] 开始扫描目录: ${directoryPath} 最大深度: ${options.maxDepth}`);
    const results: VideoFileInfo[] = [];
    const processingTasks: Promise<void>[] = [];
    await this.scanDir(directoryPath, directoryPath, 0, options.maxDepth, options.incremental, results, processingTasks);
    // 等待所有 ffprobe + 视频入库任务完成，确保 scan() 返回时 DB 已有数据
    if (processingTasks.length > 0) {
      console.info(`[VideoScanner][WebDAV] 等待 ${processingTasks.length} 个视频处理任务完成...`);
      await Promise.all(processingTasks);
      console.info(`[VideoScanner][WebDAV] 所有视频处理任务完成`);
    }
    return results;
  }

  private async scanDir(
    rootPath: string,
    currentPath: string,
    depth: number,
    maxDepth: number,
    incremental: boolean,
    results: VideoFileInfo[],
    processingTasks: Promise<void>[]
  ): Promise<void> {
    console.info(`[VideoScanner][WebDAV] 进入目录: ${currentPath}（相对配置目录深度 ${depth}/${maxDepth}）`);

    let resources: WebDAVResource[] = [];
    try {
      resources = await this.client.listDirectory(currentPath);
    } catch (err) {
      console.error(`[VideoScanner][ERROR] 列举目录失败: ${currentPath}，原因: ${JSON.stringify(err)}`);
      return;
    }

    for (const resource of resources) {
      const decodedHref = this.decodePath(resource.href);
      const relativePath = this.toRelativePath(decodedHref);

      if (this.isSamePath(relativePath, currentPath)) {
        continue;
      }

      if (resource.isCollection) {
        if (depth >= maxDepth) {
          console.info(`[VideoScanner][MAX_DEPTH] 已达最大深度 ${maxDepth}，跳过子目录: ${relativePath}`);
          continue;
        }
        await this.scanDir(rootPath, relativePath, depth + 1, maxDepth, incremental, results, processingTasks);
      } else {
        const fileName = resource.displayName || this.extractFileName(decodedHref);
        if (isVideoFile(fileName, resource.contentType)) {
          const info: VideoFileInfo = {
            sourceId: this.fileSource.id ?? 0,
            sourceName: this.fileSource.name,
            sourceType: this.fileSource.type,
            directoryPath: rootPath,
            filePath: relativePath,
            fileName: fileName,
            fileSize: resource.size,
            lastModified: resource.lastModified,
            contentType: resource.contentType,
            wasProcessed: true
          };

          console.info(
            `[VideoScanner][VIDEO] ` +
            `文件源=${this.fileSource.name} | 路径=${decodedHref} | 文件名=${fileName} | ` +
            `大小=${resource.size !== undefined ? resource.size + ' bytes' : '未知'} | ` +
            `修改时间=${resource.lastModified ?? '未知'} | 类型=${resource.contentType ?? '未知'}`
          );

          results.push(info);

          const existingVideo = incremental
            ? await FileSourceDatabase.getInstance().getVideoByPath(relativePath)
            : null;
          if (incremental && this.canSkipIncrementalProcessing(existingVideo, info)) {
            info.wasProcessed = false;
            await FileSourceDatabase.getInstance().markVideoUpdatedByPath(relativePath);
            console.info(
              `[VideoScanner][INCREMENTAL] 跳过未变化文件: ${fileName} | ` +
              `lastModified=${info.lastModified ?? '未知'}`
            );
            continue;
          }

          // ── 落库 + 刮削：加入跟踪列表，确保 scan() 返回前所有视频已入库 ──
          const authHeader = this.client.getAuthHeaderPublic();
          const httpHeader: Record<string, string> = authHeader ? { 'Authorization': authHeader } : {};
          const fullUrl = this.client.getFullUrl(relativePath);
          const capturedInfo = info;
          const capturedScrapeClient = this.scrapeClient;

          const processingTask: Promise<void> = FfprobeUtil.probe(fullUrl, httpHeader).then(async (videoInfo) => {
            if (videoInfo.success) {
              const mainVideo = videoInfo.videoTracks.length > 0 ? videoInfo.videoTracks[0] : undefined;
              console.info(
                `[VideoScanner][MEDIA] ${fileName} | ` +
                `时长=${videoInfo.durationText} | ` +
                `分辨率=${mainVideo?.width ?? '?'}x${mainVideo?.height ?? '?'} | ` +
                `编码=${mainVideo?.codecName ?? '?'} | ` +
                `帧率=${mainVideo?.frameRate ?? '?'}fps | ` +
                `音轨=${videoInfo.audioTracks.length} 字幕轨=${videoInfo.subtitleTracks.length}`
              );
              videoInfo.audioTracks.forEach((t: FfprobeTrack, i: number) => {
                console.info(`[VideoScanner][MEDIA]   音轨[${i}] codec=${t.codecName} ${t.sampleRate ?? '?'}Hz ${t.channels ?? '?'}ch 语言=${t.language || '(未知)'}`);
              });
              videoInfo.subtitleTracks.forEach((t: FfprobeTrack, i: number) => {
                console.info(`[VideoScanner][MEDIA]   字幕轨[${i}] codec=${t.codecName} 语言=${t.language || '(未知)'}`);
              });
            } else {
              console.warn(`[VideoScanner][MEDIA] 媒体信息抓取失败: ${fileName} — ${videoInfo.errorMessage ?? ''}`);
            }

            const mainVideo = videoInfo.success && videoInfo.videoTracks.length > 0
              ? videoInfo.videoTracks[0] : undefined;

            // 落库
            const videoEntity: VideoEntity = {
              sourceId: capturedInfo.sourceId,
              directoryPath: capturedInfo.directoryPath,
              filePath: capturedInfo.filePath,
              fileName: capturedInfo.fileName,
              fileSize: capturedInfo.fileSize,
              lastModified: capturedInfo.lastModified,
              contentType: capturedInfo.contentType,
              durationMs: videoInfo.success ? videoInfo.durationMs : undefined,
              width: videoInfo.success ? mainVideo?.width : undefined,
              height: videoInfo.success ? mainVideo?.height : undefined,
              frameRate: videoInfo.success ? mainVideo?.frameRate : undefined,
              videoCodec: videoInfo.success ? mainVideo?.codecName : undefined,
              audioTracksJson: videoInfo.success ? JSON.stringify(videoInfo.audioTracks) : undefined,
              subtitleTracksJson: videoInfo.success ? JSON.stringify(videoInfo.subtitleTracks) : undefined,
              scannedAt: Date.now()
            };

            let videoId: number = -1;
            try {
              videoId = await FileSourceDatabase.getInstance().upsertVideo(videoEntity);
              console.info(`[VideoScanner][DB] 落库成功 videoId=${videoId} fileName=${fileName}`);
            } catch (dbErr) {
              console.warn(`[VideoScanner][DB] 落库失败 fileName=${fileName}: ${JSON.stringify(dbErr)}`);
              return;
            }

            // 刮削（已有记录跳过）
            if (!capturedScrapeClient) {
              return;
            }
            try {
              const existing = await FileSourceDatabase.getInstance().getScrapeInfoByVideoId(videoId);
              if (existing) {
                console.info(`[VideoScanner][SCRAPE] 已有刮削记录，跳过 fileName=${fileName}`);
                return;
              }
            } catch {
              // 查询失败继续
            }

            console.info(`[VideoScanner][SCRAPE] 开始刮削 fileName=${fileName}`);
            const parsed = parseFileName(fileName);

            if (parsed.mediaType === 'movie') {
              // ── 电影 ──────────────────────────────────────────
              try {
                const movie = await capturedScrapeClient.autoScrapeMovie(fileName);
                if (!movie) {
                  console.warn(`[VideoScanner][SCRAPE] 电影刮削无结果 ${fileName}`);
                  return;
                }
                console.info(`[VideoScanner][SCRAPE] 电影刮削结果 title="${movie.title}" posterUrl=${movie.posterUrl ? movie.posterUrl.substring(0, 40) : 'null'} rating=${movie.rating ?? 'null'}`);
                const db = FileSourceDatabase.getInstance();
                let movieId: number;
                const existingMovie = await db.getMovieByProviderId(movie.provider, movie.providerId);
                if (existingMovie && existingMovie.id !== undefined) {
                  movieId = existingMovie.id;
                  console.info(`[VideoScanner][SCRAPE] 电影复用已有记录 movieId=${movieId} title="${movie.title}" 已有posterUrl=${existingMovie.posterUrl ? 'Y' : 'null'}`);
                  if (!existingMovie.posterUrl && movie.posterUrl) {
                    const updateEntity: MovieEntity = {
                      id: existingMovie.id,
                      provider: movie.provider, providerId: movie.providerId,
                      title: movie.title, originalTitle: movie.originalTitle,
                      overview: movie.overview, releaseDate: movie.releaseDate,
                      rating: movie.rating, voteCount: movie.voteCount,
                      posterPath: movie.posterPath, backdropPath: movie.backdropPath,
                      posterUrl: movie.posterUrl, backdropUrl: movie.backdropUrl,
                      genresJson: movie.genresJson, castJson: movie.castJson,
                      directorsJson: movie.directorsJson, runtime: movie.runtime,
                      originalLanguage: movie.originalLanguage, rawJson: movie.rawJson,
                      scrapedAt: Date.now()
                    };
                    await db.upsertMovie(updateEntity);
                    console.info(`[VideoScanner][SCRAPE] 电影复用更新 posterUrl movieId=${movieId}`);
                  }
                } else {
                  const movieEntity: MovieEntity = {
                    provider: movie.provider, providerId: movie.providerId,
                    title: movie.title, originalTitle: movie.originalTitle,
                    overview: movie.overview, releaseDate: movie.releaseDate,
                    rating: movie.rating, voteCount: movie.voteCount,
                    posterPath: movie.posterPath, backdropPath: movie.backdropPath,
                    posterUrl: movie.posterUrl, backdropUrl: movie.backdropUrl,
                    genresJson: movie.genresJson, castJson: movie.castJson,
                    directorsJson: movie.directorsJson, runtime: movie.runtime,
                    originalLanguage: movie.originalLanguage, rawJson: movie.rawJson,
                    scrapedAt: Date.now()
                  };
                  movieId = await db.upsertMovie(movieEntity);
                  console.info(`[VideoScanner][SCRAPE] 电影入库 movieId=${movieId} title="${movie.title}"`);
                }
                const scrapeInfo: ScrapeInfoEntity = {
                  videoId, provider: movie.provider, providerId: movie.providerId,
                  mediaType: 'movie', title: movie.title, originalTitle: movie.originalTitle,
                  movieId, scrapedAt: Date.now()
                };
                await db.upsertScrapeInfo(scrapeInfo);
                console.info(`[VideoScanner][SCRAPE] scrape_info 落库 videoId=${videoId} movieId=${movieId}`);
              } catch (e) {
                const err = e as Error;
                console.warn(`[VideoScanner][SCRAPE] 电影刮削异常 ${fileName}: ${err.message}`);
              }
            } else {
              // ── 电视剧 ────────────────────────────────────────
              try {
                const result = await capturedScrapeClient.autoScrapeTvEpisode(fileName);
                if (!result.series) {
                  console.warn(`[VideoScanner][SCRAPE] 剧集刮削无结果 ${fileName}`);
                  return;
                }
                const db = FileSourceDatabase.getInstance();
                const series: TvSeriesScrapeResult = result.series;
                const season = result.season;
                const episode = result.episode;

                let seriesId: number;
                const existingSeries = await db.getTvSeriesByProviderId(series.provider, series.providerId);
                if (existingSeries && existingSeries.id !== undefined) {
                  seriesId = existingSeries.id;
                  console.info(`[VideoScanner][SCRAPE] 剧集复用已有记录 seriesId=${seriesId} title="${series.title}"`);
                } else {
                  const seriesEntity: TvSeriesEntity = {
                    provider: series.provider, providerId: series.providerId,
                    title: series.title, originalTitle: series.originalTitle,
                    overview: series.overview, firstAirDate: series.firstAirDate,
                    rating: series.rating, voteCount: series.voteCount,
                    posterPath: series.posterPath, backdropPath: series.backdropPath,
                    posterUrl: series.posterUrl, backdropUrl: series.backdropUrl,
                    genresJson: series.genresJson, castJson: series.castJson,
                    numberOfSeasons: series.numberOfSeasons,
                    originalLanguage: series.originalLanguage, rawJson: series.rawJson,
                    scrapedAt: Date.now()
                  };
                  seriesId = await db.upsertTvSeries(seriesEntity);
                  console.info(`[VideoScanner][SCRAPE] 剧集入库 seriesId=${seriesId} title="${series.title}"`);
                }

                let seasonId: number | undefined;
                if (season) {
                  const existingSeason = await db.getTvSeason(seriesId, season.seasonNumber);
                  if (existingSeason && existingSeason.id !== undefined) {
                    seasonId = existingSeason.id;
                  } else {
                    const seasonEntity: TvSeasonEntity = {
                      seriesId, provider: season.provider, providerId: season.providerId,
                      seasonNumber: season.seasonNumber, title: season.title,
                      overview: season.overview, airDate: season.airDate,
                      episodeCount: season.episodeCount, posterPath: season.posterPath,
                      posterUrl: season.posterUrl, rawJson: season.rawJson,
                      scrapedAt: Date.now()
                    };
                    seasonId = await db.upsertTvSeason(seasonEntity);
                  }
                }

                let episodeId: number | undefined;
                if (episode) {
                  const existingEp = await db.getTvEpisode(seriesId, episode.seasonNumber, episode.episodeNumber);
                  if (existingEp && existingEp.id !== undefined) {
                    episodeId = existingEp.id;
                  } else {
                    const epEntity: TvEpisodeEntity = {
                      seriesId, seasonId, provider: episode.provider, providerId: episode.providerId,
                      seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber,
                      title: episode.title, overview: episode.overview, airDate: episode.airDate,
                      runtime: episode.runtime, rating: episode.rating,
                      stillPath: episode.stillPath, stillUrl: episode.stillUrl,
                      rawJson: episode.rawJson, scrapedAt: Date.now()
                    };
                    episodeId = await db.upsertTvEpisode(epEntity);
                  }
                }

                const mediaType = episodeId !== undefined ? 'episode' : 'tv';
                const scrapeInfo: ScrapeInfoEntity = {
                  videoId, provider: series.provider,
                  providerId: episodeId !== undefined ? (episode?.providerId ?? series.providerId) : series.providerId,
                  mediaType, title: episode?.title ?? series.title,
                  originalTitle: series.originalTitle,
                  tvSeriesId: seriesId, episodeId,
                  seasonNumber: parsed.seasonNumber, episodeNumber: parsed.episodeNumber,
                  scrapedAt: Date.now()
                };
                await db.upsertScrapeInfo(scrapeInfo);
                console.info(`[VideoScanner][SCRAPE] tv scrape_info 落库 videoId=${videoId} S${parsed.seasonNumber ?? '?'}E${parsed.episodeNumber ?? '?'}`);
              } catch (e) {
                const err = e as Error;
                console.warn(`[VideoScanner][SCRAPE] 剧集刮削异常 ${fileName}: ${err.message}`);
              }
            }
          }).catch((e: Error) => {
            console.warn(`[VideoScanner][PROCESS] 视频处理异常 ${fileName}: ${e.message}`);
          });
          processingTasks.push(processingTask);
        }
      }
    }
  }

  private decodePath(href: string): string {
    try {
      return decodeURIComponent(href);
    } catch {
      return href;
    }
  }

  private canSkipIncrementalProcessing(existingVideo: VideoEntity | null, currentInfo: VideoFileInfo): boolean {
    if (!existingVideo) {
      return false;
    }
    if (!existingVideo.lastModified || !currentInfo.lastModified) {
      return false;
    }
    return existingVideo.lastModified === currentInfo.lastModified;
  }

  private toRelativePath(fullPath: string): string {
    if (this.basePath && fullPath.startsWith(this.basePath)) {
      const rel = fullPath.substring(this.basePath.length);
      return rel.startsWith('/') ? rel : '/' + rel;
    }
    return fullPath;
  }

  private isSamePath(a: string, b: string): boolean {
    return a.replace(/\/$/, '') === b.replace(/\/$/, '');
  }

  private extractFileName(path: string): string {
    const parts = path.replace(/\/$/, '').split('/');
    return parts[parts.length - 1] ?? path;
  }
}

// ─────────────────────────────────────────────
// SMB 适配器
// ─────────────────────────────────────────────

export class SMBAdapter implements ISourceAdapter {
  private client: SMBClient;
  private fileSource: FileSource;
  private config: SMBSourceConfig;
  private scrapeClient?: ScrapeClient;

  constructor(fileSource: FileSource, scrapeClient?: ScrapeClient) {
    this.fileSource = fileSource;
    this.config = JSON.parse(fileSource.configJson) as SMBSourceConfig;
    this.client = SMBClient.fromSourceConfig(this.config);
    this.scrapeClient = scrapeClient;
  }

  /** 构建完整 smb:// 播放 URL（凭据内嵌，路径段编码，用于 FFmpeg 播放与刮削） */
  private buildSmbUrl(filePath: string): string {
    const port = this.config.port ?? 445;
    const user = encodeURIComponent(this.config.username);
    const pass = encodeURIComponent(this.config.password);
    // filePath 形如 /Videos/TV Series/xxx/yyy.mkv，对每段路径做 URI 编码（保留斜杠）
    const encodedPath = filePath.split('/').map((seg: string): string => {
      if (seg.length === 0) { return ''; }
      let decoded: string = seg;
      try { decoded = decodeURIComponent(seg); } catch { decoded = seg; }
      return encodeURIComponent(decoded);
    }).join('/');
    return `smb://${user}:${pass}@${this.config.host}:${port}${encodedPath}`;
  }

  /** 日志脱敏：smb://user:pass@host → smb://***@host */
  private maskUrl(url: string): string {
    const atIdx = url.indexOf('@');
    if (atIdx < 0) {
      return url;
    }
    const protoEnd = url.indexOf('://');
    if (protoEnd < 0) {
      return url;
    }
    return `${url.substring(0, protoEnd + 3)}***${url.substring(atIdx)}`;
  }

  /** 增量跳过判断（对照 WebDAVAdapter.canSkipIncrementalProcessing） */
  private canSkip(existing: VideoEntity | null, info: VideoFileInfo): boolean {
    if (!existing) {
      return false;
    }
    if (!existing.lastModified || !info.lastModified) {
      return false;
    }
    return existing.lastModified === info.lastModified;
  }

  async scan(directoryPath: string, options: ScanOptions): Promise<VideoFileInfo[]> {
    const rootPath = (directoryPath.trim().length === 0 || directoryPath.trim() === '/') ? '/' : directoryPath;
    console.info(`[VideoScanner][SMB] 开始扫描: ${rootPath} 最大深度: ${options.maxDepth}`);
    const results: VideoFileInfo[] = [];
    const processingTasks: Promise<void>[] = [];
    await this.scanDir(rootPath, rootPath, 0, options.maxDepth, options.incremental, results, processingTasks);
    await Promise.allSettled(processingTasks);
    return results;
  }

  private async scanDir(
    rootPath: string,
    dirPath: string,
    currentDepth: number,
    maxDepth: number,
    incremental: boolean,
    results: VideoFileInfo[],
    processingTasks: Promise<void>[]
  ): Promise<void> {
    if (currentDepth > maxDepth) {
      return;
    }

    const listResult = await this.client.listDirectory(dirPath);

    if (listResult.error) {
      console.warn(`[SMBAdapter] 跳过目录: ${listResult.error} (path=${dirPath})`);
      return;
    }

    for (const file of listResult.files) {
      if (file.isDirectory) {
        await this.scanDir(rootPath, file.path, currentDepth + 1, maxDepth, incremental, results, processingTasks);
      } else if (isVideoFile(file.name)) {
        const info: VideoFileInfo = {
          sourceId: this.fileSource.id ?? 0,
          sourceName: this.fileSource.name,
          sourceType: this.fileSource.type,
          directoryPath: rootPath,
          filePath: file.path,
          fileName: file.name,
          fileSize: file.size,
          lastModified: file.lastModifiedMs > 0 ? new Date(file.lastModifiedMs).toISOString() : undefined,
          wasProcessed: true
        };
        console.info(
          `[VideoScanner][SMB] 文件源=${this.fileSource.name} | 路径=${file.path} | 文件名=${file.name} | 大小=${file.size} bytes`
        );
        results.push(info);

        // 增量跳过：文件未变化则仅更新 updated_at，不重新处理
        if (incremental) {
          let existing: VideoEntity | null = null;
          try {
            existing = await FileSourceDatabase.getInstance().getVideoByPath(file.path);
          } catch {
            // 查询失败视为新文件
          }
          if (this.canSkip(existing, info)) {
            info.wasProcessed = false;
            try {
              await FileSourceDatabase.getInstance().markVideoUpdatedByPath(file.path);
            } catch {
              // 标记失败不阻断扫描
            }
            console.info(`[VideoScanner][SMB][INCREMENTAL] 跳过未变化文件: ${file.name}`);
            continue;
          }
        }

        // 异步处理：媒体信息抓取 + 入库 + 刮削
        const capturedInfo = info;
        const capturedScrapeClient = this.scrapeClient;
        const smbUrl = this.buildSmbUrl(file.path);
        const maskedUrl = this.maskUrl(smbUrl);

        const task: Promise<void> = FfprobeUtil.probe(smbUrl).then(async (videoInfo) => {
          if (videoInfo.success) {
            const mainVideo = videoInfo.videoTracks.length > 0 ? videoInfo.videoTracks[0] : undefined;
            console.info(
              `[VideoScanner][SMB][MEDIA] ${capturedInfo.fileName} | ` +
              `时长=${videoInfo.durationText} | ` +
              `分辨率=${mainVideo?.width ?? '?'}x${mainVideo?.height ?? '?'} | ` +
              `编码=${mainVideo?.codecName ?? '?'}`
            );
          } else {
            console.warn(`[VideoScanner][SMB][MEDIA] 媒体信息抓取失败（将无媒体元数据入库）: ${capturedInfo.fileName} — ${videoInfo.errorMessage ?? ''}`);
          }

          const mainVideo = videoInfo.success && videoInfo.videoTracks.length > 0
            ? videoInfo.videoTracks[0] : undefined;

          const videoEntity: VideoEntity = {
            sourceId: capturedInfo.sourceId,
            directoryPath: capturedInfo.directoryPath,
            filePath: capturedInfo.filePath,
            fileName: capturedInfo.fileName,
            fileSize: capturedInfo.fileSize,
            lastModified: capturedInfo.lastModified,
            contentType: undefined,
            durationMs: videoInfo.success ? videoInfo.durationMs : undefined,
            width: videoInfo.success ? mainVideo?.width : undefined,
            height: videoInfo.success ? mainVideo?.height : undefined,
            frameRate: videoInfo.success ? mainVideo?.frameRate : undefined,
            videoCodec: videoInfo.success ? mainVideo?.codecName : undefined,
            audioTracksJson: videoInfo.success ? JSON.stringify(videoInfo.audioTracks) : undefined,
            subtitleTracksJson: videoInfo.success ? JSON.stringify(videoInfo.subtitleTracks) : undefined,
            scannedAt: Date.now()
          };

          let videoId: number = -1;
          try {
            videoId = await FileSourceDatabase.getInstance().upsertVideo(videoEntity);
            console.info(`[VideoScanner][SMB][DB] 落库成功 videoId=${videoId} fileName=${capturedInfo.fileName} url=${maskedUrl}`);
          } catch (dbErr) {
            console.warn(`[VideoScanner][SMB][DB] 落库失败 fileName=${capturedInfo.fileName}: ${JSON.stringify(dbErr)}`);
            return;
          }

          if (!capturedScrapeClient) {
            return;
          }
          try {
            const existing = await FileSourceDatabase.getInstance().getScrapeInfoByVideoId(videoId);
            if (existing) {
              console.info(`[VideoScanner][SMB][SCRAPE] 已有刮削记录，跳过 fileName=${capturedInfo.fileName}`);
              return;
            }
          } catch {
            // 查询失败继续刮削
          }

          console.info(`[VideoScanner][SMB][SCRAPE] 开始刮削 fileName=${capturedInfo.fileName}`);
          const parsed = parseFileName(capturedInfo.fileName);
          const fileName = capturedInfo.fileName;
          const db = FileSourceDatabase.getInstance();

          if (parsed.mediaType === 'movie') {
            try {
              const movie = await capturedScrapeClient.autoScrapeMovie(fileName);
              if (!movie) {
                console.warn(`[VideoScanner][SMB][SCRAPE] 电影刮削无结果 ${fileName}`);
                return;
              }
              let movieId: number;
              const existingMovie = await db.getMovieByProviderId(movie.provider, movie.providerId);
              if (existingMovie && existingMovie.id !== undefined) {
                movieId = existingMovie.id;
              } else {
                const movieEntity: MovieEntity = {
                  provider: movie.provider, providerId: movie.providerId,
                  title: movie.title, originalTitle: movie.originalTitle,
                  overview: movie.overview, releaseDate: movie.releaseDate,
                  rating: movie.rating, voteCount: movie.voteCount,
                  posterPath: movie.posterPath, backdropPath: movie.backdropPath,
                  posterUrl: movie.posterUrl, backdropUrl: movie.backdropUrl,
                  genresJson: movie.genresJson, castJson: movie.castJson,
                  directorsJson: movie.directorsJson, runtime: movie.runtime,
                  originalLanguage: movie.originalLanguage, rawJson: movie.rawJson,
                  scrapedAt: Date.now()
                };
                movieId = await db.upsertMovie(movieEntity);
              }
              const scrapeInfo: ScrapeInfoEntity = {
                videoId, provider: movie.provider, providerId: movie.providerId,
                mediaType: 'movie', title: movie.title, originalTitle: movie.originalTitle,
                movieId, scrapedAt: Date.now()
              };
              await db.upsertScrapeInfo(scrapeInfo);
              console.info(`[VideoScanner][SMB][SCRAPE] movie scrape_info 落库 videoId=${videoId} movieId=${movieId}`);
            } catch (e) {
              const err = e as Error;
              console.warn(`[VideoScanner][SMB][SCRAPE] 电影刮削异常 ${fileName}: ${err.message}`);
            }
          } else {
            try {
              const result = await capturedScrapeClient.autoScrapeTvEpisode(fileName);
              if (!result.series) {
                console.warn(`[VideoScanner][SMB][SCRAPE] 剧集刮削无结果 ${fileName}`);
                return;
              }
              const series: TvSeriesScrapeResult = result.series;
              const season = result.season;
              const episode = result.episode;

              let seriesId: number;
              const existingSeries = await db.getTvSeriesByProviderId(series.provider, series.providerId);
              if (existingSeries && existingSeries.id !== undefined) {
                seriesId = existingSeries.id;
              } else {
                const seriesEntity: TvSeriesEntity = {
                  provider: series.provider, providerId: series.providerId,
                  title: series.title, originalTitle: series.originalTitle,
                  overview: series.overview, firstAirDate: series.firstAirDate,
                  rating: series.rating, voteCount: series.voteCount,
                  posterPath: series.posterPath, backdropPath: series.backdropPath,
                  posterUrl: series.posterUrl, backdropUrl: series.backdropUrl,
                  genresJson: series.genresJson, castJson: series.castJson,
                  numberOfSeasons: series.numberOfSeasons,
                  originalLanguage: series.originalLanguage, rawJson: series.rawJson,
                  scrapedAt: Date.now()
                };
                seriesId = await db.upsertTvSeries(seriesEntity);
              }

              let seasonId: number | undefined;
              if (season) {
                const existingSeason = await db.getTvSeason(seriesId, season.seasonNumber);
                if (existingSeason && existingSeason.id !== undefined) {
                  seasonId = existingSeason.id;
                } else {
                  const seasonEntity: TvSeasonEntity = {
                    seriesId, provider: season.provider, providerId: season.providerId,
                    seasonNumber: season.seasonNumber, title: season.title,
                    overview: season.overview, airDate: season.airDate,
                    episodeCount: season.episodeCount, posterPath: season.posterPath,
                    posterUrl: season.posterUrl, rawJson: season.rawJson,
                    scrapedAt: Date.now()
                  };
                  seasonId = await db.upsertTvSeason(seasonEntity);
                }
              }

              let episodeId: number | undefined;
              if (episode) {
                const existingEp = await db.getTvEpisode(seriesId, episode.seasonNumber, episode.episodeNumber);
                if (existingEp && existingEp.id !== undefined) {
                  episodeId = existingEp.id;
                } else {
                  const epEntity: TvEpisodeEntity = {
                    seriesId, seasonId, provider: episode.provider, providerId: episode.providerId,
                    seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber,
                    title: episode.title, overview: episode.overview, airDate: episode.airDate,
                    runtime: episode.runtime, rating: episode.rating,
                    stillPath: episode.stillPath, stillUrl: episode.stillUrl,
                    rawJson: episode.rawJson, scrapedAt: Date.now()
                  };
                  episodeId = await db.upsertTvEpisode(epEntity);
                }
              }

              const mediaType = episodeId !== undefined ? 'episode' : 'tv';
              const scrapeInfo: ScrapeInfoEntity = {
                videoId, provider: series.provider,
                providerId: episodeId !== undefined ? (episode?.providerId ?? series.providerId) : series.providerId,
                mediaType, title: episode?.title ?? series.title,
                originalTitle: series.originalTitle,
                tvSeriesId: seriesId, episodeId,
                seasonNumber: parsed.seasonNumber, episodeNumber: parsed.episodeNumber,
                scrapedAt: Date.now()
              };
              await db.upsertScrapeInfo(scrapeInfo);
              console.info(
                `[VideoScanner][SMB][SCRAPE] tv scrape_info 落库 videoId=${videoId} S${parsed.seasonNumber ?? '?'}E${parsed.episodeNumber ?? '?'}`
              );
            } catch (e) {
              const err = e as Error;
              console.warn(`[VideoScanner][SMB][SCRAPE] 剧集刮削异常 ${fileName}: ${err.message}`);
            }
          }
        });
        processingTasks.push(task);
      }
    }
  }
}

// ─────────────────────────────────────────────
// 不支持协议占位适配器
// ─────────────────────────────────────────────

export class UnsupportedAdapter implements ISourceAdapter {
  private sourceType: FileSourceType;
  private sourceName: string;

  constructor(sourceName: string, sourceType: FileSourceType) {
    this.sourceName = sourceName;
    this.sourceType = sourceType;
  }

  async scan(directoryPath: string, _options: ScanOptions): Promise<VideoFileInfo[]> {
    console.warn(
      `[VideoScanner][SKIP] 协议 "${this.sourceType}" 暂不支持，` +
      `文件源="${this.sourceName}"，目录="${directoryPath}"，跳过。`
    );
    return [];
  }
}

// ─────────────────────────────────────────────
// 适配器工厂
// ─────────────────────────────────────────────

function createAdapter(fileSource: FileSource, scrapeClient?: ScrapeClient): ISourceAdapter {
  switch (fileSource.type) {
    case FileSourceType.WEBDAV:
      return new WebDAVAdapter(fileSource, scrapeClient);
    case FileSourceType.SMB:
      return new SMBAdapter(fileSource, scrapeClient);
    default:
      return new UnsupportedAdapter(fileSource.name, fileSource.type);
  }
}

// ─────────────────────────────────────────────
// 核心扫描工具类
// ─────────────────────────────────────────────

export class VideoScannerUtil {
  /**
   * 扫描所有已配置文件源中的视频文件
   * @param context       鸿蒙 Context
   * @param scrapeClient  刮削客户端（可选，不传则跳过刮削）
   * @param options       扫描选项（可选，默认 maxDepth=5）
   */
  static async scan(context: Context, scrapeClient?: ScrapeClient, options?: Partial<ScanOptions>): Promise<ScanResult> {
    const scanOptions: ScanOptions = {
      maxDepth: (options?.maxDepth !== undefined) ? options.maxDepth : DEFAULT_SCAN_OPTIONS.maxDepth,
      incremental: (options?.incremental !== undefined) ? options.incremental : DEFAULT_SCAN_OPTIONS.incremental
    };

    const startTime = Date.now();
    console.info(`[VideoScanner] ======== 开始视频扫描 ========`);
    console.info(
      `[VideoScanner] 扫描参数: maxDepth=${scanOptions.maxDepth}, 增量=${scanOptions.incremental ? '是' : '否'}, 刮削=${scrapeClient ? '开启' : '关闭'}`
    );

    const db = FileSourceDatabase.getInstance(context);
    await db.init();
    await db.resetVideoUpdatedFlags();

    const fileSources = await db.getAllFileSources();
    console.info(`[VideoScanner] 共找到 ${fileSources.length} 个文件源`);

    const seenPaths = new Set<string>();
    const allVideos: VideoFileInfo[] = [];
    const perSourceStats: SourceScanStat[] = [];
    let totalDirectories = 0;

    for (const fileSource of fileSources) {
      if (!fileSource.id) {
        continue;
      }

      console.info(`[VideoScanner] ──── 文件源: "${fileSource.name}" (${fileSource.type}) ────`);

      let directories: FileSourceDirectory[] = [];
      try {
        directories = await db.getDirectoriesBySourceId(fileSource.id);
      } catch (err) {
        console.error(`[VideoScanner][ERROR] 读取文件源 "${fileSource.name}" 目录失败: ${JSON.stringify(err)}`);
        continue;
      }

      console.info(`[VideoScanner] 文件源 "${fileSource.name}" 配置了 ${directories.length} 个目录`);

      let adapter: ISourceAdapter;
      try {
        console.info(`[VideoScanner] 正在创建适配器，协议=${fileSource.type}`);
        adapter = createAdapter(fileSource, scrapeClient);
        console.info(`[VideoScanner] 适配器创建成功`);
      } catch (err) {
        console.error(`[VideoScanner][ERROR] 创建适配器失败: ${JSON.stringify(err)}`);
        continue;
      }

      const stat: SourceScanStat = {
        sourceId: fileSource.id,
        sourceName: fileSource.name,
        sourceType: fileSource.type,
        directoriesScanned: 0,
        videosFound: 0
      };

      for (const dir of directories) {
        totalDirectories++;
        stat.directoriesScanned++;
        console.info(`[VideoScanner] 准备扫描目录(${stat.directoriesScanned}/${directories.length}): ${dir.directoryPath}`);

        let found: VideoFileInfo[] = [];
        try {
          found = await adapter.scan(dir.directoryPath, scanOptions);
          console.info(`[VideoScanner] 目录 "${dir.directoryPath}" 扫描完毕，找到 ${found.length} 个视频`);
        } catch (err) {
          console.error(`[VideoScanner][ERROR] 扫描目录 "${dir.directoryPath}" 异常: ${JSON.stringify(err)}`);
          continue;
        }

        for (const video of found) {
          if (!seenPaths.has(video.filePath)) {
            seenPaths.add(video.filePath);
            allVideos.push(video);
            stat.videosFound++;
          } else {
            console.info(`[VideoScanner] 重复路径，已跳过: ${video.filePath}`);
          }
        }
      }

      perSourceStats.push(stat);
      console.info(`[VideoScanner] 文件源 "${fileSource.name}" 完成，视频=${stat.videosFound} 目录=${stat.directoriesScanned}`);
    }

    const elapsedMs = Date.now() - startTime;
    const processedVideos = allVideos.filter((video: VideoFileInfo) => video.wasProcessed !== false).length;
    const skippedVideos = allVideos.length - processedVideos;
    console.info(`[VideoScanner] ======== 扫描完成 ========`);
    console.info(`[VideoScanner][STATS] 总耗时: ${elapsedMs} ms`);
    console.info(`[VideoScanner][STATS] 扫描目录总数: ${totalDirectories}`);
    console.info(`[VideoScanner][STATS] 发现视频总数（去重后）: ${allVideos.length}`);
    console.info(`[VideoScanner][STATS] 本轮处理视频数: ${processedVideos}`);
    console.info(`[VideoScanner][STATS] 本轮跳过未变化视频数: ${skippedVideos}`);
    for (const stat of perSourceStats) {
      console.info(
        `[VideoScanner][STATS] 文件源="${stat.sourceName}" (${stat.sourceType}) | ` +
        `目录数=${stat.directoriesScanned} | 视频数=${stat.videosFound}`
      );
    }
    console.info(`[VideoScanner] ===========================`);

    return {
      totalDirectories,
      totalVideos: allVideos.length,
      processedVideos,
      skippedVideos,
      perSourceStats,
      elapsedMs,
      videos: allVideos
    };
  }
}
