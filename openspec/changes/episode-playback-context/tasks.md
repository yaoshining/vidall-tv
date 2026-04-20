## 已与现状对齐

- [x] 将 change artifacts 收敛到当前已合并实现，删除失真的旧目标描述。
- [x] 文档明确 `PlaybackContext`、`MediaLibraryContext` 与 `FileExplorerContext` 骨架已经存在。
- [x] 文档明确媒体库入口会在进入播放器前构建并传递 `playbackContext`。
- [x] 文档明确播放器设置面板中的真实 UI 是 `选集` 区块，而不是剧集列表 Tab。
- [x] 文档明确当前分页口径是 `1-6` 与 `7-最后`，而不是旧的滚动分页设计。
- [x] 文档删除或改写 `LazyForEach`、focus ring、pager pill、旧视觉 token、已看标记、旧 UI 自动化场景等过时信息。
- [x] 文档明确媒体库过滤能力已经落地，且无 `scrape_info` 的条目不会进入媒体库海报墙。

## Remaining Implementation Gap

- [x] 让播放器设置面板中的 `选集` 在选择其他剧集后真正切换当前播放 URL，并使播放器实际播放源与 `playbackContext.currentIndex` 保持一致。
