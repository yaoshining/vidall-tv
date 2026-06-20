# opensubtitles-search Specification

## Purpose

定义通过 OpenSubtitles API 搜索字幕的完整链路契约，包括文件名解析、搜索词构建、代理/直连通道自动切换，以及搜索结果按语言偏好排序的行为规范。

## Requirements

### Requirement: 系统必须支持通过文件名搜索 OpenSubtitles 字幕列表

系统 SHALL 接受视频文件路径，经 `parseFileName()` + `buildSearchTitles()` 提取搜索词后，调用 OpenSubtitles `GET /subtitles` 接口，返回按用户语言偏好排序的字幕列表。字幕列表项 SHALL 包含：字幕文件名、语言代码、下载次数、字幕 ID。

#### Scenario: 正常搜索返回结果列表
- **WHEN** 用户在播放页触发字幕搜索，视频文件为 `The.Dark.Knight.2008.1080p.mkv`
- **THEN** 系统调用 `parseFileName()` 提取 `The Dark Knight`，再调用 OpenSubtitles API
- **AND** 返回按用户语言偏好排序的字幕列表
- **AND** 列表每项包含字幕文件名、语言代码、下载次数

#### Scenario: 搜索无结果时返回空列表
- **WHEN** OpenSubtitles API 返回 0 条结果
- **THEN** 系统返回空数组，不抛出错误
- **AND** UI 展示「未找到字幕」提示

#### Scenario: 语言偏好参数正确传递
- **WHEN** 用户语言偏好为 `['zh-CN', 'zh-TW', 'en']`
- **THEN** 搜索请求的 `languages` 参数为 `"zh-CN,zh-TW,en"`
- **AND** 搜索结果按该偏好顺序排序

---

### Requirement: 搜索通道必须支持代理模式与直连模式自动切换

系统 SHALL 在 `AppPreferences.OPENSUBTITLES_API_KEY` 未设置时使用官方代理（Cloudflare Worker）；已设置时直连 `api.opensubtitles.com`。通道选择对调用方透明。

#### Scenario: 未设置 Key 时使用代理通道
- **WHEN** 用户未配置 `OPENSUBTITLES_API_KEY`
- **THEN** 搜索请求发往 Cloudflare Worker 代理
- **AND** 请求携带 `X-Device-Id` header

#### Scenario: 已设置 Key 时直连 OpenSubtitles
- **WHEN** 用户已配置 `OPENSUBTITLES_API_KEY`
- **THEN** 搜索请求直接发往 `api.opensubtitles.com`
- **AND** 请求携带 `Api-Key: <用户 Key>` header

#### Scenario: 代理限额耗尽时提示降级
- **WHEN** Cloudflare Worker 返回 HTTP 429
- **THEN** 系统抛出 `ProxyQuotaExceededError`
- **AND** UI 展示「今日搜索配额已用完，请填写您自己的 API Key」
