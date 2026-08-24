import { FileSourceDatabase } from '../db/files/FileSourceDatabase';
import { ScrapeClient, parseFileName, TvSeriesScrapeResult } from '../lib/ScrapeClient';
import { ScrapeInfoEntity, MovieEntity, TvSeriesEntity, TvSeasonEntity, TvEpisodeEntity } from '../db/models/MediaEntity';
import { extractSeriesHintFromFilePath, formatMediaTypeClassificationSignals, extractSeasonNumberFromDirectoryName } from '../lib/MediaTypeClassifier';
import { VideoFileInfo, VideoScrapeContext, ScanMode } from './VideoScannerTypes';
import { classifyVideoScrapeTarget, hasCompleteScrapeAssociation, extractEpisodeNumberFromWeakSemanticFileName, clearStaleScrapeAssociationsForOverwrite } from './VideoScannerHelpers';

function extractParentDirectoryName(filePath: string): string | undefined {
  const normalizedPath = filePath.replace(/\\/g, '/').replace(/\/+$/g, '');
  const segments = normalizedPath.split('/').filter((segment: string) => segment.length > 0);
  // segments[last] = 文件名, segments[last-1] = 父目录名
  if (segments.length < 2) {
    return undefined;
  }
  return segments[segments.length - 2];
}

/**
 * 对单个视频执行「分类 → 刮削 → 入库 → 写 scrape_info」。
 *
 * WebDAV 与 SMB 适配器共用，仅日志前缀不同（由 logPrefix 传入）。
 * 功能逻辑与刮削决策完全一致，日志输出为两适配器原实现的并集。
 */
export async function processVideoScrape(
  videoId: number,
  fileName: string,
  scrapeClient: ScrapeClient,
  mode: ScanMode,
  info: VideoFileInfo,
  logPrefix: string
): Promise<void> {
  const db = FileSourceDatabase.getInstance();
  try {
    const existing = await db.getScrapeInfoByVideoId(videoId);
    if (mode === 'incremental') {
      if (hasCompleteScrapeAssociation(existing)) {
        console.info(`${logPrefix} incremental 元数据完整，跳过 fileName=${fileName}`);
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
            console.info(`${logPrefix} fix-missing 元数据完整，跳过 fileName=${fileName}`);
            info.scrapeSkipped = true;
            return;
          }
          console.info(`${logPrefix} fix-missing 海报缺失，重新刮削 fileName=${fileName}`);
        } else {
          console.info(`${logPrefix} fix-missing 元数据不完整（ID未关联），重新刮削 fileName=${fileName}`);
        }
      }
    }
    // overwrite: 不跳过，强制重新刮削（upsertScrapeInfo 已是 upsert）
  } catch {
    // 查询失败继续刮削
  }

  console.info(`${logPrefix} 开始刮削 fileName=${fileName}`);
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
      logPrefix,
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
        `${logPrefix} 已标记弱语义文件 fileName=${fileName} reason=${classification.reason ?? 'unknown'} ` +
        `signals=${formatMediaTypeClassificationSignals(classification)}`
      );
    } catch {
      console.warn(`${logPrefix} 无法保存 unknown 标记 fileName=${fileName}`);
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
          logPrefix,
          'movie-scrape-empty'
        );
        console.warn(`${logPrefix} 电影刮削无结果 ${fileName}`);
        return;
      }
      console.info(`${logPrefix} 电影刮削结果 title="${movie.title}" posterUrl=${movie.posterUrl ? movie.posterUrl.substring(0, 40) : 'null'} rating=${movie.rating ?? 'null'}`);
      let movieId: number;
      const existingMovie = await db.getMovieByProviderId(movie.provider, movie.providerId);
      if (existingMovie && existingMovie.id !== undefined) {
        movieId = existingMovie.id;
        console.info(`${logPrefix} 电影复用已有记录 movieId=${movieId} title="${movie.title}"`);
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
          console.info(`${logPrefix} 电影复用更新 posterUrl/originCountryJson movieId=${movieId}`);
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
        console.info(`${logPrefix} 电影入库 movieId=${movieId} title="${movie.title}"`);
      }
      const movieScrapeInfo: ScrapeInfoEntity = {
        videoId, provider: movie.provider, providerId: movie.providerId,
        mediaType: 'movie', title: movie.title, originalTitle: movie.originalTitle,
        movieId, scrapedAt: Date.now()
      };
      await db.upsertScrapeInfo(movieScrapeInfo);
      console.info(`${logPrefix} movie scrape_info 落库 videoId=${videoId} movieId=${movieId}`);
    } catch (e) {
      await clearStaleScrapeAssociationsForOverwrite(
        videoId,
        mode,
        fileName,
        logPrefix,
        'movie-scrape-exception'
      );
      const err = e as Error;
      console.warn(`${logPrefix} 电影刮削异常 ${fileName}: ${err.message}`);
    }
  } else {
    try {
      // 只有无法解析标准季集标记时，才将弱语义集数按季号兜底。
      const parsedFileName = parseFileName(fileName);
      const explicitEpisodeNum = parsedFileName.episodeNumber === undefined
        ? extractEpisodeNumberFromWeakSemanticFileName(fileName)
        : undefined;
      // 从文件路径的父目录名提取季号（如"御赐小仵作第二季"→2），无目录季号时回退到1。
      // 只要文件名未解析出标准季号（SxxExx），就显式传目录季号或默认1，避免弱语义文件缺季信息。
      const parentDirName = extractParentDirectoryName(info.filePath);
      const directorySeasonNum = parentDirName !== undefined
        ? extractSeasonNumberFromDirectoryName(parentDirName)
        : undefined;
      const explicitSeasonNum = parsedFileName.seasonNumber === undefined
        ? (directorySeasonNum ?? 1)
        : undefined;
      const result = await scrapeClient.autoScrapeTvEpisode(fileName, seriesHint, classification.mediaType, explicitEpisodeNum, explicitSeasonNum);
      if (!result.series) {
        await clearStaleScrapeAssociationsForOverwrite(
          videoId,
          mode,
          fileName,
          logPrefix,
          'tv-scrape-empty'
        );
        console.warn(`${logPrefix} 剧集刮削无结果 ${fileName}`);
        return;
      }
      const series: TvSeriesScrapeResult = result.series;
      const season = result.season;
      const episode = result.episode;

      let seriesId: number;
      const existingSeries = await db.getTvSeriesByProviderId(series.provider, series.providerId);
      if (existingSeries && existingSeries.id !== undefined) {
        seriesId = existingSeries.id;
        console.info(`${logPrefix} 剧集复用已有记录 seriesId=${seriesId} title="${series.title}"`);
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
        console.info(`${logPrefix} 剧集入库 seriesId=${seriesId} title="${series.title}"`);
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
        `${logPrefix} tv scrape_info 落库 videoId=${videoId} ` +
        `S${scrapeSeasonNumber ?? '?'}E${scrapeEpisodeNumber ?? '?'}`
      );
    } catch (e) {
      await clearStaleScrapeAssociationsForOverwrite(
        videoId,
        mode,
        fileName,
        logPrefix,
        'tv-scrape-exception'
      );
      const err = e as Error;
      console.warn(`${logPrefix} 剧集刮削异常 ${fileName}: ${err.message}`);
    }
  }
}
