## Current Implementation

### 1. 播放上下文模型

当前播放器已经具备播放上下文能力：
- `PlaybackContext` 负责维护 `items`、`currentIndex`、`hasNext`、`hasPrev` 与 `jumpTo` 系列接口。
- `MediaLibraryContext.build(...)` 会从本地数据库加载当前季剧集，并定位当前播放集。
- `FileExplorerContext` 目前只保留骨架实现，不参与选集区块渲染。

这部分已经是当前真实实现，不再需要旧文档中的待设计描述。

### 2. 上下文注入链路

当前链路如下：
1. 媒体库入口在进入播放器前构建 `MediaLibraryContext`
2. `PlayerPageParam` 携带 `playbackContext`
3. `PlayerPage.aboutToAppear()` 将其赋给 `VideoPlayerController.playbackContext`
4. `PlayerSettingsDialog` 根据 `contextType === media_library` 决定是否显示 `选集` 区块

当前实现重点是把上下文带进播放器，而不是在播放器内临时异步构建。

### 3. 设置面板中的选集区块

当前 UI 结构是播放器设置面板顶部的 `选集` 区块，位于倍速等设置项之前，不是旧文档中的 Tab 结构。

区块内的真实行为如下：
- 标题为 `选集`
- 使用横向卡片展示当前季剧集
- 当前播放集依据 `context.currentIndex` 高亮
- 只在总集数大于 6 时显示分页标签
- 分页口径固定为两段：`1-6` 与 `7-最后`

当前实现没有以下旧设计元素，这些内容已从 change artifacts 中移除：
- Tab 式剧集入口
- `LazyForEach`
- pager pill
- 独立 focus ring
- 精确旧视觉 token
- 每页 6 集连续滚动分页
- 已看标记

### 4. 当前选集交互

`EpisodeListPanel` 点击某一集后，当前逻辑会：
1. 调用 `playbackContext.jumpTo(item.index)`
2. 更新上下文中的 `currentIndex`
3. 关闭设置面板

这意味着选集区块已经能更新播放器上下文中的当前集索引，但还没有把所选条目的 `videoPath` 接到真正的切源链路里。

### 5. 媒体库过滤

当前 change 还包含一项已经落地的媒体库过滤能力：
- 媒体库最近添加与相关聚合列表只保留有 `scrape_info` 的条目
- 无刮削信息的文件仍保留在数据库与文件浏览器路径中，不进入媒体库海报墙
- 已有刮削信息但缺少海报的条目仍然保留，由 UI 用标题兜底展示

## Remaining Gap

### 选集后真正切换播放 URL

当前唯一剩余的真实实现缺口是：当用户在 `选集` 区块里选择其他剧集时，播放器必须真正切换到所选条目的播放 URL，而不是只更新 `currentIndex`。

后续实现需要补齐的链路是：
1. 从 `PlaybackContextItem.videoPath` 生成播放器可用的新播放源
2. 让 `VideoPlayerController` 重新载入该播放源
3. 让播放器当前播放源、页面状态和 `playbackContext.currentIndex` 保持一致
4. 在切换成功后再关闭设置面板，避免出现索引已变但实际仍播放旧 URL 的状态

除这条链路外，本 change 的其余文档目标都已经与当前实现对齐。
