import relationalStore from '@ohos.data.relationalStore';
import { VideoEntity } from '../models/MediaEntity';
import { BusinessError } from "@kit.BasicServicesKit";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TABLE_VIDEOS, TABLE_SCRAPE_INFO, TABLE_PLAY_PROGRESS } from './DbConstants';
import { FileSourceDbCore } from './FileSourceDbCore';

/**
 * videos 表的数据访问（含鬼记录清理与扫描时间查询）。
 * 拆分自 FileSourceDatabase，保持原方法签名与行为不变。
 */
export class VideoDao {
  private core: FileSourceDbCore;

  constructor(core: FileSourceDbCore) {
    this.core = core;
  }

  /**
   * 插入或更新视频记录（以 file_path 为唯一键）
   * @returns 视频的 id
   */
  async upsertVideo(entity: VideoEntity): Promise<number> {
    const store = this.core.getStore();
    try {
      // 先查是否已存在，有则 UPDATE（保留原始 id，避免外键级联删除 scrape_info）
      const existing = await this.getVideoByPath(entity.filePath);
      if (existing && existing.id !== undefined) {
        const bucket: relationalStore.ValuesBucket = {
          source_id: entity.sourceId,
          directory_path: entity.directoryPath,
          file_name: entity.fileName,
          file_size: entity.fileSize !== undefined ? entity.fileSize : null,
          last_modified: entity.lastModified ?? null,
          content_type: entity.contentType ?? null,
          duration_ms: entity.durationMs !== undefined ? entity.durationMs : null,
          width: entity.width !== undefined ? entity.width : null,
          height: entity.height !== undefined ? entity.height : null,
          frame_rate: entity.frameRate !== undefined ? entity.frameRate : null,
          video_codec: entity.videoCodec ?? null,
          audio_tracks_json: entity.audioTracksJson ?? null,
          subtitle_tracks_json: entity.subtitleTracksJson ?? null,
          updated_in_last_scan: 1,
          scanned_at: entity.scannedAt
        };
        const pred = new relationalStore.RdbPredicates(TABLE_VIDEOS);
        pred.equalTo('id', existing.id);
        await store.update(bucket, pred);
        console.info(`[FileSourceDatabase] upsertVideo UPDATE id=${existing.id} path=${entity.filePath}`);
        return existing.id;
      }
      // 新文件 INSERT
      const sql = `
        INSERT OR IGNORE INTO ${TABLE_VIDEOS}
          (source_id, directory_path, file_path, file_name, file_size, last_modified,
           content_type, duration_ms, width, height, frame_rate, video_codec,
           audio_tracks_json, subtitle_tracks_json, updated_in_last_scan, scanned_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      `;
      const args: relationalStore.ValueType[] = [
        entity.sourceId, entity.directoryPath, entity.filePath, entity.fileName,
        entity.fileSize !== undefined ? entity.fileSize : null,
        entity.lastModified ?? null, entity.contentType ?? null,
        entity.durationMs !== undefined ? entity.durationMs : null,
        entity.width !== undefined ? entity.width : null,
        entity.height !== undefined ? entity.height : null,
        entity.frameRate !== undefined ? entity.frameRate : null,
        entity.videoCodec ?? null,
        entity.audioTracksJson ?? null,
        entity.subtitleTracksJson ?? null,
        1,
        entity.scannedAt
      ];
      await store.executeSql(sql, args);
      const inserted = await this.getVideoByPath(entity.filePath);
      const fallbackId = await this.core.querySingleIdValue(
        `SELECT id FROM ${TABLE_VIDEOS} WHERE file_path = ? LIMIT 1`,
        [entity.filePath]
      );
      const rowId = inserted?.id ?? (fallbackId > 0 ? fallbackId : await this.core.lastInsertedRowId());
      console.info(`[FileSourceDatabase] upsertVideo INSERT id=${rowId} path=${entity.filePath}`);
      return rowId;
    } catch (error) {
      console.error(`[FileSourceDatabase] upsertVideo 失败: ${JSON.stringify(error)}`);
      throw new Error('upsertVideo failed: ' + JSON.stringify(error));
    }
  }

