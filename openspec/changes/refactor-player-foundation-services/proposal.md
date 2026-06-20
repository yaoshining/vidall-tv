## Why

当前播放器相关职责分散在 `PlayerPage`、`VideoControls`、`VideoPlayerController` 与协议客户端之间，导致协议差异、续播规则、字幕获取逻辑不断向 UI 与 controller 泄漏。继续在现有结构上叠加新协议或新字幕策略，会进一步提高改动成本与回归风险，因此需要先收口外围应用层职责。

## What Changes

- 新增 `SourceAdapterService`，统一 WebDAV / SMB / local 播放源解析、headers、稳定缓存 key 与协议差异封装。
- 新增 `PlaybackProgressService`，统一 prepared resume、续播弹窗决策、退出/切后台保存与媒体级进度回写策略。
- 新增 `SubtitleAcquisitionService`，统一在线搜索、下载、缓存命中、最近使用字幕与下载后回灌流程。
- 调整 `PlayerPage` 与 `VideoControls` 的职责边界，使它们依赖 service façade，而不直接拼装协议 URL 或直接调用字幕下载基础设施。
- 保持 `VideoPlayerController` 对 UI 的现有公开 API 与当前播放行为不变。

## Capabilities

### New Capabilities
- `playback-source-adapter-service`: 为播放器入口与剧集切源提供统一的源解析、header 注入、稳定 source key 与协议差异处理能力。
- `playback-progress-service`: 为播放器提供统一的续播决策、进度持久化与媒体级进度回写能力。
- `subtitle-acquisition-service`: 为字幕面板提供统一的搜索、下载、缓存命中与最近使用字幕恢复能力。

### Modified Capabilities
- `playback-resume-recovery`: 续播行为改为由独立 service 编排，但对外续播结果与触发时机保持不变。
- `subtitle-menu-search-entry`: 在线字幕搜索入口保留现有交互，但其执行链路改为通过独立 service 协调。

## Impact

- 主要影响代码：
  - `entry/src/main/ets/pages/player/index.ets`
  - `entry/src/main/ets/components/core/player/VideoControls.ets`
  - `entry/src/main/ets/components/core/player/VideoPlayerController.ets`
  - `entry/src/main/ets/lib/WebDAVClient.ets`
  - `entry/src/main/ets/lib/SMBClient.ets`
  - `entry/src/main/ets/subtitle/*`
- 保持不变：
  - `PlayerPageParam` 结构
  - `PlaybackContext` / `PlaybackContextItem` 结构
  - `VideoPlayerController` 面向 UI 的主要公开字段与方法
- 风险集中在协议切源与续播状态回写，需要通过渐进迁移避免行为回归。
