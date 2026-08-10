# playback-backend-service Specification

## Purpose
Centralize playback backend orchestration — adapter selection, lifecycle management, and fallback coordination — into a dedicated service, decoupling backend-specific logic from `VideoPlayerController`.

## Requirements

### Requirement: Playback backend orchestration SHALL be centralized
系统 MUST 通过统一的 playback backend service 编排播放器后端选择、adapter 创建、初始化与释放，而不能由 controller 直接承担所有 backend-specific 生命周期逻辑。

#### Scenario: Choose backend for a new playback session
- **WHEN** 新的播放会话开始并提供当前视频信息与能力探测输入
- **THEN** playback backend service SHALL 产出最终选用的 backend、相关 adapter 实例以及后续 fallback 所需的运行时上下文
- **AND** 可选 backend 集合 SHALL 包含 `'avplayer'` / `'ijkplayer'` / `'mpv'`

#### Scenario: Backend decision respects user fallback preference
- **WHEN** AVPlayer 探测为无法播放当前视频
- **THEN** playback backend service SHALL 读取 `AppPreferences.PLAYER_FALLBACK` 决定回退目标
- **AND** 当偏好为 `'mpv'` 时 SHALL 选择 `'mpv'` 作为回退后端
- **AND** 当偏好为 `'ijkplayer'` 或未设置时 SHALL 选择 `'ijkplayer'` 作为回退后端

### Requirement: Fallback flow SHALL preserve existing playback continuity
当当前 backend 触发 unsupported format 或 native fallback 时，系统 MUST 由 playback backend service 统一执行 fallback，并保留现有续播位置与自动恢复播放语义。

#### Scenario: AVPlayer unsupported format fallback
- **WHEN** AVPlayer 在当前播放会话中报告格式不支持
- **THEN** playback backend service SHALL 触发用户偏好的 fallback 目标 backend（`'ijkplayer'` 或 `'mpv'`）
- **AND** 系统 SHALL 保留当前续播位置与自动恢复播放决策

#### Scenario: Native backend fallback to IJK
- **WHEN** native backend 初始化超时、无时间轴输出或报告错误
- **THEN** playback backend service SHALL 切换到 IJK backend
- **AND** 用户可见的恢复播放结果 SHALL 与当前流程保持兼容

#### Scenario: mpv backend failure triggers dual-kernel fallback prompt
- **WHEN** 当前后端为 `'mpv'` 且播放失败
- **THEN** playback backend service SHALL 触发双内核失败兜底流程
- **AND** 系统 SHALL 提示用户是否尝试 `'ijkplayer'` 作为最终回退

#### Scenario: ijkplayer backend failure triggers dual-kernel fallback prompt
- **WHEN** 当前后端为 `'ijkplayer'` 且播放失败
- **THEN** playback backend service SHALL 触发双内核失败兜底流程
- **AND** 系统 SHALL 提示用户是否尝试 `'mpv'` 作为最终回退

### Requirement: UI context binding SHALL remain backend-aware but service-driven
系统 MUST 由 playback backend service 编排 IJK / native / mpv 等需要 XComponent 上下文绑定的 backend 时序，同时保持现有 UI 触发入口不变。

#### Scenario: Bind IJK context after backend selection
- **WHEN** 当前播放会话最终选择 IJK backend 且 UI 提供 XComponent 上下文
- **THEN** playback backend service SHALL 完成与 IJK adapter 相关的上下文绑定与初始化衔接
- **AND** UI 侧仍可通过现有 controller 入口触发该绑定流程

#### Scenario: Bind mpv surface after backend selection
- **WHEN** 当前播放会话最终选择 mpv backend 且 UI 提供 XComponent surfaceId
- **THEN** playback backend service SHALL 通过 `XComponentSurfaceAdapter` 完成 `attachSurface` 绑定
- **AND** UI 侧仍可通过现有 controller 入口触发该绑定流程
- **AND** mpv 分支 SHALL 使用 `XComponentController` 模式而非 `libraryname` 模式