  /** 按 filePath 查询视频记录 */
  async getVideoByPath(filePath: string): Promise<VideoEntity | null> {
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(
        `SELECT * FROM ${TABLE_VIDEOS} WHERE file_path = ? LIMIT 1`,
        [filePath]
      );
      if (rs.goToFirstRow()) {
        return this.parseVideoEntity(rs);
      }
      return null;
    } catch (error) {
      console.error(`[FileSourceDatabase] getVideoByPath 失败: ${JSON.stringify(error)}`);
      return null;
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /** 按主键 id 查询单条视频记录 */
  async getVideoById(videoId: number): Promise<VideoEntity | null> {
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(
        `SELECT * FROM ${TABLE_VIDEOS} WHERE id = ? LIMIT 1`,
        [videoId]
      );
      if (rs.goToFirstRow()) {
        return this.parseVideoEntity(rs);
      }
      return null;
    } catch (error) {
      console.error(`[FileSourceDatabase] getVideoById 失败: ${JSON.stringify(error)}`);
      return null;
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /** 按 sourceId 查询该文件源下所有视频 */
  async getVideosBySourceId(sourceId: number): Promise<VideoEntity[]> {
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      const pred = new relationalStore.RdbPredicates(TABLE_VIDEOS);
      pred.equalTo('source_id', sourceId);
      rs = await store.query(pred);
      const list: VideoEntity[] = [];
      while (rs.goToNextRow()) {
        list.push(this.parseVideoEntity(rs));
      }
      return list;
    } catch (error) {
      console.error(`[FileSourceDatabase] getVideosBySourceId 失败: ${JSON.stringify(error)}`);
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /** 按电影关联查询视频，结果按视频主键稳定排序 */
  async getVideosByMovieId(movieId: number): Promise<VideoEntity[]> {
    return this.queryVideosByScrapeRelation('si.movie_id = ?', [movieId]);
  }

  /** 按系列关联查询视频，结果按视频主键稳定排序 */
  async getVideosByTvSeriesId(tvSeriesId: number): Promise<VideoEntity[]> {
    return this.queryVideosByScrapeRelation('si.tv_series_id = ?', [tvSeriesId]);
  }

  /** 按系列和季号查询视频，结果按视频主键稳定排序 */
  async getVideosBySeason(tvSeriesId: number, seasonNumber: number): Promise<VideoEntity[]> {
    return this.queryVideosByScrapeRelation(
      'si.tv_series_id = ? AND si.season_number = ?',
      [tvSeriesId, seasonNumber]
    );
  }

  /**
   * 查询文件夹本身及所有子目录中的视频。
   * 使用分隔符边界匹配，避免 /movie 误包含 /movie-old。
   */
  async getVideosByDirectoryTree(sourceId: number, directoryPath: string): Promise<VideoEntity[]> {
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      // 目录边界匹配：file_path 以 directoryPath + '/' 开头，或 directory_path 等于 directoryPath / 以其 + '/' 开头。
      // 同时匹配 file_path 与 directory_path，以兼容历史数据（directory_path 曾存扫描根目录，file_path 才是文件完整路径）。
      rs = await store.querySql(
        `SELECT * FROM ${TABLE_VIDEOS}
         WHERE source_id = ?
           AND (
             directory_path = ?
             OR substr(directory_path, 1, length(?) + 1) = ? || '/'
             OR substr(file_path, 1, length(?) + 1) = ? || '/'
           )
         ORDER BY id ASC`,
        [sourceId, directoryPath, directoryPath, directoryPath, directoryPath, directoryPath]
      );
      return this.collectVideos(rs);
    } catch (error) {
      console.error(`[FileSourceDatabase] getVideosByDirectoryTree 失败: ${JSON.stringify(error)}`);
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /** 获取所有视频 */
  async getAllVideos(): Promise<VideoEntity[]> {
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      const pred = new relationalStore.RdbPredicates(TABLE_VIDEOS);
      rs = await store.query(pred);
      const list: VideoEntity[] = [];
      while (rs.goToNextRow()) {
        list.push(this.parseVideoEntity(rs));
      }
      return list;
    } catch (error) {
      console.error(`[FileSourceDatabase] getAllVideos 失败: ${JSON.stringify(error)}`);
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /** 扫描前重置更新标记，扫描中命中的视频会在 upsert 时置为 1 */
  async resetVideoUpdatedFlags(): Promise<void> {
    const store = this.core.getStore();
    try {
      await store.executeSql(
        `UPDATE ${TABLE_VIDEOS} SET updated_in_last_scan = 0`
      );
      console.info('[FileSourceDatabase] resetVideoUpdatedFlags 完成');
    } catch (error) {
      console.warn(`[FileSourceDatabase] resetVideoUpdatedFlags 失败: ${JSON.stringify(error)}`);
    }
  }

  /** 将已存在的视频标记为本轮扫描命中，用于增量扫描跳过未变化文件时置位 */
  async markVideoUpdatedByPath(filePath: string): Promise<void> {
    const store = this.core.getStore();
    try {
      await store.executeSql(
        `UPDATE ${TABLE_VIDEOS} SET updated_in_last_scan = 1 WHERE file_path = ?`,
        [filePath]
      );
    } catch (error) {
      console.warn(`[FileSourceDatabase] markVideoUpdatedByPath 失败 path=${filePath}: ${JSON.stringify(error)}`);
    }
  }

  private async queryVideosByScrapeRelation(
    relationWhere: string,
    args: relationalStore.ValueType[]
  ): Promise<VideoEntity[]> {
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(
        `SELECT v.* FROM ${TABLE_VIDEOS} AS v
         INNER JOIN ${TABLE_SCRAPE_INFO} AS si ON si.video_id = v.id
         WHERE ${relationWhere}
         ORDER BY v.id ASC`,
        args
      );
      return this.collectVideos(rs);
    } catch (error) {
      console.error(`[FileSourceDatabase] queryVideosByScrapeRelation 失败: ${JSON.stringify(error)}`);
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  private collectVideos(rs: relationalStore.ResultSet): VideoEntity[] {
    const videos: VideoEntity[] = [];
    while (rs.goToNextRow()) {
      videos.push(this.parseVideoEntity(rs));
    }
    return videos;
  }

  private parseVideoEntity(rs: relationalStore.ResultSet): VideoEntity {
    try {
    const get = (col: string): number => rs.getLong(rs.getColumnIndex(col));
    const str = (col: string): string | undefined => {
      const idx = rs.getColumnIndex(col);
      return rs.isColumnNull(idx) ? undefined : rs.getString(idx);
    };
    const num = (col: string): number | undefined => {
      const idx = rs.getColumnIndex(col);
      return rs.isColumnNull(idx) ? undefined : rs.getLong(idx);
    };
    const dbl = (col: string): number | undefined => {
      const idx = rs.getColumnIndex(col);
      return rs.isColumnNull(idx) ? undefined : rs.getDouble(idx);
    };
    return {
      id: get('id'),
      sourceId: get('source_id'),
      directoryPath: rs.getString(rs.getColumnIndex('directory_path')),
      filePath: rs.getString(rs.getColumnIndex('file_path')),
      fileName: rs.getString(rs.getColumnIndex('file_name')),
      fileSize: num('file_size'),
      lastModified: str('last_modified'),
      contentType: str('content_type'),
      durationMs: num('duration_ms'),
      width: num('width'),
      height: num('height'),
      frameRate: dbl('frame_rate'),
      videoCodec: str('video_codec'),
      audioTracksJson: str('audio_tracks_json'),
      subtitleTracksJson: str('subtitle_tracks_json'),
      updatedInLastScan: num('updated_in_last_scan'),
      scannedAt: get('scanned_at')
    };
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `parseVideoEntity 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }

  /**
   * 全量覆盖扫描完成后，删除指定文件源中不再存在的鬼记录（旧扫描遗留、现已不在 NAS 上的视频）。
   * foundPaths：本轮扫描写入 DB 的 file_path 集合。
   * 注意：SQLite 外键未启用，需显式删除 scrape_info（overwrite 模式下已由 clearScrapeInfoForSources 预清空）。
   */
  async deleteGhostVideosForSources(sourceIds: number[], foundPaths: string[]): Promise<number> {
    if (!this.core.isReady() || sourceIds.length === 0) { return 0; }
    const store = this.core.getStore();
    try {
      const foundPathsSet = new Set<string>(foundPaths);
      const sidHolders = sourceIds.map(() => '?').join(', ');
      const sidArgs: relationalStore.ValueType[] = sourceIds.map(id => id as relationalStore.ValueType);

      // 1. 查询这些文件源的所有视频记录
      const rs = await store.querySql(
        `SELECT id, file_path FROM ${TABLE_VIDEOS} WHERE source_id IN (${sidHolders})`,
        sidArgs
      );
      const ghostIds: number[] = [];
      while (rs.goToNextRow()) {
        const filePath = rs.getString(rs.getColumnIndex('file_path'));
        const id = rs.getLong(rs.getColumnIndex('id'));
        if (!foundPathsSet.has(filePath)) {
          ghostIds.push(id);
        }
      }
      rs.close();

      if (ghostIds.length === 0) {
        console.info(`[DB][deleteGhostVideos] 无鬼记录，无需清理`);
        return 0;
      }

      // 2. 分批删除（SQLite IN 参数上限 999）
      const BATCH = 100;
      for (let i = 0; i < ghostIds.length; i += BATCH) {
        const batch = ghostIds.slice(i, i + BATCH);
        const idHolders = batch.map(() => '?').join(', ');
        const idArgs: relationalStore.ValueType[] = batch.map(gid => gid as relationalStore.ValueType);
        // 先删 scrape_info（无外键 CASCADE）
        await store.executeSql(
          `DELETE FROM ${TABLE_SCRAPE_INFO} WHERE video_id IN (${idHolders})`,
          idArgs
        );
        // 再删 videos
        await store.executeSql(
          `DELETE FROM ${TABLE_VIDEOS} WHERE id IN (${idHolders})`,
          idArgs
        );
      }

      console.info(`[DB][deleteGhostVideos] 已清理 ${ghostIds.length} 条鬼记录，source_id IN (${sourceIds})`);
      return ghostIds.length;
    } catch (e) {
      console.warn('[DB][deleteGhostVideos] 清理鬼记录失败: ' + JSON.stringify(e));
      return 0;
    }
  }

  /**
   * 删除单个视频的全部本地记录（scrape_info + play_progress + videos）。
   * 用于"文件已删除/移动"场景，用户确认后清理孤立元数据。
   */
  async deleteVideoWithScrapeInfo(videoId: number): Promise<void> {
    if (!this.core.isReady()) { return; }
    const store = this.core.getStore();
    try {
      const id: relationalStore.ValueType = videoId;
      await store.executeSql(
        `DELETE FROM ${TABLE_SCRAPE_INFO} WHERE video_id = ?`, [id]);
      await store.executeSql(
        `DELETE FROM ${TABLE_PLAY_PROGRESS} WHERE video_id = ?`, [id]);
      await store.executeSql(
        `DELETE FROM ${TABLE_VIDEOS} WHERE id = ?`, [id]);
      console.info(`[DB][deleteVideoWithScrapeInfo] videoId=${videoId} 已删除`);
    } catch (e) {
      console.warn('[DB][deleteVideoWithScrapeInfo] 失败: ' + JSON.stringify(e));
    }
  }

  /**
   * 获取最近一次扫描时间（videos 表中最大 scanned_at）
   * 返回 0 表示未扫描
   */
  async getLatestScanTime(): Promise<number> {
    if (!this.core.isReady()) {
      return 0;
    }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(
        `SELECT MAX(scanned_at) AS latest FROM ${TABLE_VIDEOS}`
      );
      if (rs.goToFirstRow()) {
        const idx = rs.getColumnIndex('latest');
        return rs.isColumnNull(idx) ? 0 : rs.getLong(idx);
      }
      return 0;
    } catch {
      return 0;
    } finally {
      try { rs?.close(); } catch { }
    }
  }
}
