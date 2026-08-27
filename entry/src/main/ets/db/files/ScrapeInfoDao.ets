import relationalStore from '@ohos.data.relationalStore';
import { ScrapeInfoEntity } from '../models/MediaEntity';
import { BusinessError } from "@kit.BasicServicesKit";
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  TABLE_SCRAPE_INFO, TABLE_VIDEOS, TABLE_MOVIES, TABLE_TV_SERIES, TABLE_TV_SEASONS, TABLE_TV_EPISODES
} from './DbConstants';
import { FileSourceDbCore } from './FileSourceDbCore';

/**
 * scrape_info 桥表的数据访问（含孤立数据清理）。
 * 拆分自 FileSourceDatabase，保持原方法签名与行为不变。
 */
export class ScrapeInfoDao {
  private core: FileSourceDbCore;

  constructor(core: FileSourceDbCore) {
    this.core = core;
  }

  async getScrapeInfoByVideoId(videoId: number): Promise<ScrapeInfoEntity | null> {
    if (!this.core.isReady()) { return null; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(
        `SELECT * FROM ${TABLE_SCRAPE_INFO} WHERE video_id = ? LIMIT 1`,
        [videoId]
      );
      if (rs.goToFirstRow()) { return this.parseScrapeInfoEntity(rs); }
      return null;
    } catch { return null; } finally { try { rs?.close(); } catch { } }
  }

