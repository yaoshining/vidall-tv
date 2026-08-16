## ADDED Requirements

### Requirement: 搜索必须聚合多个字幕 provider 的结果

系统 SHALL 根据 `OPENSUBTITLES_API_KEY` 是否存在选择 provider 集合：未设置 Key 时仅使用 SubHub provider；已设置 Key 时使用 OpenSubtitles（直连）provider 与 SubHub provider。系统 SHALL 并发调用所有 provider，结果按「OpenSubtitles 在前、SubHub 在后」的顺序合并，并按内容指纹去重（碰撞时保留 OpenSubtitles 结果）。去重后 SHALL 按 `downloadCount` 降序排序（同下载量时保持合并顺序，即 OpenSubtitles 在前）。单 provider 失败 SHALL 不阻塞其它 provider 的结果返回；仅当所有 provider 都失败时才抛出错误。

> 注：`downloadCount` 排序是用户体系引入前的临时策略。引入用户/权益体系后，需按用户是否具备 SubHub 访问权限（如 Pro 用户或每日普通用户限额）调整排序与过滤，约束条件待定。

#### Scenario: 未设置 Key 时仅搜索 SubHub
- **WHEN** 用户未配置 `OPENSUBTITLES_API_KEY` 并触发在线字幕搜索
- **THEN** 系统仅调用 SubHub provider
- **AND** 返回的每条结果 `source` 均为 `subhub`

#### Scenario: 已设置 Key 时直连结果在前
- **WHEN** 用户已配置 `OPENSUBTITLES_API_KEY` 并触发在线字幕搜索
- **THEN** 系统并发调用 OpenSubtitles（直连）与 SubHub provider
- **AND** 合并顺序保持 `source=opensubtitles` 的结果在前
- **AND** 最终展示按 `downloadCount` 降序（同下载量时 OpenSubtitles 在前）

#### Scenario: 去重时保留 OpenSubtitles 结果
- **WHEN** OpenSubtitles 与 SubHub 返回了内容指纹相同（归一化文件名 + 语言码相同）的结果
- **THEN** 仅保留 `source=opensubtitles` 的结果，丢弃重复的 SubHub 结果

#### Scenario: 单 provider 失败不阻塞聚合
- **WHEN** 聚合搜索中某个 provider 抛出错误而其它 provider 返回结果
- **THEN** 系统返回成功 provider 的结果
- **AND** 不因单个 provider 失败而整体报错

#### Scenario: 所有 provider 都失败
- **WHEN** 聚合搜索中所有 provider 都抛出错误
- **THEN** 系统抛出错误
- **AND** UI 展示对应的失败提示

### Requirement: 下载必须按结果来源分派

系统 SHALL 按字幕结果的 `source` 分派下载：`source=opensubtitles` 走 OpenSubtitles 下载（`POST /download` 获取临时链接后下载）；`source=subhub` 走 SubHub 下载（`GET /api/subtitles/download` 获取二进制）。两种来源下载成功后都写入本地规范路径，并更新字幕缓存记录，缓存记录的来源分别标记为 `opensubtitles` 或 `subhub`。

#### Scenario: 下载 OpenSubtitles 来源结果
- **WHEN** 用户选择一条 `source=opensubtitles` 的字幕并触发下载
- **THEN** 系统通过 OpenSubtitles `POST /download` 下载
- **AND** 缓存记录来源标记为 `opensubtitles`

#### Scenario: 下载 SubHub 来源结果
- **WHEN** 用户选择一条 `source=subhub` 的字幕并触发下载
- **THEN** 系统通过 SubHub `GET /api/subtitles/download` 下载
- **AND** 缓存记录来源标记为 `subhub`
