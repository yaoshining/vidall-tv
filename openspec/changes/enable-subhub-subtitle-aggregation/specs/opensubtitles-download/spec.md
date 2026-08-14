## ADDED Requirements

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

## REMOVED Requirements

### Requirement: 下载通道必须与搜索通道共用同一代理/直连策略

**Reason**: 无 Key 时的字幕下载改由服务层路由到 SubHub，不再走 OpenSubtitles 官方代理。

**Migration**: 无 Key 下载走 SubHub；OpenSubtitles 下载仅在已设 Key（直连模式）时由字幕获取服务调用。
