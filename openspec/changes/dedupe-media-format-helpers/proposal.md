# 去重：抽取详情页共享的媒体格式化工具函数

## Why

`tmdbImageUrl` / `formatYear` / `parseGenresArr` / `translateJob` / `toChineseSeasonLabel` / `buildEpisodeCode` / `isGenericSeasonTitle` / `toOpaqueColor` 这 8 个纯函数在 2~4 个文件中被逐字复制粘贴，形成多处 DRY 违规。修改任意一处（如 TMDB 图片域名、季名正则、中文化职位表、季号中文映射）都需要同步改多份，极易漏改导致详情页显示行为不一致。趁文件尚在持续演进前，把这些纯函数收敛到单一来源。

## What Changes

- 新建 `entry/src/main/ets/utils/MediaFormatUtil.ets`，集中导出 8 个纯函数（保持原名与语义，零行为变更）。
- `components/core/player/PlaybackContext.ets`：删除本地 `tmdbImageUrl`，改为 import。
- `pages/detail/MovieDetailPage.ets`：删除本地 `tmdbImageUrl` / `formatYear` / `parseGenresArr` / `toOpaqueColor`，改为 import。
- `pages/detail/SeasonDetailPage.ets`：删除本地 8 个函数定义，改为 import；`this.xxx(...)` 调用改为裸函数 `xxx(...)`。
- `pages/detail/SeriesDetailPage.ets`：同上。
- 不改变任何运行时行为（纯重构）。

## Capabilities

### New Capabilities

<!-- 无：纯重构，不引入新能力 -->

### Modified Capabilities

<!-- 无：无 spec 级行为变更 -->

> 本 change 为纯重构，`.openspec.yaml` 设置 `skip_specs: true`，不产生 spec delta。

## Impact

- 受影响文件：`utils/MediaFormatUtil.ets`（新增）、`components/core/player/PlaybackContext.ets`、`pages/detail/MovieDetailPage.ets`、`pages/detail/SeasonDetailPage.ets`、`pages/detail/SeriesDetailPage.ets`。
- 无 API / 依赖 / 数据库 / 资源变更。
- 无 breaking change。
