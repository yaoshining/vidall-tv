import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { FileSourceDatabase } from '../../../main/ets/db/files/FileSourceDatabase';
import { PlayHistoryEntity } from '../../../main/ets/db/models/MediaEntity';

export default function playHistoryTest() {
  describe('PlayHistoryTest', () => {
    let db: FileSourceDatabase;

    beforeAll(async () => {
      // 初始化数据库
      // 注意：在实际测试中需要提供 Context，这里仅作示例
      db = FileSourceDatabase.getInstance();
      // await db.init(); // 需要 Context，在实际测试中配置
    })

    afterAll(async () => {
      // 清理测试数据
      // await db.deleteAllPlayHistory(); // 如果有此方法
    })

    it('upsertPlayHistory_插入新记录', 0, async () => {
      const entity: PlayHistoryEntity = {
        videoId: 1,
        positionMs: 60000, // 1分钟
        durationMs: 600000, // 10分钟
        updatedAt: Date.now()
      };

      // 插入记录
      await db.upsertPlayHistory(entity);

      // 验证记录是否插入成功
      const result = await db.getPlayHistoryByVideoId(1);
      expect(result).not().assertNull();
      expect(result!.videoId).assertEqual(1);
      expect(result!.positionMs).assertEqual(60000);
      expect(result!.durationMs).assertEqual(600000);
    })

    it('upsertPlayHistory_更新已存在记录', 0, async () => {
      const entity1: PlayHistoryEntity = {
        videoId: 2,
        positionMs: 30000,
        durationMs: 600000,
        updatedAt: Date.now()
      };

      // 插入初始记录
      await db.upsertPlayHistory(entity1);

      // 更新记录
      const entity2: PlayHistoryEntity = {
        videoId: 2,
        positionMs: 120000, // 更新到2分钟
        durationMs: 600000,
        updatedAt: Date.now()
      };
      await db.upsertPlayHistory(entity2);

      // 验证记录是否更新
      const result = await db.getPlayHistoryByVideoId(2);
      expect(result).not().assertNull();
      expect(result!.videoId).assertEqual(2);
      expect(result!.positionMs).assertEqual(120000);
    })

    it('getPlayHistoryByVideoId_不存在的记录', 0, async () => {
      const result = await db.getPlayHistoryByVideoId(999);
      expect(result).assertNull();
    })

    it('deletePlayHistory_删除记录', 0, async () => {
      const entity: PlayHistoryEntity = {
        videoId: 3,
        positionMs: 90000,
        durationMs: 600000,
        updatedAt: Date.now()
      };

      // 插入记录
      await db.upsertPlayHistory(entity);

      // 验证记录存在
      let result = await db.getPlayHistoryByVideoId(3);
      expect(result).not().assertNull();

      // 删除记录
      await db.deletePlayHistory(3);

      // 验证记录已删除
      result = await db.getPlayHistoryByVideoId(3);
      expect(result).assertNull();
    })

    it('getAllPlayHistory_获取所有记录', 0, async () => {
      // 插入多条记录
      const entities: PlayHistoryEntity[] = [
        { videoId: 10, positionMs: 10000, durationMs: 100000, updatedAt: Date.now() },
        { videoId: 11, positionMs: 20000, durationMs: 200000, updatedAt: Date.now() },
        { videoId: 12, positionMs: 30000, durationMs: 300000, updatedAt: Date.now() }
      ];

      for (const entity of entities) {
        await db.upsertPlayHistory(entity);
      }

      // 获取所有记录
      const allHistory = await db.getAllPlayHistory();
      expect(allHistory.length).assertLargerOrEqual(3)

      // 验证记录按更新时间倒序排列（最新的在前）
      for (let i = 0; i < allHistory.length - 1; i++) {
        expect(allHistory[i].updatedAt).assertLargerOrEqual(allHistory[i + 1].updatedAt);
      }
    })
  })
}
