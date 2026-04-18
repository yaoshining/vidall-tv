## ADDED Requirements

### Requirement: PlaybackContext 抽象基类
系统 SHALL 提供 `PlaybackContext` 抽象基类（`@ObservedV2 abstract class`），为播放器提供上下文感知的集数导航能力。子类通过 `@Trace` 装饰响应式字段，保证 UI 自动刷新。

基类 SHALL 定义以下契约：
- `contextType: string`（abstract）
- `@Trace currentIndex: number`
- `@Trace items: PlaybackContextItem[]`
- `get hasNext(): boolean`
- `get hasPrev(): boolean`
- `jumpToNext(): PlaybackContextItem | null`（abstract）
- `jumpToPrev(): PlaybackContextItem | null`（abstract）
- `jumpTo(index: number): PlaybackContextItem | null`（abstract）

#### Scenario: hasNext 在末尾集返回 false
- **WHEN** `currentIndex === items.length - 1`
- **THEN** `hasNext` 返回 `false`

#### Scenario: hasNext 在非末尾集返回 true
- **WHEN** `currentIndex < items.length - 1`
- **THEN** `hasNext` 返回 `true`

#### Scenario: hasPrev 在第一集返回 false
- **WHEN** `currentIndex === 0`
- **THEN** `hasPrev` 返回 `false`

#### Scenario: hasPrev 在非第一集返回 true
- **WHEN** `currentIndex > 0`
- **THEN** `hasPrev` 返回 `true`

---

### Requirement: MediaLibraryContext 具体实现
系统 SHALL 提供 `MediaLibraryContext extends PlaybackContext`，从本地 DB 加载剧集列表，并支持集数跳转。

`MediaLibraryContext` SHALL：
- `contextType` 固定为 `'media_library'`
- `@Trace episodes: EpisodeItem[]`（含 `episodeNumber`、`title`、`videoPath`、`isWatched`）
- `@Trace seriesId: number`
- `@Trace seasonNumber: number`
- 提供 `static build(db, seriesId, seasonNumber, currentVideoPath): MediaLibraryContext` 工厂方法

#### Scenario: 工厂方法从 DB 加载当前季剧集
- **WHEN** 调用 `MediaLibraryContext.build(db, seriesId, seasonNumber, videoPath)`
- **THEN** 返回包含当前季所有剧集的 context，`currentIndex` 指向 `videoPath` 对应的集

#### Scenario: jumpTo 切换到指定集
- **WHEN** 调用 `jumpTo(2)` 且 `items[2]` 存在
- **THEN** `currentIndex` 更新为 `2`，返回 `items[2]`

#### Scenario: jumpTo 越界返回 null
- **WHEN** 调用 `jumpTo(-1)` 或 `jumpTo(items.length)`
- **THEN** 返回 `null`，`currentIndex` 不变

#### Scenario: jumpToNext 跳转到下一集
- **WHEN** `currentIndex = 1`，调用 `jumpToNext()`
- **THEN** `currentIndex` 变为 `2`，返回 `items[2]`

#### Scenario: jumpToPrev 跳转到上一集
- **WHEN** `currentIndex = 2`，调用 `jumpToPrev()`
- **THEN** `currentIndex` 变为 `1`，返回 `items[1]`

#### Scenario: jumpToNext 在末尾集返回 null
- **WHEN** `currentIndex === items.length - 1`，调用 `jumpToNext()`
- **THEN** 返回 `null`，`currentIndex` 不变

---

### Requirement: FileExplorerContext 骨架实现
系统 SHALL 提供 `FileExplorerContext extends PlaybackContext` 骨架类，`contextType` 固定为 `'file_explorer'`，`jumpTo / jumpToNext / jumpToPrev` 均返回 `null`（完整实现留给后续 Issue）。

#### Scenario: FileExplorerContext jumpTo 始终返回 null
- **WHEN** 调用 `FileExplorerContext.jumpTo(0)`
- **THEN** 返回 `null`

---

### Requirement: VideoPlayerController 集成 PlaybackContext
`VideoPlayerController` SHALL 新增可选字段 `playbackContext?: PlaybackContext`，不添加任何剧集业务逻辑。

#### Scenario: 不传入 playbackContext 时原有播放不受影响
- **WHEN** 未设置 `playbackContext` 即调用播放
- **THEN** 播放器正常工作，`playbackContext` 为 `undefined`

---

### Requirement: PlayerPageParam 传递 PlaybackContext
`PlayerPageParam` 接口 SHALL 新增可选字段 `playbackContext?: PlaybackContext`，由调用方（SeasonDetailPage）在跳转前构建并注入。

#### Scenario: SeasonDetailPage 传入 MediaLibraryContext
- **WHEN** 用户从 SeasonDetailPage 点击某集进入播放器
- **THEN** `PlayerPage.aboutToAppear()` 将 `params.playbackContext` 赋值给 `videoPlayerController.playbackContext`
