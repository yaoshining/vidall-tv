## ADDED Requirements

### Requirement: OpenSubtitles 搜索仅在直连模式下被调用

系统 SHALL 仅在 `AppPreferences.OPENSUBTITLES_API_KEY` 已设置时调用 OpenSubtitles 搜索，请求直连 `api.opensubtitles.com` 并携带 `Api-Key`；未设置 Key 时，字幕获取服务 SHALL 路由到 SubHub 而不调用 OpenSubtitles 搜索。

#### Scenario: 已设置 Key 时直连 OpenSubtitles
- **WHEN** 用户已配置 `OPENSUBTITLES_API_KEY`
- **THEN** 搜索请求直接发往 `api.opensubtitles.com`
- **AND** 请求携带 `Api-Key: <用户 Key>` header

#### Scenario: 未设置 Key 时不调用 OpenSubtitles 搜索
- **WHEN** 用户未配置 `OPENSUBTITLES_API_KEY`
- **THEN** 字幕获取服务路由到 SubHub
- **AND** 不向 OpenSubtitles（含代理 Worker）发起搜索请求

## REMOVED Requirements

### Requirement: 搜索通道必须支持代理模式与直连模式自动切换

**Reason**: 无 Key 时的字幕获取改由服务层路由到 SubHub，不再走 OpenSubtitles 官方代理。

**Migration**: 无 Key 搜索走 SubHub；OpenSubtitles 搜索仅在已设 Key（直连模式）时由字幕获取服务调用。
