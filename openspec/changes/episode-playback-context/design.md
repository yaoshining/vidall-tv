## Context

### 当前状态

播放器（`VideoPlayerController`）是纯播放引擎，无"我在哪个剧集上下文"的概念。`PlayerSettingsDialog` 支持音轨、字幕、画面设置，但没有集数列表面板。从 `SeasonDetailPage` / `SeriesDetailPage` 进入播放器时，只传入了一个 URL，不携带任何剧集关系信息。

媒体库首页（`getRecentlyAddedList` 等查询）目前通过三路 UNION 把"未刮削视频"也合并进最近添加，导致没有封面/标题的原始文件暴露在海报墙中，体验不完整。

### 约束

- ArkTS 严格模式：`@ObservedV2/@Trace` 只能用于 class（不能用于接口），所以 PlaybackContext 必须是抽象类而非接口
- `VideoPlayerController.ets` 已超 2400 行，不能再继续堆代码
- TV 端遥控器焦点流必须在新增 UI 面板中维护
- `build()` 内不能写变量声明，字段访问需用方法或计算属性

---

## Goals / Non-Goals

**Goals:**
- 引入 `PlaybackContext` 抽象类体系，使播放器具备"上下文感知"能力（集数导航、已看状态）
- 实现 `MediaLibraryContext`（媒体库）和 `FileExplorerContext`（文件浏览器）两个具体实现
- `PlayerSettingsDialog` 在 `MediaLibraryContext` 下展示剧集列表面板
- 媒体库过滤：有 `scrape_info` 才进海报墙；无海报用标题兜底
- TDD 开发：所有核心类先写测试，再写实现

**Non-Goals:**
- 不支持 JellyfinContext（预留扩展点但不实现）
- 不修改 SMB/WebDAV 文件浏览器的播放逻辑（FileExplorerContext 只做骨架）
- 不做服务端集数进度同步（仅本地 DB）
- 不重构 VideoPlayerController 现有逻辑

---

## Decisions

### D1：PlaybackContext 用抽象类，不用接口

**决策**：`PlaybackContext` 定义为 `@ObservedV2 abstract class`，子类字段用 `@Trace` 装饰。

**原因**：ArkTS 的响应式系统 `@ObservedV2/@Trace` 只能加在 class 上。若用接口，子类无法获得自动追踪能力，UI 无法在集数切换时自动刷新。

**替代方案**：使用接口 + 独立 ViewModel → 需要额外的数据绑定层，增加复杂度且 ArkTS 无法保证编译通过。

---

### D2：VideoPlayerController 只新增一个可选字段

**决策**：`VideoPlayerController` 只新增 `playbackContext?: PlaybackContext`，不添加任何剧集相关方法。

**原因**：控制器职责是管理播放状态（AVPlayer），不应承担集数选择的业务逻辑。所有集数导航逻辑封装在 `PlaybackContext` 子类中。

---

### D3：上下文创建时机 — 进播放器前预创建（选项 A）

**决策**：由调用方（`SeasonDetailPage.playEpisode()`）在跳转播放器前同步构建 `MediaLibraryContext`，再通过 `PlayerPageParam.playbackContext` 传入。

**原因**：本地 SQLite 查询（剧集列表、已看状态）延迟极低（< 10ms），无需异步懒加载。进播放器时 UI 即可立即渲染集数列表，无骨架屏等待。

**替代方案**：进播放器后异步加载（选项 B）→ 需要 loading 态管理，增加 UI 状态复杂度。

---

### D4：contextType 用字符串字面量类型而非枚举

**决策**：`contextType` 定义为 `'media_library' | 'file_explorer' | 'jellyfin'`（字符串字面量联合类型）。

**原因**：枚举在 ArkTS 中需要额外导入，字符串字面量在模板判断中更简洁，且可在 `build()` 内的 `if` 条件中直接使用。

---

### D5：媒体库过滤在 SQL 层处理，不在 UI 层过滤

**决策**：修改 `getRecentlyAddedList()` 等查询，在 SQL 层通过 `INNER JOIN scrape_info` 过滤掉无刮削数据的记录，无海报的记录通过 `COALESCE(poster_local_path, title)` 兜底。

