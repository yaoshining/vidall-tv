import relationalStore from '@ohos.data.relationalStore';
import { MovieEntity, TvSeriesEntity, TvSeasonEntity, TvEpisodeEntity } from '../models/MediaEntity';
import { toPinyinFull, toPinyinInitials } from '../../utils/PinyinUtil';
import { BusinessError } from "@kit.BasicServicesKit";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TABLE_MOVIES, TABLE_TV_SERIES, TABLE_TV_SEASONS, TABLE_TV_EPISODES } from './DbConstants';
import { FileSourceDbCore } from './FileSourceDbCore';

/**
 * movies / tv_series / tv_seasons / tv_episodes 表的数据访问，
 * 含从投影行映射实体与查询的辅助方法。
 * 拆分自 FileSourceDatabase，保持原方法签名与行为不变。
 */
export class MediaContentDao {
  private core: FileSourceDbCore;

  constructor(core: FileSourceDbCore) {
    this.core = core;
  }

  private buildMovieSelectSql(suffix: string = ''): string {
    return `SELECT id, provider, provider_id, title, original_title, overview, release_date, rating, vote_count, poster_path, backdrop_path, poster_url, backdrop_url, poster_local_path, backdrop_local_path, genres_json, cast_json, directors_json, runtime, original_language, origin_country_json, raw_json, scraped_at FROM ${TABLE_MOVIES}${suffix}`;
  }

  private buildTvSeriesSelectSql(suffix: string = ''): string {
    return `SELECT id, provider, provider_id, title, original_title, overview, first_air_date, rating, vote_count, poster_path, backdrop_path, poster_url, backdrop_url, poster_local_path, backdrop_local_path, genres_json, cast_json, number_of_seasons, original_language, origin_country_json, raw_json, scraped_at FROM ${TABLE_TV_SERIES}${suffix}`;
  }

