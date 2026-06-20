## ADDED Requirements

### Requirement: 系统 SHALL 在字幕下载完成后写入 metadata.json 索引

`SubtitleDownloader.download()` 完成文件写入后，系统 SHALL 调用 `SubtitleCacheManager.saveSubtitle()` 将字幕元信息写入对应视频目录的 `metadata.json`。

#### Scenario: 新视频首次缓存字幕
- **WHEN** `SubtitleDownloader.download()` 成功写入字幕文件
- **AND** 对应视频目录中不存在 `metadata.json`
- **THEN** 系统创建 `metadata.json`，包含 `videoPath`、`sourceId`、`lastUsed`（设为刚下载的文件名）、`subtitles` 数组（含本次下载的元数据）

#### Scenario: 同一视频二次下载不同字幕时追加记录
- **WHEN** 某视频已有 `metadata.json`（含 1 条记录）
- **AND** 用户下载该视频的另一条字幕
- **THEN** `metadata.json` 的 `subtitles` 数组新增一条记录
- **AND** 原有记录保留不变

#### Scenario: 同名字幕覆盖下载时不产生重复记录
- **WHEN** 下载的字幕 `fileName` 与 `metadata.json` 中已有记录的 `fileName` 相同
- **THEN** 覆盖该条记录（更新 `downloadedAt`）
- **AND** `subtitles` 数组长度不增加

### Requirement: 系统 SHALL 提供接口查询某视频的所有已缓存字幕

`SubtitleCacheManager.listCachedSubtitles(sourceType, sourceId, videoPath)` SHALL 返回该视频目录下 `metadata.json` 中的 `subtitles` 数组。

#### Scenario: 存在缓存时返回字幕列表
- **WHEN** 调用 `listCachedSubtitles(sourceType, sourceId, videoPath)`
- **AND** 对应目录存在合法 `metadata.json`
- **THEN** 返回 `subtitles` 数组（可能为空数组）

#### Scenario: 无缓存或 metadata 损坏时返回空数组
- **WHEN** 调用 `listCachedSubtitles(sourceType, sourceId, videoPath)`
- **AND** 对应目录不存在或 `metadata.json` 不是合法 JSON
- **THEN** 返回空数组 `[]`
- **AND** 不抛出异常

### Requirement: 系统 SHALL 记录并查询上次使用的字幕

`SubtitleCacheManager.getLastUsedSubtitle()` SHALL 返回 `metadata.json` 中 `lastUsed` 字段对应的本地文件完整路径；`setLastUsedSubtitle()` SHALL 更新该字段。

#### Scenario: lastUsed 文件存在时返回完整本地路径
- **WHEN** 调用 `getLastUsedSubtitle(sourceType, sourceId, videoPath)`
- **AND** `metadata.json` 中 `lastUsed` 字段不为空
- **AND** 对应字幕文件在沙盒中存在
- **THEN** 返回该字幕文件的完整绝对路径

#### Scenario: lastUsed 文件已被 LRU 清除时返回 null
- **WHEN** 调用 `getLastUsedSubtitle(sourceType, sourceId, videoPath)`
- **AND** `metadata.json` 中 `lastUsed` 字段不为空
- **AND** 对应字幕文件在沙盒中已不存在
- **THEN** 清除 `metadata.json` 中的 `lastUsed` 字段
- **AND** 返回 `null`

#### Scenario: 调用 setLastUsedSubtitle 时更新 lastUsed 字段
- **WHEN** 调用 `setLastUsedSubtitle(sourceType, sourceId, videoPath, fileName)`
- **AND** `fileName` 存在于 `subtitles` 数组中
- **THEN** `metadata.json` 中 `lastUsed` 字段更新为该 `fileName`

### Requirement: 系统 SHALL 在缓存超限时自动执行 LRU 清理

每个视频目录的字幕缓存 SHALL 不超过 10 个文件；超出时系统 SHALL 删除 `downloadedAt` 最早的文件及其 metadata 记录。

#### Scenario: 缓存未达上限时不触发清理
- **WHEN** `saveSubtitle()` 写入后 `subtitles` 数组长度 ≤ 10
- **THEN** 不删除任何文件

#### Scenario: 缓存超限时删除最旧记录
- **WHEN** `saveSubtitle()` 写入后 `subtitles` 数组长度 > 10
- **THEN** 删除 `downloadedAt` 最早的字幕文件（沙盒文件 + metadata 记录）
- **AND** `subtitles` 数组长度恢复为 10

### Requirement: 系统 SHALL 提供清除某视频全部字幕缓存的接口

`SubtitleCacheManager.clearSubtitleCache(sourceType, sourceId, videoPath)` SHALL 删除对应视频目录下的所有字幕文件及 `metadata.json`。

#### Scenario: 有缓存时清除全部
- **WHEN** 调用 `clearSubtitleCache(sourceType, sourceId, videoPath)`
- **AND** 对应目录存在
- **THEN** 该目录下所有文件（含 `metadata.json`）被删除
- **AND** 目录本身被删除

#### Scenario: 无缓存时静默完成
- **WHEN** 调用 `clearSubtitleCache(sourceType, sourceId, videoPath)`
- **AND** 对应目录不存在
- **THEN** 静默返回，不抛出异常

### Requirement: 系统 SHALL 提供全量清理字幕缓存的接口

`SubtitleCacheManager.clearAllSubtitleCaches(filesDir)` SHALL 删除 `{filesDir}/subtitles/` 目录下所有内容（所有文件源、所有视频的字幕缓存），并尝试删除 `subtitles/` 目录本身。

#### Scenario: 存在缓存时全量清理成功
- **WHEN** 调用 `clearAllSubtitleCaches(filesDir)`
- **AND** `{filesDir}/subtitles/` 目录存在且包含子目录和字幕文件
- **THEN** 所有子目录及其内容被删除
- **AND** `{filesDir}/subtitles/` 目录本身被删除（若为空）
- **AND** 方法正常返回，不抛出异常

#### Scenario: subtitles 目录不存在时静默返回
- **WHEN** 调用 `clearAllSubtitleCaches(filesDir)`
- **AND** `{filesDir}/subtitles/` 目录不存在
- **THEN** 方法静默返回
- **AND** 不抛出异常、不报错

#### Scenario: 部分子目录删除失败时不中断其他目录的清理
- **WHEN** 调用 `clearAllSubtitleCaches(filesDir)`
- **AND** 某个子目录因权限或 IO 错误无法删除
- **THEN** 继续清理其余子目录
- **AND** 所有子目录处理完毕后，若存在失败项则抛出 Error 告知调用方
