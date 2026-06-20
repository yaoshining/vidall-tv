## Context

目前运行时会话核心几乎全部集中在 `VideoPlayerController`：

- `initPlayer()` 负责自动音频路由、后端选择、SMB 代理启动、adapter 实例化与事件绑定。
- `setIjkContext()` / `setNativeContext()` 负责 UI XComponent 绑定时序。
- `loadSubtitleTracks()` / `switchSubtitleTrack()` / `adjustSubtitleDelay()` 负责字幕会话。
- `resolveAudioRoutingDecision()` / `loadAudioTracks()` / `switchAudioTrack()` 负责音轨探测与切换。
- fallback-resume、prepared resume、reloadSource resume 混杂在同一状态机里。

这使 controller 同时承担 façade、runtime state store 与 orchestration engine 三种角色。第二阶段目标是把运行时会话核心拆成独立 service，同时保留当前 UI 契约。

## Goals / Non-Goals

**Goals:**

- 用独立的 backend service 承担后端选择、adapter 生命周期与 fallback 编排。
- 用独立的 subtitle session service 承担字幕会话状态与轨道管理。
- 用独立的 audio track routing service 承担 codec 探测、能力判断与初始音轨恢复策略。
- 让 `VideoPlayerController` 退化为运行时 façade 与状态投影层。

**Non-Goals:**

- 不替换现有 `IPlayer` 接口。
- 不在本阶段重做 `PlayerPage`、`VideoControls` 外围 service 化成果。
- 不新增用户可见功能，不调整 UI 视觉或页面参数协议。

## Decisions

### 1. `VideoPlayerController` 保持 façade，不直接对 UI 破口

- 方案 A：直接让 UI 依赖多个新 service。
- 方案 B：controller 内部持有多个 service，对外保持现有 controller façade。

选择方案 B。ArkUI 已大量依赖 controller 的 `@Trace` 状态与方法，若直接让 UI 改依赖多个 service，会把第二阶段风险放大为全链路改造。

### 2. `PlaybackBackendService` 负责 adapter 生命周期和 fallback

该 service 统一负责：

- 后端选择策略
- adapter factory
- init / release
- unsupported format fallback
- native/IJK 上下文绑定时序
- SMB 代理生命周期与 fallback 重启

`VideoPlayerController` 不再直接 new adapter 或保存 backend-specific 时序细节。

### 3. `SubtitleSessionService` 负责字幕运行时而非获取

字幕获取已在第一阶段由 `SubtitleAcquisitionService` 处理；第二阶段的 subtitle session 只负责：

- `allSubtitleTracks`
- `activeSubtitleIndex`
- subtitle delay
- 当前 bridge state
- 加载、切换、附加外置字幕
- 当前视频稳定 key 与用户绑定/缓存裁决接入

这样可以把“会话内字幕状态”和“会话外字幕获取”清晰分层。

### 4. `AudioTrackRoutingService` 同时涵盖探测与恢复建议

该 service 统一输出：

- codec / channel 探测结果
- backend route / fallback 建议
- 初始音轨选择建议
- 用户历史绑定恢复建议

实际 `player.selectTrack()` 仍由 backend/session 侧执行，从而避免 routing service 侵入具体 adapter。

## Risks / Trade-offs

- [风险] fallback-resume 状态迁移时可能出现 seek 完成后未恢复播放或重复恢复播放。 → 缓解：保留现有 resume token 与 autoplay decision 语义，先迁移计算归属，再迁移状态存储。
- [风险] subtitle session 与 bridge adapter 边界划分不清，导致 controller 只是“换个名字继续很厚”。 → 缓解：明确 subtitle session 只编排状态和轨道，bridge adapter 只负责后端字幕桥接。
- [风险] audio routing service 若过度接管切轨执行，容易重新耦合 adapter。 → 缓解：routing service 仅返回建议与恢复结果，不直接调用 `IPlayer`。

## Migration Plan

1. 创建 backend/session/routing 三个 service 与最小接口。
2. 先把 `initPlayer()` 中的后端选择、adapter 创建与 fallback 编排迁入 `PlaybackBackendService`。
3. 再把字幕轨加载、切换、延迟与稳定 key 迁入 `SubtitleSessionService`。
4. 再把 codec 探测、初始 route、音轨恢复建议迁入 `AudioTrackRoutingService`。
5. 保持 controller façade 与 UI API 不变，直到所有状态已由新 service 驱动。

## Open Questions

- fallback-resume 的 pending state 最终是放在 backend service 里，还是抽成更小的 runtime resume coordinator。
- `SubtitleSessionService` 是否在本阶段就统一管理 `parsedSubtitle`，还是暂时保留 `VideoPlayer` 的解析监听逻辑。
