## 1. SourceAdapterService 落地

- [x] 1.1 盘点所有播放器入口与剧集切源路径中的 WebDAV / SMB / local 参数装配逻辑。
  - 盘点产出：`.plans/reference/plan-playerFoundationSourceAdapterInventory.md`
- [x] 1.2 定义统一的播放源描述模型，覆盖 URL、headers、sourceType、sourceId 与稳定缓存 key。
  - 类型定义：`entry/src/main/ets/services/sourceAdapter/PlaybackSource.ets`
- [x] 1.3 实现 `SourceAdapterService` 并接入详情页、历史页、文件页与 `PlayerPage.resolveEpisodePlaybackSource()`。
  - service 实现：`entry/src/main/ets/services/sourceAdapter/SourceAdapterService.ets`
  - 已接入：`PlayerPage.resolveEpisodePlaybackSource`、`MovieDetailPage.play`、`PlayHistoryPage.buildPlayUrl`、`SeasonDetailPage.playEpisode`、`SeriesDetailPage.playEpisode`、`ContinueWatchCard.buildAndPlay`
  - 暂未接入：`FileExplorerPage.playVideo`（保持双轨，详见 inventory 6 节）。
- [x] 1.4 保持 `PlayerPageParam` 与现有播放入口行为不变，删除页面层重复协议拼装。
  - 验证：仅 `pages/settings/builders/*` 仍保留 `JSON.parse(configJson)` 调用，但其用途是设置页表单回填而非播放 URL 拼装，符合预期。

## 2. PlaybackProgressService 落地

- [x] 2.1 提炼 prepared resume、弹窗续播、clear-and-play、媒体级进度回写的统一决策接口。
  - 类型契约 + 决策 pure functions：`entry/src/main/ets/services/playbackProgress/PlaybackResumeDecision.ets`
  - 设计文档：`.plans/reference/plan-playerProgressServiceDesign.md`
- [x] 2.2 实现 `PlaybackProgressService` 并替换 `PlayerPage` 中分散的续播决策与定时保存逻辑。
  - service 实现：`entry/src/main/ets/services/playbackProgress/PlaybackProgressService.ets`
  - PlayerPage 三个方法改用：`resumePlaybackForParam`（decideMediaResume）、`registerPreparedResume`（decidePlayResume）、`persistCurrentPlaybackState`（persistNow）
  - 三个调用点改用：切后台（emitter APP_BACKGROUND）、10s 定时、aboutToDisappear
- [x] 2.3 保持 `MediaProgressStore` / `FileSourceDatabase` 的持久化行为与 near-end 语义不变。
  - 持久化语义（near-end 判定 → clear，否则 save）通过 `MediaProgressStore.isNearEnd` 内部完成，service 仅编排。
  - `PlayerPage` 内 `MediaProgressStore` 直接调用从 11 处收敛为 1 处（applyMediaResumeDecision 中 clear_and_play 副作用的 `MediaProgressStore.clear(decision.mediaKey)`）+ 1 处（`MediaProgressStore.episodeKey` 构造 mediaKey 默认值）。
- [x] 2.4 验证页面切换、切后台、退出播放与剧集切换时的进度保存路径未回归。
  - 编译验证：`BUILD SUCCESSFUL in 7 s 60 ms`，0 ArkTS 错误
  - 静态路径梳理：4 个 persist 入口 + 2 个 resume 决策全部走 service
  - 真机回归：需在电视上验证 4 个场景（详见后续 issue）

## 3. SubtitleAcquisitionService 落地

- [x] 3.1 提炼字幕搜索、下载、缓存写回、last used 更新与错误映射的 service 接口。
  - 类型契约：`entry/src/main/ets/services/subtitleAcquisition/SubtitleAcquisitionTypes.ets`
  - 设计文档：`.plans/reference/plan-subtitleAcquisitionServiceDesign.md`
- [x] 3.2 实现 `SubtitleAcquisitionService`，封装 `OpenSubtitlesClient`、`SubtitleDownloader`、`SubtitleCacheManager` 调用链。
  - service 实现：`entry/src/main/ets/services/subtitleAcquisition/SubtitleAcquisitionService.ets`
  - 3 个公共方法：`search` / `download` / `markLastUsed`
- [x] 3.3 改造 `SubtitleSelectorDrawerDialog` 仅负责 UI 展示与用户操作，不直接依赖字幕基础设施。
  - VideoControls.ets 删除了 `OpenSubtitlesClient` / `SubtitleDownloader` / `SubtitleCacheManager` 3 个类与 4 个 Error 类的 import
  - `startSearch` / `downloadSubtitle` 改用 `subtitleService.search` / `subtitleService.download` / `subtitleService.markLastUsed`
  - 错误 Toast 文案统一抽到 `toastMessageForAcquisitionError`，按 `error.kind` 决定
- [x] 3.4 保持下载后自动追加字幕、自动切换到新字幕与最近使用字幕恢复行为不变。
  - 下载后顺序：service.download → videoController.addExternalSubtitle → videoController.switchSubtitleTrack → service.markLastUsed（fire-and-forget）
  - markLastUsed 失败仅 warn 不抛（与 OpenSpec 3.4 scenario 2 一致）
  - 编译验证：`BUILD SUCCESSFUL in 6 s 441 ms`，0 ArkTS 错误

## 4. 收口与回归

- [ ] 4.1 让 `VideoPlayerController` 继续作为 façade，内部委托新 service 但不修改 UI 侧主要公开 API。
- [ ] 4.2 清理迁移后已无必要的页面层重复逻辑与临时协议判断。
- [ ] 4.3 回归 WebDAV、SMB、本地文件、在线字幕搜索下载与续播恢复主路径。
