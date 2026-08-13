## MODIFIED Requirements

### Requirement: Playback backend orchestration SHALL be centralized
系统 MUST 通过统一的 playback backend service 编排播放器后端选择、adapter 创建、初始化与释放，而不能由 controller 直接承担所有 backend-specific 生命周期逻辑。

#### Scenario: Choose backend for a new playback session
- **WHEN** 新的播放会话开始并提供当前视频信息与能力探测输入
- **THEN** playback backend service SHALL 产出最终选用的 backend、相关 adapter 实例以及后续 fallback 所需的运行时上下文
- **AND** 活跃 backend 集合 SHALL 包含 `'avplayer'` 与 `'mpv'`
- **AND** 活跃 backend 集合 SHALL NOT 包含 `'ijkplayer'`

#### Scenario: Backend decision respects user fallback preference
- **WHEN** AVPlayer 探测为无法播放当前视频
- **THEN** playback backend service SHALL 忽略已弃用的用户回退偏好并选择 `'mpv'` 作为唯一回退后端
- **AND** playback backend service SHALL NOT 继续读取或持久化回退内核偏好

### Requirement: Fallback flow SHALL preserve existing playback continuity
当当前 backend 触发 unsupported format 或兼容后端 fallback 时，系统 MUST 由 playback backend service 统一执行 fallback，并保留现有续播位置与自动恢复播放语义。

#### Scenario: AVPlayer unsupported format fallback
- **WHEN** AVPlayer 在当前播放会话中报告格式不支持
- **THEN** playback backend service SHALL 触发 `'mpv'` fallback
- **AND** 系统 SHALL 保留当前续播位置与自动恢复播放决策

#### Scenario: Legacy backend identifiers map to MPV
- **WHEN** 兼容保留的 native 或 ffmpeg 后端标识进入播放流程
- **THEN** playback backend service SHALL 改为切换到 MPV backend
- **AND** 用户可见的恢复播放结果 SHALL 与当前流程保持兼容

#### Scenario: MPV backend failure enters terminal error handling
- **WHEN** 当前后端为 `'mpv'` 且播放失败
- **THEN** playback backend service SHALL 触发统一播放错误处理
- **AND** 系统 SHALL NOT 显示双内核回退提示或再触发内核回退

### Requirement: UI context binding SHALL remain backend-aware but service-driven
系统 MUST 由 playback backend service 编排保留后端需要的 XComponent 上下文绑定时序，同时保持现有 UI 触发入口可用。

#### Scenario: Bind IJK context after backend selection
- **WHEN** 历史调用路径请求绑定 IJK XComponent 上下文
- **THEN** playback backend service SHALL 拒绝创建或绑定 IJK libraryname XComponent 上下文
- **AND** UI 侧 SHALL 不再暴露 IJK context 绑定入口

#### Scenario: Bind mpv surface after backend selection
- **WHEN** 当前播放会话最终选择 mpv backend 且 UI 提供 XComponent surfaceId
- **THEN** playback backend service SHALL 通过 surface adapter 完成 surface 绑定
- **AND** mpv 分支 SHALL 使用 `XComponentController` 模式而非 `libraryname` 模式
