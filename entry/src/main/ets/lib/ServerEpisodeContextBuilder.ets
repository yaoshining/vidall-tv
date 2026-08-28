import { BusinessError } from '@kit.BasicServicesKit';
import { VideoServer, VideoServerType } from '../db/models/VideoServerEntity';
import { JellyfinClient, VideoServerEpisode, VideoServerSeason } from './JellyfinClient';
import { PlexClient } from './PlexClient';
import { ServerMediaLibraryContext, ServerMediaLibraryMeta } from '../components/core/player/PlaybackContext';

/** 从季列表中按季号定位 seasonId；未命中返回空字符串 */
function pickSeasonId(seasons: VideoServerSeason[], seasonNumber: number): string {
  for (let i = 0; i < seasons.length; i++) {
    if (seasons[i].seasonNumber === seasonNumber) {
      return seasons[i].id;
    }
  }
  return '';
}

function buildContextFromEpisodes(
  server: VideoServer,
  episodes: VideoServerEpisode[],
  currentItemKey: string,
  seriesId: string,
  seriesTitle: string,
  seasonNumber: number,
  seasonName: string,
  posterUrl: string,
  backdropUrl: string
): ServerMediaLibraryContext | null {
  if (episodes.length === 0) {
    return null;
  }
  const meta: ServerMediaLibraryMeta = {
    serverType: server.type,
    serverId: server.id ?? 0,
    seriesId: seriesId,
    seriesTitle: seriesTitle,
    seasonNumber: seasonNumber,
    seasonName: seasonName,
    posterUrl: posterUrl,
    backdropUrl: backdropUrl
  };
  return ServerMediaLibraryContext.build(episodes, currentItemKey, meta);
}

/**
 * 用已加载的季集列表直接构建服务器播放上下文（季详情页主路径，零额外请求）。
 * 列表为空时返回 null，调用方按无上下文方式降级播放。
 */
export function buildServerSeasonContextFromEpisodes(
  server: VideoServer,
  episodes: VideoServerEpisode[],
  currentItemKey: string,
  seriesId: string,
  seriesTitle: string,
  seasonNumber: number,
  seasonName: string,
  posterUrl: string,
  backdropUrl: string
): ServerMediaLibraryContext | null {
  return buildContextFromEpisodes(
    server, episodes, currentItemKey, seriesId, seriesTitle, seasonNumber, seasonName, posterUrl, backdropUrl
  );
}

/**
 * 解析指定季的剧集列表并构建服务器播放上下文。
 * @param preloadedSeasons 已加载的季列表（可选，详情页已持有 seasons 时避免重复请求）
 * 任一步骤失败（季未命中 / 拉取季列表或集列表失败）返回 null；
 * 调用方按无上下文方式降级播放，不阻塞起播。
 */
export async function buildServerSeasonContext(
  server: VideoServer,
  seriesId: string,
  seasonNumber: number,
  currentItemKey: string,
  seriesTitle: string,
  seasonName: string,
  posterUrl: string,
  backdropUrl: string,
  preloadedSeasons?: VideoServerSeason[]
): Promise<ServerMediaLibraryContext | null> {
  try {
    let seasons: VideoServerSeason[] = [];
    let episodes: VideoServerEpisode[] = [];
    if (server.type === VideoServerType.PLEX) {
      const client = PlexClient.fromConfigJson(server.configJson);
      seasons = preloadedSeasons !== undefined && preloadedSeasons.length > 0
        ? preloadedSeasons
        : await client.getSeasons(seriesId);
      const seasonId = pickSeasonId(seasons, seasonNumber);
      if (seasonId.length === 0) {
        return null;
      }
      episodes = await client.getEpisodes(seriesId, seasonId);
    } else {
      const client = JellyfinClient.fromConfigJson(server.configJson);
      seasons = preloadedSeasons !== undefined && preloadedSeasons.length > 0
        ? preloadedSeasons
        : await client.getSeasons(seriesId);
      const seasonId = pickSeasonId(seasons, seasonNumber);
      if (seasonId.length === 0) {
        return null;
      }
      episodes = await client.getEpisodes(seriesId, seasonId);
    }
    return buildContextFromEpisodes(
      server, episodes, currentItemKey, seriesId, seriesTitle, seasonNumber, seasonName, posterUrl, backdropUrl
    );
  } catch (e) {
    console.warn('[ServerEpisodeContextBuilder] 构建服务器播放上下文失败', (e as BusinessError).message ?? String(e));
    return null;
  }
}
