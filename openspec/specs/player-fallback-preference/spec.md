# player-fallback-preference Specification

## Purpose

定义播放主路径失败后的固定回退行为，确保 AVPlayer 不支持媒体或初始化失败时由 MPV 唯一接手，并在 MPV 失败后进入统一终态错误。

## Requirements

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
