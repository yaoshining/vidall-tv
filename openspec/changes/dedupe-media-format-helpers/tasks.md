# 任务：详情页共享媒体格式化工具函数去重

## 1. 新建共享工具模块

- [x] 1.1 新建 `entry/src/main/ets/utils/MediaFormatUtil.ets`
- [x] 1.2 写入 `tmdbImageUrl`（统一空值判断 `!path || path.length === 0`）
- [x] 1.3 写入 `formatYear`
- [x] 1.4 写入 `parseGenresArr`
- [x] 1.5 写入 `translateJob`
- [x] 1.6 写入 `toChineseSeasonLabel`
- [x] 1.7 写入 `buildEpisodeCode`
- [x] 1.8 写入 `isGenericSeasonTitle`
- [x] 1.9 写入 `toOpaqueColor`

## 2. PlaybackContext.ets 迁移

- [x] 2.1 追加 `import { tmdbImageUrl } from '../../../utils/MediaFormatUtil'`
- [x] 2.2 删除本地 `tmdbImageUrl` 定义

## 3. MovieDetailPage.ets 迁移

- [x] 3.1 追加 import（`tmdbImageUrl` / `formatYear` / `parseGenresArr` / `toOpaqueColor`）
- [x] 3.2 删除本地 4 个函数定义
- [x] 3.3 `this.toOpaqueColor(...)` → `toOpaqueColor(...)`

## 4. SeasonDetailPage.ets 迁移

- [x] 4.1 追加 import（8 个函数）
- [x] 4.2 删除本地 8 个函数定义
- [x] 4.3 `this.toChineseSeasonLabel(...)` → `toChineseSeasonLabel(...)`
- [x] 4.4 `this.buildEpisodeCode(...)` → `buildEpisodeCode(...)`
- [x] 4.5 `this.isGenericSeasonTitle(...)` → `isGenericSeasonTitle(...)`
- [x] 4.6 `this.toOpaqueColor(...)` → `toOpaqueColor(...)`

## 5. SeriesDetailPage.ets 迁移

- [x] 5.1 追加 import（8 个函数）
- [x] 5.2 删除本地 8 个函数定义
- [x] 5.3 `this.toChineseSeasonLabel(...)` → `toChineseSeasonLabel(...)`
- [x] 5.4 `this.buildEpisodeCode(...)` → `buildEpisodeCode(...)`
- [x] 5.5 `this.isGenericSeasonTitle(...)` → `isGenericSeasonTitle(...)`
- [x] 5.6 `this.toOpaqueColor(...)` → `toOpaqueColor(...)`

## 6. 验证

- [x] 6.1 `hvigorw assembleHap`（`--no-daemon`）编译通过
- [x] 6.2 真机冒烟：电影详情页 / 季详情页 / 剧详情页 / 播放器选集入口显示正常
- [x] 6.3 `openspec validate dedupe-media-format-helpers` 通过
