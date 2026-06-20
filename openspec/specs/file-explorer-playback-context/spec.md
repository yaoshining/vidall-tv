# File Explorer Playback Context

## Purpose

定义文件浏览器进入播放器时的 `FileExplorerContext` 构建、导航与播放器联动规范，确保当前文件夹视频列表可作为播放器内文件列表与上一个/下一个切换的数据来源。

## Requirements

### Requirement: FileExplorerContext 提供静态工厂方法从当前文件夹视频列表构建上下文
`FileExplorerContext` SHALL 提供 `static build(resources: FileExplorerResource[], currentVideoPath: string): FileExplorerContext` 工厂方法，接受已过滤排序的文件列表，过滤出视频文件（匹配已知视频扩展名），将每项映射为 `PlaybackContextItem`（`title` = 文件名，`videoPath` = 文件路径），并以 `currentVideoPath` 定位 `currentIndex`。

#### Scenario: 当前文件夹有 3 个视频时构建包含 3 项的上下文
- **WHEN** 调用 `FileExplorerContext.build(resources, currentVideoPath)`，resources 中有 3 个视频文件（无目录）
- **THEN** 返回的 `FileExplorerContext.items.length === 3`，每项 `title` 为对应文件名

#### Scenario: 当前播放文件定位 currentIndex
- **WHEN** `currentVideoPath` 与 `resources` 中第 2 个视频的 `path` 一致
- **THEN** `FileExplorerContext.currentIndex === 1`（0-indexed）

#### Scenario: resources 中包含目录时目录被过滤
- **WHEN** `resources` 中含 2 个目录 + 3 个视频文件
- **THEN** `items.length === 3`，目录不出现在结果中

#### Scenario: currentVideoPath 不在列表中时 currentIndex 为 0
- **WHEN** `currentVideoPath` 与任何视频路径均不匹配
- **THEN** `FileExplorerContext.currentIndex === 0`

---

### Requirement: FileExplorerContext 支持 jumpTo / jumpToNext / jumpToPrev 导航
`FileExplorerContext` 的 `jumpTo(index)` SHALL 更新 `currentIndex` 并返回对应 `PlaybackContextItem`；越界时返回 `null`。`jumpToNext()` / `jumpToPrev()` SHALL 基于 `jumpTo` 实现，分别向后/向前移动一项，到达边界时返回 `null`。

#### Scenario: jumpTo 有效索引返回对应条目
- **WHEN** `items.length === 3`，调用 `jumpTo(1)`
- **THEN** 返回 `items[1]`，`currentIndex === 1`

#### Scenario: jumpTo 越界返回 null
- **WHEN** `items.length === 3`，调用 `jumpTo(5)`
- **THEN** 返回 `null`，`currentIndex` 不变

#### Scenario: jumpToNext 到达末尾时返回 null
- **WHEN** `currentIndex === items.length - 1`，调用 `jumpToNext()`
- **THEN** 返回 `null`

#### Scenario: jumpToPrev 在第一项时返回 null
- **WHEN** `currentIndex === 0`，调用 `jumpToPrev()`
- **THEN** 返回 `null`

---

### Requirement: 文件浏览器页面跳转播放器时附带 FileExplorerContext
WebDAV 文件浏览器页（`pages/files/index.ets`）和 SMB 文件浏览器页（`SmbFileExplorerPage.ets`）在打开视频文件进入播放器时，SHALL 构建 `FileExplorerContext`（使用当前已排序过滤的视频资源列表）并附带到 `PlayerPageParam.playbackContext`。

#### Scenario: WebDAV 文件浏览器进入播放器时附带 FileExplorerContext
- **WHEN** 用户在 WebDAV 文件浏览器中点击视频文件
- **THEN** 推入 PlayerPage 的 `PlayerPageParam.playbackContext` 为 `FileExplorerContext`，`contextType === 'file_explorer'`

#### Scenario: SMB 文件浏览器进入播放器时附带 FileExplorerContext
- **WHEN** 用户在 SMB 文件浏览器中点击视频文件
- **THEN** 推入 PlayerPage 的 `PlayerPageParam.playbackContext` 为 `FileExplorerContext`，`contextType === 'file_explorer'`

---

### Requirement: PlayerPage prev/next 支持 FileExplorerContext
`PlayerPage` 的自动上一个/下一个切换逻辑 SHALL 支持 `FileExplorerContext`：当 `playbackContext.contextType === 'file_explorer'` 时，`buildNextPlayerPageParam` 和 `buildPrevPlayerPageParam` SHALL 从上下文中取出下一个/上一个 `PlaybackContextItem`，构建对应的 `PlayerPageParam`（含 `url`、`title`）并返回；边界处返回 `null`。

#### Scenario: 文件浏览器上下文下切换到下一个视频
- **WHEN** `playbackContext` 为 `FileExplorerContext`，`hasNext === true`，触发"下一个"切换
- **THEN** 播放器切换到下一个文件的 URL，`title` 更新为下一个文件名

#### Scenario: 已是最后一个视频时不触发切换
- **WHEN** `playbackContext` 为 `FileExplorerContext`，`hasNext === false`，触发"下一个"切换
- **THEN** 返回 `null`，播放器不切换
