import { FileSourceDatabase } from '../db/files/FileSourceDatabase';
import {
  MovieScrapeResult,
  ScrapeClient,
  parseFileName,
  TvEpisodeScrapeBundle
} from '../lib/ScrapeClient';
import { ScrapeInfoEntity, MovieEntity, TvSeriesEntity, TvSeasonEntity, TvEpisodeEntity } from '../db/models/MediaEntity';
import { extractSeriesHintFromFilePath, formatMediaTypeClassificationSignals, extractSeasonNumberFromDirectoryName } from '../lib/MediaTypeClassifier';
import { VideoFileInfo, VideoScrapeContext, ScanMode } from './VideoScannerTypes';
import { classifyVideoScrapeTarget, hasCompleteScrapeAssociation, extractEpisodeNumberFromWeakSemanticFileName } from './VideoScannerHelpers';
import {
  FAILURE_CATEGORY_DB_WRITE,
  FAILURE_CATEGORY_NO_MATCH,
  FAILURE_CATEGORY_PARSE_EPISODE,
  FAILURE_CATEGORY_SCRAPER_ERROR,
  ScrapeVideoOutcome
} from '../services/scrape/ScopedScrapeTypes';

export async function applyMovieScrapeResult(
  videoId: number,
  movie: MovieScrapeResult,
  logPrefix: string
): Promise<boolean> {
  const db = FileSourceDatabase.getInstance();
  try {
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
    const existingMovie = await db.getMovieByProviderId(movie.provider, movie.providerId);
    if (existingMovie?.id !== undefined) {
      movieEntity.id = existingMovie.id;
    }
    const movieId = await db.upsertMovie(movieEntity);
    const scrapeInfo: ScrapeInfoEntity = {
      videoId, provider: movie.provider, providerId: movie.providerId,
      mediaType: 'movie', title: movie.title, originalTitle: movie.originalTitle,
      movieId, scrapedAt: Date.now()
    };
    await db.upsertScrapeInfo(scrapeInfo);
    return true;
  } catch (e) {
    const err = e as Error;
    console.warn(`${logPrefix} 电影结果落库失败: ${err.message}`);
    return false;
  }
}

