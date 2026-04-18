## Why

播放器目前只支持单集播放，没有"我在哪个剧集里、前后集是什么"的概念，导致用户无法在播放器内切集、看集数列表或看已看/未看状态。同时媒体库对未刮削文件的展示策略不清晰，需要统一。

## What Changes

- 新增 `PlaybackContext` 抽象类体系（`MediaLibraryContext` / `FileExplorerContext`），解耦播放器与数据来源
- `VideoPlayerController` 新增可选的 `playbackContext?: PlaybackContext` 字段
- `PlayerSettingsDialog` 根据 `contextType` 决定是否展示剧集列表面板（`EpisodeListPanel`）
- `PlayerPageParam` 新增 `playbackContext` 字段，由调用方在进入播放器前构建并传入（选项A：预加载）
- 媒体库过滤策略：`getRecentlyAddedList()` 移除未刮削视频（无 `scrape_info`）那一路查询；有 `scrape_info` 但无海报的内容用标题兜底展示，不过滤
- 未刮削视频数据保留在 DB，便于补全元信息

## Capabilities

### New Capabilities

- `playback-context`: PlaybackContext 抽象类及其两个具体实现（MediaLibraryContext、FileExplorerContext），含响应式状态（@ObservedV2/@Trace）、集数列表、jumpTo/hasNext/hasPrev 接口
- `episode-list-panel`: 播放器设置弹层内的剧集列表面板 UI，含已看标记、当前集高亮、TV 遥控器焦点管理
- `media-library-filter`: 媒体库展示过滤策略（有 scrape_info 的才展示，无海报用标题兜底）

### Modified Capabilities

- `player-settings-ui-tests`: PlayerSettingsDialog 新增剧集列表 Tab，现有 UI 测试需补充新场景断言

## Impact

**新增文件：**
- `entry/src/main/ets/components/core/player/PlaybackContext.ets`（抽象类 + MediaLibraryContext + FileExplorerContext）
- `entry/src/main/ets/components/core/player/EpisodeListPanel.ets`（UI 组件）

**修改文件：**
- `entry/src/main/ets/components/core/player/VideoPlayerController.ets`（+1 字段）
- `entry/src/main/ets/components/core/player/VideoControls.ets`（PlayerSettingsDialog 扩展）
- `entry/src/main/ets/pages/player/index.ets`（PlayerPageParam 扩展 + 注入逻辑）
- `entry/src/main/ets/pages/detail/SeasonDetailPage.ets`（构建 MediaLibraryContext 并传参）
- `entry/src/main/ets/pages/detail/SeriesDetailPage.ets`（同上）
- `entry/src/main/ets/db/files/FileSourceDatabase.ets`（getRecentlyAddedList 移除未刮削路）

**测试：**
- TDD 开发，测试用例覆盖：PlaybackContext 状态切换、jumpTo 边界、hasNext/hasPrev、MediaLibraryContext 加载逻辑
- 提交前本地跑单测（`hvigorw test`）+ 集成测试，全通后创建 PR
