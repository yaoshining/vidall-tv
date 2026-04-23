## Context

本 change 的实现已全部完成并合并到主线，当前文档需要收敛为已完成、可归档的真实状态。

已经落地的能力如下：
- 播放器已引入 `PlaybackContext` 抽象类，并提供 `MediaLibraryContext` 与 `FileExplorerContext` 骨架。
- 媒体库入口会在进入播放器前构建 `MediaLibraryContext`，并通过 `PlayerPageParam` 传给 `VideoPlayerController`。
- `PlayerSettingsDialog` 在媒体库上下文下会显示顶部 `选集` 区块，而不是旧文档里的 Tab 结构。
- `EpisodeListPanel` 已能展示当前季剧集，并按 `1-6`、`7-最后` 两段分页切换。
- 媒体库最近添加与相关聚合列表已经过滤无 `scrape_info` 的条目；有刮削信息但无海报时保留条目，由标题兜底。

当前没有剩余实现缺口；`选集` 区块的选集切换、播放源重载与当前索引同步都已完成。

## Goal

把本次 change artifacts 收敛到当前已合并实现，并确认该 change 已完成、可归档。

## Non Goals

本 change 不再保留下列已经失真的目标或描述：
- 剧集列表 Tab
- 每页 6 集的滚动分页设计
- `LazyForEach`
- focus ring、pager pill、旧视觉 token
- 已看标记
- 旧版 UI 自动化场景

本 change 已完成，当前不再引入新的实现目标；本文件仅用于记录已交付状态。
