# opensubtitles-proxy-worker Specification

## Purpose

定义 Cloudflare Worker 代理的职责边界、请求转发契约、设备级限流策略与 API Key 安全注入规范，确保 App 在无需用户配置 Key 的前提下可使用 OpenSubtitles 功能。

## Requirements

### Requirement: Cloudflare Worker 必须将 App 请求透明转发至 OpenSubtitles API

Worker SHALL 接受 `GET /v1/subtitles` 和 `POST /v1/download` 两个路由，注入开发者 API Key（来自 Cloudflare 环境变量 `OPENSUBTITLES_API_KEY`），透传请求参数和 body，返回 OpenSubtitles 原始响应。

#### Scenario: 搜索请求转发
- **WHEN** App 发送 `GET /v1/subtitles?query=...&languages=...`
- **THEN** Worker 转发到 `https://api.opensubtitles.com/api/v1/subtitles?query=...&languages=...`
- **AND** 注入 `Api-Key` header
- **AND** 返回 OpenSubtitles 原始 JSON 响应

#### Scenario: 下载请求转发
- **WHEN** App 发送 `POST /v1/download`（body 含字幕 ID）
- **THEN** Worker 转发到 `https://api.opensubtitles.com/api/v1/download`
- **AND** 注入 `Api-Key` header
- **AND** 返回临时下载 URL

---

### Requirement: Worker 必须按设备 ID 做每日限流

Worker SHALL 读取请求头 `X-Device-Id`，使用 Cloudflare KV 记录该设备当日请求次数。当次数超过 50 次/天时，Worker SHALL 返回 HTTP 429，body 为 `{"error":"quota_exceeded"}`。计数在每日 00:00 UTC 重置（KV key 含日期）。

#### Scenario: 正常请求通过
- **WHEN** 设备今日请求次数 < 50
- **THEN** Worker 正常转发请求并返回 OpenSubtitles 响应

#### Scenario: 超出限额返回 429
- **WHEN** 设备今日请求次数 ≥ 50
- **THEN** Worker 返回 HTTP 429，body `{"error":"quota_exceeded"}`
- **AND** 不转发请求到 OpenSubtitles

#### Scenario: 缺少 X-Device-Id 时拒绝请求
- **WHEN** 请求未携带 `X-Device-Id` header
- **THEN** Worker 返回 HTTP 400，body `{"error":"missing_device_id"}`

---

### Requirement: Worker API Key 不得暴露在代码库中

Worker 的 OpenSubtitles API Key SHALL 仅通过 Cloudflare Worker 环境变量（`wrangler secret`）注入，不得硬编码在任何代码文件或版本控制中。

#### Scenario: 本地开发使用 .dev.vars
- **WHEN** 开发者在本地运行 `wrangler dev`
- **THEN** 从 `.dev.vars` 文件读取 `OPENSUBTITLES_API_KEY`（该文件在 .gitignore 中）

#### Scenario: 生产部署使用 wrangler secret
- **WHEN** 执行 `wrangler deploy` 部署 Worker
- **THEN** API Key 从 Cloudflare secret store 读取
- **AND** 代码仓库中不含任何 Key 明文
