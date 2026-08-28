## 1. 服务器播放上下文

- [x] 1.1 在 `PlaybackContext.ets` 新增 `ServerMediaLibraryContext`（contextType `server_media_library`，静态 `buildItems(episodes, currentKey)` 纯函数 + `build()` 工厂，按集号升序，索引回退 0）；验证：类型检查通过、结构对照 `MediaLibraryContext`
- [x] 1.2 `EpisodePlaybackManager.getContextForAutoplay` 白名单加入 `server_media_library`；验证：既有单测全绿

## 2. 播放入口附带上下文

- [x] 2.1 新增共享的「解析当季集列表 → 构建上下文」辅助方法（getSeasons → 匹配 seasonNumber → getEpisodes，失败返回 null）；验证：辅助方法被多个入口复用、catch 静默
- [x] 2.2 `ServerSeasonDetailPage.playEpisode` 用已加载 `episodes` 构建上下文并附带；验证：单集播放参数含上下文
- [x] 2.3 `ServerMediaDetailPage.play`（series 播 nextUp）与 `ServerSeasonDetailPage.playMediaItem`（跨季续播）附带上下文；验证：两入口参数含上下文
- [x] 2.4 `MediaLibraryTab.doServerDirectPlayWithServer` 对剧集条目附带上下文；验证：继续观看直播放参数含上下文

## 3. 播放器切集分支

- [x] 3.1 `handleEpisodeSelect` 增加 server 分支：构建客户端 → getStreamUrl/getStreamHeader → 新 playSessionId → 旧集 stopped → 新集 started → 组装新 `PlayerPageParam` 原地 reloadSource + jumpTo；验证：代码路径与 media_library 分支对称
- [x] 3.2 切集失败走既有「自动播放下一集失败」toast 与抑制逻辑；验证：异常路径复用 `markAutoplayFailed`

## 4. 单元测试

- [x] 4.1 新增 `ServerMediaLibraryContext.test.ets`：升序排列、索引定位、索引回退、条目字段完整性；验证：UnitTestBuild 全绿
- [x] 4.2 扩展 `EpisodePlaybackManager.test.ets`：server 上下文 hasNext / getContextForAutoplay 放行 / 最后一集无下一集；验证：UnitTestBuild 全绿

## 5. 编译验证与交付

- [x] 5.1 本地单测构建 `UnitTestBuild`（BUILD SUCCESSFUL 且退出码 0）；验证：构建日志
- [x] 5.2 `assembleHap` 完整编译通过；验证：BUILD SUCCESSFUL
- [ ] 5.3 中文提交（含 Co-authored-by trailer）推送分支并创建 PR；验证：PR 链接可访问
- [ ] 5.4 不执行 OpenSpec 归档，等待用户通知；验证：`openspec/changes/archive` 无本变更