**原因**：UI 层过滤会导致分页失效（数量不准确），SQL 层是正确的过滤位置。

---

## 架构设计

### 类结构

```
PlaybackContext（@ObservedV2 abstract class）
├── contextType: string（abstract）
├── @Trace currentIndex: number
├── @Trace items: PlaybackContextItem[]
├── hasNext: boolean（get，基于 currentIndex + items.length）
├── hasPrev: boolean（get，基于 currentIndex）
├── jumpToNext(): PlaybackContextItem | null（abstract）
├── jumpToPrev(): PlaybackContextItem | null（abstract）
└── jumpTo(index: number): PlaybackContextItem | null（abstract）

MediaLibraryContext extends PlaybackContext
├── contextType = 'media_library'
├── @Trace seriesId: number
├── @Trace seasonNumber: number
├── @Trace episodes: EpisodeItem[]（含 isWatched, episodeNumber, title, videoPath）
├── @Trace currentEpisodeId: number
└── static build(db, seriesId, seasonNumber, videoPath): MediaLibraryContext

FileExplorerContext extends PlaybackContext
├── contextType = 'file_explorer'
└── （暂时只有骨架实现，jumpTo 系列返回 null）

PlaybackContextItem（interface）
├── videoPath: string
├── title: string
└── index: number
```

### 调用链

```
SeasonDetailPage.playEpisode(episode)
  → MediaLibraryContext.build(db, seriesId, seasonNumber, videoPath)
  → router.pushUrl({ url: 'PlayerPage', params: { ...playerPageParam, playbackContext } })
  → PlayerPage.aboutToAppear()
  → videoPlayerController.playbackContext = params.playbackContext
  → PlayerSettingsDialog（build 时检查 playbackContext?.contextType === 'media_library'）
  → 显示 EpisodeListPanel（传入 context）
```

### 文件布局

```
entry/src/main/ets/
└── components/core/player/
    ├── PlaybackContext.ets         ← 新建：抽象类 + MediaLibraryContext + FileExplorerContext + PlaybackContextItem
    └── EpisodeListPanel.ets        ← 新建：剧集列表 UI 组件
```

---

## Risks / Trade-offs

| 风险 | 缓解措施 |
|------|---------|
| `@ObservedV2` 抽象类继承在 ArkTS 中可能有编译限制 | 先单独验证最小抽象类 + 子类原型，确认编译通过后再展开 |
| `EpisodeListPanel` 的遥控器焦点流在大列表（50+ 集）下滚动性能 | 使用 `LazyForEach` + `DataSource` 代替 `ForEach` |
| `MediaLibraryContext.build()` 同步查询如果剧集数大（500+）可能阻塞 UI 线程 | 加 50ms 超时兜底；未来可改为异步 + 骨架屏 |
| 修改 `getRecentlyAddedList()` 过滤策略可能影响现有 UI 测试 | `player-settings-ui-tests` spec 需补充回归断言 |

---

## Migration Plan

1. 新增 `PlaybackContext.ets`（纯新文件，无破坏性）
2. 修改 `PlayerPageParam`（新增可选字段，向后兼容）
3. 修改 `VideoPlayerController`（新增可选字段）
4. 修改 `PlayerSettingsDialog`（条件渲染新增面板，不影响原有 Tab）
5. 修改 `SeasonDetailPage` / `SeriesDetailPage`（构建 context，原有播放路径不变）
6. 修改 `getRecentlyAddedList()`（最后改，影响面最大，需回归）

**回滚策略**：步骤 1-5 均为加法，可单独 revert。步骤 6 需备份原 SQL 查询。

---

## Open Questions

- EpisodeListPanel 中已看状态的更新是否需要实时监听（Emitter），还是重新进详情页时刷新即可？
  → 初版先用进入播放器时的快照，后续可通过 Emitter 订阅 `MEDIA_PROGRESS_SAVED` 刷新
- `FileExplorerContext` 的集数条目是否包含"同文件夹下的全部视频文件"？
  → 初版骨架实现（jumpTo 返回 null），完整实现留给后续 Issue
