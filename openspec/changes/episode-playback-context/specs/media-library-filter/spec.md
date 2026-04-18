## ADDED Requirements

### Requirement: 无刮削数据的视频不进媒体库 UI
系统 SHALL 确保媒体库首页（最近添加、电影、剧集等列表）不展示无 `scrape_info` 记录的视频文件。`getRecentlyAddedList()` 及相关查询 SHALL 通过 `INNER JOIN scrape_info` 过滤掉无刮削数据的记录。

无刮削数据的视频记录 SHALL 保留在 `videos` 数据库表中，以便补全元信息后自动出现在媒体库。

#### Scenario: 无 scrape_info 的视频不出现在最近添加
- **WHEN** 存在一条 `videos` 记录但无对应 `scrape_info` 记录
- **THEN** 该记录不出现在 `getRecentlyAddedList()` 结果中

#### Scenario: 有 scrape_info 的视频正常出现在最近添加
- **WHEN** 存在一条 `videos` 记录且有对应 `scrape_info` 记录
- **THEN** 该记录出现在 `getRecentlyAddedList()` 结果中

#### Scenario: 扫描后补全刮削数据时自动进入媒体库
- **WHEN** 原本无 scrape_info 的视频完成刮削，写入 `scrape_info` 记录
- **THEN** 下次查询 `getRecentlyAddedList()` 时该视频出现在结果中

---

### Requirement: 无海报但有完整剧集信息的视频用标题兜底展示
当视频有 `scrape_info` 记录，但 `poster_local_path` 和 `poster_url` 均为 `NULL` 时，系统 SHALL 允许该视频出现在媒体库，使用标题作为兜底显示。

"完整剧集信息"指具备 `tv_series_id`、`season_number`、`episode_number` 及剧集标题。

#### Scenario: 无海报但有完整信息的剧集正常显示
- **WHEN** scrape_info 存在但 poster_local_path=NULL 且 poster_url=NULL，且剧集关系字段完整
- **THEN** 该集出现在剧集详情页集数列表中，展示集数标题，无封面图

#### Scenario: 无海报且信息不完整的视频不展示
- **WHEN** scrape_info 存在但 poster_local_path=NULL、poster_url=NULL，且剧集关系字段（tv_series_id等）缺失
- **THEN** 该视频 SHALL NOT 出现在媒体库 UI（海报墙）中

---

### Requirement: 用户可通过文件浏览器访问未刮削视频
未刮削视频 SHALL 仍可通过「文件源 → 文件浏览器」路径找到并播放，不受媒体库过滤策略影响。

#### Scenario: 文件浏览器展示所有视频文件
- **WHEN** 用户在文件浏览器中浏览文件源目录
- **THEN** 所有视频文件（含未刮削）均显示，可选择单个文件播放
