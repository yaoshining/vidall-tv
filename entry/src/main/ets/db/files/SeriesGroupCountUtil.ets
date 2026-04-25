export interface SeriesEpisodeCountSource {
  episodeId?: number;
}

export function countSeriesEpisodeRows(items: SeriesEpisodeCountSource[]): number {
  const episodeIds: Set<number> = new Set<number>();
  let fallbackCount = 0;
  for (const item of items) {
    if (item.episodeId !== undefined) {
      episodeIds.add(item.episodeId);
      continue;
    }
    fallbackCount++;
  }
  return episodeIds.size > 0 ? episodeIds.size : fallbackCount;
}
