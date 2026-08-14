## Why

当前在线字幕搜索/下载只走 OpenSubtitles 一个源：未配置 Key 时经 Cloudflare Worker 代理（每设备每日 50 次限额），配置 Key 后直连。SubHub 自托管字幕网关已上线并提供了多 provider 聚合出口（opensubtitles + xunlei），但 TV 端尚未接入。本变更把字幕获取改为「按是否有 OpenSubtitles API Key 路由」：无 Key 默认走 SubHub（免注册、无需代理限额），有 Key 时 OpenSubtitles 直连结果优先、SubHub 结果拼接在后，并用来源标记区分两条链路。账户体系尚未建立，因此本次不引入会员/免费额度门控，仅做按 Key 的路由。

## What Changes

- **新增 SubHub 字幕 Provider**：将 `SubHubClient`（搜索/下载）接入统一字幕获取链路，映射 SubHub 响应为统一搜索结果，并支持 `Content-Disposition` 文件名解析与本地落盘。
- **新增 Provider 抽象与解析器**：定义 `SubtitleProvider` 接口；`SubtitleProviderResolver` 按 `OPENSUBTITLES_API_KEY` 是否为空决定 provider 列表——有 Key 返回 `[OpenSubtitles, SubHub]`，无 Key 返回 `[SubHub]`。
- **搜索聚合**：`SubtitleAcquisitionService.search` 并发调用多个 provider，OpenSubtitles 结果在前、SubHub 结果在后，按「内容指纹」去重（OS 优先），单 provider 失败不阻塞另一个（partial 语义）。
- **下载分支**：`SubtitleAcquisitionService.download` 按结果来源分支——`opensubtitles` 走现有 `SubtitleDownloader`（POST /download），`subhub` 走 SubHub 下载（GET 二进制流）后写盘；两者都写 `SubtitleCacheManager`（`source` 分别标记）。
- **统一结果类型**：`SubtitleSearchResult` 由「复用 OpenSubtitlesClient 类型」改为本地统一定义，新增 `source`、`subtitleRef`，`fileId` 变可选。
- **来源标记 UI**：字幕搜索结果行新增来源 chip（`直连` / `SubHub`），下载进行态改按 `subtitleId` 跟踪。
- **默认通道文案**：设置页 OpenSubtitles 配置默认状态由「官方代理 · 推荐」改为「SubHub · 推荐」（清空 Key 后回到 SubHub 通道）。
- **无 Key 不再走 OS 代理**：字幕获取在无 Key 时不再请求 Cloudflare Worker，改走 SubHub；OpenSubtitles provider 仅在设置 Key（直连模式）时被调用。OS 代理 Worker 代码保留不删，但不再被字幕面板默认路径使用。
- **错误映射扩展**：新增 `subhub_auth_invalid` / `subhub_quota_exhausted` / `subhub_unavailable` / `subhub_not_found` 四种 `SubtitleAcquisitionErrorKind` 及对应 Toast 文案。

## Capabilities

### New Capabilities

- `subhub-subtitle-provider`: SubHub 字幕 provider 的客户端封装、字段映射、下载落盘、Caller Key 配置与错误分类。

### Modified Capabilities

- `subtitle-acquisition-service`: 搜索从「单一 OpenSubtitles」改为「多 provider 并发聚合 + 去重 + 来源标记」；下载按来源分支到 OpenSubtitles 或 SubHub。
- `opensubtitles-api-key-config`: 默认通道由「官方代理」改为「SubHub」；清空 Key 后恢复到 SubHub 通道而非代理。
- `opensubtitles-search`: 未设置 Key 时不再经 OS 代理搜索，改由服务层路由到 SubHub；OpenSubtitles provider 仅在直连模式（已设 Key）下被调用。
- `opensubtitles-download`: 下载通道策略同步调整——OS 下载仅在直连模式下发生，无 Key 的字幕下载走 SubHub。
- `subtitle-menu-search-entry`: 搜索结果行新增来源 chip（区分直连/SubHub），下载进行态按 `subtitleId` 跟踪。

## Impact

- **新增代码**：
  - `entry/src/main/ets/services/subtitleAcquisition/providers/SubtitleProvider.ets`
  - `entry/src/main/ets/services/subtitleAcquisition/providers/OpenSubtitlesSubtitleProvider.ets`
  - `entry/src/main/ets/services/subtitleAcquisition/providers/SubHubSubtitleProvider.ets`
  - `entry/src/main/ets/services/subtitleAcquisition/providers/SubtitleProviderResolver.ets`
  - `entry/src/main/ets/services/subtitleAcquisition/providers/SubtitleDeduplicator.ets`
- **修改代码**：
  - `entry/src/main/ets/services/subtitleAcquisition/SubtitleAcquisitionTypes.ets`：统一 `SubtitleSearchResult`、扩展 `SubtitleDownloadInput`、扩展 `SubtitleAcquisitionErrorKind` 与 `classifyAcquisitionError`
  - `entry/src/main/ets/services/subtitleAcquisition/SubtitleAcquisitionService.ets`：搜索聚合 + 下载分支
  - `entry/src/main/ets/config/AppEnv.ets`：新增 `SUBHUB_API_KEY`（Caller Key 常量）
  - `entry/src/main/ets/lib/SubHubClient.ets`：默认 Caller Key 改为 `AppEnv.SUBHUB_API_KEY`
  - `entry/src/main/ets/components/core/player/SubtitleSelectorDrawerDialog.ets`：来源 chip + 下载 key 跟踪 + 新增 toast 文案
  - `entry/src/main/ets/pages/settings/builders/OpenSubtitlesConfigBuilder.ets`：默认状态文案改为「SubHub · 推荐」
  - `entry/src/main/ets/subtitle/SubtitleDownloader.ets`：抽取可复用的字幕写盘 helper（供 SubHub 下载复用）
- **不变/保留**：`proxy/opensubtitles-worker` 与 `AppEnv.OS_PROXY_BASE_URL` 保留不删（本次不再作为字幕面板无 Key 默认路径）。
- **依赖**：复用已落地的 `SubHubClient.ets`；无新增第三方依赖。

## 延后（本次不做）

- 会员/免费用户每日额度门控：账户体系未建立，仅按「有无 OS Key」路由；未来接入 `entitlement-architecture` 的 EntitlementService 后叠加额度逻辑。
- SubHub Caller Key 明文暂存 AppEnv 常量，后续迁移 BuildProfile/secret。
- 演示页（`SubHubDemoPage` 及顶栏入口）后续由用户通知时移除。
