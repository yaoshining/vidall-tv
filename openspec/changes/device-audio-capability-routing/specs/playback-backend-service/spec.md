## MODIFIED Requirements

### Requirement: Playback backend orchestration SHALL be centralized
系统 MUST 通过统一的 playback backend service 编排播放器后端选择、adapter 创建、初始化与释放，而不能由 controller 直接承担所有 backend-specific 生命周期逻辑。

#### Scenario: Choose backend for a new playback session
- **WHEN** 新的播放会话开始并提供当前视频信息与能力探测输入
- **THEN** playback backend service SHALL 产出最终选用的 backend、相关 adapter 实例以及后续 fallback 所需的运行时上下文
- **AND** 活跃 backend 集合 SHALL 包含 `'avplayer'` 与 `'mpv'`

#### Scenario: 无兼容音轨时主选 MPV
- **WHEN** 设备能力判定当前媒体不存在任何兼容音轨
- **THEN** playback backend service SHALL 将 `preferredBackend` 置为 `'mpv'`（作为主选，而非 AVPlayer 的 fallback）
- **AND** 系统 SHALL NOT 先创建或 prepare AVPlayer

#### Scenario: 后端决策忽略已弃用的用户回退偏好
- **WHEN** AVPlayer 探测为无法播放当前视频
- **THEN** playback backend service SHALL 忽略已弃用的用户回退偏好并选择 `'mpv'` 作为唯一回退后端
- **AND** playback backend service SHALL NOT 继续读取或持久化回退内核偏好

### Requirement: Fallback flow SHALL preserve existing playback continuity
当当前 backend 触发 unsupported format 或兼容后端 fallback 时，系统 MUST 由 playback backend service 统一执行 fallback，并保留现有续播位置与自动恢复播放语义。

#### Scenario: AVPlayer unsupported format fallback
- **WHEN** AVPlayer 在当前播放会话中报告格式不支持
- **THEN** playback backend service SHALL 触发 `'mpv'` fallback
- **AND** 系统 SHALL 保留当前续播位置与自动恢复播放决策
- **AND** 系统 SHALL 记录该 codec 的设备/固件纠偏结果

#### Scenario: Legacy backend identifiers map to MPV
- **WHEN** 兼容保留的 native 或 ffmpeg 后端标识进入播放流程
- **THEN** playback backend service SHALL 改为切换到 MPV backend
- **AND** 用户可见的恢复播放结果 SHALL 与当前流程保持兼容

#### Scenario: MPV backend failure enters terminal error handling
- **WHEN** 当前后端为 `'mpv'` 且播放失败
- **THEN** playback backend service SHALL 触发统一播放错误处理
- **AND** 系统 SHALL NOT 显示双内核回退提示或再触发内核回退
