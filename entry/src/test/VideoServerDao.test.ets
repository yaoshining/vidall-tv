import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@ohos.abilityAccessCtrl';
import { FileSourceDatabase } from '../main/ets/db/files/FileSourceDatabase';
import { VideoServer, VideoServerType } from '../main/ets/db/models/VideoServerEntity';

/**
 * VideoServerDao 集成测试（UnitTestBuild 侧，真实 Context）。
 * 覆盖 video_servers 表 CRUD 与敏感凭据加密回环。
 */
export default function videoServerDaoTest() {
  const isolatedDatabaseName = `FILE_SOURCES_DB_VIDEO_SERVER_TEST_${Date.now()}`;

  describe('VideoServerDao_integration', () => {
    beforeAll(() => {
      FileSourceDatabase.setDatabaseNameForTesting(isolatedDatabaseName);
    });

    afterAll(() => {
      FileSourceDatabase.setDatabaseNameForTesting(null);
    });

    it('insert_and_read_jellyfin_server_with_decrypted_password', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const db = FileSourceDatabase.getInstance(ctx);
      await db.init();

      const server: VideoServer = {
        name: 'Home',
        type: VideoServerType.JELLYFIN,
        configJson: JSON.stringify({
          url: '192.168.1.100',
          port: 8096,
          protocol: 'http',
          authMethod: 'password',
          username: 'alice',
          password: 'secret-password-123'
        }),
        createdAt: Date.now()
      };
      const id = await db.insertVideoServer(server);

      const loaded = await db.getVideoServerById(id);
      expect(loaded !== null).assertTrue();
      expect(loaded!.name).assertEqual('Home');
      expect(loaded!.type).assertEqual(VideoServerType.JELLYFIN);

      const config = JSON.parse(loaded!.configJson) as Record<string, string>;
      expect(config['password']).assertEqual('secret-password-123');

      await db.deleteVideoServer(id);
      const afterDelete = await db.getVideoServerById(id);
      expect(afterDelete).assertEqual(null);
    });

    it('insert_and_read_plex_server_with_decrypted_token', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const db = FileSourceDatabase.getInstance(ctx);
      await db.init();

      const server: VideoServer = {
        name: 'Plex NAS',
        type: VideoServerType.PLEX,
        configJson: JSON.stringify({
          url: '192.168.1.50',
          port: 32400,
          protocol: 'http',
          token: 'plex-token-abc'
        }),
        createdAt: Date.now()
      };
      const id = await db.insertVideoServer(server);

      const loaded = await db.getVideoServerById(id);
      const config = JSON.parse(loaded!.configJson) as Record<string, string>;
      expect(config['token']).assertEqual('plex-token-abc');

      await db.deleteVideoServer(id);
    });

    it('get_all_video_servers_returns_array', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const db = FileSourceDatabase.getInstance(ctx);
      await db.init();
      const servers = await db.getAllVideoServers();
      expect(Array.isArray(servers)).assertTrue();
    });
  });
}
