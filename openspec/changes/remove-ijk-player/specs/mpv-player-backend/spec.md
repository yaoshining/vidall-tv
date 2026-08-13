## MODIFIED Requirements

### Requirement: MPV backend SHALL be registered as the fallback playback backend
系统 MUST 注册 `'mpv'` 为 AVPlayer 的唯一回退播放后端，同时保留 MPV adapter 的既有播放能力。

#### Scenario: Backend enumeration includes mpv
- **WHEN** 系统初始化播放后端选择逻辑
- **THEN** `'mpv'` SHALL 作为有效后端值存在
- **AND** `'ijkplayer'` SHALL NOT 作为有效活跃后端值存在

#### Scenario: AVPlayer falls back to mpv
- **WHEN** AVPlayer 无法播放当前媒体
- **THEN** 系统 SHALL 创建 MPV adapter 接手播放
- **AND** 用户无需选择回退内核

#### Scenario: mpv adapter creation
- **WHEN** 后端决策结果为 `'mpv'`
- **THEN** playback backend service SHALL 创建 MPV adapter 实例
- **AND** 该实例 SHALL 实现统一播放器接口的全部方法与回调注册
