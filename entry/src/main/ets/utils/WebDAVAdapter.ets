import { FileSource } from '../db/models/FileSourceEntity';
import { FileSourceDatabase } from '../db/files/FileSourceDatabase';
import { WebDAVClient, WebDAVConfig, WebDAVResource } from '../lib/WebDAVClient';
import { FfprobeUtil, FfprobeTrack } from './FfprobeUtil';
import { ScrapeClient, parseFileName, TvSeriesScrapeResult } from '../lib/ScrapeClient';
import { VideoEntity, ScrapeInfoEntity, MovieEntity, TvSeriesEntity, TvSeasonEntity, TvEpisodeEntity } from '../db/models/MediaEntity';
import { extractSeriesHintFromFilePath, formatMediaTypeClassificationSignals } from '../lib/MediaTypeClassifier';
import { ISourceAdapter, VideoFileInfo, VideoScrapeContext, ScanOptions, ScanMode } from './VideoScannerTypes';
import { createVideoScrapeContext, hasSeasonSiblingDirectory, isVideoFile, hasCompleteScrapeAssociation, shouldRepairIncompleteTvEpisode, extractEpisodeNumberFromWeakSemanticFileName, clearStaleScrapeAssociationsForOverwrite, classifyVideoScrapeTarget } from './VideoScannerHelpers';

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
    await this.scanDir(directoryPath, directoryPath, 0, options.maxDepth, options.mode, results, processingTasks);
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
    mode: ScanMode,
    results: VideoFileInfo[],
    processingTasks: Promise<void>[]
  ): Promise<void> {
    console.info(`[VideoScanner][WebDAV] 进入目录: ${currentPath}（相对配置目录深度 ${depth}/${maxDepth}）`);

    let resources: WebDAVResource[] = [];
    try {
      resources = await this.client.listDirectory(currentPath);
    } catch (err) {
      const errMsg = (err as Error).message ?? String(err);
      console.error(`[VideoScanner][ERROR] 列举目录失败: ${currentPath}，原因: ${errMsg}`);
      // 根目录（depth===0）失败时向上抛出，让调用方可以写 dir_status；子目录失败继续跳过
      if (depth === 0) {
        throw new Error(errMsg);
      }
      return;
    }

    const childDirectoryNames: string[] = [];
    resources.forEach((resource: WebDAVResource) => {
      if (resource.isCollection) {
        const decodedHref = this.decodePath(resource.href);
        const relativePath = this.toRelativePath(decodedHref);
        if (this.isSamePath(relativePath, currentPath)) {
          return;
        }
        childDirectoryNames.push(resource.displayName || this.extractFileName(decodedHref));
      }
    });
    const videoScrapeContext = createVideoScrapeContext(
      rootPath,
      depth,
      hasSeasonSiblingDirectory(childDirectoryNames)
    );

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
        await this.scanDir(rootPath, relativePath, depth + 1, maxDepth, mode, results, processingTasks);
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
            wasProcessed: true,
            seasonSiblingDetected: videoScrapeContext.seasonSiblingDetected,
            seriesHint: videoScrapeContext.seriesHint
          };

          console.info(
            `[VideoScanner][VIDEO] ` +
            `文件源=${this.fileSource.name} | 路径=${decodedHref} | 文件名=${fileName} | ` +
            `大小=${resource.size !== undefined ? resource.size + ' bytes' : '未知'} | ` +
            `修改时间=${resource.lastModified ?? '未知'} | 类型=${resource.contentType ?? '未知'}`
          );

          results.push(info);

          const existingVideo = (mode === 'incremental')
            ? await FileSourceDatabase.getInstance().getVideoByPath(relativePath)
            : null;
          if (mode === 'incremental' && this.canSkipIncrementalProcessing(existingVideo, info)) {
            info.wasProcessed = false;
            await FileSourceDatabase.getInstance().markVideoUpdatedByPath(relativePath);
            // 文件未变化，但若从未成功刮削过，仍需补刮削
            if (existingVideo?.id !== undefined && this.scrapeClient) {
              try {
                const existingScrape =
                  await FileSourceDatabase.getInstance().getScrapeInfoByVideoId(existingVideo.id);
                if (!existingScrape) {
                  // #191 第三轮修复：如果无 scrape_info 但检测到季目录兄弟，应重新完整处理（分类+刮削）
                  if (videoScrapeContext.seasonSiblingDetected) {
                    console.info(
                      `[VideoScanner][INCREMENTAL] 文件未变化但无刮削记录且检测到季目录兄弟，` +
                      `重新处理: ${fileName}`
                    );
                    // 不 continue，继续执行后续的完整处理流程
                  } else {
                    console.info(
                      `[VideoScanner][INCREMENTAL] 文件未变化但无刮削记录，触发补刮削: ${fileName}`
                    );
                    const capturedVideoId = existingVideo.id;
                    const capturedFileName = fileName;
                    const capturedDirPath = info.directoryPath;
                    const capturedScrapeClient = this.scrapeClient;
                    const capturedMode = mode;
                    const retryTask: Promise<void> =
                      this.doScrapeOnly(capturedVideoId, capturedFileName,
                        capturedScrapeClient, capturedMode, info).catch(() => {});
                    processingTasks.push(retryTask);
                    continue;
                  }
                } else if (!hasCompleteScrapeAssociation(existingScrape)) {
                  console.info(
                    `[VideoScanner][INCREMENTAL] 文件未变化但元数据关联缺失，触发补刮削: ${fileName}`
                  );
                  const capturedVideoId = existingVideo.id;
                  const capturedFileName = fileName;
                  const capturedScrapeClient = this.scrapeClient;
                  const capturedMode = mode;
                  const retryTask: Promise<void> =
                    this.doScrapeOnly(capturedVideoId, capturedFileName,
                      capturedScrapeClient, capturedMode, info).catch(() => {});
                  processingTasks.push(retryTask);
                  continue;
                } else if (existingScrape.mediaType === 'unknown' && videoScrapeContext.seasonSiblingDetected) {
                  // #191 修复：文件之前分类为 unknown，但现在扫描上下文变化（检测到季目录兄弟），应重新处理
                  console.info(
                    `[VideoScanner][INCREMENTAL] 检测到扫描上下文变化（seasonSiblingDetected=true），` +
                    `重新处理之前的 unknown 文件: ${fileName}`
                  );
                  // 清理旧的 unknown scrape_info 记录，以便后续重新刮削
                  try {
                    await FileSourceDatabase.getInstance().clearScrapeInfoForVideo(existingVideo.id);
                    console.info(`[VideoScanner][INCREMENTAL] 已清理旧 unknown 标记: ${fileName}`);
                  } catch {
                    console.warn(`[VideoScanner][INCREMENTAL] 清理旧 unknown 标记失败: ${fileName}`);
                  }
                  // 不 continue，继续执行后续的完整处理流程
                } else if (shouldRepairIncompleteTvEpisode(existingScrape, fileName)) {
                  // #191 第四轮修复：检测到 tv + title 非空但 episodeId 为空，且文件名可提取 episode number
                  console.info(
                    `[VideoScanner][INCREMENTAL] 检测到不完整的 TV 剧集关联（tv + title 但无 episodeId），` +
                    `重新处理: ${fileName} | title=${existingScrape.title}`
                  );
                  // 清理旧的不完整 scrape_info 记录，以便后续重新刮削
                  try {
                    await FileSourceDatabase.getInstance().clearScrapeInfoForVideo(existingVideo.id);
                    console.info(`[VideoScanner][INCREMENTAL] 已清理不完整 TV 关联: ${fileName}`);
                  } catch {
                    console.warn(`[VideoScanner][INCREMENTAL] 清理不完整 TV 关联失败: ${fileName}`);
                  }
                  // 不 continue，继续执行后续的完整处理流程
                } else {
                  console.info(
                    `[VideoScanner][INCREMENTAL] 跳过未变化文件: ${fileName} | ` +
                    `lastModified=${info.lastModified ?? '未知'}`
                  );
                  continue;
                }
              } catch {
                // 查询失败，按已有刮削记录处理，正常跳过
                console.info(
                  `[VideoScanner][INCREMENTAL] 跳过未变化文件: ${fileName} | ` +
                  `lastModified=${info.lastModified ?? '未知'}`
                );
                continue;
              }
            } else {
              console.info(
                `[VideoScanner][INCREMENTAL] 跳过未变化文件: ${fileName} | ` +
                `lastModified=${info.lastModified ?? '未知'}`
              );
              continue;
            }
          }

          // ── 落库 + 刮削：加入跟踪列表，确保 scan() 返回前所有视频已入库 ──
          const authHeader = this.client.getAuthHeaderPublic();
          const httpHeader: Record<string, string> = authHeader ? { 'Authorization': authHeader } : {};
          const fullUrl = this.client.getFullUrl(relativePath);
          const capturedInfo = info;
          const capturedScrapeClient = this.scrapeClient;
          const capturedMode = mode;

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

            if (capturedScrapeClient) {
              await this.doScrapeOnly(videoId, fileName,
                capturedScrapeClient, capturedMode, capturedInfo);
            }
          }).catch(() => {
            console.warn(`[VideoScanner][PROCESS] 视频处理异常 ${fileName}`);
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
          console.info(`[VideoScanner][SCRAPE] incremental 元数据完整，跳过 fileName=${fileName}`);
          return;
        }
      } else if (mode === 'fix-missing') {
        if (existing) {
          const isComplete = existing.mediaType === 'movie'
            ? existing.movieId !== undefined
            : existing.tvSeriesId !== undefined;
          if (isComplete) {
            let hasPoster = false;
            try {
              const db = FileSourceDatabase.getInstance();
              if (existing.mediaType === 'movie' && existing.movieId !== undefined) {
                const movie = await db.getMovieById(existing.movieId);
                hasPoster = !!(movie?.posterUrl);
              } else if (existing.tvSeriesId !== undefined) {
                const series = await db.getTvSeriesById(existing.tvSeriesId);
                hasPoster = !!(series?.posterUrl);
              }
            } catch {
              hasPoster = true;
            }
            if (hasPoster) {
              console.info(`[VideoScanner][SCRAPE] fix-missing 元数据完整，跳过 fileName=${fileName}`);
              info.scrapeSkipped = true;
              return;
            }
            console.info(`[VideoScanner][SCRAPE] fix-missing 海报缺失，重新刮削 fileName=${fileName}`);
          } else {
            console.info(`[VideoScanner][SCRAPE] fix-missing 元数据不完整（ID未关联），重新刮削 fileName=${fileName}`);
          }
        }
      }
    } catch {
      // 查询失败继续刮削
    }

    console.info(`[VideoScanner][SCRAPE] 开始刮削 fileName=${fileName}`);
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
        '[VideoScanner][SCRAPE]',
        `unknown:${classification.reason ?? 'unknown'}`
      );
      // #191 修复：为 unknown 文件创建 scrape_info 记录，以便增量扫描时能检测上下文变化
      const db = FileSourceDatabase.getInstance();
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
          `[VideoScanner][SCRAPE] 已标记弱语义文件 fileName=${fileName} reason=${classification.reason ?? 'unknown'} ` +
          `signals=${formatMediaTypeClassificationSignals(classification)}`
        );
      } catch {
        console.warn(`[VideoScanner][SCRAPE] 无法保存 unknown 标记 fileName=${fileName}`);
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
            '[VideoScanner][SCRAPE]',
            'movie-scrape-empty'
          );
          console.warn(`[VideoScanner][SCRAPE] 电影刮削无结果 ${fileName}`);
          return;
        }
        console.info(`[VideoScanner][SCRAPE] 电影刮削结果 title="${movie.title}" posterUrl=${movie.posterUrl ? movie.posterUrl.substring(0, 40) : 'null'} rating=${movie.rating ?? 'null'}`);
        const db = FileSourceDatabase.getInstance();
        let movieId: number;
        const existingMovie = await db.getMovieByProviderId(movie.provider, movie.providerId);
        if (existingMovie && existingMovie.id !== undefined) {
          movieId = existingMovie.id;
          console.info(`[VideoScanner][SCRAPE] 电影复用已有记录 movieId=${movieId} title="${movie.title}"`);
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
          console.info(`[VideoScanner][SCRAPE] 电影入库 movieId=${movieId} title="${movie.title}"`);
        }
        const movieScrapeInfo: ScrapeInfoEntity = {
          videoId, provider: movie.provider, providerId: movie.providerId,
          mediaType: 'movie', title: movie.title, originalTitle: movie.originalTitle,
          movieId, scrapedAt: Date.now()
        };
        await db.upsertScrapeInfo(movieScrapeInfo);
        console.info(`[VideoScanner][SCRAPE] scrape_info 落库 videoId=${videoId} movieId=${movieId}`);
      } catch (e) {
        await clearStaleScrapeAssociationsForOverwrite(
          videoId,
          mode,
          fileName,
          '[VideoScanner][SCRAPE]',
          'movie-scrape-exception'
        );
        const err = e as Error;
        console.warn(`[VideoScanner][SCRAPE] 电影刮削异常 ${fileName}: ${err.message}`);
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
            '[VideoScanner][SCRAPE]',
            'tv-scrape-empty'
          );
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
            originalLanguage: series.originalLanguage,
            originCountryJson: series.originCountryJson, rawJson: series.rawJson,
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
          `[VideoScanner][SCRAPE] tv scrape_info 落库 videoId=${videoId} ` +
          `S${scrapeSeasonNumber ?? '?'}E${scrapeEpisodeNumber ?? '?'}`
        );
      } catch (e) {
        await clearStaleScrapeAssociationsForOverwrite(
          videoId,
          mode,
          fileName,
          '[VideoScanner][SCRAPE]',
          'tv-scrape-exception'
        );
        const err = e as Error;
        console.warn(`[VideoScanner][SCRAPE] 剧集刮削异常 ${fileName}: ${err.message}`);
      }
    }
  }

  private canSkipIncrementalProcessing(existingVideo: VideoEntity | null, currentInfo: VideoFileInfo): boolean {
    if (!existingVideo) {
      return false;
    }
    // 优先用 lastModified 比较
    if (existingVideo.lastModified && currentInfo.lastModified) {
      return existingVideo.lastModified === currentInfo.lastModified;
    }
    // lastModified 不可用时（部分 WebDAV 服务器不返回 Last-Modified），用文件大小兜底
    if (existingVideo.fileSize !== undefined && currentInfo.fileSize !== undefined) {
      return existingVideo.fileSize === currentInfo.fileSize;
    }
    return false;
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
