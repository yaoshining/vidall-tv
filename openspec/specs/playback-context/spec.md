# Playback Context

## Purpose

定义播放器可选播放上下文的当前实现边界，使播放器可以接收当季剧集集合与当前集索引，并按当前已落地的方式在设置面板中展示选集区块。

## Requirements

### Requirement: 播放器接受可选 PlaybackContext

播放器 SHALL 接受一个可选的 `PlaybackContext` 作为播放会话上下文；当调用方未传入该字段时，播放器继续保持单文件播放流程，不因缺少上下文报错。

#### Scenario: 无上下文时保持基础播放
- **WHEN** `PlayerPageParam.playbackContext` 未设置
- **THEN** `PlayerPage` 仍可初始化播放器
- **AND** `VideoPlayerController.playbackContext` 被显式更新为 `undefined`

#### Scenario: 有上下文时写入控制器
- **WHEN** 调用方传入 `PlayerPageParam.playbackContext`
- **THEN** `PlayerPage` 将该值赋给 `VideoPlayerController.playbackContext`

---

### Requirement: MediaLibraryContext 表达当前季剧集集合

系统 SHALL 提供 `MediaLibraryContext extends PlaybackContext`，用于表达当前实现中的媒体库剧集上下文。

`MediaLibraryContext` SHALL：
- `contextType` 固定为 `'media_library'`
- 暴露 `seriesId`、`seasonNumber`、`episodes`、`items`、`currentIndex`
- 通过 `build(db, seriesId, seasonNumber, currentVideoPath)` 查询整部剧数据后按 `seasonNumber` 过滤当前季
- 通过 `currentVideoPath` 定位 `currentIndex`，未命中时回退为 `0`
- 为每个 `PlaybackContextItem` 填充 `videoPath`、`title`、`index`、可选 `episodeNumber` 与可选 `thumbnailUrl`

#### Scenario: buildItems 按季过滤并定位当前集
- **WHEN** 调用 `MediaLibraryContext.buildItems(allItems, 1, '/ep2.mkv')`
- **THEN** 返回结果仅包含第 1 季条目
- **AND** `currentIndex` 指向 `'/ep2.mkv'` 对应的集

#### Scenario: currentVideoPath 未命中时回退到第 0 集
- **WHEN** `currentVideoPath` 不在当前季列表中
- **THEN** `currentIndex` 返回 `0`

#### Scenario: 标题缺失时回退到文件名
- **WHEN** 某个媒体项的 `title` 为 `undefined`
- **THEN** 对应 `PlaybackContextItem.title` 使用 `fileName`

#### Scenario: 剧集缩略图优先来自 still 图
- **WHEN** `TvEpisodeEntity.stillUrl` 存在
- **THEN** `PlaybackContextItem.thumbnailUrl` 使用 `stillUrl`

#### Scenario: stillUrl 缺失时由 stillPath 生成缩略图地址
- **WHEN** `TvEpisodeEntity.stillUrl` 缺失且 `stillPath` 存在
- **THEN** `PlaybackContextItem.thumbnailUrl` 使用 `https://image.tmdb.org/t/p/w342${stillPath}`

---

### Requirement: PlaybackContext 导航契约反映当前已实现行为

系统 SHALL 提供 `PlaybackContext` 抽象基类与当前两个已落地的具体类型：`MediaLibraryContext`、`FileExplorerContext`。

#### Scenario: 抽象基类提供前后集判断
- **WHEN** `currentIndex === items.length - 1`
- **THEN** `hasNext` 返回 `false`

#### Scenario: 抽象基类提供前一集判断
- **WHEN** `currentIndex === 0`
- **THEN** `hasPrev` 返回 `false`

#### Scenario: MediaLibraryContext 支持按索引切换上下文位置
- **WHEN** 调用 `MediaLibraryContext.jumpTo(2)` 且索引有效
- **THEN** `currentIndex` 更新为 `2`
- **AND** 返回 `items[2]`

#### Scenario: MediaLibraryContext 越界跳转返回 null
- **WHEN** 调用 `jumpTo(-1)` 或 `jumpTo(items.length)`
- **THEN** 返回 `null`
- **AND** `currentIndex` 保持不变

#### Scenario: FileExplorerContext 仍是骨架实现
- **WHEN** 调用 `FileExplorerContext.jumpTo(0)`、`jumpToNext()` 或 `jumpToPrev()`
- **THEN** 返回 `null`

---

### Requirement: 媒体库入口在进入播放器前构建上下文

当前实现中，媒体库入口 SHALL 在跳转播放器前预构建 `MediaLibraryContext` 并通过 `PlayerPageParam` 注入；当 `seriesId` 或 `seasonNumber` 不可用时，可以跳过上下文构建而不阻断播放。

#### Scenario: SeasonDetailPage 预构建并注入上下文
- **WHEN** 用户从 `SeasonDetailPage` 播放某一集，且 `seriesId > 0` 且 `seasonNumber > 0`
- **THEN** 页面调用 `MediaLibraryContext.build(...)`
- **AND** 将结果写入 `PlayerPageParam.playbackContext`

#### Scenario: SeriesDetailPage 预构建并注入上下文
- **WHEN** 用户从 `SeriesDetailPage` 播放某一集，且 `seriesId > 0` 且 `seasonNumber > 0`
- **THEN** 页面调用 `MediaLibraryContext.build(...)`
- **AND** 将结果写入 `PlayerPageParam.playbackContext`

---

### Requirement: PlayerSettingsDialog 仅在媒体库上下文下显示选集区块

`PlayerSettingsDialog` SHALL 在 `videoController.playbackContext.contextType === 'media_library'` 时显示 `EpisodeListPanel` 选集区块；当前实现为直接显示在设置滚动内容中的“选集”区块，而不是单独 Tab。

#### Scenario: MediaLibraryContext 时显示选集区块
- **WHEN** `videoController.playbackContext.contextType === 'media_library'`
- **THEN** 设置面板顶部显示标题为“选集”的区块

#### Scenario: 无上下文或文件浏览器上下文时隐藏选集区块
- **WHEN** `videoController.playbackContext` 为 `undefined` 或 `contextType === 'file_explorer'`
- **THEN** 设置面板不渲染 `EpisodeListPanel`

#### Scenario: 选择某集时仅更新上下文索引并关闭面板
- **WHEN** 用户在 `EpisodeListPanel` 选中某个条目
- **THEN** `PlayerSettingsDialog` 调用 `videoController.playbackContext?.jumpTo(item.index)`
- **AND** 关闭设置面板
- **AND** 主规格不要求此操作立即切换当前播放 URL
