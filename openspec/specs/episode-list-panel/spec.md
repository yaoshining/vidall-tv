# Episode List Panel

## Purpose

定义播放器设置面板中的“选集/文件列表”区块当前实现行为，包括上下文显示规则、渲染结构、分页规则与遥控器交互方式。

## Requirements

### Requirement: PlayerSettingsDialog 根据播放上下文显示选集或文件列表区块
当 `videoPlayerController.playbackContext` 是 `MediaLibraryContext` 时，播放器设置面板 SHALL 在顶部显示 `选集` 区块；当 `videoPlayerController.playbackContext` 是 `FileExplorerContext` 时，播放器设置面板 SHALL 在顶部显示 `文件列表` 区块；当 `playbackContext` 不存在时，设置面板 SHALL 保持原有结构，不显示该区块。

#### Scenario: MediaLibraryContext 时显示选集区块
- **WHEN** 播放器携带 `MediaLibraryContext` 打开设置面板
- **THEN** 面板顶部显示标题为 `选集` 的区块

#### Scenario: FileExplorerContext 时显示文件列表区块
- **WHEN** 播放器携带 `FileExplorerContext` 打开设置面板
- **THEN** 面板顶部显示标题为 `文件列表` 的区块

#### Scenario: 无播放上下文时不显示列表区块
- **WHEN** `playbackContext` 为 `undefined`
- **THEN** 设置面板中不显示 `选集` 或 `文件列表` 区块

---

### Requirement: 列表区块以连续横向滚动全部条目呈现
`EpisodeListPanel` SHALL 以单一扁平 `List`（`listDirection: Axis.Horizontal`）渲染当前播放上下文的全部条目；在 `MediaLibraryContext` 下为全集列表，在 `FileExplorerContext` 下为当前文件夹视频列表。组件不得保留 `currentPage`、`pageRange`、`displayedEpisodes` 等分页状态。

#### Scenario: 全部集数可在同一列表中横向浏览
- **WHEN** 当前季共有 30 集，用户在选集弹层中左右方向键导航
- **THEN** 1-30 集均在同一横向列表中连续可访问，不存在切页操作

#### Scenario: 集数不超过 6 时仍以单列表呈现
- **WHEN** 当前季共有 4 集
- **THEN** 4 集在同一横向列表中呈现，下方无分组标签或仅显示一个锚点

---

### Requirement: 下方分组标签作为 scrollToIndex 锚点定位
下方分组标签（如 `1-6`、`7-12`）SHALL 仅承担"快速定位锚点"语义，点击后通过 `ListScroller.scrollToIndex(groupStartIndex, true, ScrollAlign.START)` 将对应分组首集滚动至列表容器最左端，不触发分页或数据切换。

#### Scenario: 点击 1-6 锚点定位到第 1 集
- **WHEN** 用户在下方分组标签区点击 `1-6`
- **THEN** 第 1 集（index 0）滚动到列表容器最左边（ScrollAlign.START）

#### Scenario: 点击 7-12 锚点定位到第 7 集
- **WHEN** 用户在下方分组标签区点击 `7-12`
- **THEN** 第 7 集（index 6）滚动到列表容器最左边

#### Scenario: 最后一组不足 6 集时正确定位到该组首集
- **WHEN** 当前季共有 10 集，用户点击 `7-10` 锚点
- **THEN** 第 7 集（index 6）滚动到列表容器最左边

---

### Requirement: 面板打开时自动将当前播放条目滚动到可见区
`EpisodeListPanel` SHALL 在 `onAppear` 回调中调用 `scrollToIndex(currentIndex, false, ScrollAlign.START)`，使当前播放条目在列表中可见（非平滑滚动，避免与面板出现动效冲突）。

#### Scenario: 当前播放集在列表中间时面板打开后自动定位
- **WHEN** 当前播放第 15 集，用户打开选集面板
- **THEN** 第 15 集出现在列表可见区域最左边

---

### Requirement: 选择列表条目会先更新播放上下文中的当前位置
当前实现下，用户从 `选集` 或 `文件列表` 区块选择某个条目时，系统 SHALL 先通过 `jumpTo` 更新 `playbackContext.currentIndex`，再关闭设置面板。

