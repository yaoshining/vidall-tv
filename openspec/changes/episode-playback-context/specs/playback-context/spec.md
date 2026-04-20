## MODIFIED Requirements

### Requirement: 播放器保存可选的 PlaybackContext
系统 SHALL 提供 `PlaybackContext` 抽象基类，为播放器保存当前播放条目列表与当前位置。

`PlaybackContext` SHALL 提供：
- `items`
- `currentIndex`
- `hasNext`
- `hasPrev`
- `jumpTo`
- `jumpToNext`
- `jumpToPrev`

#### Scenario: 当前条目不是最后一集时 hasNext 为 true
- **WHEN** `currentIndex < items.length - 1`
- **THEN** `hasNext` 返回 `true`

#### Scenario: 当前条目是第一集时 hasPrev 为 false
- **WHEN** `currentIndex = 0`
- **THEN** `hasPrev` 返回 `false`

---

### Requirement: MediaLibraryContext 从本地媒体库构建当前季上下文
系统 SHALL 提供 `MediaLibraryContext.build(db, seriesId, seasonNumber, currentVideoPath)`，用于在进入播放器前构建当前季的播放上下文。

#### Scenario: 工厂方法加载当前季剧集并定位 currentIndex
- **WHEN** 媒体库入口调用 `MediaLibraryContext.build(...)`
- **THEN** 返回的上下文包含当前季剧集列表，并把 `currentIndex` 指向 `currentVideoPath` 对应条目

#### Scenario: jumpTo 更新上下文当前位置
- **WHEN** 调用 `jumpTo(index)` 且索引有效
- **THEN** `currentIndex` 更新为该索引，并返回对应条目

#### Scenario: jumpTo 越界时返回 null
- **WHEN** 调用 `jumpTo(index)` 且索引越界
- **THEN** 返回 `null`，且 `currentIndex` 保持不变

---

### Requirement: FileExplorerContext 保持骨架实现
系统 SHALL 保留 `FileExplorerContext` 骨架类，供非媒体库入口复用统一的播放上下文类型。

#### Scenario: FileExplorerContext 不提供选集跳转
- **WHEN** 调用 `jumpTo`、`jumpToNext` 或 `jumpToPrev`
- **THEN** 返回 `null`

---

### Requirement: 播放器页面接收并保存 playbackContext
`PlayerPageParam` SHALL 支持可选的 `playbackContext` 字段，`PlayerPage.aboutToAppear()` SHALL 将其赋给 `VideoPlayerController.playbackContext`。

#### Scenario: 媒体库入口把上下文传入播放器
- **WHEN** 用户从季详情页、剧集详情页或继续观看入口进入播放器
- **THEN** 对应入口可以在跳转前构建 `MediaLibraryContext` 并传入播放器页面

#### Scenario: 没有 playbackContext 时原有播放流程不受影响
- **WHEN** 页面参数中不包含 `playbackContext`
- **THEN** 播放器仍按原有单视频路径工作