  private mapMovieEntityFromProjectedRow(rs: relationalStore.ResultSet): MovieEntity {
    try {
      const entity: MovieEntity = {
        id: rs.getLong(0),
        provider: rs.getString(1),
        providerId: rs.getString(2),
        title: rs.getString(3),
        originalTitle: this.core.nullableString(rs, 4),
        overview: this.core.nullableString(rs, 5),
        releaseDate: this.core.nullableString(rs, 6),
        rating: this.core.nullableDouble(rs, 7),
        voteCount: this.core.nullableLong(rs, 8),
        posterPath: this.core.nullableString(rs, 9),
        backdropPath: this.core.nullableString(rs, 10),
        posterUrl: this.core.nullableString(rs, 11),
        backdropUrl: this.core.nullableString(rs, 12),
        posterLocalPath: this.core.nullableString(rs, 13),
        backdropLocalPath: this.core.nullableString(rs, 14),
        genresJson: this.core.nullableString(rs, 15),
        castJson: this.core.nullableString(rs, 16),
        directorsJson: this.core.nullableString(rs, 17),
        runtime: this.core.nullableLong(rs, 18),
        originalLanguage: this.core.nullableString(rs, 19),
        originCountryJson: this.core.nullableString(rs, 20),
        rawJson: this.core.nullableString(rs, 21),
        scrapedAt: rs.getLong(22)
      };
      return entity;
    } catch (e) {
      throw new Error(`mapMovieEntityFromProjectedRow failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  private mapTvSeriesEntityFromProjectedRow(rs: relationalStore.ResultSet): TvSeriesEntity {
    let entity: TvSeriesEntity | null = null;
    try {
      entity = {
        id: rs.getLong(0),
        provider: rs.getString(1),
        providerId: rs.getString(2),
        title: rs.getString(3),
        originalTitle: this.core.nullableString(rs, 4),
        overview: this.core.nullableString(rs, 5),
        firstAirDate: this.core.nullableString(rs, 6),
        rating: this.core.nullableDouble(rs, 7),
        voteCount: this.core.nullableLong(rs, 8),
        posterPath: this.core.nullableString(rs, 9),
        backdropPath: this.core.nullableString(rs, 10),
        posterUrl: this.core.nullableString(rs, 11),
        backdropUrl: this.core.nullableString(rs, 12),
        posterLocalPath: this.core.nullableString(rs, 13),
        backdropLocalPath: this.core.nullableString(rs, 14),
        genresJson: this.core.nullableString(rs, 15),
        castJson: this.core.nullableString(rs, 16),
        numberOfSeasons: this.core.nullableLong(rs, 17),
        originalLanguage: this.core.nullableString(rs, 18),
        originCountryJson: this.core.nullableString(rs, 19),
        rawJson: this.core.nullableString(rs, 20),
        scrapedAt: rs.getLong(21)
      };
    } catch (e) {
      throw new Error(`mapTvSeriesEntityFromProjectedRow failed: ${e instanceof Error ? e.message : String(e)}`);
    }
    return entity!;
  }

  private async queryMovies(sql: string, args: relationalStore.ValueType[]): Promise<MovieEntity[]> {
    if (!this.core.isReady()) { return []; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(sql, args);
      const items: MovieEntity[] = [];
      if (!rs.goToFirstRow()) {
        return items;
      }
      do {
        items.push(this.mapMovieEntityFromProjectedRow(rs));
      } while (rs.goToNextRow());
      return items;
    } catch (e) {
      console.error(`[DB][queryMovies] sql=${sql} args=${JSON.stringify(args)} error=${JSON.stringify(e)}`);
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  private async queryTvSeries(sql: string, args: relationalStore.ValueType[]): Promise<TvSeriesEntity[]> {
    if (!this.core.isReady()) { return []; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(sql, args);
      const items: TvSeriesEntity[] = [];
      if (!rs.goToFirstRow()) {
        return items;
      }
      do {
        items.push(this.mapTvSeriesEntityFromProjectedRow(rs));
      } while (rs.goToNextRow());
      return items;
    } catch (e) {
      console.error(`[DB][queryTvSeries] sql=${sql} args=${JSON.stringify(args)} error=${JSON.stringify(e)}`);
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /** 按 provider+providerId 查询电影，存在则返回，不存在返回 null */
  async getMovieByProviderId(provider: string, providerId: string): Promise<MovieEntity | null> {
    const items = await this.queryMovies(
      this.buildMovieSelectSql(' WHERE provider = ? AND provider_id = ? LIMIT 1'),
      [provider, providerId]
    );
    return items.length > 0 ? items[0] : null;
  }

  async getMovieById(id: number): Promise<MovieEntity | null> {
    const items = await this.queryMovies(
      this.buildMovieSelectSql(' WHERE id = ? LIMIT 1'),
      [id]
    );
    return items.length > 0 ? items[0] : null;
  }

  /** 批量获取所有电影，供播放历史等场景一次性加载 */
  async getAllMovies(): Promise<MovieEntity[]> {
    return this.queryMovies(this.buildMovieSelectSql(), []);
  }

  /** 插入或更新电影（以 provider+provider_id 唯一），返回 id */
  async upsertMovie(e: MovieEntity): Promise<number> {
    const store = this.core.getStore();
    try {
    // 先查，有则 UPDATE，无则 INSERT OR IGNORE 保证并发安全
    const existing = await this.getMovieByProviderId(e.provider, e.providerId);
    if (existing && existing.id !== undefined) {
      const bucket: relationalStore.ValuesBucket = {
        provider: e.provider, provider_id: e.providerId, title: e.title,
        original_title: e.originalTitle ?? null, overview: e.overview ?? null,
        release_date: e.releaseDate ?? null, rating: e.rating ?? null,
        vote_count: e.voteCount ?? null, poster_path: e.posterPath ?? null,
        backdrop_path: e.backdropPath ?? null, poster_url: e.posterUrl ?? null,
        backdrop_url: e.backdropUrl ?? null, poster_local_path: e.posterLocalPath ?? null,
        backdrop_local_path: e.backdropLocalPath ?? null, genres_json: e.genresJson ?? null,
        cast_json: e.castJson ?? null, directors_json: e.directorsJson ?? null,
        runtime: e.runtime ?? null, original_language: e.originalLanguage ?? null,
        origin_country_json: e.originCountryJson ?? null,
        raw_json: e.rawJson ?? null, scraped_at: e.scrapedAt,
        title_pinyin: toPinyinFull(e.title),
        title_initials: toPinyinInitials(e.title)
      };
      const pred = new relationalStore.RdbPredicates(TABLE_MOVIES);
      pred.equalTo('id', existing.id);
      await store.update(bucket, pred);
      console.info(`[DB][upsertMovie] UPDATE id=${existing.id} title="${e.title}" posterUrl=${e.posterUrl ? e.posterUrl.substring(0, 40) : 'null'}`);
      return existing.id;
    }
    const columns: string[] = ['provider', 'provider_id', 'title', 'scraped_at'];
    const args: relationalStore.ValueType[] = [e.provider, e.providerId, e.title, e.scrapedAt];
    if (e.originalTitle !== undefined) {
      columns.push('original_title');
      args.push(e.originalTitle);
    }
    if (e.overview !== undefined) {
      columns.push('overview');
      args.push(e.overview);
    }
    if (e.releaseDate !== undefined) {
      columns.push('release_date');
      args.push(e.releaseDate);
    }
    if (e.rating !== undefined) {
      columns.push('rating');
      args.push(e.rating);
    }
    if (e.voteCount !== undefined) {
      columns.push('vote_count');
      args.push(e.voteCount);
    }
    if (e.posterPath !== undefined) {
      columns.push('poster_path');
      args.push(e.posterPath);
    }
    if (e.backdropPath !== undefined) {
      columns.push('backdrop_path');
      args.push(e.backdropPath);
    }
    if (e.posterUrl !== undefined) {
      columns.push('poster_url');
      args.push(e.posterUrl);
    }
    if (e.backdropUrl !== undefined) {
      columns.push('backdrop_url');
      args.push(e.backdropUrl);
    }
    if (e.posterLocalPath !== undefined) {
      columns.push('poster_local_path');
      args.push(e.posterLocalPath);
    }
    if (e.backdropLocalPath !== undefined) {
      columns.push('backdrop_local_path');
      args.push(e.backdropLocalPath);
    }
    if (e.genresJson !== undefined) {
      columns.push('genres_json');
      args.push(e.genresJson);
    }
    if (e.castJson !== undefined) {
      columns.push('cast_json');
      args.push(e.castJson);
    }
    if (e.directorsJson !== undefined) {
      columns.push('directors_json');
      args.push(e.directorsJson);
    }
    if (e.runtime !== undefined) {
      columns.push('runtime');
      args.push(e.runtime);
    }
    if (e.originalLanguage !== undefined) {
      columns.push('original_language');
      args.push(e.originalLanguage);
    }
    if (e.originCountryJson !== undefined) {
      columns.push('origin_country_json');
      args.push(e.originCountryJson);
    }
    if (e.rawJson !== undefined) {
      columns.push('raw_json');
      args.push(e.rawJson);
    }
    columns.push('title_pinyin');
    args.push(toPinyinFull(e.title));
    columns.push('title_initials');
    args.push(toPinyinInitials(e.title));
    const placeholders = columns.map(() => '?').join(', ');
    const sql = `INSERT INTO ${TABLE_MOVIES} (${columns.join(', ')}) VALUES (${placeholders})`;
    await store.executeSql(sql, args);
    // 查回刚插入的 id
    const inserted = await this.getMovieByProviderId(e.provider, e.providerId);
    const newId = inserted?.id ?? -1;
    if (newId <= 0) {
      const visibleMovies = await this.getAllMovies();
      const totalMovieCount = await this.core.querySingleIdValue(
        `SELECT COUNT(*) AS id FROM ${TABLE_MOVIES}`,
        []
      );
      const movieTableExists = await this.core.querySingleIdValue(
        `SELECT COUNT(*) AS id FROM sqlite_master WHERE type = 'table' AND name = '${TABLE_MOVIES}'`,
        []
      );
      throw new Error(`upsertMovie unresolved id dbName=${FileSourceDbCore.getDatabaseName()} provider=${e.provider} providerId=${e.providerId} visibleMoviesCount=${visibleMovies.length} totalMovieCount=${totalMovieCount} movieTableExists=${movieTableExists}`);
    }
    console.info(`[DB][upsertMovie] INSERT id=${newId} title="${e.title}" posterUrl=${e.posterUrl ? e.posterUrl.substring(0, 40) : 'null'}`);
    return newId;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `upsertMovie 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }

  private parseMovieEntity(rs: relationalStore.ResultSet): MovieEntity {
    try {
    const str = (col: string): string | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getString(i); };
    const num = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getLong(i); };
    const dbl = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getDouble(i); };
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      provider: rs.getString(rs.getColumnIndex('provider')),
      providerId: rs.getString(rs.getColumnIndex('provider_id')),
      title: rs.getString(rs.getColumnIndex('title')),
      originalTitle: str('original_title'), overview: str('overview'),
      releaseDate: str('release_date'), rating: dbl('rating'), voteCount: num('vote_count'),
      posterPath: str('poster_path'), backdropPath: str('backdrop_path'),
      posterUrl: str('poster_url'), backdropUrl: str('backdrop_url'),
      posterLocalPath: str('poster_local_path'), backdropLocalPath: str('backdrop_local_path'),
      genresJson: str('genres_json'), castJson: str('cast_json'), directorsJson: str('directors_json'),
      runtime: num('runtime'), originalLanguage: str('original_language'),
      originCountryJson: str('origin_country_json'),
      rawJson: str('raw_json'), scrapedAt: rs.getLong(rs.getColumnIndex('scraped_at'))
    };
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `parseMovieEntity 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }

  async getTvSeriesByProviderId(provider: string, providerId: string): Promise<TvSeriesEntity | null> {
    const items = await this.queryTvSeries(
      this.buildTvSeriesSelectSql(' WHERE provider = ? AND provider_id = ? LIMIT 1'),
      [provider, providerId]
    );
    return items.length > 0 ? items[0] : null;
  }

  /** 批量获取所有剧集，供播放历史等场景一次性加载 */
  async getAllTvSeries(): Promise<TvSeriesEntity[]> {
    return this.queryTvSeries(this.buildTvSeriesSelectSql(), []);
  }

  async upsertTvSeries(e: TvSeriesEntity): Promise<number> {
    const store = this.core.getStore();
    try {
    const existing = await this.getTvSeriesByProviderId(e.provider, e.providerId);
    if (existing && existing.id !== undefined) {
      const bucket: relationalStore.ValuesBucket = {
        provider: e.provider, provider_id: e.providerId, title: e.title,
        original_title: e.originalTitle ?? null, overview: e.overview ?? null,
        first_air_date: e.firstAirDate ?? null, rating: e.rating ?? null,
        vote_count: e.voteCount ?? null, poster_path: e.posterPath ?? null,
        backdrop_path: e.backdropPath ?? null, poster_url: e.posterUrl ?? null,
        backdrop_url: e.backdropUrl ?? null, poster_local_path: e.posterLocalPath ?? null,
        backdrop_local_path: e.backdropLocalPath ?? null, genres_json: e.genresJson ?? null,
        cast_json: e.castJson ?? null, number_of_seasons: e.numberOfSeasons ?? null,
        original_language: e.originalLanguage ?? null, origin_country_json: e.originCountryJson ?? null,
        raw_json: e.rawJson ?? null,
        scraped_at: e.scrapedAt,
        title_pinyin: toPinyinFull(e.title),
        title_initials: toPinyinInitials(e.title)
      };
      const pred = new relationalStore.RdbPredicates(TABLE_TV_SERIES);
      pred.equalTo('id', existing.id);
      await store.update(bucket, pred);
      return existing.id;
    }
    const insertBucket: relationalStore.ValuesBucket = {
      provider: e.provider,
      provider_id: e.providerId,
      title: e.title,
      original_title: e.originalTitle ?? null,
      overview: e.overview ?? null,
      first_air_date: e.firstAirDate ?? null,
      rating: e.rating ?? null,
      vote_count: e.voteCount ?? null,
      poster_path: e.posterPath ?? null,
      backdrop_path: e.backdropPath ?? null,
      poster_url: e.posterUrl ?? null,
      backdrop_url: e.backdropUrl ?? null,
      poster_local_path: e.posterLocalPath ?? null,
      backdrop_local_path: e.backdropLocalPath ?? null,
      genres_json: e.genresJson ?? null,
      cast_json: e.castJson ?? null,
      number_of_seasons: e.numberOfSeasons ?? null,
      original_language: e.originalLanguage ?? null,
      origin_country_json: e.originCountryJson ?? null,
      raw_json: e.rawJson ?? null,
      scraped_at: e.scrapedAt,
      title_pinyin: toPinyinFull(e.title),
      title_initials: toPinyinInitials(e.title)
    };
    let insertedRowId = -1;
    try {
      insertedRowId = await store.insert(TABLE_TV_SERIES, insertBucket);
    } catch (insertError) {
      const recovered = await this.getTvSeriesByProviderId(e.provider, e.providerId);
      if (recovered && recovered.id !== undefined) {
        return recovered.id;
      }
      const insertErr = insertError as BusinessError;
      throw new Error(insertErr.message);
    }
    const inserted = await this.getTvSeriesByProviderId(e.provider, e.providerId);
    const fallbackId = await this.core.querySingleIdValue(
      `SELECT id FROM ${TABLE_TV_SERIES} WHERE provider = ? AND provider_id = ? LIMIT 1`,
      [e.provider, e.providerId]
    );
    const lastInsertedId = await this.core.lastInsertedRowId();
    const resolvedId = inserted?.id ?? (insertedRowId > 0 ? insertedRowId : (fallbackId > 0 ? fallbackId : lastInsertedId));
    if (resolvedId <= 0) {
      const totalSeriesCount = await this.core.querySingleIdValue(
        `SELECT COUNT(*) AS id FROM ${TABLE_TV_SERIES}`,
        []
      );
      const matchedSeriesCount = await this.core.querySingleIdValue(
        `SELECT COUNT(*) AS id FROM ${TABLE_TV_SERIES} WHERE provider = ? AND provider_id = ?`,
        [e.provider, e.providerId]
      );
      const visibleSeries = await this.getAllTvSeries();
      throw new Error(
        `upsertTvSeries unresolved id dbName=${FileSourceDbCore.getDatabaseName()} provider=${e.provider} providerId=${e.providerId} fallbackId=${fallbackId} lastInsertedId=${lastInsertedId} totalSeriesCount=${totalSeriesCount} matchedSeriesCount=${matchedSeriesCount} visibleSeriesCount=${visibleSeries.length}`
      );
    }
    return resolvedId;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `upsertTvSeries 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }

  private parseTvSeriesEntity(rs: relationalStore.ResultSet): TvSeriesEntity {
    try {
    const optionalIndex = (col: string): number => {
      try {
        return rs.getColumnIndex(col);
      } catch {
        return -1;
      }
    };
    const str = (col: string): string | undefined => {
      const i = optionalIndex(col);
      return i < 0 || rs.isColumnNull(i) ? undefined : rs.getString(i);
    };
    const num = (col: string): number | undefined => {
      const i = optionalIndex(col);
      return i < 0 || rs.isColumnNull(i) ? undefined : rs.getLong(i);
    };
    const dbl = (col: string): number | undefined => {
      const i = optionalIndex(col);
      return i < 0 || rs.isColumnNull(i) ? undefined : rs.getDouble(i);
    };
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      provider: rs.getString(rs.getColumnIndex('provider')),
      providerId: rs.getString(rs.getColumnIndex('provider_id')),
      title: rs.getString(rs.getColumnIndex('title')),
      originalTitle: str('original_title'), overview: str('overview'),
      firstAirDate: str('first_air_date'), rating: dbl('rating'), voteCount: num('vote_count'),
      posterPath: str('poster_path'), backdropPath: str('backdrop_path'),
      posterUrl: str('poster_url'), backdropUrl: str('backdrop_url'),
      posterLocalPath: str('poster_local_path'), backdropLocalPath: str('backdrop_local_path'),
      genresJson: str('genres_json'), castJson: str('cast_json'),
      numberOfSeasons: num('number_of_seasons'), originalLanguage: str('original_language'),
      originCountryJson: str('origin_country_json'),
      rawJson: str('raw_json'), scrapedAt: rs.getLong(rs.getColumnIndex('scraped_at'))
    };
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `parseTvSeriesEntity 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }

  async getTvSeason(seriesId: number, seasonNumber: number): Promise<TvSeasonEntity | null> {
    if (!this.core.isReady()) { return null; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(
        `SELECT * FROM ${TABLE_TV_SEASONS} WHERE series_id = ? AND season_number = ? LIMIT 1`,
        [seriesId, seasonNumber]
      );
      if (rs.goToFirstRow()) { return this.parseTvSeasonEntity(rs); }
      return null;
    } catch { return null; } finally { try { rs?.close(); } catch { } }
  }

  async upsertTvSeason(e: TvSeasonEntity): Promise<number> {
    const store = this.core.getStore();
    try {
    const existing = await this.getTvSeason(e.seriesId, e.seasonNumber);
    if (existing && existing.id !== undefined) {
      const bucket: relationalStore.ValuesBucket = {
        series_id: e.seriesId, provider: e.provider, provider_id: e.providerId,
        season_number: e.seasonNumber, title: e.title ?? null, overview: e.overview ?? null,
        air_date: e.airDate ?? null, episode_count: e.episodeCount ?? null,
        poster_path: e.posterPath ?? null, poster_url: e.posterUrl ?? null,
        poster_local_path: e.posterLocalPath ?? null, raw_json: e.rawJson ?? null,
        scraped_at: e.scrapedAt
      };
      const pred = new relationalStore.RdbPredicates(TABLE_TV_SEASONS);
      pred.equalTo('id', existing.id);
      await store.update(bucket, pred);
      return existing.id;
    }
    const sql = `
      INSERT OR IGNORE INTO ${TABLE_TV_SEASONS}
        (series_id, provider, provider_id, season_number, title, overview,
         air_date, episode_count, poster_path, poster_url, poster_local_path, raw_json, scraped_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
    `;
    const args: relationalStore.ValueType[] = [
      e.seriesId, e.provider, e.providerId, e.seasonNumber,
      e.title ?? null, e.overview ?? null, e.airDate ?? null,
      e.episodeCount !== undefined ? e.episodeCount : null,
      e.posterPath ?? null, e.posterUrl ?? null, e.posterLocalPath ?? null,
      e.rawJson ?? null, e.scrapedAt
    ];
    await store.executeSql(sql, args);
    const inserted = await this.getTvSeason(e.seriesId, e.seasonNumber);
    const fallbackId = await this.core.querySingleIdValue(
      `SELECT id FROM ${TABLE_TV_SEASONS} WHERE series_id = ? AND season_number = ? LIMIT 1`,
      [e.seriesId, e.seasonNumber]
    );
    return inserted?.id ?? (fallbackId > 0 ? fallbackId : await this.core.lastInsertedRowId());
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `upsertTvSeason 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }

  private parseTvSeasonEntity(rs: relationalStore.ResultSet): TvSeasonEntity {
    try {
    const str = (col: string): string | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getString(i); };
    const num = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getLong(i); };
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      seriesId: rs.getLong(rs.getColumnIndex('series_id')),
      provider: rs.getString(rs.getColumnIndex('provider')),
      providerId: rs.getString(rs.getColumnIndex('provider_id')),
      seasonNumber: rs.getLong(rs.getColumnIndex('season_number')),
      title: str('title'), overview: str('overview'), airDate: str('air_date'),
      episodeCount: num('episode_count'), posterPath: str('poster_path'),
      posterUrl: str('poster_url'), posterLocalPath: str('poster_local_path'),
      rawJson: str('raw_json'), scrapedAt: rs.getLong(rs.getColumnIndex('scraped_at'))
    };
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `parseTvSeasonEntity 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }

  async getTvEpisode(seriesId: number, seasonNumber: number, episodeNumber: number): Promise<TvEpisodeEntity | null> {
    if (!this.core.isReady()) { return null; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await store.querySql(
        `SELECT * FROM ${TABLE_TV_EPISODES} ` +
        `WHERE series_id = ? AND season_number = ? AND episode_number = ? LIMIT 1`,
        [seriesId, seasonNumber, episodeNumber]
      );
      if (rs.goToFirstRow()) { return this.parseTvEpisodeEntity(rs); }
      return null;
    } catch { return null; } finally { try { rs?.close(); } catch { } }
  }

  /** 获取某部剧某季的全部集（按 episode_number 升序），用于季详情页集列表展示 */
  async getEpisodesBySeriesAndSeason(seriesId: number, seasonNumber: number): Promise<TvEpisodeEntity[]> {
    if (!this.core.isReady()) { return []; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql = `SELECT * FROM ${TABLE_TV_EPISODES}
        WHERE series_id = ? AND season_number = ?
        ORDER BY episode_number ASC`;
      rs = await store.querySql(sql, [seriesId, seasonNumber]);
      const items: TvEpisodeEntity[] = [];
      while (rs.goToNextRow()) { items.push(this.parseTvEpisodeEntity(rs)); }
      return items;
    } catch (e) {
      console.error('[DB][getEpisodesBySeriesAndSeason]', JSON.stringify(e));
      return [];
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /** 获取剧集中 season_number > 0 的最小季、最小集号的第一集（用于续播卡片默认展示） */
  async getFirstTvEpisode(seriesId: number): Promise<TvEpisodeEntity | null> {
    if (!this.core.isReady()) { return null; }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | null = null;
    try {
      const sql = `SELECT * FROM ${TABLE_TV_EPISODES}
        WHERE series_id = ? AND season_number > 0
        ORDER BY season_number ASC, episode_number ASC
        LIMIT 1`;
      rs = await store.querySql(sql, [seriesId]);
      if (rs.goToFirstRow()) { return this.parseTvEpisodeEntity(rs); }
      return null;
    } catch { return null; } finally { try { rs?.close(); } catch { } }
  }

  async upsertTvEpisode(e: TvEpisodeEntity): Promise<number> {
    const store = this.core.getStore();
    try {
    const existing = await this.getTvEpisode(e.seriesId, e.seasonNumber, e.episodeNumber);
    if (existing && existing.id !== undefined) {
      const bucket: relationalStore.ValuesBucket = {
        series_id: e.seriesId, season_id: e.seasonId !== undefined ? e.seasonId : null,
        provider: e.provider, provider_id: e.providerId,
        season_number: e.seasonNumber, episode_number: e.episodeNumber,
        title: e.title ?? null, overview: e.overview ?? null, air_date: e.airDate ?? null,
        runtime: e.runtime !== undefined ? e.runtime : null,
        rating: e.rating !== undefined ? e.rating : null,
        still_path: e.stillPath ?? null, still_url: e.stillUrl ?? null,
        raw_json: e.rawJson ?? null, scraped_at: e.scrapedAt
      };
      const pred = new relationalStore.RdbPredicates(TABLE_TV_EPISODES);
      pred.equalTo('id', existing.id);
      await store.update(bucket, pred);
      return existing.id;
    }
    const sql = `
      INSERT OR IGNORE INTO ${TABLE_TV_EPISODES}
        (series_id, season_id, provider, provider_id, season_number, episode_number,
         title, overview, air_date, runtime, rating, still_path, still_url, raw_json, scraped_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    `;
    const args: relationalStore.ValueType[] = [
      e.seriesId, e.seasonId !== undefined ? e.seasonId : null,
      e.provider, e.providerId, e.seasonNumber, e.episodeNumber,
      e.title ?? null, e.overview ?? null, e.airDate ?? null,
      e.runtime !== undefined ? e.runtime : null,
      e.rating !== undefined ? e.rating : null,
      e.stillPath ?? null, e.stillUrl ?? null,
      e.rawJson ?? null, e.scrapedAt
    ];
    await store.executeSql(sql, args);
    const inserted = await this.getTvEpisode(e.seriesId, e.seasonNumber, e.episodeNumber);
    const fallbackId = await this.core.querySingleIdValue(
      `SELECT id FROM ${TABLE_TV_EPISODES} ` +
      `WHERE series_id = ? AND season_number = ? AND episode_number = ? LIMIT 1`,
      [e.seriesId, e.seasonNumber, e.episodeNumber]
    );
    return inserted?.id ?? (fallbackId > 0 ? fallbackId : await this.core.lastInsertedRowId());
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `upsertTvEpisode 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }

  private parseTvEpisodeEntity(rs: relationalStore.ResultSet): TvEpisodeEntity {
    try {
    const str = (col: string): string | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getString(i); };
    const num = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getLong(i); };
    const dbl = (col: string): number | undefined => { const i = rs.getColumnIndex(col); return rs.isColumnNull(i) ? undefined : rs.getDouble(i); };
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      seriesId: rs.getLong(rs.getColumnIndex('series_id')),
      seasonId: num('season_id'),
      provider: rs.getString(rs.getColumnIndex('provider')),
      providerId: rs.getString(rs.getColumnIndex('provider_id')),
      seasonNumber: rs.getLong(rs.getColumnIndex('season_number')),
      episodeNumber: rs.getLong(rs.getColumnIndex('episode_number')),
      title: str('title'), overview: str('overview'), airDate: str('air_date'),
      runtime: num('runtime'), rating: dbl('rating'),
      stillPath: str('still_path'), stillUrl: str('still_url'),
      rawJson: str('raw_json'), scrapedAt: rs.getLong(rs.getColumnIndex('scraped_at'))
    };
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'FileSourceDatabase', `parseTvEpisodeEntity 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }

  /**
   * 按主键查询 tv_series 行（用于剧集详情页显示简介/类别/演员等）
   */
  async getTvSeriesById(id: number): Promise<TvSeriesEntity | null> {
    const items = await this.queryTvSeries(
      this.buildTvSeriesSelectSql(' WHERE id = ? LIMIT 1'),
      [id]
    );
    return items.length > 0 ? items[0] : null;
  }

  /**
   * 检查指定 movie 是否已有 origin_country_json。
   */
  async hasMovieOriginCountry(movieId: number): Promise<boolean> {
    if (!this.core.isReady()) {
      return false;
    }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | undefined;
    try {
      rs = await store.querySql('SELECT origin_country_json FROM movies WHERE id = ?', [movieId]);
      if (rs.goToNextRow()) {
        const idx = rs.getColumnIndex('origin_country_json');
        const isNull = rs.isColumnNull(idx);
        return !isNull;
      }
      return false;
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[DB][hasMovieOriginCountry] 失败 code=${err.code} msg=${err.message}`);
      return false;
    } finally {
      try { rs?.close(); } catch { }
    }
  }

  /**
   * 检查指定 tv_series 是否已有 origin_country_json。
   */
  async hasTvSeriesOriginCountry(seriesId: number): Promise<boolean> {
    if (!this.core.isReady()) {
      return false;
    }
    const store = this.core.getStore();
    let rs: relationalStore.ResultSet | undefined;
    try {
      rs = await store.querySql('SELECT origin_country_json FROM tv_series WHERE id = ?', [seriesId]);
      if (rs.goToNextRow()) {
        const idx = rs.getColumnIndex('origin_country_json');
        const isNull = rs.isColumnNull(idx);
        return !isNull;
      }
      return false;
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[DB][hasTvSeriesOriginCountry] 失败 code=${err.code} msg=${err.message}`);
      return false;
    } finally {
      try { rs?.close(); } catch { }
    }
  }
}
