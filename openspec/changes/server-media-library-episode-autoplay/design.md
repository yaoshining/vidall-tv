## Context

文件源 / 本地媒体库的自动连播由三层构成（见 `file-explorer-playback-context` 等既有能力）：

1. `PlaybackContext` 体系：`MediaLibraryContext` / `FileExplorerContext` 携带集列表与 `currentIndex`
2. `EpisodePlaybackManager.sync()`：播放器页 500ms 轮询，近完播返回倒计时浮层状态 / 切集指令
3. 播放器页 `handleEpisodeSelect()`：解析下一集源并原地 `reloadSource`

影视服务器 4 个播放入口（`MediaLibraryTab.doServerDirectPlayWithServer`、`ServerMediaDetailPage.play`、`ServerSeasonDetailPage.playEpisode`、`ServerSeasonDetailPage.playMediaItem`）均不传 `playbackContext`，故 `EpisodePlaybackManager` 返回 idle。服务器客户端已具备 `getSeasons` / `getEpisodes` / `getStreamUrl` / `getStreamHeader`；进度上报由 `ServerProgressReporter`（started / progress / stopped，按 playSessionId 串行队列）承担。

## Goals / Non-Goals

**Goals**

- 服务器剧集播放复用既有自动连播机制：同一开关、同一倒计时、同一浮层 UI 与取消行为
- 切集时服务器进度上报正确衔接：旧集 stopped → 新会话 started，服务端「接下来」随之推进
- 列表拉取失败时静默降级，绝不阻塞起播

**Non-Goals**

- 不跨季连播（与文件源「按当季列表连播」一致）
- 不新增设置项或新浮层 UI
- 不改动 `ServerProgressReporter` 队列机制
- 不处理服务器直播 / 转码画质切换等播放策略问题

## Decisions

### D1：新增 `ServerMediaLibraryContext`，而非复用 `MediaLibraryContext`

`MediaLibraryContext` 的条目定位与切集都依赖本地 DB（`sourceId` / `videoId` / `SourceAdapterService`），服务器条目标识是字符串 `serverItemId`，两者数据来源与切集路径完全不同。新增 `contextType: 'server_media_library'` 上下文类，条目 `videoPath` 存服务器条目 ID（沿用基类 `hasNext` / `jumpTo*` 导航语义），另附 `serverType` / `serverId` / `seriesTitle` / `posterUrl` / `backdropUrl` 等切集渲染所需字段。备选方案（给 `PlaybackContextItem` 加服务器字段并塞进 `MediaLibraryContext`）会污染本地媒体库语义，放弃。

### D2：上下文构建纯函数化，保证可单测

仿照 `MediaLibraryContext.buildItems`：静态 `buildItems(episodes, currentItemKey)` 返回 `{ items, currentIndex }`，不依赖 DB 与网络；`build()` 工厂方法负责客户端调用。集展示标题复用季详情页现有格式（`系列名 季名 第N集 分集名`），缺集名时回退 `第N集`。

### D3：四个入口的集列表解析策略

- **季详情页**：已持有 `episodes: VideoServerEpisode[]`，直接构建，零额外请求
- **详情页 / 跨季续播 / 首页直播放**：仅有 `seriesId + seasonNumber`，需先 `getSeasons(seriesId)` 按 `seasonNumber` 匹配 `seasonId`，再 `getEpisodes(seriesId, seasonId)`。复用两个客户端既有 API；两步中任一步失败 → 降级为无上下文播放（spec 的降级要求）
- **电影**：不构建上下文，天然走既有无上下文路径

### D4：切集在 `handleEpisodeSelect` 增加 server 分支

既有 `file_explorer` 分支纯本地换 URL、`media_library` 分支走 `SourceAdapterService`；server 分支按 `context.serverType/serverId` 构建客户端 → `getStreamUrl(next.serverItemId)` + `getStreamHeader()` → 生成新 `serverPlaySessionId` → 复用页内既有 `reportServerProgress()` 上报旧集 stopped（位置取切集时刻播放位置，近完播场景即标记看完）→ `reportServerPlaybackStarted` 上报新集 → 组装新 `PlayerPageParam` 原地 `reloadSource` + `context.jumpTo(index)`。下一集起播位置取其 `positionMs`（未看则为 0，从头播）。

### D5：近完播「继续播放指针推进」不在 server 侧实现

`getNextEpisodeHintForNearEnd()` 依赖 TMDB mediaKey，仅适用本地媒体库。服务器侧「接下来 / 继续观看」由服务端根据 stopped/started 上报自行计算，客户端无需也不应再推进本地 media_progress。该函数对 server 上下文保持返回 null，无需修改。

### D6：浮层轮询与设置零改动

`EpisodePlaybackManager.getContextForAutoplay` 仅需在上下文类型白名单中加入 `'server_media_library'`；倒计时、取消、`suppressedEpisodeKey` 失败抑制、浮层 UI 全部复用。全局设置 `EpisodeAutoplayPreferences` 天然覆盖新上下文。

## Risks / Trade-offs

- [切集时 `getStreamUrl` 网络延迟] → 倒计时归零才触发切集，切换期间播放器已有 loading 态；失败走既有「自动播放下一集失败」toast + 抑制
- [首页直播放起播前新增 2 次列表请求，起播变慢] → 仅剧集条目触发；失败静默降级；季详情页主路径零额外请求
- [集列表与服务器实际播放状态短暂不一致（如在别处看过）] → 连播按当季线性顺序推进，下一集 `positionMs` 由起播参数传入，服务端进度以上报为准
- [旧集 stopped 上报失败不阻塞切集] → `reportServerProgress` 已有 catch，切集继续

## Migration Plan

纯增量：新上下文类 + 入口附带参数 + 播放器新分支，不改既有文件源 / 本地媒体库行为。回滚仅需移除入口处的上下文附带即可完全恢复旧行为。

## Open Questions

（无）
