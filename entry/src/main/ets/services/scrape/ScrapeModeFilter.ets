import { ScrapeInfoEntity } from '../../db/models/MediaEntity';
import { ScanMode } from '../../utils/VideoScannerTypes';
import { ScopedScrapeVideo } from './ScopedScrapeTypes';

export function hasRequiredScrapeAssociation(scrapeInfo?: ScrapeInfoEntity): boolean {
  if (scrapeInfo === undefined) {
    return false;
  }
  if (scrapeInfo.mediaType === 'movie') {
    return scrapeInfo.movieId !== undefined;
  }
  if (scrapeInfo.mediaType === 'tv' || scrapeInfo.mediaType === 'episode') {
    return scrapeInfo.tvSeriesId !== undefined &&
      (scrapeInfo.mediaType !== 'episode' || scrapeInfo.episodeId !== undefined);
  }
  return false;
}

export function shouldScrapeVideo(target: ScopedScrapeVideo, mode: ScanMode): boolean {
  if (mode === 'overwrite') {
    return true;
  }
  const hasAssociation = hasRequiredScrapeAssociation(target.scrapeInfo);
  if (mode === 'fix-missing') {
    return !hasAssociation || !target.posterAvailable;
  }
  return target.video.updatedInLastScan === 1 || !hasAssociation;
}

export function filterScrapeTargets(targets: ScopedScrapeVideo[], mode: ScanMode): ScopedScrapeVideo[] {
  return targets.filter((target: ScopedScrapeVideo): boolean => shouldScrapeVideo(target, mode));
}
