import { MediaItem, TvEpisodeEntity } from '../../../db/models/MediaEntity'

function tmdbStillImageUrl(path: string | undefined, width: string): string {
  if (path === undefined || path.length === 0) {
    return ''
  }
  return `https://image.tmdb.org/t/p/${width}${path}`
}

export interface EpisodeGroupMatchItem {
  videoPath: string
  title: string
  index: number
  thumbnailUrl?: string
  episodeNumber?: number
  seasonNumber?: number
  sourceId?: number
  videoId?: number
  durationMs?: number
}

export interface EpisodeGroupMatchResult {
  mediaItems: MediaItem[]
  items: EpisodeGroupMatchItem[]
}

export class EpisodeGroupMatcher {
  private readonly seasonCache: Map<string, EpisodeGroupMatchResult> = new Map<string, EpisodeGroupMatchResult>()

  async matchSeasonEpisodes(
    seriesId: number,
    seasonNumber: number,
    loadMediaItems: () => Promise<MediaItem[]>,
    loadEpisodeEntities: () => Promise<TvEpisodeEntity[]>
  ): Promise<EpisodeGroupMatchResult> {
    const cacheKey = this.buildCacheKey(seriesId, seasonNumber)
    const cached = this.seasonCache.get(cacheKey)
    if (cached !== undefined) {
      return cached
    }

    const allItems = await loadMediaItems()
    const seasonItems = this.filterSeasonItems(allItems, seasonNumber)
    const episodeEntities = await loadEpisodeEntities()
    const episodeEntityByNumber = this.buildEpisodeEntityByNumber(episodeEntities)

    const playbackItems: EpisodeGroupMatchItem[] = []
    for (let i = 0; i < seasonItems.length; i++) {
      const mediaItem = seasonItems[i]
      const episodeEntity = this.findEpisodeEntity(mediaItem, i, episodeEntities, episodeEntityByNumber)
      const playbackItem: EpisodeGroupMatchItem = {
        videoPath: mediaItem.filePath,
        title: this.getEpisodeDisplayTitle(mediaItem, episodeEntity),
        index: i,
        thumbnailUrl: this.getEpisodeThumbnailUrl(episodeEntity),
        episodeNumber: mediaItem.episodeNumber ?? undefined,
        seasonNumber: mediaItem.seasonNumber ?? undefined,
        sourceId: mediaItem.sourceId,
        videoId: mediaItem.id,
        durationMs: mediaItem.durationMs ?? undefined
      }
      playbackItems.push(playbackItem)
    }

    const result: EpisodeGroupMatchResult = {
      mediaItems: seasonItems,
      items: playbackItems
    }
    this.seasonCache.set(cacheKey, result)
    return result
  }

  clearCache(): void {
    this.seasonCache.clear()
  }

  private buildCacheKey(seriesId: number, seasonNumber: number): string {
    return `${seriesId}:${seasonNumber}`
  }

  private filterSeasonItems(allItems: MediaItem[], seasonNumber: number): MediaItem[] {
    const seasonItems: MediaItem[] = []
    for (let i = 0; i < allItems.length; i++) {
      const item = allItems[i]
      if (item.seasonNumber === seasonNumber) {
        seasonItems.push(item)
      }
    }
    seasonItems.sort((a: MediaItem, b: MediaItem): number => {
      const aEpisode = a.episodeNumber ?? Number.MAX_SAFE_INTEGER
      const bEpisode = b.episodeNumber ?? Number.MAX_SAFE_INTEGER
      if (aEpisode !== bEpisode) {
        return aEpisode - bEpisode
      }
      return a.filePath.localeCompare(b.filePath)
    })
    return seasonItems
  }

  private buildEpisodeEntityByNumber(episodeEntities: TvEpisodeEntity[]): Map<number, TvEpisodeEntity> {
    const result = new Map<number, TvEpisodeEntity>()
    for (let i = 0; i < episodeEntities.length; i++) {
      const entity = episodeEntities[i]
      result.set(entity.episodeNumber, entity)
    }
    return result
  }

  private findEpisodeEntity(
    mediaItem: MediaItem,
    index: number,
    episodeEntities: TvEpisodeEntity[],
    episodeEntityByNumber: Map<number, TvEpisodeEntity>
  ): TvEpisodeEntity | undefined {
    if (mediaItem.episodeNumber !== undefined) {
      const matchedEntity = episodeEntityByNumber.get(mediaItem.episodeNumber)
      if (matchedEntity !== undefined) {
        return matchedEntity
      }
      return undefined
    }
    if (index >= 0 && index < episodeEntities.length) {
      return episodeEntities[index]
    }
    return undefined
  }

  private getEpisodeDisplayTitle(mediaItem: MediaItem, episodeEntity: TvEpisodeEntity | undefined): string {
    const entityTitle = (episodeEntity?.title ?? '').trim()
    if (entityTitle.length > 0) {
      return entityTitle
    }
    const episodeNumber = mediaItem.episodeNumber ?? 0
    if (episodeNumber > 0) {
      return `第${episodeNumber}集`
    }
    const title = (mediaItem.title ?? '').trim()
    if (title.length > 0) {
      return title
    }
    const fileName = (mediaItem.fileName ?? '').trim()
    if (fileName.length > 0) {
      return fileName
    }
    return '未知集名'
  }

  private getEpisodeThumbnailUrl(episodeEntity: TvEpisodeEntity | undefined): string | undefined {
    if (episodeEntity === undefined) {
      return undefined
    }
    if (episodeEntity.stillUrl !== undefined && episodeEntity.stillUrl.length > 0) {
      return episodeEntity.stillUrl
    }
    if (episodeEntity.stillPath !== undefined && episodeEntity.stillPath.length > 0) {
      return tmdbStillImageUrl(episodeEntity.stillPath, 'w342')
    }
    return undefined
  }
}
