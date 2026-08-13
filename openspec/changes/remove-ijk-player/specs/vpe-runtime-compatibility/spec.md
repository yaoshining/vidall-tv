## MODIFIED Requirements

### Requirement: MPV 后端在不兼容架构上 SHALL 安全失败
MPV 播放后端依赖包含目标架构原生库的播放器包。系统 MUST 在运行环境与 MPV 原生库不兼容时阻止加载 MPV，并进入统一播放错误处理，不得回退到已移除的播放内核。

#### Scenario: 不兼容架构触发统一播放错误
- **WHEN** AVPlayer 无法播放当前媒体
- **AND** 当前运行架构无法加载 MPV 原生库
- **THEN** 系统 SHALL 显示统一播放错误
- **AND** 系统 SHALL NOT 尝试加载 IJKPlayer

#### Scenario: ARM 真机上 MPV 后端正常可用
- **WHEN** 应用运行在 MPV 原生库支持的 ARM 真机
- **THEN** MPV 后端 SHALL 正常工作
- **AND** AVPlayer 失败后 SHALL 能够回退到 MPV
