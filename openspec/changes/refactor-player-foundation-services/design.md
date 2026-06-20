## Context

当前播放器外围职责同时分布在页面层、控制层与字幕面板中：

- `PlayerPage` 负责页面参数消费、续播弹窗、媒体级进度定时保存、剧集切源与协议重建。
- `VideoControls` 中的 `SubtitleSelectorDrawerDialog` 直接依赖 `OpenSubtitlesClient`、`SubtitleDownloader`、`SubtitleCacheManager`。
- `VideoPlayerController` 仍承担稳定缓存 key、字幕缓存上下文与一部分续播状态机。

这些职责虽然不直接属于播放器内核，但已经决定了播放器链路的外部编排方式。若不先收口外围 service，后续拆分运行时内核时会同时触碰 UI、协议、续播与字幕下载路径，风险过高。

## Goals / Non-Goals

**Goals:**

- 把协议源解析从页面层与剧集切源逻辑中抽离为统一 service。
- 把播放进度恢复与持久化逻辑从 `PlayerPage` 和 `VideoPlayerController` 的混合实现收口。
- 把字幕获取链路从 `VideoControls` 中抽离，保留现有 UI 行为与入口。
- 保持现有 `PlayerPageParam`、`VideoPlayerController` façade 与现有用户可见行为不变。

**Non-Goals:**

- 不重写 AVPlayer / IJK / Native adapter。
- 不在本阶段拆分 `PlaybackBackendService`、`SubtitleSessionService`、`AudioTrackRoutingService`。
- 不新增协议，不调整字幕 UI 视觉，不改变 fallback 策略。

## Decisions

### 1. 先拆外围应用层，再拆运行时内核

- 方案 A：直接拆 `VideoPlayerController` 内核职责。
- 方案 B：先拆页面/UI 外围职责，再拆内核。

选择方案 B。外围 service 的输入输出更稳定、对播放时序侵入更小，能先减少跨层耦合，再为第二阶段创造清晰边界。

### 2. `VideoPlayerController` 继续保留 façade 角色

- 方案 A：第一阶段同步缩小 controller 公开 API。
- 方案 B：保留现有 controller API，只把内部实现委托给新 service。

选择方案 B。当前 ArkUI 组件直接依赖大量 `@Trace` 状态，若在第一阶段同步改 façade，会放大回归面。

### 3. `SourceAdapterService` 统一输出稳定播放源描述

该 service 统一返回：

- 播放 URL
- HTTP headers
- `fileSourceType` / `fileSourceId`
- 稳定缓存 key 所需的 source identity
- 预置轨道与时长提示所需的补充信息

这样 `PlayerPage`、详情页、文件页与剧集切源逻辑不再自行拼装 WebDAV / SMB 细节。

### 4. `PlaybackProgressService` 同时覆盖 play_progress 与 media_progress

续播与保存逻辑目前横跨 `FileSourceDatabase` 与 `MediaProgressStore` 两条路径。新 service 负责统一：

- prepared 后恢复策略
- 是否弹续播框
- 退出/切后台/定时保存
- near-end 清理与 mark watched

`PlayerPage` 只保留事件绑定与 UI 展示。

### 5. `SubtitleAcquisitionService` 作为字幕获取用例层

该 service 封装：

- 搜索词构造
- 语言偏好读取
- OpenSubtitles 搜索
- 字幕下载
- 缓存 metadata 更新
- last used 写回
- 返回可直接追加到当前播放会话的结果

UI 只负责展示搜索结果、进度与错误提示。

## Risks / Trade-offs

- [风险] 第一阶段不改 façade，短期内 `VideoPlayerController` 体积不会明显下降太多。 → 缓解：本阶段优先移除页面/UI 对底层协议与字幕基础设施的直接依赖，为第二阶段 controller 瘦身建立前提。
- [风险] 进度恢复逻辑迁移时可能出现 prepared 后 seek/play 时机漂移。 → 缓解：保持现有决策顺序与事件触发点不变，只迁移决策归属。
- [风险] SMB 稳定缓存 key 与代理 URL 差异若处理不一致，会导致字幕缓存失效。 → 缓解：把稳定 source identity 作为 `SourceAdapterService` 的强制输出，而不是 UI/Controller 临时规则。

## Migration Plan

1. 引入 `SourceAdapterService`，先替换页面层和剧集切源里的协议装配逻辑。
2. 引入 `PlaybackProgressService`，替换 `PlayerPage` 中的续播与保存决策逻辑。
3. 引入 `SubtitleAcquisitionService`，替换 `SubtitleSelectorDrawerDialog` 中直接调用基础设施的流程。
4. 保持 `VideoPlayerController` 现有公开 API 不变，仅把内部调用逐步委托给 service。
5. 完成后以现有播放入口回归 WebDAV、SMB、本地文件与字幕搜索/下载路径。

## Open Questions

- `SourceAdapterService` 是否在第一阶段就统一承担 ffprobe 预置轨道补全，还是先只处理 URL / headers / source identity。
- `PlaybackProgressService` 是否需要在第一阶段就接管 fallback-resume 的完整状态，还是只覆盖页面可见的 prepared resume 与保存路径。
