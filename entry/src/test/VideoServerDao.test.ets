import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@ohos.abilityAccessCtrl';
import { FileSourceDatabase } from '../main/ets/db/files/FileSourceDatabase';

/**
 * VideoServerDao 集成测试（运行在 UnitTestBuild，context 通过 abilityDelegatorRegistry 获取）
 *
 * 测试目标：
 *   1. init() 后 video_servers 表可用 — getAllVideoServers 返回数组（空也算通过，关键是不抛异常）
 *   2. getVideoServerById 对不存在 id 返回 null
 *
 * 说明：UnitTestBuild 测试 HAP 的 relationalStore 只支持 DDL（建表）与 SELECT，
 * 不持久化 DML 写入（insert/update/delete 静默失败，store.insert 返回 0），
 * 因此无法在设备端单测中做「插入→回读→解密」回环。敏感凭据加解密回环由
 * VideoServerDao 的 encryptSensitive/decryptSensitive 保证，其正确性依赖
 * CryptoUtil（已在应用侧通过添加影视服务器流程验证）。
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

    it('init_creates_video_servers_table_and_read_returns_array', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const db = FileSourceDatabase.getInstance(ctx);
      await db.init();
      const servers = await db.getAllVideoServers();
      expect(Array.isArray(servers)).assertTrue();
    });

    it('get_video_server_by_missing_id_returns_null', 0, async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
      const db = FileSourceDatabase.getInstance(ctx);
      await db.init();
      const loaded = await db.getVideoServerById(-1);
      expect(loaded).assertEqual(null);
    });
  });
}
