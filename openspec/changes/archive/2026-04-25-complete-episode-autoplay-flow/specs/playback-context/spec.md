## MODIFIED Requirements

### Requirement: MediaLibraryContext 表达当前季剧集集合

系统 SHALL 提供 `MediaLibraryContext extends PlaybackContext`，用于表达当前实现中的媒体库剧集上下文。

`MediaLibraryContext` SHALL：
- `contextType` 固定为 `'media_library'`
- 暴露 `seriesId`、`seasonNumber`、`episodes`、`items`、`currentIndex`
- 通过本地 `EpisodeGroupMatcher` 基于 `tv_episodes`、`scrape_info` 与 `videos` 构建当前季可播放列表
- 仅使用本地已刮削数据，不在播放器流程中实时请求 TMDB API
- 通过 `currentVideoPath` 定位 `currentIndex`，未命中时回退为 `0`
- 为每个 `PlaybackContextItem` 填充 `videoPath`、`title`、`index`、可选 `episodeNumber` 与可选 `thumbnailUrl`
- 在同一播放会话内允许按 `seriesId + seasonNumber` 维度命中内存缓存，避免重复查询本地数据库

#### Scenario: buildItems 基于本地季集匹配结果构建当前季列表
- **WHEN** `MediaLibraryContext` 为某一部剧的第 1 季构建播放上下文
- **THEN** 系统使用本地 `EpisodeGroupMatcher` 查询当前季已刮削集数与已匹配视频
- **AND** 返回结果仅包含当前季的可播放条目

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

#### Scenario: 本地视频缺少部分集数时返回可播放子集
- **WHEN** 当前季在 `tv_episodes` 中存在 10 集，但本地仅匹配到其中 6 集视频文件
- **THEN** `MediaLibraryContext` 返回这 6 个可播放条目
- **AND** 条目顺序仍按 `episodeNumber` 升序排列

#### Scenario: 同季重复查询命中缓存
- **WHEN** 同一播放会话内再次构建相同 `seriesId` 和 `seasonNumber` 的 `MediaLibraryContext`
- **THEN** 系统优先复用进程内缓存结果
- **AND** 不重复执行相同的本地数据库查询与匹配
