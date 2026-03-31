import { FileSourceDatabase } from './files/FileSourceDatabase';
import { MediaProgressEntry } from './models/MediaEntity';

/**
 * 媒体级播放进度读写工具类。
 *
 * Key 规则：
 *   - 剧集：media_progress_series_<seriesProviderId>
 *   - 电影：media_progress_movie_<movieId>
 *
 * 完播阈值：剩余时长 < 60 秒 或 已播比例 > 95%，由调用方判断后调用 clear()。
 */
export class MediaProgressStore {
  /** 构造剧集媒体进度 key */
  static seriesKey(seriesProviderId: string): string {
    return `media_progress_series_${seriesProviderId}`;
  }

  /** 构造电影媒体进度 key */
  static movieKey(movieId: string): string {
    return `media_progress_movie_${movieId}`;
  }

  /**
   * 判断当前播放位置是否达到完播阈值。
   * 剩余时长 < 60 秒 或 已播比例 > 95% 视为完播。
   */
  static isNearEnd(positionMs: number, durationMs: number): boolean {
    if (durationMs <= 0) {
      return false;
    }
    return (durationMs - positionMs) < 60000 || positionMs > durationMs * 0.95;
  }

  /**
   * 保存媒体级进度。
   * @param key         由 seriesKey / movieKey 生成的存储键
   * @param posMs       当前播放位置（毫秒）
   * @param durMs       视频总时长（毫秒）
   * @param seasonNumber  剧集：季号（电影传 0）
   * @param episodeNumber 剧集：集号（电影传 0）
   */
  static async save(
    key: string,
    posMs: number,
    durMs: number,
    seasonNumber: number,
    episodeNumber: number
  ): Promise<void> {
    const entry: MediaProgressEntry = {
      mediaKey: key,
      positionMs: posMs,
      durationMs: durMs,
      lastPlayedAt: Date.now(),
      episodeNumber: episodeNumber,
      seasonNumber: seasonNumber
    };
    await FileSourceDatabase.getInstance().upsertMediaProgress(entry);
  }

  /**
   * 读取媒体级进度，不存在时返回 null。
   */
  static async get(key: string): Promise<MediaProgressEntry | null> {
    return FileSourceDatabase.getInstance().getMediaProgress(key);
  }

  /**
   * 清除媒体级进度（完播重置）。
   */
  static async clear(key: string): Promise<void> {
    await FileSourceDatabase.getInstance().clearMediaProgress(key);
  }
}
