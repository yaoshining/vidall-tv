import relationalStore from '@ohos.data.relationalStore';
import { PlayProgressEntity, MediaProgressEntry } from '../models/MediaEntity';
import { BusinessError } from "@kit.BasicServicesKit";
import { TABLE_PLAY_PROGRESS, TABLE_MEDIA_PROGRESS } from './DbConstants';
import { FileSourceDbCore } from './FileSourceDbCore';

/**
 * play_progress 与 media_progress 表的数据访问。
 * 拆分自 FileSourceDatabase，保持原方法签名与行为不变。
 */
export class PlayProgressDao {
  private core: FileSourceDbCore;

  constructor(core: FileSourceDbCore) {
    this.core = core;
  }

  /**
   * 写入或更新播放进度（以 video_id 为唯一键，INSERT OR REPLACE）。
   * 写入失败仅打 warn 日志，不抛出异常，不阻塞播放。
   */
  async upsertPlayProgress(progress: PlayProgressEntity): Promise<void> {
    if (!this.core.isReady()) {
      console.warn('[DB][upsertPlayProgress] DB 未初始化，跳过写入');
      return;
    }
    const store = this.core.getStore();
    try {
      const sql = `
        INSERT OR REPLACE INTO ${TABLE_PLAY_PROGRESS}
          (video_id, series_provider_id, season_number, episode_number,
           position_ms, duration_ms, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      `;
      const args: relationalStore.ValueType[] = [
        progress.videoId,
        progress.seriesProviderId,
        progress.seasonNumber,
        progress.episodeNumber,
        progress.positionMs,
        progress.durationMs,
        progress.updatedAt
      ];
      await store.executeSql(sql, args);
      console.info(
        `[DB][upsertPlayProgress] videoId=${progress.videoId} pos=${progress.positionMs}ms ` +
        `series=${progress.seriesProviderId} s${progress.seasonNumber}e${progress.episodeNumber}`
      );
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][upsertPlayProgress] 写入失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 查询指定视频的播放进度，不存在返回 null。
   */
  async getPlayProgress(videoId: number): Promise<PlayProgressEntity | null> {
    if (!this.core.isReady()) { return null; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      const pred = new relationalStore.RdbPredicates(TABLE_PLAY_PROGRESS);
      pred.equalTo('video_id', videoId);
      rs = await store.query(pred);
      if (rs.goToFirstRow()) {
        return this.parsePlayProgressEntity(rs);
      }
      return null;
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][getPlayProgress] 查询失败 videoId=${videoId} code=${err.code} msg=${err.message}`);
      return null;
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /**
   * 批量查询某剧某季的播放进度列表（避免逐集查询）。
   */
  async getPlayProgressBySeriesContext(
    seriesProviderId: string,
    seasonNumber: number
  ): Promise<PlayProgressEntity[]> {
    if (!this.core.isReady()) { return []; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      const pred = new relationalStore.RdbPredicates(TABLE_PLAY_PROGRESS);
      pred.equalTo('series_provider_id', seriesProviderId)
        .and()
        .equalTo('season_number', seasonNumber);
      rs = await store.query(pred);
      const list: PlayProgressEntity[] = [];
      while (rs.goToNextRow()) {
        list.push(this.parsePlayProgressEntity(rs));
      }
      return list;
    } catch (error) {
      const err = error as BusinessError;
      console.warn(
        `[DB][getPlayProgressBySeriesContext] 查询失败 series=${seriesProviderId} s=${seasonNumber} ` +
        `code=${err.code} msg=${err.message}`
      );
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /**
   * 查询某剧所有进度记录（用于 ContinueWatchingCard 展示最近播放集）。
   */
  async getPlayProgressBySeries(seriesProviderId: string): Promise<PlayProgressEntity[]> {
    if (!this.core.isReady()) { return []; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      const pred = new relationalStore.RdbPredicates(TABLE_PLAY_PROGRESS);
      pred.equalTo('series_provider_id', seriesProviderId).orderByDesc('updated_at');
      rs = await store.query(pred);
      const list: PlayProgressEntity[] = [];
      while (rs.goToNextRow()) {
        list.push(this.parsePlayProgressEntity(rs));
      }
      return list;
    } catch (error) {
      const err = error as BusinessError;
      console.warn(
        `[DB][getPlayProgressBySeries] 查询失败 series=${seriesProviderId} ` +
        `code=${err.code} msg=${err.message}`
      );
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  private parsePlayProgressEntity(rs: relationalStore.ResultSet): PlayProgressEntity {
    const num = (col: string): number => {
      const i = rs.getColumnIndex(col);
      return rs.isColumnNull(i) ? 0 : rs.getLong(i);
    };
    const str = (col: string): string => {
      const i = rs.getColumnIndex(col);
      return rs.isColumnNull(i) ? '' : rs.getString(i);
    };
    return {
      id: num('id'),
      videoId: num('video_id'),
      seriesProviderId: str('series_provider_id'),
      seasonNumber: num('season_number'),
      episodeNumber: num('episode_number'),
      positionMs: num('position_ms'),
      durationMs: num('duration_ms'),
      updatedAt: num('updated_at')
    };
  }

  /**
   * 写入或更新媒体级播放进度（以 media_key 为主键，INSERT OR REPLACE）。
   * 写入失败仅打 warn，不抛出异常，不阻塞调用方。
   */
  async upsertMediaProgress(entry: MediaProgressEntry): Promise<void> {
    if (!this.core.isReady()) {
      console.warn('[DB][upsertMediaProgress] DB 未初始化，跳过写入');
      return;
    }
    const store = this.core.getStore();
    try {
      const sql = `
        INSERT OR REPLACE INTO ${TABLE_MEDIA_PROGRESS}
          (media_key, position_ms, duration_ms, last_played_at, episode_number, season_number, is_watched)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      `;
      const args: relationalStore.ValueType[] = [
        entry.mediaKey,
        entry.positionMs,
        entry.durationMs,
        entry.lastPlayedAt,
        entry.episodeNumber,
        entry.seasonNumber,
        entry.isWatched ?? 0
      ];
      await store.executeSql(sql, args);
      console.info(
        `[DB][upsertMediaProgress] key=${entry.mediaKey} pos=${entry.positionMs}ms ` +
        `s${entry.seasonNumber}e${entry.episodeNumber}`
      );
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][upsertMediaProgress] 写入失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 查询媒体级播放进度，不存在返回 null。
   */
  async getMediaProgress(mediaKey: string): Promise<MediaProgressEntry | null> {
    if (!this.core.isReady()) {
      return null;
    }
    const store = this.core.getStore();
    try {
      const pred = new relationalStore.RdbPredicates(TABLE_MEDIA_PROGRESS);
      pred.equalTo('media_key', mediaKey);
      const rs = await store.query(pred, [
        'media_key', 'position_ms', 'duration_ms', 'last_played_at',
        'episode_number', 'season_number', 'is_watched'
      ]);
      if (!rs.goToFirstRow()) {
        rs.close();
        return null;
      }
      const entry = new MediaProgressEntry(
        rs.getString(rs.getColumnIndex('media_key')),
        rs.getLong(rs.getColumnIndex('position_ms')),
        rs.getLong(rs.getColumnIndex('duration_ms')),
        rs.getLong(rs.getColumnIndex('last_played_at')),
        rs.getLong(rs.getColumnIndex('season_number')),
        rs.getLong(rs.getColumnIndex('episode_number'))
      );
      entry.isWatched = rs.getLong(rs.getColumnIndex('is_watched'));
      rs.close();
      return entry;
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][getMediaProgress] 查询失败 code=${err.code} msg=${err.message}`);
      return null;
    }
  }

  /**
   * 删除媒体级播放进度（完播重置）。
   */
  async clearMediaProgress(mediaKey: string): Promise<void> {
    if (!this.core.isReady()) {
      return;
    }
    const store = this.core.getStore();
    try {
      const pred = new relationalStore.RdbPredicates(TABLE_MEDIA_PROGRESS);
      pred.equalTo('media_key', mediaKey);
      await store.delete(pred);
      console.info(`[DB][clearMediaProgress] key=${mediaKey} 已清除`);
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][clearMediaProgress] 删除失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 删除指定剧集所有集的进度记录。
   * 匹配所有 media_key 以 media_progress_episode_tmdb_{seriesTmdbId}_ 开头的记录。
   * @param seriesTmdbId 剧集 TMDB ID（如 "1399"），不含下划线等特殊字符
   */
  async clearAllMediaProgressBySeries(seriesTmdbId: string): Promise<void> {
    if (!this.core.isReady()) {
      return;
    }
    const store = this.core.getStore();
    if (!/^\d+$/.test(seriesTmdbId)) {
      console.warn(`[DB][clearAllMediaProgressBySeries] 非法 seriesTmdbId: ${seriesTmdbId}`);
      return;
    }
    try {
      // 同时清除新格式（集级 key）和旧格式（整剧级 key），确保历史迁移数据也能被删除
      const episodePrefix = `media_progress_episode_tmdb_${seriesTmdbId}_`;
      const oldKey = `media_progress_series_tmdb_${seriesTmdbId}`;
      const sql =
        `DELETE FROM ${TABLE_MEDIA_PROGRESS}` +
        ` WHERE media_key LIKE ? OR media_key = ?`;
      await store.executeSql(sql, [`${episodePrefix}%`, oldKey]);
      console.info(`[DB][clearAllMediaProgressBySeries] seriesTmdbId=${seriesTmdbId} 已全部清除（含旧格式）`);
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][clearAllMediaProgressBySeries] 删除失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 将指定媒体标记为已完播（is_watched = 1）。
   * - 若记录已存在：UPDATE，同时将 position_ms 推进到 duration_ms（完播状态）。
   * - 若记录不存在（从未播放过）：INSERT 一条哨兵记录（is_watched = 1，时长未知为 0）。
   * 两步操作均幂等，重复调用安全。
   * @param mediaKey 媒体进度存储 key
   */
  async markAsWatched(mediaKey: string): Promise<void> {
    if (!this.core.isReady()) {
      return;
    }
    const store = this.core.getStore();
    try {
      // 步骤 1：UPDATE 已有记录（设置完播标记，position_ms 推进到 duration_ms）
      const updateSql =
        `UPDATE ${TABLE_MEDIA_PROGRESS}` +
        ` SET is_watched = 1,` +
        `     position_ms = CASE WHEN duration_ms > 0 THEN duration_ms ELSE position_ms END,` +
        `     last_played_at = ?` +
        ` WHERE media_key = ?`;
      await store.executeSql(updateSql, [Date.now(), mediaKey]);
      // 步骤 2：INSERT OR IGNORE（记录不存在时插入哨兵行；若已 UPDATE 成功则 IGNORE 保留原行）
      const insertSql =
        `INSERT OR IGNORE INTO ${TABLE_MEDIA_PROGRESS}` +
        ` (media_key, position_ms, duration_ms, last_played_at, episode_number, season_number, is_watched)` +
        ` VALUES (?, 0, 0, ?, 0, 0, 1)`;
      await store.executeSql(insertSql, [mediaKey, Date.now()]);
      console.info(`[DB][markAsWatched] key=${mediaKey} 已标记完播`);
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][markAsWatched] 失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 将指定剧集所有集的进度记录标记为已完播（is_watched = 1）。
   * 仅 UPDATE 已有记录；对从未播放过的剧集，调用方应按需单独处理。
   * @param seriesTmdbId 剧集 TMDB ID（如 "1399"），纯数字
   */
  async markAllSeriesWatched(seriesTmdbId: string): Promise<void> {
    if (!this.core.isReady()) {
      return;
    }
    const store = this.core.getStore();
    if (!/^\d+$/.test(seriesTmdbId)) {
      console.warn(`[DB][markAllSeriesWatched] 非法 seriesTmdbId: ${seriesTmdbId}`);
      return;
    }
    try {
      const episodePrefix = `media_progress_episode_tmdb_${seriesTmdbId}_`;
      const oldKey = `media_progress_series_tmdb_${seriesTmdbId}`;
      const sql =
        `UPDATE ${TABLE_MEDIA_PROGRESS}` +
        ` SET is_watched = 1,` +
        `     position_ms = CASE WHEN duration_ms > 0 THEN duration_ms ELSE position_ms END,` +
        `     last_played_at = ?` +
        ` WHERE media_key LIKE ? OR media_key = ?`;
      await store.executeSql(sql, [Date.now(), `${episodePrefix}%`, oldKey]);
      console.info(`[DB][markAllSeriesWatched] seriesTmdbId=${seriesTmdbId} 所有集已标记完播`);
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][markAllSeriesWatched] 失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 查询指定剧集最近播放的一集进度。
   * @param seriesTmdbId 剧集 TMDB ID，如 "1399"
   */
  async getLatestMediaProgressBySeries(seriesTmdbId: string): Promise<MediaProgressEntry | null> {
    if (!this.core.isReady()) {
      return null;
    }
    const store = this.core.getStore();
    if (!/^\d+$/.test(seriesTmdbId)) {
      console.warn(`[DB][getLatestMediaProgressBySeries] 非法 seriesTmdbId: ${seriesTmdbId}`);
      return null;
    }
    let rs: relationalStore.ResultSet | null = null;
    try {
      const episodePrefix = `media_progress_episode_tmdb_${seriesTmdbId}_`;
      const oldKey = `media_progress_series_tmdb_${seriesTmdbId}`;
      // 同时查新旧格式，取最近播放的一条
      const sql =
        `SELECT media_key, position_ms, duration_ms, last_played_at, episode_number, season_number, is_watched` +
        ` FROM ${TABLE_MEDIA_PROGRESS}` +
        ` WHERE media_key LIKE ? OR media_key = ?` +
        ` ORDER BY last_played_at DESC LIMIT 1`;
      rs = await store.querySql(sql, [`${episodePrefix}%`, oldKey]);
      if (rs.goToNextRow()) {
        const entry = new MediaProgressEntry(
          rs.getString(rs.getColumnIndex('media_key')),
          rs.getLong(rs.getColumnIndex('position_ms')),
          rs.getLong(rs.getColumnIndex('duration_ms')),
          rs.getLong(rs.getColumnIndex('last_played_at')),
          rs.getLong(rs.getColumnIndex('season_number')),
          rs.getLong(rs.getColumnIndex('episode_number'))
        );
        entry.isWatched = rs.getLong(rs.getColumnIndex('is_watched'));
        return entry;
      }
      return null;
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[DB][getLatestMediaProgressBySeries] 查询失败 code=${err.code} msg=${err.message}`);
      return null;
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /**
   * 查询全部媒体级播放进度，按最近播放时间倒序返回。
   * 用于「继续播放」栏数据源。
   */
  async getAllMediaProgress(limit: number = 40): Promise<MediaProgressEntry[]> {
    if (!this.core.isReady()) {
      return [];
    }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      // limit 为数字类型，不存在注入风险；默认 40 用于「继续播放」栏，历史页可传 200
      const sql =
        `SELECT media_key, position_ms, duration_ms, last_played_at, episode_number, season_number, is_watched` +
        ` FROM ${TABLE_MEDIA_PROGRESS}` +
        ` ORDER BY last_played_at DESC LIMIT ${limit}`;
      rs = await store.querySql(sql);
      const result: MediaProgressEntry[] = [];
      while (rs.goToNextRow()) {
        const entry = new MediaProgressEntry(
          rs.getString(rs.getColumnIndex('media_key')),
          rs.getLong(rs.getColumnIndex('position_ms')),
          rs.getLong(rs.getColumnIndex('duration_ms')),
          rs.getLong(rs.getColumnIndex('last_played_at')),
          rs.getLong(rs.getColumnIndex('season_number')),
          rs.getLong(rs.getColumnIndex('episode_number'))
        );
        entry.isWatched = rs.getLong(rs.getColumnIndex('is_watched'));
        result.push(entry);
      }
      console.info(`[DB][getAllMediaProgress] 共 ${result.length} 条记录`);
      return result;
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[DB][getAllMediaProgress] 查询失败 code=${err.code} msg=${err.message}`);
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /**
   * 删除指定剧集在 play_progress 表中的进度记录。
   * @param seriesProviderId 剧集 provider ID（如 TMDB ID 字符串）
   */
  async clearPlayProgressBySeries(seriesProviderId: string): Promise<void> {
    if (!this.core.isReady()) {
      return;
    }
    const store = this.core.getStore();
    try {
      const pred = new relationalStore.RdbPredicates(TABLE_PLAY_PROGRESS);
      pred.equalTo('series_provider_id', seriesProviderId);
      await store.delete(pred);
      console.info(`[DB][clearPlayProgressBySeries] series=${seriesProviderId} 已清除`);
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][clearPlayProgressBySeries] 失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 清空 play_progress 表全部记录（用于"清除全部历史"场景）。
   */
  async clearAllPlayProgress(): Promise<void> {
    if (!this.core.isReady()) {
      return;
    }
    const store = this.core.getStore();
    try {
      await store.executeSql(
        `DELETE FROM ${TABLE_PLAY_PROGRESS}`
      );
      console.info('[DB][clearAllPlayProgress] 全部已清除');
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`[DB][clearAllPlayProgress] 失败 code=${err.code} msg=${err.message}`);
    }
  }
}