  /** 清理孤立 scrape_info（video_id 不在 videos 表中），由历史 INSERT OR REPLACE 产生 */
  async cleanupOrphanedScrapeInfo(): Promise<void> {
    if (!this.core.isReady()) { return; }
    const store = this.core.getStore();
    try {
      await store.executeSql(
        `DELETE FROM ${TABLE_SCRAPE_INFO} WHERE video_id NOT IN (SELECT id FROM ${TABLE_VIDEOS})`
      );
      console.info('[DB] cleanupOrphanedScrapeInfo 完成');
    } catch (e) {
      console.warn(`[DB] cleanupOrphanedScrapeInfo 失败: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 全量覆盖模式专用：清空指定文件源下所有视频的 scrape_info，
   * 确保重刮前无历史垃圾数据干扰。
   */
  async clearScrapeInfoForSources(sourceIds: number[]): Promise<void> {
    if (!this.core.isReady() || sourceIds.length === 0) { return; }
    const store = this.core.getStore();
    try {
      const placeholders = sourceIds.map(() => '?').join(',');
      const args: relationalStore.ValueType[] = [];
      for (const id of sourceIds) {
        args.push(id);
      }
      await store.executeSql(
        `DELETE FROM ${TABLE_SCRAPE_INFO}
         WHERE video_id IN (
           SELECT id FROM ${TABLE_VIDEOS} WHERE source_id IN (${placeholders})
         )`,
        args
      );
      console.info(`[DB] clearScrapeInfoForSources 完成 sourceIds=[${sourceIds.join(',')}]`);
    } catch (e) {
      console.warn(`[DB] clearScrapeInfoForSources 失败: ${JSON.stringify(e)}`);
    }
  }

  /** 查询 scrape_info 中某剧已刮削的所有季号（用于季列表过滤） */
  async getScrapedSeasonNumbers(tvSeriesId: number): Promise<number[]> {
    if (!this.core.isReady()) { return []; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      const pred = new relationalStore.RdbPredicates(TABLE_SCRAPE_INFO);
      pred.equalTo('tv_series_id', tvSeriesId).and().isNotNull('season_number');
      rs = await store.query(pred, ['season_number']);
      const nums: number[] = [];
      while (rs.goToNextRow()) {
        const n = rs.getLong(rs.getColumnIndex('season_number'));
        if (nums.indexOf(n) < 0) { nums.push(n); }
      }
      return nums;
    } catch { return []; } finally { try { rs?.close(); } catch { } }
  }

  async upsertScrapeInfo(e: ScrapeInfoEntity): Promise<void> {
    const store = this.core.getStore();
    try {
    // 先查 video_id 是否已有 scrape_info，有则 UPDATE（不依赖 provider+provider_id 唯一索引）
    const existing = await this.getScrapeInfoByVideoId(e.videoId);
    if (existing && existing.id !== undefined) {
      const bucket: relationalStore.ValuesBucket = {
        provider: e.provider,
        provider_id: e.providerId,
        media_type: e.mediaType,
        title: e.title,
        original_title: e.originalTitle ?? null,
        movie_id: e.movieId !== undefined ? e.movieId : null,
        tv_series_id: e.tvSeriesId !== undefined ? e.tvSeriesId : null,
        episode_id: e.episodeId !== undefined ? e.episodeId : null,
        season_number: e.seasonNumber !== undefined ? e.seasonNumber : null,
        episode_number: e.episodeNumber !== undefined ? e.episodeNumber : null,
        scraped_at: e.scrapedAt
      };
      const pred = new relationalStore.RdbPredicates(TABLE_SCRAPE_INFO);
      pred.equalTo('id', existing.id);
      await store.update(bucket, pred);
      return;
    }
    const sql = `
      INSERT OR IGNORE INTO ${TABLE_SCRAPE_INFO}
        (video_id, provider, provider_id, media_type, title, original_title,
         movie_id, tv_series_id, episode_id, season_number, episode_number, scraped_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `;
    const args: relationalStore.ValueType[] = [
      e.videoId,
      e.provider,
      e.providerId,
      e.mediaType,
      e.title,
      e.originalTitle ?? null,
      e.movieId !== undefined ? e.movieId : null,
      e.tvSeriesId !== undefined ? e.tvSeriesId : null,
      e.episodeId !== undefined ? e.episodeId : null,
      e.seasonNumber !== undefined ? e.seasonNumber : null,
      e.episodeNumber !== undefined ? e.episodeNumber : null,
      e.scrapedAt
    ];
    await store.executeSql(sql, args);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `upsertScrapeInfo 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }

  /** 删除指定 tv_series_id 下所有 scrape_info，再级联清理孤立媒体数据 */
  async clearScrapeInfoByTvSeriesId(tvSeriesId: number): Promise<void> {
    if (!this.core.isReady()) { return; }
    const store = this.core.getStore();
    try {
      const pred = new relationalStore.RdbPredicates(TABLE_SCRAPE_INFO);
      pred.equalTo('tv_series_id', tvSeriesId);
      await store.delete(pred);
      await this.cleanupOrphanScrapeMedia();
      console.info(`[DB][clearScrapeInfoByTvSeriesId] tvSeriesId=${tvSeriesId} 已清理`);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `clearScrapeInfoByTvSeriesId 失败: ${err.message}`);
    }
  }

  async clearScrapeInfoForVideo(videoId: number): Promise<void> {
    const store = this.core.getStore();
    try {
      const pred = new relationalStore.RdbPredicates(TABLE_SCRAPE_INFO);
      pred.equalTo('video_id', videoId);
      await store.delete(pred);
      await this.cleanupOrphanScrapeMedia();
      console.info(`[DB][clearScrapeInfoForVideo] videoId=${videoId} 已清理旧关联`);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `clearScrapeInfoForVideo 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }

  async cleanupOrphanScrapeMedia(): Promise<void> {
    if (!this.core.isReady()) { return; }
    const store = this.core.getStore();
    try {
      await store.executeSql(
      `DELETE FROM ${TABLE_TV_EPISODES} AS te ` +
      `WHERE NOT EXISTS (` +
      `  SELECT 1 FROM ${TABLE_SCRAPE_INFO} AS si ` +
      `  WHERE si.episode_id = te.id` +
      `)`
    );
    await store.executeSql(
      `DELETE FROM ${TABLE_TV_SEASONS} AS tsn ` +
      `WHERE NOT EXISTS (` +
      `  SELECT 1 FROM ${TABLE_TV_EPISODES} AS te ` +
      `  WHERE te.season_id = tsn.id` +
      `) AND NOT EXISTS (` +
      `  SELECT 1 FROM ${TABLE_SCRAPE_INFO} AS si ` +
      `  WHERE si.tv_series_id = tsn.series_id AND si.season_number = tsn.season_number` +
      `)`
    );
    await store.executeSql(
      `DELETE FROM ${TABLE_TV_SERIES} AS ts ` +
      `WHERE NOT EXISTS (` +
      `  SELECT 1 FROM ${TABLE_SCRAPE_INFO} AS si ` +
      `  WHERE si.tv_series_id = ts.id` +
      `)`
    );
    await store.executeSql(
      `DELETE FROM ${TABLE_MOVIES} AS m ` +
      `WHERE NOT EXISTS (` +
      `  SELECT 1 FROM ${TABLE_SCRAPE_INFO} AS si ` +
      `  WHERE si.movie_id = m.id` +
      `)`
    );
    } catch (e) {
      const error = e as BusinessError;
      hilog.warn(0x0000, 'FileSourceDatabase', `cleanupOrphanScrapeMedia: ${error.message}`);
      throw new Error(error.message);
    }
  }

  private parseScrapeInfoEntity(rs: relationalStore.ResultSet): ScrapeInfoEntity {
    try {
    const num = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getLong(i); };
    const str = (col: string): string | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getString(i); };
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      videoId: rs.getLong(rs.getColumnIndex('video_id')),
      provider: rs.getString(rs.getColumnIndex('provider')),
      providerId: rs.getString(rs.getColumnIndex('provider_id')),
      mediaType: rs.getString(rs.getColumnIndex('media_type')),
      title: rs.getString(rs.getColumnIndex('title')),
      originalTitle: str('original_title'),
      movieId: num('movie_id'), tvSeriesId: num('tv_series_id'),
      episodeId: num('episode_id'), seasonNumber: num('season_number'),
      episodeNumber: num('episode_number'),
      scrapedAt: rs.getLong(rs.getColumnIndex('scraped_at'))
    };
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `parseScrapeInfoEntity 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }
}
