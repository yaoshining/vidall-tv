## MODIFIED Requirements

### Requirement: UmamiReporter 将指标映射为 Umami `/api/send` 请求

系统 SHALL 提供 `UmamiReporter`，实现 `MetricsReporter` 接口，并使用 `@ohos.net.http` 将播放、字幕和扫描指标映射为 Umami `POST /api/send` 请求。每个请求 MUST 使用 `type + payload` 结构，并带上固定 `website`、`hostname` 和按事件类型构造的 `url`。`UmamiReporter` 额外暴露 `trackPageView(path: string)` 和 `trackCustomEvent(feature: string, name: string, data: UmamiEventData)` 两个公开方法，供 `UmamiAnalyticsService` 调用。所有事件的 `payload.data` MUST 包含 `screen` 和 `language` 标准字段。

#### Scenario: playback_attempt 映射为 event 请求
- **WHEN** 业务层调用 `recordPlaybackAttempt(true, 450, media, 'network')`
- **THEN** `UmamiReporter` 发送 `type = event` 的请求，`payload.name = playback_attempt`，并在 `payload.data` 中包含 `success`、`first_frame_ms`、`source_type`、媒体标识字段、`screen = "3840x2160"` 以及 `language`（系统语言）

#### Scenario: subtitle_usage 映射为 event 请求
- **WHEN** 业务层调用 `recordSubtitleUsage('zh')`
- **THEN** `UmamiReporter` 发送 `type = event` 的请求，`payload.name = subtitle_usage`，并在 `payload.data` 中包含 `language`、`has_subtitle`、`screen` 和系统 `language` 字段

#### Scenario: scan_coverage 映射为 event 请求
- **WHEN** 业务层调用 `recordScanCoverage(450, 500)`
- **THEN** `UmamiReporter` 发送 `type = event` 的请求，`payload.name = scan_coverage`，并在 `payload.data` 中包含 `scanned`、`total`、`coverage_pct`、`screen` 和 `language` 字段

#### Scenario: trackPageView 发送 page_view 语义请求
- **WHEN** `UmamiAnalyticsService` 调用 `umamiReporter.trackPageView('/player')`
- **THEN** `UmamiReporter` 发送 `type = event` 请求，`payload.url = '/player'`，标识为 page_view

#### Scenario: trackCustomEvent 发送行为事件请求
- **WHEN** `UmamiAnalyticsService` 调用 `umamiReporter.trackCustomEvent('lifecycle', 'app_launch', { version: '1.0', os_version: '6.0.2' })`
- **THEN** `UmamiReporter` 发送 `type = event` 请求，`payload.name = app_launch`，`payload.data` 包含传入字段及 `screen`、`language` 标准字段

#### Scenario: language 字段获取失败时降级为 zh-CN
- **WHEN** `i18n.System.getSystemLanguage()` 抛出异常
- **THEN** `language` 字段降级为 `"zh-CN"`，事件正常发送，不抛出异常

## ADDED Requirements

### Requirement: UmamiEventData 扩展 screen 和 language 标准字段

`UmamiEventData` 接口 SHALL 新增 `screen: string` 和 `language: string` 可选字段。`UmamiReporter` MUST 在构建每条事件 payload 时通过 `buildBaseFields()` 辅助函数自动注入这两个字段，调用方不需要手动传入。

#### Scenario: 标准字段自动注入
- **WHEN** 任意事件通过 `UmamiReporter` 发送
- **THEN** 最终发送的 `payload.data` 中包含 `screen = "3840x2160"` 和正确的系统 `language` 值，无需调用方显式传入
