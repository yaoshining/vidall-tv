## ADDED Requirements

### Requirement: AVPlayer SHALL fixedly fall back to MPV
系统 MUST 在 AVPlayer 无法播放当前媒体或初始化失败时固定回退到 MPV，不读取或持久化用户回退内核偏好。

#### Scenario: AVPlayer reports unsupported format
- **WHEN** AVPlayer 报告当前媒体格式不支持
- **THEN** 系统 SHALL 选择 MPV 作为唯一回退后端
- **AND** 系统 SHALL 保留当前播放位置与自动播放决策

#### Scenario: MPV also fails
- **WHEN** MPV 接手播放后仍初始化或播放失败
- **THEN** 系统 SHALL 进入统一播放错误处理
- **AND** 系统 SHALL NOT 再尝试其他播放内核

## REMOVED Requirements

### Requirement: System SHALL persist user's fallback kernel preference
**Reason**: 回退目标固定为 MPV，不再需要用户偏好。
**Migration**: 忽略既有 `PLAYER_FALLBACK` 数据，无需迁移。

### Requirement: Settings page SHALL expose fallback kernel selection
**Reason**: 唯一回退后端不需要设置入口。
**Migration**: 从设置页移除该分组。

### Requirement: Backend decision SHALL respect user fallback preference
**Reason**: 后端决策改为固定选择 MPV。
**Migration**: 调用方不再提供回退偏好。

### Requirement: Playback menu SHALL provide kernel switch entry
**Reason**: 播放中不再允许在 IJK 与 MPV 间切换。
**Migration**: 从播放控制菜单移除内核切换入口。

### Requirement: Dual-kernel failure SHALL prompt user for final fallback
**Reason**: IJK 已移除，不存在另一回退内核。
**Migration**: MPV 失败时使用统一错误处理。

### Requirement: mpv kernel SHALL be marked as real-device only in settings
**Reason**: 回退内核设置页入口被移除。
**Migration**: 运行时兼容性由后端能力探测和统一错误处理负责。
