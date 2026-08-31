import { VideoServer, VideoServerType } from '../db/models/VideoServerEntity';
import { JellyfinClient, VideoServerEpisode, VideoServerSeason } from '../lib/JellyfinClient';
import { PlexClient } from '../lib/PlexClient';
import {
  buildServerPlaybackItems,
  ServerBuildItemsResult,
  ServerMediaLibraryContext
} from '../components/core/player/PlaybackContext';

export interface ServerEpisodeCatalogClient {
  getSeasons(seriesId: string): Promise<VideoServerSeason[]>;
  getEpisodes(seriesId: string, seasonId: string): Promise<VideoServerEpisode[]>;
}

export function createServerEpisodeCatalogClient(server: VideoServer): ServerEpisodeCatalogClient {
  if (server.type === VideoServerType.PLEX) {
    return PlexClient.fromConfigJson(server.configJson);
  }
  return JellyfinClient.fromConfigJson(server.configJson);
}

/**
 * 基于目录客户端构建整剧上下文：按季遍历拉取全部集，
 * 排序、定位与上下文生成复用 buildServerPlaybackItems。
 * 独立导出以便用 mock 客户端验证 Jellyfin/Emby/Plex 映射一致性。
 */
export async function buildServerEpisodeContextFromCatalog(serverType: VideoServerType, serverId: number,
  seriesId: string, currentItemId: string,
  client: ServerEpisodeCatalogClient): Promise<ServerMediaLibraryContext | null> {
  if (seriesId.length === 0 || currentItemId.length === 0) {
    return null;
  }
  const seasons = await client.getSeasons(seriesId);
  const episodes: VideoServerEpisode[] = [];
  const episodeIds: Set<string> = new Set();
  for (let index: number = 0; index < seasons.length; index += 1) {
    const seasonEpisodes = await client.getEpisodes(seriesId, seasons[index].id);
    seasonEpisodes.forEach((episode: VideoServerEpisode) => {
      if (episode.id.length > 0 && !episodeIds.has(episode.id)) {
        episodeIds.add(episode.id);
        episodes.push(episode);
      }
    });
  }
  const result: ServerBuildItemsResult = buildServerPlaybackItems(
    serverType, serverId, seriesId, episodes, currentItemId);
  if (result.currentIndex < 0 || result.items.length === 0) {
    return null;
  }
  return new ServerMediaLibraryContext(result.items, result.currentIndex);
}

export async function buildServerEpisodePlaybackContext(server: VideoServer, seriesId: string,
  currentItemId: string): Promise<ServerMediaLibraryContext | null> {
  if (server.id === undefined || seriesId.length === 0 || currentItemId.length === 0) {
    return null;
  }
  return buildServerEpisodeContextFromCatalog(
    server.type, server.id, seriesId, currentItemId, createServerEpisodeCatalogClient(server));
}