#### Scenario: 选择其他条目时 currentIndex 更新
- **WHEN** 当前播放索引为 1，用户在列表区块中选择索引为 4 的其他条目
- **THEN** `playbackContext.currentIndex` 更新为索引 4，并关闭设置面板

---

### Requirement: 选择列表条目 SHALL 真正切换当前播放 URL
用户从 `选集` 或 `文件列表` 区块选择其他条目后，播放器 SHALL 重新载入所选条目的播放 URL，使实际播放内容与 `playbackContext.currentIndex` 保持一致。

#### Scenario: 选择其他条目后播放器切换到所选 URL
- **WHEN** 当前正在播放索引为 1 的条目，用户在列表区块中选择索引为 4 的其他条目
- **THEN** 播放器当前播放源切换为索引 4 条目对应的 URL，而不是继续播放原来的 URL

---

### Requirement: EpisodeListPanel 根据播放上下文渲染剧集卡片或文件列表条目

系统 SHALL 提供 `EpisodeListPanel` 组件，并在 `PlayerSettingsDialog` 中接收播放上下文与 `onSelect(item)` 回调。

`EpisodeListPanel` SHALL：
- 在 `MediaLibraryContext` 下显示区块标题“选集”
- 在 `FileExplorerContext` 下显示区块标题“文件列表”
- 使用 `List` + `ForEach` 渲染当前上下文的全部条目（不再分页）
- 在 `MediaLibraryContext` 下为每个条目显示剧集缩略图；当 `thumbnailUrl` 缺失时回退为 `app.media.empty_folder`
- 在 `MediaLibraryContext` 下为每个条目显示 `第N集` 文本，其中 `N` 优先取 `episodeNumber`，否则取 `index + 1`
- 在 `FileExplorerContext` 下为每个条目显示文件名，不显示缩略图区域，也不显示 `第N集` 等剧集语义文案
- 在 `FileExplorerContext` 下，超长文件名在 UI 中以省略号截断，不破坏布局
- 对当前播放项使用当前态背景/字体样式，并显示波形图标；该高亮强度在 `FileExplorerContext` 下与媒体库上下文保持同级视觉强调
- 在条目点击时调用 `onSelect(item)`

#### Scenario: 全部集数条目显示为上图下字卡片
- **WHEN** `EpisodeListPanel` 渲染全部剧集
- **THEN** 每个条目显示缩略图区域和 `第N集` 文本

#### Scenario: FileExplorerContext 条目显示文件名且无缩略图
- **WHEN** `EpisodeListPanel` 在 `FileExplorerContext` 下渲染当前文件夹视频列表
- **THEN** 每个条目显示视频文件名
- **AND** 不显示缩略图区域

#### Scenario: 文件名超长时省略号截断
- **WHEN** `FileExplorerContext` 下某个视频文件名超过显示区域宽度
- **THEN** 文件名在 UI 中以省略号截断，不破坏布局

#### Scenario: 当前播放项显示波形图标
- **WHEN** 某个条目的 `item.index === context.currentIndex`
- **THEN** 该条目显示当前播放波形图标并使用当前态样式

#### Scenario: FileExplorerContext 下不显示第N集文案
- **WHEN** `EpisodeListPanel` 在 `FileExplorerContext` 下渲染条目
- **THEN** 条目标签区显示文件名，不出现 `第1集`、`第2集` 等剧集语义文字

#### Scenario: 点击条目触发 onSelect
- **WHEN** 用户点击某个列表条目
- **THEN** `onSelect` 以该 `PlaybackContextItem` 为参数被调用

---

### Requirement: EpisodeListPanel 支持当前已实现的遥控器与锚点导航交互

`EpisodeListPanel` SHALL 支持当前代码中已实现的横向卡片导航与锚点标签焦点切换。

#### Scenario: 从卡片列表向下进入锚点标签区
- **WHEN** 焦点位于卡片列表，且用户按下下方向键
- **THEN** 焦点切换到锚点标签区

#### Scenario: 锚点标签通过点击或确认键触发定位
- **WHEN** 用户点击某个锚点标签，或在锚点标签上按下确认键
- **THEN** 列表滚动到对应分组首集

#### Scenario: 锚点标签按上键返回卡片区
- **WHEN** 焦点位于锚点标签区，且用户按下上方向键
- **THEN** 焦点返回卡片列表
