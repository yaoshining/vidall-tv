import relationalStore from '@ohos.data.relationalStore';
import {
  MediaItem, MediaStats, SeriesGroup, MediaListItem, SearchMediaOptions
} from '../models/MediaEntity';
import { BusinessError } from "@kit.BasicServicesKit";
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  TABLE_VIDEOS, TABLE_SCRAPE_INFO, TABLE_MOVIES, TABLE_TV_SERIES,
  TABLE_TV_SEASONS, TABLE_TV_EPISODES, TABLE_MEDIA_PROGRESS
} from './DbConstants';
import { FileSourceDbCore } from './FileSourceDbCore';
import { countSeriesEpisodeRows } from './SeriesGroupCountUtil';

/**
 * 媒体库聚合查询、搜索与流派查询。
 * 拆分自 FileSourceDatabase，保持原方法签名与行为不变。
 */
export class MediaQueryDao {
  private core: FileSourceDbCore;

  constructor(core: FileSourceDbCore) {
    this.core = core;
  }

  /** 公共 SELECT 片段：videos LEFT JOIN scrape_info LEFT JOIN movies/tv_series */
  private get mediaItemSql(): string {
    return `
      SELECT v.id, v.source_id, v.directory_path, v.file_path, v.file_name,
             v.file_size, v.duration_ms, v.width, v.height, v.video_codec,
             v.audio_tracks_json, v.scanned_at,
             s.provider, s.provider_id, s.media_type,
             s.movie_id, s.tv_series_id, s.episode_id,
             s.season_number, s.episode_number,
             COALESCE(m.title, ts.title, s.title)                 AS scrape_title,
             COALESCE(m.original_title, ts.original_title)        AS original_title,
             COALESCE(te.overview, m.overview, ts.overview)       AS overview,
             COALESCE(m.release_date, ts.first_air_date)          AS release_date,
             COALESCE(m.rating, ts.rating)                        AS rating,
             COALESCE(m.genres_json, ts.genres_json)              AS genres_json,
             COALESCE(ts.poster_url, m.poster_url)                AS poster_url,
             COALESCE(ts.backdrop_url, m.backdrop_url)            AS backdrop_url,
             COALESCE(ts.poster_local_path, m.poster_local_path)  AS poster_local_path,
             COALESCE(ts.backdrop_local_path, m.backdrop_local_path) AS backdrop_local_path
      FROM ${TABLE_VIDEOS} v
      LEFT JOIN ${TABLE_SCRAPE_INFO} s ON v.id = s.video_id
      LEFT JOIN ${TABLE_MOVIES} m ON s.movie_id = m.id
      LEFT JOIN ${TABLE_TV_SERIES} ts ON s.tv_series_id = ts.id
      LEFT JOIN ${TABLE_TV_EPISODES} te ON s.episode_id = te.id
    `;
  }

