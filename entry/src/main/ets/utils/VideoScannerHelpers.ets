import { isSeasonDirectorySegment, createFileNameSemanticInfo, classifyMediaType, buildMediaTypeClassificationInput, MediaTypeClassificationResult, MediaTypeClassificationOptions } from '../lib/MediaTypeClassifier';
import { parseFileName } from '../lib/ScrapeClient';
import { ScrapeInfoEntity } from '../db/models/MediaEntity';
import { FileSourceDatabase } from '../db/files/FileSourceDatabase';
import { VideoScrapeContext, ScanMode } from './VideoScannerTypes';

// ─────────────────────────────────────────────
// 视频扩展名白名单
// ─────────────────────────────────────────────

const VIDEO_EXTENSIONS: Set<string> = new Set([
  'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv',
  'ts', 'm2ts', 'mts', 'rmvb', 'rm', 'webm',
  'm4v', 'mpeg', 'mpg', '3gp', 'ogv', 'vob',
  'divx', 'xvid', 'hevc', 'h264', 'h265'
]);

export function isVideoFile(fileName: string, contentType?: string): boolean {
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

export function hasSeasonSiblingDirectory(directoryNames: string[]): boolean {
  return directoryNames.some((directoryName: string) => isSeasonDirectorySegment(directoryName));
}

function extractLastPathSegment(path: string): string | undefined {
  const normalizedPath = path.replace(/\\/g, '/').replace(/\/+$/g, '');
  const segments = normalizedPath.split('/').filter((segment: string) => segment.length > 0);
  if (segments.length === 0) {
    return undefined;
  }
  return segments[segments.length - 1];
}

export function createVideoScrapeContext(rootPath: string, depth: number, seasonSiblingDetected: boolean): VideoScrapeContext {
  const context: VideoScrapeContext = {
    seasonSiblingDetected
  };
  if (depth === 0) {
    context.seriesHint = extractLastPathSegment(rootPath);
  }
  return context;
}

export function classifyVideoScrapeTarget(
  fileName: string,
  filePath: string,
  context?: VideoScrapeContext
): MediaTypeClassificationResult {
  const parsed = parseFileName(fileName);
  const fileNameInfo = createFileNameSemanticInfo(
    parsed.title,
    parsed.language,
    parsed.mediaType,
    parsed.seasonNumber,
    parsed.episodeNumber,
    parsed.year
  );
  const classificationOptions: MediaTypeClassificationOptions = {
    seasonSiblingDetected: context?.seasonSiblingDetected
  };
  return classifyMediaType(
    buildMediaTypeClassificationInput(fileName, filePath, fileNameInfo, classificationOptions)
  );
}

/**
 * 判断是否需要修复不完整的 TV 剧集关联
 *
 * 场景：scrape_info 已标记为 tv + title 非空，但 episodeId 为空
 * 策略：如果能从文件名提取 episode number，返回 true
 *
 * @param scrapeInfo 已有的刮削信息
 * @param fileName 文件名
 * @returns true 表示需要修复，false 表示不需要
 */
export function hasCompleteScrapeAssociation(scrapeInfo: ScrapeInfoEntity | null): boolean {
  if (scrapeInfo === null) {
    return false;
  }
  if (scrapeInfo.mediaType === 'movie') {
    return scrapeInfo.movieId !== undefined;
  }
  return scrapeInfo.tvSeriesId !== undefined;
}

export function shouldRepairIncompleteTvEpisode(
  scrapeInfo: ScrapeInfoEntity | null,
  fileName: string
): boolean {
  // 1. scrapeInfo 不存在，不需要修复
  if (scrapeInfo === null) {
    return false;
  }

  // 2. mediaType 不是 tv，不需要修复
  if (scrapeInfo.mediaType !== 'tv') {
    return false;
  }

  // 3. title 为空，不需要修复
  if (scrapeInfo.title === undefined || scrapeInfo.title.trim() === '') {
    return false;
  }

  // 4. episodeId 已存在，不需要修复
  if (scrapeInfo.episodeId !== undefined) {
    return false;
  }

  // 5. 尝试从文件名提取 episode number
  const extractedEpisode = extractEpisodeNumberFromWeakSemanticFileName(fileName);
  if (extractedEpisode === undefined) {
    return false;
  }

  // 满足所有条件：tv + title 非空 + episodeId 空 + 文件名可提取 episode
  return true;
}

/**
 * 从弱语义文件名提取 episode number
 *
 * 支持格式：
 * - 19.mp4 -> 19
 * - 19 4K.mp4 -> 19
 * - 20 4K.mp4 -> 20
 * - E19.mp4 -> 19
 *
 * 不支持格式：
 * - trailer.mp4 -> undefined
 * - 2024.mp4 -> undefined (年份，过滤掉)
 *
 * @param fileName 文件名
 * @returns episode number，如果无法提取则返回 undefined
 */
export function extractEpisodeNumberFromWeakSemanticFileName(fileName: string): number | undefined {
  const withoutExt = fileName.replace(/\.[^.]+$/, '');

  // 1. 先尝试 SxxEyy 格式（优先级最高）
  const standardMatch = withoutExt.match(/[Ss](\d{1,2})[Ee](\d{1,3})/);
  if (standardMatch) {
    return parseInt(standardMatch[2]);
  }

  // 2. 尝试单独的 Eyy 格式
  const episodeOnlyMatch = withoutExt.match(/^[Ee](\d{1,3})/);
  if (episodeOnlyMatch) {
    return parseInt(episodeOnlyMatch[1]);
  }

  // 3. 尝试纯数字开头（如 "19 4K"、"19~4K"、"19_4K"、"19-4K" 或 "19"）
  const pureNumberMatch = withoutExt.match(/^(\d{1,3})(?:[\s~_\-]|$)/);
  if (pureNumberMatch) {
    const num = parseInt(pureNumberMatch[1]);
    // 过滤掉年份（1900-2099）
    if (num >= 1900 && num <= 2099) {
      return undefined;
    }
    // 过滤掉过大的数字（episode 通常 < 999）
    if (num > 999) {
      return undefined;
    }
    return num;
  }

  return undefined;
}

export async function clearStaleScrapeAssociationsForOverwrite(
  videoId: number,
  mode: ScanMode,
  fileName: string,
  logPrefix: string,
  reason: string
): Promise<void> {
  if (mode !== 'overwrite') {
    return;
  }
  await FileSourceDatabase.getInstance().clearScrapeInfoForVideo(videoId);
  console.info(`${logPrefix} overwrite 已清理旧刮削关联 fileName=${fileName} reason=${reason}`);
}
