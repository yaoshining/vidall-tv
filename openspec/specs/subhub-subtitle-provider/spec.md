# subhub-subtitle-provider Specification

## Purpose

定义 SubHub 字幕 provider 的行为契约：通过 SubHub 统一字幕出口 API 搜索与下载字幕，并把 SubHub 响应映射为统一的字幕搜索结果，供字幕获取服务聚合。

## Requirements

### Requirement: SubHub 搜索结果必须映射为统一搜索结果

系统 SHALL 调用 SubHub `GET /api/subtitles/search`，并把返回的 `results[]` 映射为统一字幕搜索结果，其中 `source` 为 `subhub`、`subtitleId` 为网关引用 `id`、`fileName` 为 `releaseName`（空时兜底）、`languageCode` 为 `language`（空时兜底）、`downloadCount` 为 `raw.download_count`（缺失时为 0）、`subtitleRef` 为网关引用 `id`。

#### Scenario: 搜索成功返回映射结果
- **WHEN** SubHub 搜索返回 `results[]` 且包含 `id` / `releaseName` / `language` / `downloadUrl`
- **THEN** 每条结果映射为 `source=subhub` 的统一搜索结果
- **AND** `subtitleId` 与 `subtitleRef` 均为网关引用 `id`
- **AND** `downloadCount` 取 `raw.download_count`，缺失时为 0

#### Scenario: releaseName 或 language 为空
- **WHEN** SubHub 搜索结果的 `releaseName` 或 `language` 为 `null`
- **THEN** 映射结果使用非空兜底值，不抛出异常

### Requirement: SubHub 搜索结果无结果时返回空列表

系统 SHALL 将 SubHub 搜索返回 `NO_RESULTS`（HTTP 404）视为无结果，返回空列表，不抛出错误。

#### Scenario: 无匹配字幕
- **WHEN** SubHub 搜索返回 HTTP 404 且错误码为 `NO_RESULTS`
- **THEN** 系统返回空数组
- **AND** 不抛出错误

### Requirement: 系统必须通过 SubHub 下载字幕并写入本地规范路径

系统 SHALL 调用 SubHub `GET /api/subtitles/download?subtitleId=...` 获取字幕文件二进制内容，优先按 `Content-Disposition` 解析文件名（失败时回退到调用方提供的兜底文件名），并写入与 OpenSubtitles 下载一致的本地规范路径。

#### Scenario: 成功下载并写入本地
- **WHEN** 用户选择一条 `source=subhub` 的字幕并触发下载
- **THEN** 系统请求 `GET /api/subtitles/download?subtitleId=...`
- **AND** 返回内容为字幕文件二进制
- **AND** 文件写入本地规范路径后返回本地路径与文件名

#### Scenario: 下载目标字幕不存在
- **WHEN** SubHub 下载返回 HTTP 404 且错误码为 `SUBTITLE_NOT_FOUND`
- **THEN** 系统抛出字幕失效错误
- **AND** UI 展示「字幕已失效，请重新搜索」提示

#### Scenario: 下载时目标目录不存在
- **WHEN** 对应视频的字幕缓存目录尚不存在
- **THEN** 系统自动递归创建目录后写入文件

### Requirement: SubHub 请求必须携带 Caller Key 鉴权

系统 SHALL 在每次 SubHub 搜索与下载请求中携带 `Authorization: Bearer <CallerKey>` 头，Caller Key 来自应用配置。

#### Scenario: 请求携带 Bearer 鉴权
- **WHEN** 系统发起 SubHub 搜索或下载请求
- **THEN** 请求头包含 `Authorization: Bearer <CallerKey>`

### Requirement: SubHub 错误必须归类为业务错误

系统 SHALL 将 SubHub 统一错误结构 `{error:{code,message}}` 归类为可区分的业务错误：鉴权无效归为 `subhub_auth_invalid`、上游凭据耗尽归为 `subhub_quota_exhausted`、字幕失效归为 `subhub_not_found`、服务未就绪/上游失败/超时归为 `subhub_unavailable`。

#### Scenario: Caller Key 无效
- **WHEN** SubHub 返回错误码 `CALLER_KEY_INVALID` 或 `CALLER_KEY_SUSPENDED` 或 `FORBIDDEN`
- **THEN** 系统归类为 `subhub_auth_invalid`

#### Scenario: 上游凭据耗尽
- **WHEN** SubHub 返回错误码 `PROVIDER_CREDENTIAL_EXHAUSTED`
- **THEN** 系统归类为 `subhub_quota_exhausted`

#### Scenario: 服务不可用或超时
- **WHEN** SubHub 返回 `SERVICE_NOT_READY` / `PROVIDER_UNAVAILABLE` / `UPSTREAM_FAILED` / `TIMEOUT`，或发生网络错误
- **THEN** 系统归类为 `subhub_unavailable`
