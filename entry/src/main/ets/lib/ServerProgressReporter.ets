import { JellyfinClient } from './JellyfinClient';
import { PlexClient } from './PlexClient';

/**
 * 上报影视服务器播放开始（会话建立）。
 * Jellyfin/Emby 需要 playSessionId 关联整个会话；Plex 通过 ratingKey 关联。
 */
export async function reportServerPlaybackStarted(
  serverType: string,
  serverConfigJson: string,
  itemId: string,
  playSessionId: string,
  positionMs: number,
  durationMs: number
): Promise<void> {
  if (serverType === 'plex') {
    await PlexClient.fromConfigJson(serverConfigJson).reportPlaying(itemId, positionMs, durationMs);
  } else {
    const client = JellyfinClient.fromConfigJson(serverConfigJson);
    const mediaSourceId = await client.getPlaybackInfo(itemId);
    await client.reportPlaying(playSessionId, itemId, mediaSourceId, positionMs);
  }
}

/**
 * 周期性上报影视服务器播放进度（不结束会话）。
 */
export async function reportServerPlaybackProgress(
  serverType: string,
  serverConfigJson: string,
  itemId: string,
  playSessionId: string,
  positionMs: number,
  durationMs: number
): Promise<void> {
  if (serverType === 'plex') {
    await PlexClient.fromConfigJson(serverConfigJson).reportProgress(itemId, positionMs, durationMs);
  } else {
    await JellyfinClient.fromConfigJson(serverConfigJson).reportProgress(playSessionId, itemId, positionMs, false);
  }
}

/**
 * 上报影视服务器播放停止（退出播放器时调用），供服务器「继续观看」续播。
 */
export async function reportServerPlaybackStopped(
  serverType: string,
  serverConfigJson: string,
  itemId: string,
  playSessionId: string,
  positionMs: number,
  durationMs: number
): Promise<void> {
  if (serverType === 'plex') {
    await PlexClient.fromConfigJson(serverConfigJson).reportStopped(itemId, positionMs, durationMs);
  } else {
    await JellyfinClient.fromConfigJson(serverConfigJson).reportStopped(playSessionId, itemId, positionMs);
  }
}
