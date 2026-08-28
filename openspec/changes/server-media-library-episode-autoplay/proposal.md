# Proposal: server-media-library-episode-autoplay

## Why

影视服务器（Jellyfin / Plex）媒体库中播放剧集时，播完不会自动播放下一集；而文件源 / 本地媒体库已有完整的「自动下一集」能力（倒计时浮层 + 取消 + 全局开关）。两条播放链路体验不一致，用户观看服务器剧集时需要手动手动切集，体验割裂。

## What Changes

- 新增 `ServerMediaLibraryContext`（`contextType: 'server_media_library'`）播放上下文：由服务器当季剧集列表（`VideoServerEpisode[]`）构建，携带切集所需的服务器标识与集信息
- 影视服务器 4 个剧集播放入口在起播时附带该上下文：
  1. `MediaLibraryTab` 继续观看 / 接下来 episode 直播放
  2. `ServerMediaDetailPage` 详情页播放（series 播 nextUp）
  3. `ServerSeasonDetailPage.playEpisode` 季详情页单集播放
  4. `ServerSeasonDetailPage.playMediaItem` 跨季「继续上次观看」
- `EpisodePlaybackManager` 放行 `server_media_library` 上下文，完整复用既有倒计时 / 取消 / 失败抑制逻辑
- 播放器 `handleEpisodeSelect` 增加 server 切集分支：经 Jellyfin/Plex 客户端解析下一集流 URL 与 Header、生成新 playSessionId、旧集上报 stopped、新集上报 started、原地 `reloadSource` 切集
- 电影及当季集列表拉取失败时降级为无上下文播放（不自动连播），不阻塞起播
- 自动连播设置与浮层 UI 完全复用现有实现（全局「自动下一集」开关 + 3~10s 倒计时），不新增设置项
- 行为边界与文件源一致：仅当季内连播，当季最后一集播完不跨季连播

## Capabilities

### New Capabilities

- `server-media-library-episode-autoplay`: 影视服务器媒体库播放的剧集自动连播能力——服务器播放上下文构建、四入口附带上下文、播放器内按剧集信息自动切集与进度上报衔接

### Modified Capabilities

（无：既有能力的需求不发生变化，文件源/本地媒体库行为保持不变）

## Impact

- `entry/src/main/ets/components/core/player/PlaybackContext.ets`：新增 `ServerMediaLibraryContext`
- `entry/src/main/ets/components/core/player/EpisodePlaybackManager.ets`：上下文类型放行
- `entry/src/main/ets/pages/player/index.ets`：切集 server 分支与上报衔接
- `entry/src/main/ets/pages/home/tabs/MediaLibraryTab.ets`、`entry/src/main/ets/pages/detail/ServerMediaDetailPage.ets`、`entry/src/main/ets/pages/detail/ServerSeasonDetailPage.ets`：起播时构建并附带上下文
- `entry/src/main/ets/lib/JellyfinClient.ets` / `PlexClient.ets`：仅复用既有 API（`getSeasons` / `getEpisodes` / `getStreamUrl` / `getStreamHeader`），无接口变更
- 单测：新增 `ServerMediaLibraryContext.test.ets`，扩展 `EpisodePlaybackManager.test.ets`
