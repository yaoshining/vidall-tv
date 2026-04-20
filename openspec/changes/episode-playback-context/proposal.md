## Context

本 change 已有大部分实现合并到主线，当前文档需要收敛到真实状态。

已经落地的能力如下：
- 播放器已引入 `PlaybackContext` 抽象类，并提供 `MediaLibraryContext` 与 `FileExplorerContext` 骨架。
- 媒体库入口会在进入播放器前构建 `MediaLibraryContext`，并通过 `PlayerPageParam` 传给 `VideoPlayerController`。
- `PlayerSettingsDialog` 在媒体库上下文下会显示顶部 `选集` 区块，而不是旧文档里的 Tab 结构。
- `EpisodeListPanel` 已能展示当前季剧集，并按 `1-6`、`7-最后` 两段分页切换。
- 媒体库最近添加与相关聚合列表已经过滤无 `scrape_info` 的条目；有刮削信息但无海报时保留条目，由标题兜底。

当前唯一仍未闭合的实现缺口是：
- 在 `选集` 区块中选择其他剧集后，播放器还没有真正切换到所选条目的播放 URL。

## Goal

把本次 change artifacts 收敛到当前已合并实现，并把后续开发目标明确收束为一个真实缺口：`选集后真正切换当前播放 URL`。

## Non Goals

本 change 不再保留下列已经失真的目标或描述：
- 剧集列表 Tab
- 每页 6 集的滚动分页设计
- `LazyForEach`
- focus ring、pager pill、旧视觉 token
- 已看标记
- 旧版 UI 自动化场景

本轮也不改业务代码和测试代码，只同步 change artifacts。
