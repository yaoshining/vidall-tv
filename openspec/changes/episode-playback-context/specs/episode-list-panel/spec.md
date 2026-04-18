## ADDED Requirements

### Requirement: EpisodeListPanel UI 组件
系统 SHALL 提供 `EpisodeListPanel` 组件，在播放器设置弹层（`PlayerSettingsDialog`）内展示当前季的剧集列表，支持 TV 遥控器焦点导航。

`EpisodeListPanel` SHALL：
- 接收 `context: MediaLibraryContext` 作为参数
- 展示集数列表（集号、标题、已看状态标记）
- 高亮当前正在播放的集（通过 `context.currentIndex` 判断）
- 支持用户选中某集触发 `onSelect(item: PlaybackContextItem)` 回调
- 使用 `LazyForEach` 渲染大列表（防止 50+ 集时性能劣化）

#### Scenario: 渲染当前季剧集列表
- **WHEN** EpisodeListPanel 以包含 10 集的 MediaLibraryContext 渲染
- **THEN** 展示 10 个集数条目，每条显示集号和标题

#### Scenario: 高亮当前播放集
- **WHEN** `context.currentIndex = 3`
- **THEN** 第 4 集（index=3）的条目有视觉高亮，其余条目无高亮

#### Scenario: 已看集显示已看标记
- **WHEN** 某集的 `isWatched = true`
- **THEN** 该集条目显示已看标记（如勾选图标）

#### Scenario: 选中某集触发回调
- **WHEN** 用户选中第 2 集
- **THEN** `onSelect` 回调以 `items[2]` 为参数被调用

---

### Requirement: PlayerSettingsDialog 按 contextType 条件展示剧集列表
`PlayerSettingsDialog` SHALL 在 `playbackContext?.contextType === 'media_library'` 时展示剧集列表 Tab，否则不渲染该 Tab，原有音轨、字幕、画面等 Tab 不受影响。

#### Scenario: MediaLibraryContext 时显示剧集列表 Tab
- **WHEN** `videoPlayerController.playbackContext.contextType === 'media_library'`
- **THEN** 设置弹层中显示"剧集列表"Tab 入口

#### Scenario: 无 playbackContext 时不显示剧集列表 Tab
- **WHEN** `videoPlayerController.playbackContext` 为 `undefined`
- **THEN** 设置弹层中不存在"剧集列表"Tab

#### Scenario: FileExplorerContext 时不显示剧集列表 Tab
- **WHEN** `videoPlayerController.playbackContext.contextType === 'file_explorer'`
- **THEN** 设置弹层中不存在"剧集列表"Tab

---

### Requirement: TV 遥控器焦点管理
EpisodeListPanel 中的集数列表 SHALL 支持 TV 遥控器上下方向键导航，且不影响 PlayerSettingsDialog 中其他 Tab 的焦点流。

#### Scenario: 上下键在列表内导航
- **WHEN** 焦点在 EpisodeListPanel 内，用户按下方向键下
- **THEN** 焦点移到下一个集数条目

#### Scenario: 上边界时焦点不越出列表
- **WHEN** 焦点在第一个条目，用户按方向键上
- **THEN** 焦点停留在第一个条目，不跳出面板
