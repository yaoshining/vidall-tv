# 设计：详情页共享媒体格式化工具函数去重

## 目标

将 8 个在多个文件中逐字重复的纯函数收敛到单一模块 `MediaFormatUtil`，消除 DRY 违规，保持零行为变更。

## 决策记录

### D1：抽取范围仅限 8 个无 `this` 依赖的纯函数

纳入本次的 8 个函数均满足「纯函数、签名一致、逐字或语义等价」：

| 函数 | 签名 | 出现次数 | 文件 |
|---|---|---|---|
| `tmdbImageUrl` | `(path: string \| undefined, width: string): string` | 4 | PlaybackContext / Movie / Season / Series |
| `formatYear` | `(date: string \| undefined): string` | 3 | Movie / Season / Series |
| `parseGenresArr` | `(json: string \| undefined): string[]` | 3 | Movie / Season / Series |
| `translateJob` | `(job: string): string` | 2 | Season / Series |
| `toChineseSeasonLabel` | `(n: number): string` | 2 | Season / Series |
| `buildEpisodeCode` | `(seasonNumber: number, episodeNumber: number): string` | 2 | Season / Series |
| `isGenericSeasonTitle` | `(title: string, n: number): boolean` | 2 | Season / Series |
| `toOpaqueColor` | `(hex: string): string` | 3 | Movie / Season / Series |

**明确不纳入本次**（依赖组件状态或签名不同，需单独重构）：

- `getSeasonNameForPlayer()`（Season 无参）vs `getSeasonNameForPlayer(seasonNumber)`（Series 有参）——签名不同且依赖 `this.seasonTitle` / `this.seasons`。
- `buildPlayerTitle` / `resolveEpisodeName`——依赖 `this.group` / `this.seriesEntity` / `this.seasonTitle`。
- `formatMovieDuration(runtimeMinutes, durationMs)`（Movie）vs `formatDuration(ms)`（Season）——用途不同。
- `formatProgressTime(ms)`——仅 Season 单处，非重复。

### D2：目标模块命名与位置

- 命名：`MediaFormatUtil`。
- 位置：`entry/src/main/ets/utils/MediaFormatUtil.ets`，与既有 `TimeUtil.ets`、`VideoFileUtil.ets`、`FfprobeUtil.ets` 同层，属中立 utils 层（`PlaybackContext` 与 detail pages 均可无环依赖地 import）。

### D3：保持原名与签名不变

函数名、参数、返回类型、实现逻辑原样迁移，调用点改动最小化，降低 diff 噪音与回归风险。

### D4：统一 `tmdbImageUrl` 空值判断（语义等价）

PlaybackContext 用 `path === undefined || path.length === 0`，其余三处用 `!path || path.length === 0`。两者对 `undefined` / `''` 的判定语义等价（`!undefined === true`、`!'' === true`）。统一采用 `!path || path.length === 0`，行为不变。

### D5：方法 → 裸函数迁移的 ArkTS 合法性

`toChineseSeasonLabel` / `buildEpisodeCode` / `isGenericSeasonTitle` / `toOpaqueColor` 目前是 `@ComponentV2` struct 的 `private` 方法。迁移后改为在组件内直接调用 import 的纯函数。此模式已有先例：`MovieDetailPage` 已在 `@Builder` 内调用 import 的 `millisecondsToTime`，`PlaybackContext` 已调用 `isVideoFile`。ArkTS 对 import 纯函数在组件内调用无限制。

### D6：验证策略

- 编译验证：`hvigorw assembleHap`（`--no-daemon`）。
- 行为验证：真机冒烟（电影详情页 / 季详情页 / 剧详情页 / 播放器选集入口），确认海报、年份、类型、季名、集代码、职位翻译、渐变遮罩颜色显示不变。
- 不新增单测（纯重构，无行为变更；复用既有页面冒烟）。

## 迁移计划

1. 新建 `MediaFormatUtil.ets`，写入 8 个 `export function`。
2. 对 4 个文件分别：追加 import → 删除本地函数定义 → 将 `this.xxx(...)` 调用改为 `xxx(...)`。
3. `assembleHap` 编译通过。
4. 真机冒烟 4 个入口。
5. `openspec validate` 通过后归档。

## 风险与回滚

- 风险极低：纯函数迁移，无逻辑改动。
- 回滚：revert 单次 commit 即可恢复。
