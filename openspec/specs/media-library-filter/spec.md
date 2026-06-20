# Media Library Filter

## Purpose

定义媒体库首页与搜索结果中，哪些视频会进入媒体库展示，以及当前实现对缺失元数据和缺失海报的处理方式。

## Requirements

### Requirement: 最近添加列表基于已刮削元数据构建

媒体库首页的 `recentlyAddedList` SHALL 来自 `FileSourceDatabase.getRecentlyAddedList()`，并以 `scrape_info` 中已经建立关联的条目为数据源，而不是直接展示全部 `videos` 记录。

`getRecentlyAddedList()` SHALL：
- 将电视剧按 `(tv_series_id, season_number)` 聚合
- 将电影按 `movie_id` / `video_id` 关联到刮削结果
- 以最新 `scraped_at` 倒序合并电视剧与电影条目

#### Scenario: 无 scrape_info 的视频不进入最近添加列表
- **WHEN** 某条 `videos` 记录尚未建立 `scrape_info` 关联
- **THEN** 该视频不出现在媒体库首页的 `recentlyAddedList`

#### Scenario: 剧集按剧和季聚合进入最近添加
- **WHEN** 多集电视剧已写入同一 `tv_series_id` 且存在季号
- **THEN** 最近添加按 `(tv_series_id, season_number)` 聚合为系列卡片

---

### Requirement: 电视剧媒体库结果剔除缺少系列关联的脏数据

媒体库中的电视剧查询 SHALL 过滤掉缺少 `tv_series_id` 的单集数据，避免在 UI 中出现无标题、无系列归属的脏数据。

#### Scenario: TV 搜索过滤缺少 tv_series_id 的条目
- **WHEN** 搜索条件 `mediaType='tv'`
- **THEN** 查询条件要求 `s.media_type IN ('tv', 'episode') AND s.tv_series_id IS NOT NULL`

#### Scenario: 展示层剔除无系列标题的 TV 脏数据
- **WHEN** 某个 `tv` 或 `episode` 结果缺少 `tvSeriesId` 或可展示标题
- **THEN** 该条目不会进入最终 `displayItems`

---

### Requirement: 已刮削但无海报的媒体项使用标题兜底展示

媒体库卡片 SHALL 在缺少海报资源时使用标题文本占位，而不是直接留空。

#### Scenario: SeriesCard 无海报时显示标题占位
- **WHEN** `SeriesCard` 既没有季海报，也没有剧海报
- **THEN** 卡片显示 `group.title` 文本占位

#### Scenario: PosterCard 无海报时显示标题占位
- **WHEN** `PosterCard` 没有 `posterLocalPath` 且没有 `posterUrl`
- **THEN** 卡片显示媒体标题文本占位

---

### Requirement: 媒体库过滤不影响文件浏览器访问原始视频

媒体库过滤只影响媒体库展示层；未进入媒体库的视频文件 SHALL 仍可通过文件源与文件浏览器路径访问。

#### Scenario: 未刮削视频仍可在文件浏览器访问
- **WHEN** 某个视频文件未进入 `recentlyAddedList` 或电视剧片库
- **THEN** 用户仍可通过文件源中的文件浏览器找到该文件
