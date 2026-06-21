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