export async function applyTvEpisodeScrapeResult(
  videoId: number,
  result: TvEpisodeScrapeBundle,
  logPrefix: string
): Promise<boolean> {
  const db = FileSourceDatabase.getInstance();
  const series = result.series;
  if (series === null || result.episode === null) {
    return false;
  }
  try {
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
    const existingSeries = await db.getTvSeriesByProviderId(series.provider, series.providerId);
    if (existingSeries?.id !== undefined) {
      seriesEntity.id = existingSeries.id;
    }
    const seriesId = await db.upsertTvSeries(seriesEntity);
    let seasonId: number | undefined;
    if (result.season !== null) {
      const season = result.season;
      const seasonEntity: TvSeasonEntity = {
        seriesId, provider: season.provider, providerId: season.providerId,
        seasonNumber: season.seasonNumber, title: season.title,
        overview: season.overview, airDate: season.airDate,
        episodeCount: season.episodeCount, posterPath: season.posterPath,
        posterUrl: season.posterUrl, rawJson: season.rawJson, scrapedAt: Date.now()
      };
      const existingSeason = await db.getTvSeason(seriesId, season.seasonNumber);
      if (existingSeason?.id !== undefined) {
        seasonEntity.id = existingSeason.id;
      }
      seasonId = await db.upsertTvSeason(seasonEntity);
    }
    let episodeId: number | undefined;
    if (result.episode !== null) {
      const episode = result.episode;
      const episodeEntity: TvEpisodeEntity = {
        seriesId, seasonId, provider: episode.provider, providerId: episode.providerId,
        seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber,
        title: episode.title, overview: episode.overview, airDate: episode.airDate,
        runtime: episode.runtime, rating: episode.rating,
        stillPath: episode.stillPath, stillUrl: episode.stillUrl,
        rawJson: episode.rawJson, scrapedAt: Date.now()
      };
      const existingEpisode = await db.getTvEpisode(seriesId, episode.seasonNumber, episode.episodeNumber);
      if (existingEpisode?.id !== undefined) {
        episodeEntity.id = existingEpisode.id;
      }
      episodeId = await db.upsertTvEpisode(episodeEntity);
    }
    const scrapeInfo: ScrapeInfoEntity = {
      videoId, provider: series.provider,
      providerId: result.episode?.providerId ?? series.providerId,
      mediaType: episodeId !== undefined ? 'episode' : 'tv',
      title: result.episode?.title ?? series.title,
      originalTitle: series.originalTitle, tvSeriesId: seriesId, episodeId,
      seasonNumber: result.episode?.seasonNumber ?? result.season?.seasonNumber,
      episodeNumber: result.episode?.episodeNumber, scrapedAt: Date.now()
    };
    await db.upsertScrapeInfo(scrapeInfo);
    return true;
  } catch (e) {
    const err = e as Error;
    console.warn(`${logPrefix} 剧集结果落库失败: ${err.message}`);
    return false;
  }
}

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
): Promise<ScrapeVideoOutcome> {
  const db = FileSourceDatabase.getInstance();
  try {
    const existing = await db.getScrapeInfoByVideoId(videoId);
    if (mode === 'incremental') {
      if (hasCompleteScrapeAssociation(existing)) {
        console.info(`${logPrefix} incremental 元数据完整，跳过 fileName=${fileName}`);
        return { success: true };
      }
    } else if (mode === 'fix-missing') {
      if (existing && hasCompleteScrapeAssociation(existing)) {
        let hasPoster = false;
        if (existing.mediaType === 'movie' && existing.movieId !== undefined) {
          const movie = await db.getMovieById(existing.movieId);
          hasPoster = !!(movie?.posterUrl || movie?.posterLocalPath);
        } else if (existing.tvSeriesId !== undefined) {
          const series = await db.getTvSeriesById(existing.tvSeriesId);
          hasPoster = !!(series?.posterUrl || series?.posterLocalPath);
        }
        if (hasPoster) {
          console.info(`${logPrefix} fix-missing 元数据完整，跳过 fileName=${fileName}`);
          info.scrapeSkipped = true;
          return { success: true };
        }
        console.info(`${logPrefix} fix-missing 海报缺失，重新刮削 fileName=${fileName}`);
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
    return { success: true };
  }

  if (classification.mediaType === 'movie') {
    try {
      if (classification.fallbackTitle !== undefined) {
        console.info(`${logPrefix} 文件名弱语义，使用父目录片名兜底搜索 fallbackTitle="${classification.fallbackTitle}"`);
      }
      const movie = await scrapeClient.autoScrapeMovie(fileName, classification.fallbackTitle);
      if (!movie) {
        console.warn(`${logPrefix} 电影刮削无结果 ${fileName}`);
        return { success: false, category: FAILURE_CATEGORY_NO_MATCH };
      }
      console.info(`${logPrefix} 电影刮削结果 title="${movie.title}" posterUrl=${movie.posterUrl ? movie.posterUrl.substring(0, 40) : 'null'} rating=${movie.rating ?? 'null'}`);
      const movieApplied = await applyMovieScrapeResult(videoId, movie, logPrefix);
      if (!movieApplied) {
        return { success: false, category: FAILURE_CATEGORY_DB_WRITE };
      }
      return { success: true };
    } catch (e) {
      const err = e as Error;
      console.warn(`${logPrefix} 电影刮削异常 ${fileName}: ${err.message}`);
      return { success: false, category: FAILURE_CATEGORY_SCRAPER_ERROR, detail: err.message };
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
      const resolvedEpisodeNum = parsedFileName.episodeNumber ?? explicitEpisodeNum;
      if (resolvedEpisodeNum === undefined) {
        console.warn(`${logPrefix} 无法解析剧集集号 ${fileName}`);
        return { success: false, category: FAILURE_CATEGORY_PARSE_EPISODE };
      }
      const result = await scrapeClient.autoScrapeTvEpisode(fileName, seriesHint, classification.mediaType, explicitEpisodeNum, explicitSeasonNum);
      if (!result.series) {
        console.warn(`${logPrefix} 剧集刮削无结果 ${fileName}`);
        return { success: false, category: FAILURE_CATEGORY_NO_MATCH };
      }
      const tvApplied = await applyTvEpisodeScrapeResult(videoId, result, logPrefix);
      if (!tvApplied) {
        if (result.episode === null) {
          return { success: false, category: FAILURE_CATEGORY_NO_MATCH };
        }
        return { success: false, category: FAILURE_CATEGORY_DB_WRITE };
      }
      return { success: true };
    } catch (e) {
      const err = e as Error;
      console.warn(`${logPrefix} 剧集刮削异常 ${fileName}: ${err.message}`);
      return { success: false, category: FAILURE_CATEGORY_SCRAPER_ERROR, detail: err.message };
    }
  }
  return { success: true };
}
