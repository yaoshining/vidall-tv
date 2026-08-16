# subtitle-acquisition-service Specification

## Purpose
统一收口在线字幕搜索、下载与最近使用字幕记录更新流程，将字幕面板对 `OpenSubtitlesClient`、`SubtitleDownloader`、`SubtitleCacheManager` 的直接依赖剥离到独立的 service 中。

## Requirements

### Requirement: Subtitle acquisition SHALL be coordinated by a dedicated service
在线字幕搜索、下载、缓存命中与最近使用字幕更新，系统 MUST 通过统一的 subtitle acquisition service 编排，而不能由字幕面板直接调用底层 client 与 cache manager。

#### Scenario: User searches online subtitles
- **WHEN** 用户在字幕面板中触发在线搜索
- **THEN** subtitle acquisition service SHALL 负责构造搜索请求、读取语言偏好并返回可展示的搜索结果

### Requirement: Downloaded subtitles SHALL be returned as session-ready results
字幕下载成功后，系统 MUST 返回能够直接追加到当前播放会话中的结果，而不是要求 UI 自行拼装缓存元数据与文件路径语义。

#### Scenario: User downloads a subtitle result
- **WHEN** 用户从搜索结果中选择并下载字幕
- **THEN** subtitle acquisition service SHALL 返回本地字幕路径、必要的缓存更新结果，以及供当前播放会话追加该字幕的统一结果

### Requirement: Last-used subtitle state SHALL remain consistent
系统 MUST 在字幕下载成功、用户选择缓存字幕或恢复最近使用字幕时，保持同一稳定视频标识上的 last-used 字幕记录一致。

#### Scenario: Reopen a video after downloading a subtitle
- **WHEN** 用户为某个视频下载并切换到一条字幕后关闭播放，再次打开同一视频
- **THEN** 系统 SHALL 能基于同一稳定视频标识恢复该最近使用字幕，而不依赖 UI 重复写入底层缓存逻辑

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
