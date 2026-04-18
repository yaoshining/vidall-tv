## 1. PlaybackContext 抽象类（TDD：先写测试）

- [ ] 1.1 创建 `entry/src/test/ets/PlaybackContextTest.ets`，编写 PlaybackContext 基类单测：`hasNext/hasPrev` 边界、`jumpTo` 越界、空列表处理
- [ ] 1.2 创建 `entry/src/main/ets/components/core/player/PlaybackContext.ets`，实现 `@ObservedV2 abstract class PlaybackContext`，包含 `contextType`、`currentIndex`、`items`、`hasNext`、`hasPrev` getter
- [ ] 1.3 运行单测，确认 1.1 中全部用例通过

## 2. MediaLibraryContext 实现（TDD）

- [ ] 2.1 在 `PlaybackContextTest.ets` 中追加 MediaLibraryContext 单测：工厂方法、`jumpTo` 正常/越界、`jumpToNext` 末尾、`jumpToPrev` 首集
- [ ] 2.2 在 `PlaybackContext.ets` 中实现 `MediaLibraryContext extends PlaybackContext`，含 `@Trace episodes: EpisodeItem[]`、`seriesId`、`seasonNumber`、`contextType = 'media_library'`
- [ ] 2.3 实现 `static MediaLibraryContext.build(db, seriesId, seasonNumber, currentVideoPath)` 工厂方法，查询 DB 中对应季剧集并定位 `currentIndex`
- [ ] 2.4 实现 `jumpTo / jumpToNext / jumpToPrev`，更新 `currentIndex` 并返回对应 `PlaybackContextItem`
- [ ] 2.5 运行单测，确认 2.1 中全部用例通过

## 3. FileExplorerContext 骨架

- [ ] 3.1 在 `PlaybackContext.ets` 中实现 `FileExplorerContext extends PlaybackContext`，`contextType = 'file_explorer'`，全部 `jumpTo` 系列返回 `null`
- [ ] 3.2 补充 FileExplorerContext 骨架单测（jumpTo 始终 null）

## 4. PlayerPageParam 和 VideoPlayerController 扩展

- [ ] 4.1 在 `entry/src/main/ets/pages/player/index.ets` 的 `PlayerPageParam` 接口中新增 `playbackContext?: PlaybackContext` 字段
- [ ] 4.2 在 `VideoPlayerController.ets` 中新增 `playbackContext?: PlaybackContext` 字段（不添加任何剧集业务逻辑）
- [ ] 4.3 在 `PlayerPage.aboutToAppear()` 中读取 `params.playbackContext` 并赋值到 `videoPlayerController.playbackContext`

## 5. SeasonDetailPage 构建并传递 Context

- [ ] 5.1 在 `SeasonDetailPage.playEpisode()` 中（第 873 行附近）调用 `MediaLibraryContext.build(db, seriesId, seasonNumber, videoPath)`，将结果附加到 `PlayerPageParam`
- [ ] 5.2 在 `SeriesDetailPage` 的对应播放入口处同样构建并传递 `MediaLibraryContext`

## 6. EpisodeListPanel UI 组件

> 严格按照 design.md「EpisodeListPanel 设计规范」章节实现，所有尺寸用 vp（禁止 px 绝对值）。

- [ ] 6.1 创建 `entry/src/main/ets/components/core/player/EpisodeListPanel.ets`，使用 `LazyForEach` 渲染集数列表，接收 `context: MediaLibraryContext` 和 `onSelect: (item: PlaybackContextItem) => void`
- [ ] 6.2 实现集数卡片：当前集宽度 210vp（高亮描边 `#A9F4FF` 4vp）、普通集 256vp、圆角 26vp、间距 48vp；最右侧 edgeCard 168vp 截断提示翻页
- [ ] 6.3 实现集数标签：fontSize=24vp, fontWeight=700, fill=`#F0F4F9`，高度 28vp，居中
- [ ] 6.4 实现分页范围条：每页6集，条目格式"1-6/7-12"，激活项 `#F3F7FB`，非激活 `#D5DDE8`，下划线高3vp 圆角2vp
- [ ] 6.5 实现 pagerPill 胶囊（76×34vp, cornerRadius=18vp, 半透明白）：焦点在分页条时显示
- [ ] 6.6 实现焦点环（42×42vp 椭圆，inside stroke 5vp `#FFFFFF`）叠加在焦点卡片角
- [ ] 6.7 实现 TV 遥控器焦点管理（上下键导航，边界不越出列表；左右键在卡片间切换，到边缘时触发翻页）

## 7. PlayerSettingsDialog 集成

- [ ] 7.1 在 `VideoControls.ets` 的 `PlayerSettingsDialog`（第 593 行）中，判断 `playbackContext?.contextType === 'media_library'` 时展示"剧集列表"Tab
- [ ] 7.2 在剧集列表 Tab 内嵌入 `EpisodeListPanel`，`onSelect` 回调触发切集（跳转 URL）
- [ ] 7.3 验证无 `playbackContext` 时设置弹层原有 Tab（音轨、字幕、画面比例）不受影响

## 8. 媒体库过滤策略

- [ ] 8.1 修改 `FileSourceDatabase.getRecentlyAddedList()`（第 2667 行），删除 `unscrapedSql` 那一路 UNION 查询
- [ ] 8.2 确认有 `scrape_info` 但 `poster_local_path=NULL && poster_url=NULL` 的记录仍可出现在结果中（标题兜底）
- [ ] 8.3 检查 `getMovieList()`、`getTvSeriesList()` 等其他媒体库查询，统一应用相同过滤策略

## 9. 本地验证与提交

- [ ] 9.1 本地运行单测：`DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw test --mode module -p module=entry@default test --no-daemon`，确认全部通过
- [ ] 9.2 更新 `player-settings-ui-tests` 集成测试，补充"有 MediaLibraryContext 时显示剧集列表 Tab"和"无 Context 时不显示"两个场景
- [ ] 9.3 创建分支 `feat/issue-119-episode-playback-context`，提交所有改动
- [ ] 9.4 推送分支并创建 PR，在 PR 描述中关联 Issue #119 #121 #122 #123 #124