  async getAllMediaItems(): Promise<MediaItem[]> {
    if (!this.core.isReady()) { return []; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(this.mediaItemSql + ' ORDER BY v.scanned_at DESC');
      const items: MediaItem[] = [];
      while (rs.goToNextRow()) { items.push(this.parseMediaItem(rs)); }
      // ── 诊断日志 ──
      const withTitle = items.filter(i => i.title !== undefined).length;
      const withPoster = items.filter(i => i.posterUrl !== undefined || i.posterLocalPath !== undefined).length;
      const withRating = items.filter(i => i.rating !== undefined).length;
      const sample = items.slice(0, 3).map(i =>
        `{id=${i.id} type=${i.mediaType ?? 'null'} title=${i.title ?? 'null'} tvSid=${i.tvSeriesId ?? 'null'} movieId=${i.movieId ?? 'null'} rating=${i.rating ?? 'null'} poster=${i.posterUrl ? 'Y' : 'N'}}`
      ).join(', ');
      console.info(`[DB][getAllMediaItems] 总数=${items.length} 有标题=${withTitle} 有海报=${withPoster} 有评分=${withRating}`);
      console.info(`[DB][getAllMediaItems] 采样(前3): ${sample}`);
      return items;
    } catch (e) {
      console.error('[FileSourceDatabase] getAllMediaItems', JSON.stringify(e));
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  async getMediaItemsByType(mediaType: string): Promise<MediaItem[]> {
    if (!this.core.isReady()) { return []; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql = this.mediaItemSql + ' WHERE s.media_type = ? ORDER BY v.scanned_at DESC';
      rs = await store.querySql(sql, [mediaType]);
      const items: MediaItem[] = [];
      while (rs.goToNextRow()) { items.push(this.parseMediaItem(rs)); }
      // ── 诊断日志 ──
      const withPoster = items.filter(i => i.posterUrl !== undefined || i.posterLocalPath !== undefined).length;
      const sample = items.slice(0, 2).map(i =>
        `{id=${i.id} tvSid=${i.tvSeriesId ?? 'null'} title=${i.title ?? 'null'} poster=${i.posterUrl ? 'Y' : 'N'}}`
      ).join(', ');
      console.info(`[DB][getMediaItemsByType('${mediaType}')] 数量=${items.length} 有海报=${withPoster} 采样: ${sample}`);
      return items;
    } catch (e) { console.error('[FileSourceDatabase] getMediaItemsByType', JSON.stringify(e)); return []; } finally { try { rs?.close(); } catch { } }
  }

  async getMediaItemsByRating(): Promise<MediaItem[]> {
    if (!this.core.isReady()) { return []; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql = this.mediaItemSql + ' WHERE COALESCE(m.rating, ts.rating) IS NOT NULL ORDER BY COALESCE(m.rating, ts.rating) DESC';
      rs = await store.querySql(sql);
      const items: MediaItem[] = [];
      while (rs.goToNextRow()) { items.push(this.parseMediaItem(rs)); }
      console.info(`[DB][getMediaItemsByRating] 数量=${items.length} (有评分的视频数)`);
      return items;
    } catch (e) { console.error('[FileSourceDatabase] getMediaItemsByRating', JSON.stringify(e)); return []; } finally { try { rs?.close(); } catch { } }
  }

  async getDistinctReleaseYears(): Promise<string[]> {
    if (!this.core.isReady()) { return []; }
    const store = this.core.getStore();
    try {
      // ── 先诊断 scrape_info / movies / tv_series 的基本数量 ──
      const diagRs = await store.querySql(`SELECT
        (SELECT COUNT(*) FROM ${TABLE_SCRAPE_INFO}) AS si_cnt,
        (SELECT COUNT(*) FROM ${TABLE_MOVIES}) AS m_cnt,
        (SELECT COUNT(*) FROM ${TABLE_TV_SERIES}) AS ts_cnt,
        (SELECT COUNT(*) FROM ${TABLE_TV_SERIES} WHERE first_air_date IS NOT NULL) AS ts_date_cnt,
        (SELECT COUNT(*) FROM ${TABLE_MOVIES} WHERE release_date IS NOT NULL) AS m_date_cnt`);
      if (diagRs.goToFirstRow()) {
        const siCnt = diagRs.getLong(diagRs.getColumnIndex('si_cnt'));
        const mCnt = diagRs.getLong(diagRs.getColumnIndex('m_cnt'));
        const tsCnt = diagRs.getLong(diagRs.getColumnIndex('ts_cnt'));
        const tsDateCnt = diagRs.getLong(diagRs.getColumnIndex('ts_date_cnt'));
        const mDateCnt = diagRs.getLong(diagRs.getColumnIndex('m_date_cnt'));
        console.info(`[DB][诊断] scrape_info=${siCnt} movies=${mCnt}(有日期=${mDateCnt}) tv_series=${tsCnt}(有日期=${tsDateCnt})`);
      }
      diagRs.close();

      // ── 诊断 scrape_info 中 movie_id / tv_series_id 的分布 ──
      const joinRs = await store.querySql(`SELECT
        COUNT(*) AS total,
        SUM(CASE WHEN movie_id IS NOT NULL THEN 1 ELSE 0 END) AS has_movie_id,
        SUM(CASE WHEN tv_series_id IS NOT NULL THEN 1 ELSE 0 END) AS has_tv_series_id,
        SUM(CASE WHEN movie_id IS NULL AND tv_series_id IS NULL THEN 1 ELSE 0 END) AS no_fk
        FROM ${TABLE_SCRAPE_INFO}`);
      if (joinRs.goToFirstRow()) {
        const total = joinRs.getLong(joinRs.getColumnIndex('total'));
        const hasMov = joinRs.getLong(joinRs.getColumnIndex('has_movie_id'));
        const hasTv = joinRs.getLong(joinRs.getColumnIndex('has_tv_series_id'));
        const noFk = joinRs.getLong(joinRs.getColumnIndex('no_fk'));
        console.info(`[DB][诊断] scrape_info: 总=${total} 有movie_id=${hasMov} 有tv_series_id=${hasTv} 无FK=${noFk}`);
      }
      joinRs.close();

      const sql = `
        SELECT DISTINCT substr(COALESCE(m.release_date, ts.first_air_date), 1, 4) AS year
        FROM ${TABLE_SCRAPE_INFO} s
        LEFT JOIN ${TABLE_MOVIES} m ON s.movie_id = m.id
        LEFT JOIN ${TABLE_TV_SERIES} ts ON s.tv_series_id = ts.id
        WHERE COALESCE(m.release_date, ts.first_air_date) IS NOT NULL
        ORDER BY year DESC
      `;
      let rs: relationalStore.ResultSet | null = null;
      try {
        rs = await store.querySql(sql);
        const years: string[] = [];
        while (rs.goToNextRow()) { const y = rs.getString(rs.getColumnIndex('year')); if (y) { years.push(y); } }
        console.info(`[DB][getDistinctReleaseYears] 年份列表: ${JSON.stringify(years)}`);
        return years;
      } finally {
        rs?.close();
      }
    } catch (e) { console.error('[DB][getDistinctReleaseYears] 异常', JSON.stringify(e)); return []; }
  }

  async getMediaItemsByYear(year: string): Promise<MediaItem[]> {
    if (!this.core.isReady()) { return []; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql = this.mediaItemSql + ` WHERE substr(COALESCE(m.release_date, ts.first_air_date), 1, 4) = ? ORDER BY COALESCE(m.release_date, ts.first_air_date) DESC`;
      rs = await store.querySql(sql, [year]);
      const items: MediaItem[] = [];
      while (rs.goToNextRow()) { items.push(this.parseMediaItem(rs)); }
      return items;
    } catch { return []; } finally { try { rs?.close(); } catch { } }
  }

  async getMediaStats(): Promise<MediaStats> {
    if (!this.core.isReady()) { return { total: 0, movies: 0, tv: 0, other: 0 }; }
    const store = this.core.getStore();
    try {
      const q = async (sql: string): Promise<number> => {
        let rs: relationalStore.ResultSet | null = null;
        try {
          rs = await store.querySql(sql);
          rs.goToFirstRow();
          return rs.getLong(rs.getColumnIndex('cnt'));
        } finally {
          rs?.close();
        }
      };
      const total = await q(`SELECT COUNT(*) AS cnt FROM ${TABLE_VIDEOS}`);
      const movies = await q(`SELECT COUNT(DISTINCT movie_id) AS cnt FROM ${TABLE_SCRAPE_INFO} WHERE movie_id IS NOT NULL`);
      const tv = await q(`SELECT COUNT(DISTINCT tv_series_id) AS cnt FROM ${TABLE_SCRAPE_INFO} WHERE tv_series_id IS NOT NULL`);
      const scraped = await q(`SELECT COUNT(DISTINCT video_id) AS cnt FROM ${TABLE_SCRAPE_INFO}`);
      const other = total - scraped;

      // 诊断：打印无刮削记录的文件列表（source_id + file_name）
      if (other > 0) {
        let diagRs: relationalStore.ResultSet | undefined;
        try {
          diagRs = await store.querySql(
            `SELECT v.source_id, v.file_name, v.file_path FROM ${TABLE_VIDEOS} v
             WHERE NOT EXISTS (SELECT 1 FROM ${TABLE_SCRAPE_INFO} s WHERE s.video_id = v.id)
             ORDER BY v.source_id, v.file_name`
          );
          const unscrapedFiles: string[] = [];
          while (diagRs.goToNextRow()) {
            const sid = diagRs.getLong(diagRs.getColumnIndex('source_id'));
            const name = diagRs.getString(diagRs.getColumnIndex('file_name'));
            unscrapedFiles.push(`[src=${sid}] ${name}`);
          }
          console.info(`[DB][getMediaStats] 未刮削文件(${other}个):\n${unscrapedFiles.join('\n')}`);
        } catch {
          // 诊断失败不影响主流程
        } finally {
          diagRs?.close();
        }
      }

      return { total, movies, tv, other };
    } catch { return { total: 0, movies: 0, tv: 0, other: 0 }; }
  }

  private parseMediaItem(rs: relationalStore.ResultSet): MediaItem {
    try {
    const L = (col: string): number => { const i = rs.getColumnIndex(col); return i >= 0 && !rs.isColumnNull(i) ? rs.getLong(i) : 0; };
    const str = (col: string): string | undefined => { const i = rs.getColumnIndex(col); return i >= 0 && !rs.isColumnNull(i) ? rs.getString(i) : undefined; };
    const dbl = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return i >= 0 && !rs.isColumnNull(i) ? rs.getDouble(i) : undefined; };
    const numOpt = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return i >= 0 && !rs.isColumnNull(i) ? rs.getLong(i) : undefined; };
    return {
      id: L('id'), sourceId: L('source_id'),
      directoryPath: rs.getString(rs.getColumnIndex('directory_path')),
      filePath: rs.getString(rs.getColumnIndex('file_path')),
      fileName: rs.getString(rs.getColumnIndex('file_name')),
      fileSize: numOpt('file_size'), durationMs: numOpt('duration_ms'),
      width: numOpt('width'), height: numOpt('height'),
      videoCodec: str('video_codec'), audioTracksJson: str('audio_tracks_json'),
      scannedAt: L('scanned_at'),
      provider: str('provider'), providerId: str('provider_id'), mediaType: str('media_type'),
      movieId: numOpt('movie_id'), tvSeriesId: numOpt('tv_series_id'),
      episodeId: numOpt('episode_id'), seasonNumber: numOpt('season_number'),
      episodeNumber: numOpt('episode_number'),
      title: str('scrape_title'), originalTitle: str('original_title'),
      overview: str('overview'), releaseDate: str('release_date'),
      rating: dbl('rating'), genresJson: str('genres_json'),
      posterUrl: str('poster_url'), backdropUrl: str('backdrop_url'),
      posterLocalPath: str('poster_local_path'), backdropLocalPath: str('backdrop_local_path'),
    };
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `parseMediaItem 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }

  /**
   * 按 tv_series_id 查询该剧所有分集（含元数据），按季号+集号排序
   * 用于剧集详情页加载集列表
   */
  async getMediaItemsByTvSeriesId(seriesId: number): Promise<MediaItem[]> {
    if (!this.core.isReady()) { return []; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      // 同一 episode_id 可能对应多个版本文件（如 4K 和 HDR），只保留 file_size 最大的那个
      // 用 CTE 先聚合出每个 episode_id 应保留的 video_id（NULL 安全，避免 NOT EXISTS 的 N×N 扫描）：
      // - COALESCE(file_size, 0) 处理 file_size 为 NULL 的情况
      // - 同大时以 video_id 较大者（较新扫描）为准
      // - episode_id IS NULL 的行（未刮削集）均保留，不纳入去重
      const SCRAPE = TABLE_SCRAPE_INFO;
      const VIDEOS = TABLE_VIDEOS;
      // 两步 CTE：先按 episode_id 找最大 file_size，再在相同 file_size 内取最大 video_id。
      // 避免将两字段打包成单一 rank_key（超出 SQLite 64 位整数安全范围时会转浮点，精度丢失）。
      const sql =
        `WITH best_size AS (` +
        `  SELECT si.episode_id,` +
        `         MAX(COALESCE(vi.file_size, 0)) AS max_file_size` +
        `  FROM ${SCRAPE} si` +
        `  JOIN ${VIDEOS} vi ON si.video_id = vi.id` +
        `  WHERE si.tv_series_id = ? AND si.episode_id IS NOT NULL` +
        `  GROUP BY si.episode_id` +
        `), best_vid AS (` +
        `  SELECT si.episode_id, MAX(si.video_id) AS best_video_id` +
        `  FROM ${SCRAPE} si` +
        `  JOIN ${VIDEOS} vi ON si.video_id = vi.id` +
        `  JOIN best_size bs ON bs.episode_id = si.episode_id` +
        `                    AND COALESCE(vi.file_size, 0) = bs.max_file_size` +
        `  WHERE si.tv_series_id = ? AND si.episode_id IS NOT NULL` +
        `  GROUP BY si.episode_id` +
        `)` +
        this.mediaItemSql +
        ` WHERE s.tv_series_id = ?` +
        `   AND (` +
        `     s.episode_id IS NULL` +
        `     OR EXISTS (` +
        `       SELECT 1 FROM best_vid bv` +
        `       WHERE bv.episode_id = s.episode_id` +
        `         AND s.video_id = bv.best_video_id` +
        `     )` +
        `   )` +
        ` ORDER BY COALESCE(s.season_number, 0) ASC, COALESCE(s.episode_number, 0) ASC`;
      rs = await store.querySql(sql, [seriesId, seriesId, seriesId]);
      const items: MediaItem[] = [];
      while (rs.goToNextRow()) { items.push(this.parseMediaItem(rs)); }
      return items;
    } catch (e) {
      console.error('[DB][getMediaItemsByTvSeriesId]', JSON.stringify(e));
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /**
   * 聚合电视剧/综艺合集
   *
   * 聚合策略：
   * 1. 有刮削数据（media_type='tv'）-> 以 provider::providerId 聚合
   * 2. 无刮削数据 -> 以视频文件的"直接父目录"路径聚合，
   *    同目录 >= 2 个视频才算合集（单文件不算）
   *    若父目录名是通用季名（如 Season1、S01、第1季）则再取上一级目录名作合集标题
   */
  async getSeriesGroups(): Promise<SeriesGroup[]> {
    const store = this.core.getStore();
    try {
      // TMDB 对剧集整体返回 media_type='tv'，对单集返回 media_type='episode'，两者都要纳入聚合
      const scrapedTv = await this.getMediaItemsByType('tv');
      const scrapedEpisode = await this.getMediaItemsByType('episode');

      // ── 诊断：直接查 scrape_info 表，验证 media_type 分布 ──
      let rawRs: relationalStore.ResultSet | null = null;
      const mediaTypeDist: string[] = [];
      try {
        rawRs = await store.querySql(`
          SELECT media_type, COUNT(*) AS cnt, MIN(tv_series_id) AS min_tsid, MAX(tv_series_id) AS max_tsid
          FROM ${TABLE_SCRAPE_INFO}
          GROUP BY media_type
        `);
        while (rawRs.goToNextRow()) {
          const mt = rawRs.getString(rawRs.getColumnIndex('media_type'));
          const cnt = rawRs.getLong(rawRs.getColumnIndex('cnt'));
          const minTsid = rawRs.isColumnNull(rawRs.getColumnIndex('min_tsid')) ? 'null' : String(rawRs.getLong(rawRs.getColumnIndex('min_tsid')));
          const maxTsid = rawRs.isColumnNull(rawRs.getColumnIndex('max_tsid')) ? 'null' : String(rawRs.getLong(rawRs.getColumnIndex('max_tsid')));
          mediaTypeDist.push(`${mt}:${cnt}(tsid=${minTsid}~${maxTsid})`);
        }
      } finally {
        rawRs?.close();
      }
      console.info(`[DB][getSeriesGroups] scrape_info media_type分布: ${mediaTypeDist.join(', ')}`);

      // ── 诊断：JOIN 是否正常 ──
      let joinDiagRs: relationalStore.ResultSet | null = null;
      const joinSamples: string[] = [];
      try {
        joinDiagRs = await store.querySql(`
          SELECT s.video_id, s.media_type, s.tv_series_id, ts.title AS ts_title, ts.poster_url AS ts_poster
          FROM ${TABLE_SCRAPE_INFO} s
          LEFT JOIN ${TABLE_TV_SERIES} ts ON s.tv_series_id = ts.id
          WHERE s.media_type IN ('tv','episode')
          LIMIT 5
        `);
        while (joinDiagRs.goToNextRow()) {
          const vid = joinDiagRs.getLong(joinDiagRs.getColumnIndex('video_id'));
          const mt = joinDiagRs.getString(joinDiagRs.getColumnIndex('media_type'));
          const tsid = joinDiagRs.isColumnNull(joinDiagRs.getColumnIndex('tv_series_id')) ? 'null' : String(joinDiagRs.getLong(joinDiagRs.getColumnIndex('tv_series_id')));
          const tsTitle = joinDiagRs.isColumnNull(joinDiagRs.getColumnIndex('ts_title')) ? 'null' : joinDiagRs.getString(joinDiagRs.getColumnIndex('ts_title'));
          const tsPoster = joinDiagRs.isColumnNull(joinDiagRs.getColumnIndex('ts_poster')) ? 'null' : 'Y';
          joinSamples.push(`vid=${vid} type=${mt} tsid=${tsid} title=${tsTitle} poster=${tsPoster}`);
        }
      } finally {
        joinDiagRs?.close();
      }
      console.info(`[DB][getSeriesGroups] JOIN诊断(前5): ${joinSamples.join(' | ')}`);

      const allScrapedTv: MediaItem[] = [];
      for (const it of scrapedTv) { allScrapedTv.push(it); }
      for (const it of scrapedEpisode) { allScrapedTv.push(it); }

      const unscrapedAll = await this.getUnscrapedMediaItems();
      console.info(`[DB][getSeriesGroups] 输入: tv=${scrapedTv.length} episode=${scrapedEpisode.length} unscraped=${unscrapedAll.length}`);

      const providerMap = new Map<string, MediaItem[]>();

      // ── 有刮削 tv/episode：以 tvSeriesId 聚合（精确，避免标题歧义）──
      for (const item of allScrapedTv) {
        // tvSeriesId 是最精确的 key；无则降级用规范化标题
        const key = item.tvSeriesId !== undefined
          ? `scraped::sid::${item.tvSeriesId}`
          : `scraped::title::${this.extractBaseSeriesTitle(item.title ?? item.fileName)}`;
        const existing = providerMap.get(key);
        if (existing) {
          existing.push(item);
        } else {
          providerMap.set(key, [item]);
        }
      }

      // ── 无刮削：以直接父目录聚合，先统计数量 ──
      const unscrapedMap = new Map<string, MediaItem[]>();
      for (const item of unscrapedAll) {
        const parentDir = this.getParentDir(item.filePath);
        const existing = unscrapedMap.get(parentDir);
        if (existing) {
          existing.push(item);
        } else {
          unscrapedMap.set(parentDir, [item]);
        }
      }

      // 若父目录是「Season N / 第X季 / S01」等季目录，先归并到上一层系列目录，再按 >=2 过滤
      const mergedUnscrapedMap = new Map<string, MediaItem[]>();
      const unscrapedEntries: string[] = [];
      unscrapedMap.forEach((_v: MediaItem[], k: string) => {
        unscrapedEntries.push(k);
      });
      for (const parentDir of unscrapedEntries) {
        const items = unscrapedMap.get(parentDir);
        if (items === undefined || items.length === 0) { continue; }
        const segs = parentDir.split('/').filter((s: string) => s.length > 0);
        const lastSeg = segs.length > 0 ? segs[segs.length - 1] : '';
        // 季目录 → 归并到上一层（系列根目录）
        let mergeKey: string;
        if (lastSeg.length > 0 && this.isGenericSeasonName(lastSeg) && segs.length >= 2) {
          mergeKey = segs.slice(0, segs.length - 1).join('/');
        } else {
          mergeKey = parentDir;
        }
        const existing = mergedUnscrapedMap.get(mergeKey);
        if (existing) {
          for (const item of items) { existing.push(item); }
        } else {
          const arr: MediaItem[] = [];
          for (const item of items) { arr.push(item); }
          mergedUnscrapedMap.set(mergeKey, arr);
        }
      }
      // 只有 >=2 个文件才算合集
      const mergedKeys: string[] = [];
      mergedUnscrapedMap.forEach((_v: MediaItem[], k: string) => {
        mergedKeys.push(k);
      });
      for (const mergeKey of mergedKeys) {
        const items = mergedUnscrapedMap.get(mergeKey);
        if (items !== undefined && items.length >= 2) {
          providerMap.set(`unscraped::${mergeKey}`, items);
        }
      }

      const groups: SeriesGroup[] = [];
      const providerKeys: string[] = [];
      providerMap.forEach((_v: MediaItem[], k: string) => {
        providerKeys.push(k);
      });

      for (const key of providerKeys) {
        const items = providerMap.get(key);
        if (items === undefined || items.length === 0) {
          continue;
        }
        const first = items[0];
        if (first === undefined) {
          continue;
        }
        let latestScannedAt = 0;
        for (const it of items) {
          if (it.scannedAt > latestScannedAt) {
            latestScannedAt = it.scannedAt;
          }
        }

        // 合集标题：有刮削的统一用基础剧名（去掉"第X季"后缀），首页不显示季标签
        let groupTitle: string;
        let seasonLabel: string | undefined = undefined;
        if (first.tvSeriesId !== undefined || first.title) {
          // 有刮削：取基础剧名（COALESCE 已取到 ts.title，去掉季名后缀即为基础剧名）
          groupTitle = this.extractBaseSeriesTitle(first.title ?? first.fileName);
        } else {
          const parentDir = this.getParentDir(first.filePath);
          const segments = parentDir.split('/').filter((s: string) => s.length > 0);
          const lastSeg = segments.length > 0 ? segments[segments.length - 1] : '';
          const dirName = lastSeg ?? '';
          if (this.isGenericSeasonName(dirName) && segments.length >= 2) {
            const parentSeg = segments[segments.length - 2];
            groupTitle = parentSeg ?? dirName;
            seasonLabel = this.formatSeasonLabel(dirName);
          } else {
            groupTitle = dirName.length > 0 ? dirName : first.fileName;
          }
        }
        void key;

        // 从所有 items 中挑最佳代表封面：有海报且评分最高的
        let representative: MediaItem = first;
        for (const it of items) {
          const itHasPoster = it.posterUrl !== undefined || it.posterLocalPath !== undefined;
          const curHasPoster = representative.posterUrl !== undefined || representative.posterLocalPath !== undefined;
          if (itHasPoster && !curHasPoster) {
            representative = it;
          } else if (itHasPoster === curHasPoster && (it.rating ?? 0) > (representative.rating ?? 0)) {
            representative = it;
          }
        }

        // 查该季的海报（tv_seasons 表）
        let seasonPosterUrl: string | undefined;
        const repSeasonNum = first.seasonNumber;
        const repSeriesId = first.tvSeriesId;
        if (repSeriesId !== undefined && repSeasonNum !== undefined) {
          try {
            let seasonRs: relationalStore.ResultSet | null = null;
            try {
              seasonRs = await store.querySql(
                `SELECT poster_url FROM ${TABLE_TV_SEASONS} WHERE series_id=? AND season_number=? LIMIT 1`,
                [repSeriesId, repSeasonNum]
              );
              if (seasonRs.goToFirstRow()) {
                const idx = seasonRs.getColumnIndex('poster_url');
                if (!seasonRs.isColumnNull(idx)) {
                  seasonPosterUrl = seasonRs.getString(idx);
                }
              }
            } finally {
              seasonRs?.close();
            }
          } catch {
            // 查不到就不设，不影响主流程
          }
        }

        const group: SeriesGroup = {
          title: groupTitle,
          seasonLabel,
          posterUrl: representative.posterUrl,
          posterLocalPath: representative.posterLocalPath,
          backdropUrl: representative.backdropUrl,
          seasonNumber: repSeasonNum,
          seasonPosterUrl,
          rating: representative.rating,
          episodeCount: countSeriesEpisodeRows(items),
          episodes: items,
          latestScannedAt
        };
        groups.push(group);
      }

      groups.sort((a, b) => b.latestScannedAt - a.latestScannedAt);
      console.info(
        `[FileSourceDatabase] getSeriesGroups: ${groups.length} 组` +
        `（有刮削 tv=${scrapedTv.length} episode=${scrapedEpisode.length} 集，无刮削候选=${unscrapedAll.length} 个）`
      );
      return groups;
    } catch (error) {
      console.error(`[FileSourceDatabase] getSeriesGroups 失败: ${JSON.stringify(error)}`);
      return [];
    }
  }

  /**
   * 电视剧栏：从 scrape_info 按 tv_series_id GROUP BY，
   * 取去重后的每部剧（联 tv_series 拿海报、评分），按最新刮削时间倒序。
   */
  async getDistinctTvSeriesGroups(limit: number = 30): Promise<SeriesGroup[]> {
    if (!this.core.isReady()) { return []; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql = `
        SELECT ts.id AS series_id, ts.title, ts.rating,
               ts.poster_url, ts.backdrop_url,
               ts.poster_local_path, ts.backdrop_local_path,
               CASE
                 WHEN COUNT(DISTINCT CASE WHEN si.episode_id IS NOT NULL THEN si.episode_id END) > 0
                 THEN COUNT(DISTINCT CASE WHEN si.episode_id IS NOT NULL THEN si.episode_id END)
                 ELSE COUNT(*)
               END AS episode_count,
               MAX(si.scraped_at) AS latest_scraped_at
        FROM ${TABLE_SCRAPE_INFO} si
        JOIN ${TABLE_TV_SERIES} ts ON si.tv_series_id = ts.id
        WHERE si.tv_series_id IS NOT NULL
        GROUP BY si.tv_series_id
        ORDER BY latest_scraped_at DESC
        LIMIT ?
      `;
      rs = await store.querySql(sql, [limit]);
      const groups: SeriesGroup[] = [];
      while (rs.goToNextRow()) {
        const str = (col: string): string | undefined => {
          const i = rs!.getColumnIndex(col);
          return rs!.isColumnNull(i) ? undefined : rs!.getString(i);
        };
        const dbl = (col: string): number | undefined => {
          const i = rs!.getColumnIndex(col);
          return rs!.isColumnNull(i) ? undefined : rs!.getDouble(i);
        };
        const seriesId = rs.getLong(rs.getColumnIndex('series_id'));
        const group: SeriesGroup = {
          title: rs.getString(rs.getColumnIndex('title')),
          tvSeriesId: seriesId,
          posterUrl: str('poster_url'),
          backdropUrl: str('backdrop_url'),
          posterLocalPath: str('poster_local_path'),
          rating: dbl('rating'),
          episodeCount: rs.getLong(rs.getColumnIndex('episode_count')),
          episodes: [],
          latestScannedAt: rs.getLong(rs.getColumnIndex('latest_scraped_at'))
        };
        groups.push(group);
      }
      console.info(`[DB][getDistinctTvSeriesGroups] ${groups.length} 部电视剧`);
      return groups;
    } catch (e) {
      console.error('[DB][getDistinctTvSeriesGroups] 查询失败', JSON.stringify(e));
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /**
   * 最近添加列表：
   * - 电视剧按 (tv_series_id, season_number) GROUP BY，取季海报，按最新刮削时间倒序
   * - 电影按 scraped_at 倒序
   * - 两者合并后按 sortTs 倒序，取前 limit 条
   */
  async getRecentlyAddedList(limit: number = 20): Promise<MediaListItem[]> {
    if (!this.core.isReady()) { return []; }
    const store = this.core.getStore();
    let tvRs: relationalStore.ResultSet | null = null;
    let movieRs: relationalStore.ResultSet | null = null;
    try {
      // ── 电视剧（按剧+季分组）──────────────────────────────────
      const tvSql = `
        SELECT si.tv_series_id, COALESCE(si.season_number, 0) AS season_num,
               ts.title, ts.rating, ts.poster_url, ts.poster_local_path, ts.backdrop_url,
               tss.poster_url AS season_poster_url,
               COUNT(*) AS episode_count,
               MAX(si.scraped_at) AS latest_scraped_at
        FROM ${TABLE_SCRAPE_INFO} si
        JOIN ${TABLE_TV_SERIES} ts ON si.tv_series_id = ts.id
        LEFT JOIN ${TABLE_TV_SEASONS} tss
               ON tss.series_id = si.tv_series_id
              AND tss.season_number = si.season_number
         WHERE si.tv_series_id IS NOT NULL
           AND (
             si.media_type = 'episode'
             OR NOT EXISTS (
               SELECT 1
               FROM ${TABLE_SCRAPE_INFO} sibling
               WHERE sibling.tv_series_id = si.tv_series_id
                 AND sibling.media_type = 'episode'
             )
           )
         GROUP BY si.tv_series_id, COALESCE(si.season_number, 0)
        ORDER BY latest_scraped_at DESC
        LIMIT ?
      `;
      tvRs = await store.querySql(tvSql, [limit]);
      const tvItems: MediaListItem[] = [];
      while (tvRs.goToNextRow()) {
        const str = (col: string): string | undefined => {
          const i = tvRs!.getColumnIndex(col);
          return tvRs!.isColumnNull(i) ? undefined : tvRs!.getString(i);
        };
        const dbl = (col: string): number | undefined => {
          const i = tvRs!.getColumnIndex(col);
          return tvRs!.isColumnNull(i) ? undefined : tvRs!.getDouble(i);
        };
        const seasonNum = tvRs.getLong(tvRs.getColumnIndex('season_num'));
        const sortTs = tvRs.getLong(tvRs.getColumnIndex('latest_scraped_at'));
        const group: SeriesGroup = {
          title: tvRs.getString(tvRs.getColumnIndex('title')),
          tvSeriesId: tvRs.getLong(tvRs.getColumnIndex('tv_series_id')),
          seasonNumber: seasonNum > 0 ? seasonNum : undefined,
          seasonLabel: seasonNum > 0 ? `第${seasonNum}季` : undefined,
          posterUrl: str('poster_url'),
          backdropUrl: str('backdrop_url'),
          posterLocalPath: str('poster_local_path'),
          seasonPosterUrl: str('season_poster_url'),
          rating: dbl('rating'),
          episodeCount: tvRs.getLong(tvRs.getColumnIndex('episode_count')),
          episodes: [],
          latestScannedAt: sortTs
        };
        const item: MediaListItem = { kind: 'series', series: group, sortTs };
        tvItems.push(item);
      }
      tvRs.close(); tvRs = null;

      // ── 电影 ─────────────────────────────────────────────────
      const movieSql = `
        SELECT m.title, m.rating, m.poster_url, m.poster_local_path, m.backdrop_url,
               v.id AS vid, v.source_id, v.directory_path, v.file_path, v.file_name,
               v.file_size, v.duration_ms, v.width, v.height, v.video_codec,
               v.audio_tracks_json, v.scanned_at,
               si.scraped_at, si.provider, si.provider_id, si.movie_id
        FROM ${TABLE_SCRAPE_INFO} si
        JOIN ${TABLE_MOVIES} m ON si.movie_id = m.id
        JOIN ${TABLE_VIDEOS} v ON si.video_id = v.id
        WHERE si.movie_id IS NOT NULL
        ORDER BY si.scraped_at DESC
        LIMIT ?
      `;
      movieRs = await store.querySql(movieSql, [limit]);
      const movieItems: MediaListItem[] = [];
      while (movieRs.goToNextRow()) {
        const str = (col: string): string | undefined => {
          const i = movieRs!.getColumnIndex(col);
          return movieRs!.isColumnNull(i) ? undefined : movieRs!.getString(i);
        };
        const num = (col: string): number | undefined => {
          const i = movieRs!.getColumnIndex(col);
          return movieRs!.isColumnNull(i) ? undefined : movieRs!.getLong(i);
        };
        const dbl = (col: string): number | undefined => {
          const i = movieRs!.getColumnIndex(col);
          return movieRs!.isColumnNull(i) ? undefined : movieRs!.getDouble(i);
        };
        const scrapedAt = movieRs.getLong(movieRs.getColumnIndex('scraped_at'));
        const mediaItem: MediaItem = {
          id: movieRs.getLong(movieRs.getColumnIndex('vid')),
          sourceId: movieRs.getLong(movieRs.getColumnIndex('source_id')),
          directoryPath: str('directory_path') ?? '',
          filePath: str('file_path') ?? '',
          fileName: str('file_name') ?? '',
          fileSize: num('file_size'),
          durationMs: num('duration_ms'),
          width: num('width'),
          height: num('height'),
          videoCodec: str('video_codec'),
          audioTracksJson: str('audio_tracks_json'),
          scannedAt: movieRs.getLong(movieRs.getColumnIndex('scanned_at')),
          mediaType: 'movie',
          title: str('title'),
          posterUrl: str('poster_url'),
          posterLocalPath: str('poster_local_path'),
          backdropUrl: str('backdrop_url'),
          rating: dbl('rating'),
          provider: str('provider'),
          providerId: str('provider_id'),
          movieId: num('movie_id')
        };
        const item: MediaListItem = { kind: 'video', video: mediaItem, sortTs: scrapedAt };
        movieItems.push(item);
      }
      movieRs.close(); movieRs = null;

      // ── 合并，按 sortTs 倒序，取前 limit 条 ──────────────────
      // 注意：仅保留有 scrape_info 记录的条目（tvSql/movieSql 均通过 scrape_info JOIN 过滤）
      // 有 scrape_info 但 poster 为空的记录仍会出现，由 UI 层用 title 兜底展示
      const combined: MediaListItem[] = [];
      for (const it of tvItems) { combined.push(it); }
      for (const it of movieItems) { combined.push(it); }
      combined.sort((a: MediaListItem, b: MediaListItem) => b.sortTs - a.sortTs);
      const result = combined.slice(0, limit);
      console.info(`[DB][getRecentlyAddedList] TV季=${tvItems.length} 电影=${movieItems.length} 合并后=${result.length}`);
      return result;
    } catch (e) {
      console.error('[DB][getRecentlyAddedList] 查询失败', JSON.stringify(e));
      return [];
    } finally {
      try { tvRs?.close(); } catch { }
      try { movieRs?.close(); } catch { }
    }
  }

  /**
   * 判断目录名是否是通用季名，如 Season1/Season 1/S01/第1季/第一季 等
   */
  private isGenericSeasonName(name: string): boolean {
    const lower = name.toLowerCase();
    return lower.startsWith('season') ||
      lower.startsWith('s0') ||
      lower.startsWith('s1') ||
      lower.startsWith('s2') ||
      lower.startsWith('s3') ||
      name.startsWith('第') ||
      lower === 'extras' ||
      lower === 'specials' ||
      lower === 'featurettes';
  }

  /**
   * 把目录名格式化为短季标签显示在卡片上，统一用「第X季」中文格式
   * Season1 / Season 1 → 第1季
   * S01 / S1 → 第1季
   * 第八季 → 第八季（保留中文数字）
   * extras / specials → 特典
   */
  private formatSeasonLabel(dirName: string): string {
    const lower = dirName.toLowerCase().trim();
    // Season N / Season N
    const seasonMatch = lower.match(/^season\s*(\d+)$/);
    if (seasonMatch) {
      return `第${parseInt(seasonMatch[1])}季`;
    }
    // S01 / S1 等
    const sMatch = lower.match(/^s(\d+)$/);
    if (sMatch) {
      return `第${parseInt(sMatch[1])}季`;
    }
    // 第N季（中文数字保留原样）
    if (dirName.startsWith('第') && dirName.endsWith('季')) {
      return dirName;
    }
    // 特典类
    if (lower === 'extras' || lower === 'specials' || lower === 'featurettes') {
      return '特典';
    }
    // 其他直接返回原名（截短）
    return dirName.length > 6 ? dirName.substring(0, 6) : dirName;
  }

  /**
   * 从刮削标题中提取基础剧名，去掉季数后缀，用于首页合并同系列不同季。
   *
   * 处理示例：
   *   "权力的游戏 第七季"  → "权力的游戏"
   *   "Game of Thrones Season 7" → "Game of Thrones"
   *   "The Crown (Season 4)"     → "The Crown"
   *   "Breaking Bad"             → "Breaking Bad"（无变化）
   */
  private extractBaseSeriesTitle(title: string): string {
    if (!title || title.length === 0) { return title; }
    let t = title.trim();

    // 中文：去掉末尾"第X季"（X 为数字或汉字数字）
    // 例："权力的游戏 第七季" / "权力的游戏第3季"
    t = t.replace(/\s*第[零一二三四五六七八九十百\d]+季\s*$/, '').trim();

    // 英文：去掉末尾 Season N / S1 / (Season N) 等
    // 例："Game of Thrones Season 7" / "The Crown (Season 4)"
    t = t.replace(/\s*[\(（]?\s*[Ss]eason\s*\d+\s*[\)）]?\s*$/, '').trim();
    t = t.replace(/\s*[\(（]?\s*[Ss]\d+\s*[\)）]?\s*$/, '').trim();

    // 冒号 + 季名后缀："权力的游戏：第七季" / "Game of Thrones: Season 7"
    t = t.replace(/\s*[：:]\s*第[零一二三四五六七八九十百\d]+季\s*$/, '').trim();
    t = t.replace(/\s*[：:]\s*[Ss]eason\s*\d+\s*$/, '').trim();

    return t.length > 0 ? t : title;
  }

  /** 辅助：取文件路径的直接父目录（去掉最后一段文件名） */
  private getParentDir(filePath: string): string {
    const lastSlash = filePath.lastIndexOf('/');
    if (lastSlash <= 0) {
      return '/';
    }
    return filePath.substring(0, lastSlash);
  }

  /** 查询所有没有刮削数据的视频（scrape_info 为 NULL） */
  private async getUnscrapedMediaItems(): Promise<MediaItem[]> {
    if (!this.core.isReady()) {
      return [];
    }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql = `
        SELECT v.id, v.source_id, v.directory_path, v.file_path, v.file_name,
               v.file_size, v.duration_ms, v.width, v.height, v.video_codec,
               v.audio_tracks_json, v.scanned_at,
               NULL AS provider, NULL AS provider_id, NULL AS media_type,
               NULL AS movie_id, NULL AS tv_series_id, NULL AS episode_id,
               NULL AS season_number, NULL AS episode_number,
               NULL AS scrape_title, NULL AS original_title, NULL AS overview,
               NULL AS release_date, NULL AS rating, NULL AS genres_json,
               NULL AS poster_url, NULL AS backdrop_url,
               NULL AS poster_local_path, NULL AS backdrop_local_path
        FROM ${TABLE_VIDEOS} v
        WHERE NOT EXISTS (
          SELECT 1 FROM ${TABLE_SCRAPE_INFO} s WHERE s.video_id = v.id
        )
        ORDER BY v.scanned_at DESC
      `;
      rs = await store.querySql(sql);
      const items: MediaItem[] = [];
      while (rs.goToNextRow()) {
        items.push(this.parseMediaItem(rs));
      }
      return items;
    } catch (error) {
      console.error(`[FileSourceDatabase] getUnscrapedMediaItems 失败: ${JSON.stringify(error)}`);
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /**
   * 多条件媒体搜索，支持关键词/类型/类别/评分/年份/排序/分页。
   *
   * - keyword 为空字符串时返回全部（受其余筛选条件约束）
   * - 所有用户输入均通过 ? 参数化，不拼接进 SQL 字符串
   *
   * @param keyword  搜索关键词（标题 / 原始标题模糊匹配）
   * @param options  可选筛选与排序参数，缺省值见各字段注释
   */
  async searchMediaItems(keyword: string, options?: SearchMediaOptions): Promise<MediaItem[]> {
    if (!this.core.isReady()) {
      return [];
    }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      const conditions: string[] = [];
      const params: relationalStore.ValueType[] = [];

      // ── 统一 trim keyword，避免含前后空格时无法正确匹配 ──
      const kw: string = keyword.trim();

      // ── keyword 非空时：title / original_title + 拼音字段模糊匹配 ──
      if (kw.length > 0) {
        const kwLike: string = `%${kw}%`;
        const kwLower: string = kw.toLowerCase();
        // 拼音前缀匹配：转义 LIKE 通配符，避免 %/_ 被误当通配符；使用 ESCAPE '\'
        const kwLowerEscape: string = kwLower.replace(/%/g, '\\%').replace(/_/g, '\\_');
        const kwLowerEscapePrefix: string = `${kwLowerEscape}%`;
        conditions.push(
          '(m.title LIKE ? OR m.original_title LIKE ? OR ts.title LIKE ? OR ts.original_title LIKE ?' +
          " OR m.title_pinyin LIKE ? ESCAPE '\\' OR m.title_initials LIKE ? ESCAPE '\\'" +
          " OR ts.title_pinyin LIKE ? ESCAPE '\\' OR ts.title_initials LIKE ? ESCAPE '\\')"
        );
        params.push(kwLike, kwLike, kwLike, kwLike);
        params.push(kwLowerEscapePrefix, kwLowerEscapePrefix, kwLowerEscapePrefix, kwLowerEscapePrefix);
      }

      // ── mediaType 过滤（'all' 时不加条件） ──
      // TV 系列整体存为 media_type='tv'，单集存为 media_type='episode'，两者均属电视剧
      // 同时要求 tv_series_id IS NOT NULL，剔除刮削不完整的脏数据（无系列关联的单集）
      const mediaType: string = options?.mediaType ?? 'all';
      if (mediaType === 'tv') {
        conditions.push("(s.media_type IN ('tv', 'episode') AND s.tv_series_id IS NOT NULL)");
      } else if (mediaType !== 'all') {
        conditions.push('s.media_type = ?');
        params.push(mediaType);
      }

      // ── genre 过滤：genres_json 模糊匹配（加表别名避免多表 JOIN 时列名歧义） ──
      if (options?.genre !== undefined && options.genre.length > 0) {
        conditions.push('COALESCE(m.genres_json, ts.genres_json) LIKE ?');
        params.push(`%${options.genre}%`);
      }

      // ── minRating 过滤 ──
      if (options?.minRating !== undefined) {
        conditions.push('COALESCE(m.rating, ts.rating) >= ?');
        params.push(options.minRating);
      }

      // ── yearFrom / yearTo 过滤：十年段区间匹配 ──
      if (options?.yearFrom !== undefined) {
        conditions.push("CAST(substr(COALESCE(m.release_date, ts.first_air_date), 1, 4) AS INTEGER) >= ?");
        params.push(options.yearFrom);
      }
      if (options?.yearTo !== undefined) {
        conditions.push("CAST(substr(COALESCE(m.release_date, ts.first_air_date), 1, 4) AS INTEGER) <= ?");
        params.push(options.yearTo);
      }

      // ── watchProgress 过滤：通过 EXISTS 子查询匹配 media_progress 表 ──
      // 电影 key 格式: media_progress_movie_{s.provider_id}
      // 集级剧集 key 格式: media_progress_episode_tmdb_{ts.provider_id}_s{n}_e{n}
      // 使用 '_s%' 后缀而非 '_%'，避免 provider_id 为前缀子串时误匹配（如 1399 匹配到 13990）
      if (options?.watchProgress === 'unseen') {
        conditions.push(
          `((s.media_type = 'movie' AND NOT EXISTS (` +
            `SELECT 1 FROM ${TABLE_MEDIA_PROGRESS} mp2 ` +
            `WHERE mp2.media_key = 'media_progress_movie_' || s.provider_id ` +
            `AND (mp2.position_ms > 0 OR mp2.is_watched = 1)` +
          `)) OR (s.media_type IN ('tv', 'episode') AND ts.provider_id IS NOT NULL AND NOT EXISTS (` +
            `SELECT 1 FROM ${TABLE_MEDIA_PROGRESS} mp2 ` +
            `WHERE mp2.media_key LIKE 'media_progress_episode_tmdb_' || ts.provider_id || '_s%' ` +
            `AND (mp2.position_ms > 0 OR mp2.is_watched = 1)` +
          `)))`
        );
      } else if (options?.watchProgress === 'partial') {
        conditions.push(
          `((s.media_type = 'movie' AND EXISTS (` +
            `SELECT 1 FROM ${TABLE_MEDIA_PROGRESS} mp2 ` +
            `WHERE mp2.media_key = 'media_progress_movie_' || s.provider_id ` +
            `AND mp2.position_ms > 0 AND mp2.duration_ms > 0 ` +
            `AND CAST(mp2.position_ms AS REAL) < CAST(mp2.duration_ms AS REAL) * 0.9` +
          `)) OR (s.media_type IN ('tv', 'episode') AND ts.provider_id IS NOT NULL AND EXISTS (` +
            `SELECT 1 FROM ${TABLE_MEDIA_PROGRESS} mp2 ` +
            `WHERE mp2.media_key LIKE 'media_progress_episode_tmdb_' || ts.provider_id || '_s%' ` +
            `AND mp2.position_ms > 0 AND mp2.duration_ms > 0 ` +
            `AND CAST(mp2.position_ms AS REAL) < CAST(mp2.duration_ms AS REAL) * 0.9` +
          `)))`
        );
      } else if (options?.watchProgress === 'done') {
        conditions.push(
          `((s.media_type = 'movie' AND EXISTS (` +
            `SELECT 1 FROM ${TABLE_MEDIA_PROGRESS} mp2 ` +
            `WHERE mp2.media_key = 'media_progress_movie_' || s.provider_id ` +
            `AND (mp2.is_watched = 1 OR (mp2.duration_ms > 0 AND CAST(mp2.position_ms AS REAL) >= CAST(mp2.duration_ms AS REAL) * 0.9))` +
          `)) OR (s.media_type IN ('tv', 'episode') AND ts.provider_id IS NOT NULL AND EXISTS (` +
            `SELECT 1 FROM ${TABLE_MEDIA_PROGRESS} mp2 ` +
            `WHERE mp2.media_key LIKE 'media_progress_episode_tmdb_' || ts.provider_id || '_s%' ` +
            `AND (mp2.is_watched = 1 OR (mp2.duration_ms > 0 AND CAST(mp2.position_ms AS REAL) >= CAST(mp2.duration_ms AS REAL) * 0.9))` +
          `)))`
        );
      }

      // ── originCountry 过滤：分别匹配 movies / tv_series 的 origin_country_json ──
      // 用 OR 而非 COALESCE，避免 COALESCE 优先取电影字段导致同行存在 tv_series 国家数据时被屏蔽，
      // 同时保持参数化查询防止 SQL 注入。
      if (options?.originCountry !== undefined && options.originCountry.length > 0) {
        conditions.push('(m.origin_country_json LIKE ? OR ts.origin_country_json LIKE ?)');
        params.push(`%"${options.originCountry}"%`);
        params.push(`%"${options.originCountry}"%`);
      }

      const whereClause: string = conditions.length > 0 ? ` WHERE ${conditions.join(' AND ')}` : '';

      // ── ORDER BY ──
      const sortBy: string = options?.sortBy ?? 'rating';
      let orderClause: string;
      if (sortBy === 'year') {
        orderClause = ' ORDER BY release_date DESC';
      } else if (sortBy === 'title') {
        orderClause = ' ORDER BY COALESCE(m.title, ts.title) ASC';
      } else if (kw.length > 0) {
        // keyword 搜索时：相关度分层排序，次级按评分降序
        // SQLite ORDER BY CASE WHEN 不支持 ? 参数化绑定（relationalStore API 限制）；
        // 已通过三重转义保证安全：单引号转义（''）+ LIKE 通配符转义（\%/\_）+ ESCAPE '\\'
        const kwEscape: string = kw.replace(/'/g, "''").replace(/%/g, '\\%').replace(/_/g, '\\_');
        const kwLowerEscape: string = kw.toLowerCase().replace(/'/g, "''").replace(/%/g, '\\%').replace(/_/g, '\\_');
        orderClause =
          ` ORDER BY CASE` +
          ` WHEN COALESCE(m.title, ts.title) = '${kwEscape}' THEN 0` +
          ` WHEN COALESCE(m.title, ts.title) LIKE '${kwEscape}%' ESCAPE '\\' THEN 1` +
          ` WHEN COALESCE(m.title, ts.title) LIKE '%${kwEscape}%' ESCAPE '\\' THEN 2` +
          ` WHEN COALESCE(m.title_pinyin, ts.title_pinyin) LIKE '${kwLowerEscape}%' ESCAPE '\\' THEN 3` +
          ` WHEN COALESCE(m.title_initials, ts.title_initials) LIKE '${kwLowerEscape}%' ESCAPE '\\' THEN 4` +
          ` ELSE 5 END ASC,` +
          ` COALESCE(m.rating, ts.rating) DESC`;
      } else {
        // 无 keyword：默认按评分
        orderClause = ' ORDER BY COALESCE(m.rating, ts.rating) DESC';
      }

      // ── LIMIT 范围校验，防止 NaN/负数/超大值 ──
      const rawLimit: number = options?.limit ?? 50;
      const safeLimit: number = (Number.isInteger(rawLimit) && rawLimit > 0) ? Math.min(rawLimit, 500) : 50;

      // TV 模式：SQL 层直接按 tv_series_id 分组去重，LIMIT 对准唯一 series 数量
      // 非 TV 模式：多拉一批后在内存去重再裁剪（电影 movieId 唯一，冗余极少）
      let groupClause: string;
      let fetchLimit: number;
      if (mediaType === 'tv') {
        groupClause = ' GROUP BY s.tv_series_id';
        fetchLimit = safeLimit;
      } else {
        groupClause = '';
        fetchLimit = Math.min(safeLimit * 10, 2000);
      }
      const limitClause: string = ` LIMIT ${fetchLimit}`;

      const sql: string = this.mediaItemSql + whereClause + groupClause + orderClause + limitClause;
      rs = await store.querySql(sql, params);
      const rawItems: MediaItem[] = [];
      while (rs.goToNextRow()) {
        rawItems.push(this.parseMediaItem(rs));
      }

      // 按 tvSeriesId / movieId 去重，避免同一部剧多集重复展示
      const seen = new Set<string>();
      const items: MediaItem[] = [];
      for (const item of rawItems) {
        let key: string;
        if (item.tvSeriesId !== undefined) {
          key = `tv-${item.tvSeriesId}`;
        } else if (item.movieId !== undefined) {
          key = `mv-${item.movieId}`;
        } else {
          key = `vid-${item.id}`;
        }
        if (!seen.has(key)) {
          seen.add(key);
          items.push(item);
          if (items.length >= safeLimit) { break; }
        }
      }

      // 剔除 tv/episode 类型但缺少系列关联的脏数据（tv_series_id=NULL 导致无标题无海报）
      const displayItems = items.filter((item: MediaItem): boolean => {
        if (item.mediaType === 'episode' || item.mediaType === 'tv') {
          return item.tvSeriesId !== undefined && item.title !== undefined;
        }
        // 剔除完全未刮削的视频（无标题、无海报），此类内容在媒体库中无可识别信息
        if (item.title === undefined && item.posterUrl === undefined && item.posterLocalPath === undefined) {
          return false;
        }
        return true;
      });

      console.info(`[DB][searchMediaItems] keyword=[${kw.length}chars] type=${mediaType} raw=${rawItems.length} deduped=${items.length} display=${displayItems.length}`);
      return displayItems;
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[DB][searchMediaItems] 异常 code=${err.code} msg=${err.message}`);
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /**
   * 获取所有有效的 genres_json 原始值列表（DISTINCT，升序排列）。
   *
   * genres_json 格式示例：`["剧情","动作"]`
   * 调用方需自行解析 JSON 数组、拆分并去重各类别标签。
   * 此方法仅负责从 DB 获取原始值，不做 JSON 解析。
   */
  async getDistinctGenres(): Promise<string[]> {
    if (!this.core.isReady()) {
      return [];
    }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql: string = `
        SELECT DISTINCT COALESCE(m.genres_json, ts.genres_json) AS genres_json
        FROM ${TABLE_SCRAPE_INFO} s
        LEFT JOIN ${TABLE_MOVIES} m ON s.movie_id = m.id
        LEFT JOIN ${TABLE_TV_SERIES} ts ON s.tv_series_id = ts.id
        WHERE COALESCE(m.genres_json, ts.genres_json) IS NOT NULL
        ORDER BY genres_json ASC
      `;
      rs = await store.querySql(sql);
      const result: string[] = [];
      while (rs.goToNextRow()) {
        const g: string = rs.getString(rs.getColumnIndex('genres_json'));
        if (g) {
          result.push(g);
        }
      }
      console.info(`[DB][getDistinctGenres] 共 ${result.length} 条 genres_json 记录`);
      return result;
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[DB][getDistinctGenres] 异常 code=${err.code} msg=${err.message}`);
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /**
   * 从当前库中提取所有独立 genre 名称（已解析，去重，排序）。
   * @param mediaType 'movie' | 'tv' | undefined（undefined = 全部）
   */
  async getDistinctGenreNames(mediaType?: 'movie' | 'tv'): Promise<string[]> {
    if (!this.core.isReady()) { return []; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      let typeCondition: string = '';
      const typeParams: relationalStore.ValueType[] = [];
      if (mediaType === 'movie') {
        typeCondition = "WHERE s.media_type = 'movie' AND m.genres_json IS NOT NULL";
      } else if (mediaType === 'tv') {
        typeCondition = "WHERE (s.media_type IN ('tv', 'episode')) AND s.tv_series_id IS NOT NULL AND ts.genres_json IS NOT NULL";
      } else {
        typeCondition = 'WHERE COALESCE(m.genres_json, ts.genres_json) IS NOT NULL';
      }
      const sql: string = `
        SELECT COALESCE(m.genres_json, ts.genres_json) AS genres_json
        FROM ${TABLE_SCRAPE_INFO} s
        LEFT JOIN ${TABLE_MOVIES} m ON s.movie_id = m.id
        LEFT JOIN ${TABLE_TV_SERIES} ts ON s.tv_series_id = ts.id
        ${typeCondition}
      `;
      rs = await store.querySql(sql, typeParams);
      const nameSet = new Set<string>();
      while (rs.goToNextRow()) {
        const raw: string = rs.getString(rs.getColumnIndex('genres_json'));
        if (raw) {
          try {
            const arr = JSON.parse(raw) as string[];
            for (const name of arr) {
              if (name && name.length > 0) { nameSet.add(name); }
            }
          } catch {
            // 解析失败跳过
          }
        }
      }
      const result: string[] = Array.from(nameSet).sort();
      console.info(`[DB][getDistinctGenreNames] mediaType=${mediaType ?? 'all'} 共 ${result.length} 个 genre`);
      return result;
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[DB][getDistinctGenreNames] 异常 code=${err.code} msg=${err.message}`);
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }
}
