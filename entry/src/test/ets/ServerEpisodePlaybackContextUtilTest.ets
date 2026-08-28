import { describe, it, expect } from '@ohos/hypium';
import {
  ServerEpisodeCatalogClient,
  buildServerEpisodeContextFromCatalog
} from '../../main/ets/utils/ServerEpisodePlaybackContextUtil';
import { VideoServerEpisode, VideoServerSeason } from '../../main/ets/lib/JellyfinClient';
import { VideoServer, VideoServerType } from '../../main/ets/db/models/VideoServerEntity';
import { ServerPlaybackContextItem } from '../../main/ets/components/core/player/PlaybackContext';

// 用同一份目录数据模拟不同服务器客户端的返回，验证 Jellyfin/Emby/Plex 映射结构一致
class MockCatalogClient implements ServerEpisodeCatalogClient {
  seasons: VideoServerSeason[] = [];
  episodesBySeasonId: Map<string, VideoServerEpisode[]> = new Map();
  getSeasonsCalled: number = 0;
  getEpisodesCalled: number = 0;

  getSeasons(seriesId: string): Promise<VideoServerSeason[]> {
    this.getSeasonsCalled += 1;
    return Promise.resolve(this.seasons);
  }

  getEpisodes(seriesId: string, seasonId: string): Promise<VideoServerEpisode[]> {
    this.getEpisodesCalled += 1;
    return Promise.resolve(this.episodesBySeasonId.get(seasonId) ?? []);
  }
}

function makeSeason(id: string, seasonNumber: number): VideoServerSeason {
  const season: VideoServerSeason = {
    id: id,
    seasonNumber: seasonNumber,
    name: `第 ${seasonNumber} 季`,
    posterUrl: '',
    overview: ''
  };
  return season;
}

function makeEpisode(id: string, seasonNumber: number, episodeNumber: number): VideoServerEpisode {
  const episode: VideoServerEpisode = {
    id: id,
    episodeNumber: episodeNumber,
    seasonNumber: seasonNumber,
    title: `S${seasonNumber}E${episodeNumber}`,
    overview: '',
    stillUrl: '',
    durationMs: 1500000,
    rating: 0,
    positionMs: 0,
    lastPlayedDate: 0
  };
  return episode;
}

function buildTwoSeasonCatalog(): MockCatalogClient {
  const client = new MockCatalogClient();
  client.seasons = [makeSeason('season-1', 1), makeSeason('season-2', 2)];
  client.episodesBySeasonId.set('season-1', [
    makeEpisode('jf-s1e2', 1, 2),
    makeEpisode('jf-s1e1', 1, 1)
  ]);
  client.episodesBySeasonId.set('season-2', [
    makeEpisode('jf-s2e1', 2, 1)
  ]);
  return client;
}

function extractItemFields(items: ServerPlaybackContextItem[]): string[] {
  const fields: string[] = [];
  items.forEach((item: ServerPlaybackContextItem) => {
    fields.push(`${item.serverItemId}|${item.seasonNumber ?? 0}|${item.episodeNumber ?? 0}|${item.title}`);
  });
  return fields;
}

export default function serverEpisodePlaybackContextUtilTest() {
  describe('ServerEpisodePlaybackContextUtilTest', () => {

    it('Jellyfin 与 Plex 相同目录数据生成一致的上下文结构', 0, async () => {
      const jellyfinContext = await buildServerEpisodeContextFromCatalog(
        VideoServerType.JELLYFIN, 11, 'series-1', 'jf-s1e2', buildTwoSeasonCatalog());
      const plexContext = await buildServerEpisodeContextFromCatalog(
        VideoServerType.PLEX, 12, 'series-1', 'jf-s1e2', buildTwoSeasonCatalog());

      expect(jellyfinContext !== null).assertTrue();
      expect(plexContext !== null).assertTrue();
      if (jellyfinContext !== null && plexContext !== null) {
        expect(jellyfinContext.contextType).assertEqual('server_media_library');
        expect(plexContext.contextType).assertEqual('server_media_library');
        expect(jellyfinContext.currentIndex).assertEqual(1);
        expect(plexContext.currentIndex).assertEqual(1);
        expect(extractItemFields(jellyfinContext.items as ServerPlaybackContextItem[]).join(';'))
          .assertEqual(extractItemFields(plexContext.items as ServerPlaybackContextItem[]).join(';'));
        // 服务器差异仅体现在 serverType/serverId 元数据上
        expect((jellyfinContext.items[0] as ServerPlaybackContextItem).serverType)
          .assertEqual(VideoServerType.JELLYFIN);
        expect((plexContext.items[0] as ServerPlaybackContextItem).serverType)
          .assertEqual(VideoServerType.PLEX);
        expect((jellyfinContext.items[0] as ServerPlaybackContextItem).serverId).assertEqual(11);
        expect((plexContext.items[0] as ServerPlaybackContextItem).serverId).assertEqual(12);
      }
    });

    it('当前项不在目录返回的集列表中时返回 null（安全退化单集播放）', 0, async () => {
      const context = await buildServerEpisodeContextFromCatalog(
        VideoServerType.EMBY, 3, 'series-1', 'missing-item', buildTwoSeasonCatalog());
      expect(context).assertNull();
    });

    it('空 seriesId 或空 currentItemId 直接返回 null，不请求服务器目录', 0, async () => {
      const client = buildTwoSeasonCatalog();
      const emptySeriesContext = await buildServerEpisodeContextFromCatalog(
        VideoServerType.JELLYFIN, 5, '', 'jf-s1e1', client);
      const emptyItemContext = await buildServerEpisodeContextFromCatalog(
        VideoServerType.JELLYFIN, 5, 'series-1', '', client);
      expect(emptySeriesContext).assertNull();
      expect(emptyItemContext).assertNull();
      expect(client.getSeasonsCalled).assertEqual(0);
      expect(client.getEpisodesCalled).assertEqual(0);
    });

    it('季数据为空时返回 null', 0, async () => {
      const context = await buildServerEpisodeContextFromCatalog(
        VideoServerType.PLEX, 5, 'series-1', 'jf-s1e1', new MockCatalogClient());
      expect(context).assertNull();
    });
  });
}
