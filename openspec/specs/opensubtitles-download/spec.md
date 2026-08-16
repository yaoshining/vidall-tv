# opensubtitles-download Specification

## Purpose

定义字幕文件下载的完整链路契约，包括通过 OpenSubtitles `/download` 接口获取临时 URL、使用 `@ohos.net.http` 写入本地沙盒规范路径，以及下载通道的路由策略。

## Requirements

### Requirement: 系统必须能下载字幕文件并写入本地沙盒规范路径

系统 SHALL 接受字幕 ID，通过 `POST /download` 获取临时下载 URL，再使用 `@ohos.net.http` 下载字幕文件二进制内容，写入路径 `context.filesDir/subtitles/{sourceType}_{sourceId}/{filePathHash}/{subtitleFileName}`，其中 `filePathHash` 为视频完整路径的 SHA256 前 16 字节 hex。

#### Scenario: 成功下载并写入本地
- **WHEN** 用户在字幕列表中选择一条字幕
- **THEN** 系统调用 `POST /download` 获取临时 URL
- **AND** 下载字幕文件内容
- **AND** 文件写入规范路径后通知 UI 刷新字幕列表
- **AND** 本次下载消耗 OpenSubtitles API 1 次下载配额

#### Scenario: 下载失败时展示错误提示
- **WHEN** 字幕文件下载过程中发生网络错误
- **THEN** 系统抛出 `SubtitleDownloadError`
- **AND** UI 展示简短错误提示，不崩溃

#### Scenario: 目标目录不存在时自动创建
- **WHEN** 对应视频的字幕缓存目录尚不存在
- **THEN** 系统自动递归创建目录后写入文件
- **AND** 不因目录缺失导致写入失败

### Requirement: OpenSubtitles 下载仅在直连模式下发生

系统 SHALL 仅在 `AppPreferences.OPENSUBTITLES_API_KEY` 已设置时通过 OpenSubtitles 下载字幕（`POST /download` 获取临时链接后下载）；未设置 Key 时的字幕下载 SHALL 由字幕获取服务路由到 SubHub。

#### Scenario: 已设置 Key 时通过 OpenSubtitles 下载
- **WHEN** 用户已配置 `OPENSUBTITLES_API_KEY` 并选择一条 `source=opensubtitles` 的字幕
- **THEN** `POST /download` 请求直接发往 `api.opensubtitles.com`
- **AND** 请求携带 `Api-Key: <用户 Key>` header

#### Scenario: 未设置 Key 时下载走 SubHub
- **WHEN** 用户未配置 `OPENSUBTITLES_API_KEY` 并选择一条字幕
- **THEN** 该字幕来源为 `subhub`
- **AND** 下载通过 SubHub 完成
