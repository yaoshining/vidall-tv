import { FileSource, SMBSourceConfig } from '../db/models/FileSourceEntity';
import { SMBClient } from '../lib/SMBClient';
import { FileSourceDatabase } from '../db/files/FileSourceDatabase';
import { FfprobeUtil } from './FfprobeUtil';
import { ScrapeClient, parseFileName, TvSeriesScrapeResult } from '../lib/ScrapeClient';
import { VideoEntity, ScrapeInfoEntity, MovieEntity, TvSeriesEntity, TvSeasonEntity, TvEpisodeEntity } from '../db/models/MediaEntity';
import { extractSeriesHintFromFilePath, formatMediaTypeClassificationSignals } from '../lib/MediaTypeClassifier';
import { ISourceAdapter, VideoFileInfo, VideoScrapeContext, ScanOptions, ScanMode } from './VideoScannerTypes';
import { createVideoScrapeContext, hasSeasonSiblingDirectory, isVideoFile, hasCompleteScrapeAssociation, shouldRepairIncompleteTvEpisode, extractEpisodeNumberFromWeakSemanticFileName, clearStaleScrapeAssociationsForOverwrite, classifyVideoScrapeTarget } from './VideoScannerHelpers';

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
    // 优先用 lastModified 比较；SMB 源 lastModifiedMs=0 时 lastModified 为 undefined，降级用文件大小
    if (existing.lastModified && info.lastModified) {
      return existing.lastModified === info.lastModified;
    }
    // lastModified 不可用（SMB 库未返回有效时间戳），用文件大小作为变化检测后备
    if (existing.fileSize !== undefined && info.fileSize !== undefined) {
      return existing.fileSize === info.fileSize;
    }
    return false;
  }

  async scan(directoryPath: string, options: ScanOptions): Promise<VideoFileInfo[]> {
    const rootPath = (directoryPath.trim().length === 0 || directoryPath.trim() === '/') ? '/' : directoryPath;
    console.info(`[VideoScanner][SMB] 开始扫描: ${rootPath} 最大深度: ${options.maxDepth}`);
    const results: VideoFileInfo[] = [];
    const processingTasks: Promise<void>[] = [];
    await this.scanDir(rootPath, rootPath, 0, options.maxDepth, options.mode, results, processingTasks);
    await Promise.allSettled(processingTasks);
    return results;
  }

  private async scanDir(
    rootPath: string,
    dirPath: string,
    currentDepth: number,
    maxDepth: number,
    mode: ScanMode,
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

    const childDirectoryNames: string[] = [];
    listResult.files.forEach((file) => {
      if (file.isDirectory) {
        childDirectoryNames.push(file.name);
      }
    });
    const videoScrapeContext = createVideoScrapeContext(
      rootPath,
      currentDepth,
      hasSeasonSiblingDirectory(childDirectoryNames)
    );

    for (const file of listResult.files) {
      if (file.isDirectory) {
        await this.scanDir(rootPath, file.path, currentDepth + 1, maxDepth, mode, results, processingTasks);
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
          wasProcessed: true,
          seasonSiblingDetected: videoScrapeContext.seasonSiblingDetected,
          seriesHint: videoScrapeContext.seriesHint
        };
        console.info(
          `[VideoScanner][SMB] 文件源=${this.fileSource.name} | 路径=${file.path} | 文件名=${file.name} | 大小=${file.size} bytes`
        );
        results.push(info);

        // 增量跳过：文件未变化则仅更新 updated_at，不重新处理
        if (mode === 'incremental') {
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
            // 文件未变化，但若从未成功刮削过，仍需补刮削
            if (existing?.id !== undefined && this.scrapeClient) {
              try {
                const existingScrape =
                  await FileSourceDatabase.getInstance().getScrapeInfoByVideoId(existing.id);
                if (!existingScrape) {
                  // #191 第三轮修复：如果无 scrape_info 但检测到季目录兄弟，应重新完整处理（分类+刮削）
                  if (videoScrapeContext.seasonSiblingDetected) {
                    console.info(
                      `[VideoScanner][SMB][INCREMENTAL] 文件未变化但无刮削记录且检测到季目录兄弟，` +
                      `重新处理: ${file.name}`
                    );
                    // 不 continue，继续执行后续的完整处理流程
                  } else {
                    console.info(
                      `[VideoScanner][SMB][INCREMENTAL] 文件未变化但无刮削记录，触发补刮削: ${file.name}`
                    );
                    const capturedVideoId = existing.id;
                    const capturedScrapeClientR = this.scrapeClient;
                    const capturedModeR = mode;
                    const retryTask: Promise<void> =
                      this.doScrapeOnly(capturedVideoId, file.name,
                        capturedScrapeClientR, capturedModeR, info).catch(() => {});
                    processingTasks.push(retryTask);
                    continue;
                  }
                } else if (!hasCompleteScrapeAssociation(existingScrape)) {
                  console.info(
                    `[VideoScanner][SMB][INCREMENTAL] 文件未变化但元数据关联缺失，触发补刮削: ${file.name}`
                  );
                  const capturedVideoId = existing.id;
                  const capturedScrapeClientR = this.scrapeClient;
                  const capturedModeR = mode;
                  const retryTask: Promise<void> =
                    this.doScrapeOnly(capturedVideoId, file.name,
                      capturedScrapeClientR, capturedModeR, info).catch(() => {});
                  processingTasks.push(retryTask);
                  continue;
                } else if (existingScrape.mediaType === 'unknown' && videoScrapeContext.seasonSiblingDetected) {
                  // #191 修复：文件之前分类为 unknown，但现在扫描上下文变化（检测到季目录兄弟），应重新处理
                  console.info(
                    `[VideoScanner][SMB][INCREMENTAL] 检测到扫描上下文变化（seasonSiblingDetected=true），` +
                    `重新处理之前的 unknown 文件: ${file.name}`
                  );
                  // 清理旧的 unknown scrape_info 记录，以便后续重新刮削
                  try {
                    await FileSourceDatabase.getInstance().clearScrapeInfoForVideo(existing.id);
                    console.info(`[VideoScanner][SMB][INCREMENTAL] 已清理旧 unknown 标记: ${file.name}`);
                  } catch {
                    console.warn(`[VideoScanner][SMB][INCREMENTAL] 清理旧 unknown 标记失败: ${file.name}`);
                  }
                  // 不 continue，继续执行后续的完整处理流程
                } else if (shouldRepairIncompleteTvEpisode(existingScrape, file.name)) {
                  // #191 第四轮修复：检测到 tv + title 非空但 episodeId 为空，且文件名可提取 episode number
                  console.info(
                    `[VideoScanner][SMB][INCREMENTAL] 检测到不完整的 TV 剧集关联（tv + title 但无 episodeId），` +
                    `重新处理: ${file.name} | title=${existingScrape.title}`
                  );
                  // 清理旧的不完整 scrape_info 记录，以便后续重新刮削
                  try {
                    await FileSourceDatabase.getInstance().clearScrapeInfoForVideo(existing.id);
                    console.info(`[VideoScanner][SMB][INCREMENTAL] 已清理不完整 TV 关联: ${file.name}`);
                  } catch {
                    console.warn(`[VideoScanner][SMB][INCREMENTAL] 清理不完整 TV 关联失败: ${file.name}`);
                  }
                  // 不 continue，继续执行后续的完整处理流程
                } else {
                  console.info(`[VideoScanner][SMB][INCREMENTAL] 跳过未变化文件: ${file.name}`);
                  continue;
                }
              } catch {
                // 查询失败，正常跳过
                console.info(`[VideoScanner][SMB][INCREMENTAL] 跳过未变化文件: ${file.name}`);
                continue;
              }
            } else {
              console.info(`[VideoScanner][SMB][INCREMENTAL] 跳过未变化文件: ${file.name}`);
              continue;
            }
          }
        }

        // 异步处理：媒体信息抓取 + 入库 + 刮削
        const capturedInfo = info;
        const capturedScrapeClient = this.scrapeClient;
        const capturedMode = mode;
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

          if (capturedScrapeClient) {
            await this.doScrapeOnly(videoId, capturedInfo.fileName,
              capturedScrapeClient, capturedMode, capturedInfo);
          }
        }).catch(() => {
          console.warn(`[VideoScanner][SMB][TASK] 未处理异常 fileName=${capturedInfo.fileName}`);
        });
        processingTasks.push(task);
      }
    }
  }

  private async doScrapeOnly(
    videoId: number,
    fileName: string,
    scrapeClient: ScrapeClient,
    mode: ScanMode,
    info: VideoFileInfo
  ): Promise<void> {
    try {
      const existing = await FileSourceDatabase.getInstance().getScrapeInfoByVideoId(videoId);
      if (mode === 'incremental') {
        if (hasCompleteScrapeAssociation(existing)) {
          console.info(`[VideoScanner][SMB][SCRAPE] incremental 元数据完整，跳过 fileName=${fileName}`);
          return;
        }
      } else if (mode === 'fix-missing') {
        // fix-missing: scrape_info 存在且 ID 已关联，且海报不为空，才跳过
        if (existing) {
          const isComplete = existing.mediaType === 'movie'
            ? existing.movieId !== undefined
            : existing.tvSeriesId !== undefined;
          if (isComplete) {
            let hasPoster = false;
            try {
              const sdb = FileSourceDatabase.getInstance();
              if (existing.mediaType === 'movie' && existing.movieId !== undefined) {
                const mov = await sdb.getMovieById(existing.movieId);
                hasPoster = !!(mov?.posterUrl);
              } else if (existing.tvSeriesId !== undefined) {
                const ser = await sdb.getTvSeriesById(existing.tvSeriesId);
                hasPoster = !!(ser?.posterUrl);
              }
            } catch {
              hasPoster = true;
            }
            if (hasPoster) {
              console.info(`[VideoScanner][SMB][SCRAPE] fix-missing 元数据完整，跳过 fileName=${fileName}`);
              info.scrapeSkipped = true;
              return;
            }
            console.info(`[VideoScanner][SMB][SCRAPE] fix-missing 海报缺失，重新刮削 fileName=${fileName}`);
          } else {
            console.info(`[VideoScanner][SMB][SCRAPE] fix-missing 元数据不完整（ID未关联），重新刮削 fileName=${fileName}`);
          }
        }
      }
      // overwrite: 不跳过，强制重新刮削（upsertScrapeInfo 已是 upsert）
    } catch {
      // 查询失败继续刮削
    }

    console.info(`[VideoScanner][SMB][SCRAPE] 开始刮削 fileName=${fileName}`);
    const db = FileSourceDatabase.getInstance();
    const classificationContext: VideoScrapeContext = {
      seasonSiblingDetected: info.seasonSiblingDetected
    };
    const classification = classifyVideoScrapeTarget(fileName, info.filePath, classificationContext);
    const extractedSeriesHint = extractSeriesHintFromFilePath(info.filePath);
    const seriesHint = extractedSeriesHint ?? info.seriesHint;
    if (classification.mediaType === 'unknown') {
      await clearStaleScrapeAssociationsForOverwrite(
        videoId,
        mode,
        fileName,
        '[VideoScanner][SMB][SCRAPE]',
        `unknown:${classification.reason ?? 'unknown'}`
      );
      // #191 修复：为 unknown 文件创建 scrape_info 记录，以便增量扫描时能检测上下文变化
      const unknownScrapeInfo: ScrapeInfoEntity = {
        videoId,
        provider: 'local',
        providerId: `unknown_${videoId}`,
        mediaType: 'unknown',
        title: fileName,
        scrapedAt: Date.now()
      };
      try {
        await db.upsertScrapeInfo(unknownScrapeInfo);
        console.info(
          `[VideoScanner][SMB][SCRAPE] 已标记弱语义文件 fileName=${fileName} reason=${classification.reason ?? 'unknown'} ` +
          `signals=${formatMediaTypeClassificationSignals(classification)}`
        );
      } catch {
        console.warn(`[VideoScanner][SMB][SCRAPE] 无法保存 unknown 标记 fileName=${fileName}`);
      }
      info.scrapeSkipped = true;
      return;
    }

    if (classification.mediaType === 'movie') {
      try {
        const movie = await scrapeClient.autoScrapeMovie(fileName);
        if (!movie) {
          await clearStaleScrapeAssociationsForOverwrite(
            videoId,
            mode,
            fileName,
            '[VideoScanner][SMB][SCRAPE]',
            'movie-scrape-empty'
          );
          console.warn(`[VideoScanner][SMB][SCRAPE] 电影刮削无结果 ${fileName}`);
          return;
        }
        let movieId: number;
        const existingMovie = await db.getMovieByProviderId(movie.provider, movie.providerId);
        if (existingMovie && existingMovie.id !== undefined) {
          movieId = existingMovie.id;
          console.info(`[VideoScanner][SMB][SCRAPE] 电影复用已有记录 movieId=${movieId} title="${movie.title}"`);
          const needsUpdate = (!existingMovie.posterUrl && movie.posterUrl) ||
            (!existingMovie.originCountryJson && movie.originCountryJson);
          if (needsUpdate) {
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
              originalLanguage: movie.originalLanguage,
              originCountryJson: movie.originCountryJson, rawJson: movie.rawJson,
              scrapedAt: Date.now()
            };
            await db.upsertMovie(updateEntity);
            console.info(`[VideoScanner][SMB][SCRAPE] 电影复用更新 posterUrl/originCountryJson movieId=${movieId}`);
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
            originalLanguage: movie.originalLanguage,
            originCountryJson: movie.originCountryJson, rawJson: movie.rawJson,
            scrapedAt: Date.now()
          };
          movieId = await db.upsertMovie(movieEntity);
        }
        const smScrapeInfo: ScrapeInfoEntity = {
          videoId, provider: movie.provider, providerId: movie.providerId,
          mediaType: 'movie', title: movie.title, originalTitle: movie.originalTitle,
          movieId, scrapedAt: Date.now()
        };
        await db.upsertScrapeInfo(smScrapeInfo);
        console.info(`[VideoScanner][SMB][SCRAPE] movie scrape_info 落库 videoId=${videoId} movieId=${movieId}`);
      } catch (e) {
        await clearStaleScrapeAssociationsForOverwrite(
          videoId,
          mode,
          fileName,
          '[VideoScanner][SMB][SCRAPE]',
          'movie-scrape-exception'
        );
        const err = e as Error;
        console.warn(`[VideoScanner][SMB][SCRAPE] 电影刮削异常 ${fileName}: ${err.message}`);
      }
    } else {
      try {
        // 只有无法解析标准季集标记时，才将弱语义集数按第一季兜底。
        const parsedFileName = parseFileName(fileName);
        const explicitEpisodeNum = parsedFileName.episodeNumber === undefined
          ? extractEpisodeNumberFromWeakSemanticFileName(fileName)
          : undefined;
        const explicitSeasonNum = explicitEpisodeNum !== undefined ? 1 : undefined;
        const result = await scrapeClient.autoScrapeTvEpisode(fileName, seriesHint, classification.mediaType, explicitEpisodeNum, explicitSeasonNum);
        if (!result.series) {
          await clearStaleScrapeAssociationsForOverwrite(
            videoId,
            mode,
            fileName,
            '[VideoScanner][SMB][SCRAPE]',
            'tv-scrape-empty'
          );
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
            originalLanguage: series.originalLanguage,
            originCountryJson: series.originCountryJson, rawJson: series.rawJson,
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
        const scrapeSeasonNumber = episode?.seasonNumber ?? season?.seasonNumber;
        const scrapeEpisodeNumber = episode?.episodeNumber;
        const tvScrapeInfo: ScrapeInfoEntity = {
          videoId, provider: series.provider,
          providerId: episodeId !== undefined ? (episode?.providerId ?? series.providerId) : series.providerId,
          mediaType, title: episode?.title ?? series.title,
          originalTitle: series.originalTitle,
          tvSeriesId: seriesId, episodeId,
          seasonNumber: scrapeSeasonNumber, episodeNumber: scrapeEpisodeNumber,
          scrapedAt: Date.now()
        };
        await db.upsertScrapeInfo(tvScrapeInfo);
        console.info(
          `[VideoScanner][SMB][SCRAPE] tv scrape_info 落库 videoId=${videoId} ` +
          `S${scrapeSeasonNumber ?? '?'}E${scrapeEpisodeNumber ?? '?'}`
        );
      } catch (e) {
        await clearStaleScrapeAssociationsForOverwrite(
          videoId,
          mode,
          fileName,
          '[VideoScanner][SMB][SCRAPE]',
          'tv-scrape-exception'
        );
        const err = e as Error;
        console.warn(`[VideoScanner][SMB][SCRAPE] 剧集刮削异常 ${fileName}: ${err.message}`);
      }
    }
  }
}
