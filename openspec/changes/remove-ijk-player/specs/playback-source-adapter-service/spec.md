## MODIFIED Requirements

### Requirement: Player source resolution SHALL be centralized
播放器相关入口在构建播放请求时，系统 MUST 通过统一的 source adapter service 解析播放源，而不能由页面层或剧集切源逻辑各自拼装协议细节。

#### Scenario: Resolve WebDAV playback source
- **WHEN** 播放入口传入 WebDAV 文件源与文件路径
- **THEN** source adapter service SHALL 返回已编码的播放 URL、对应请求 headers，以及与该播放源关联的 source identity 信息

#### Scenario: Resolve SMB playback source
- **WHEN** 播放入口传入 SMB 文件源与文件路径
- **THEN** source adapter service SHALL 返回适合目标保留后端消费的 SMB 播放 URL
- **AND** 系统 SHALL 保留稳定 source identity 供字幕缓存与后续协议处理使用

#### Scenario: MPV backend consumes SMB source directly
- **WHEN** 播放后端为 `'mpv'` 且文件源为 SMB
- **THEN** source adapter service SHALL 返回无 userinfo 的 SMB URI
- **AND** SHALL 通过 Authorization header 传递认证信息
- **AND** 系统 SHALL NOT 启动 SMB HTTP 代理

#### Scenario: AVPlayer backend consumes SMB source via HTTP proxy
- **WHEN** 播放后端为 `'avplayer'` 且文件源为 SMB
- **THEN** source adapter service SHALL 返回可供代理模块处理的 SMB URI
- **AND** 系统 SHALL 将代理 URL 转交 AVPlayer 消费
- **AND** 系统 SHALL NOT 为已移除的 IJK 后端启动或保留 HTTP 代理
