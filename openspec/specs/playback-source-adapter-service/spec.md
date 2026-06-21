# playback-source-adapter-service Specification

## Purpose
统一收口播放器入口的协议源解析，将 WebDAV、SMB、本地文件的 URL 拼装与认证头构造从页面层剥离到独立的 service 中。

## Requirements

### Requirement: Player source resolution SHALL be centralized
播放器相关入口在构建播放请求时，系统 MUST 通过统一的 source adapter service 解析播放源，而不能由页面层或剧集切源逻辑各自拼装协议细节。

#### Scenario: Resolve WebDAV playback source
- **WHEN** 播放入口传入 WebDAV 文件源与文件路径
- **THEN** source adapter service SHALL 返回已编码的播放 URL、对应请求 headers，以及与该播放源关联的 source identity 信息

#### Scenario: Resolve SMB playback source
- **WHEN** 播放入口传入 SMB 文件源与文件路径
- **THEN** source adapter service SHALL 返回可供播放器消费的 SMB 播放 URL，并保留稳定 source identity 供字幕缓存与后续协议处理使用

### Requirement: Episode source switching SHALL reuse the same resolution contract
播放器内切换剧集时，系统 MUST 复用与初始播放入口一致的 source resolution contract，以避免媒体库入口与切集入口出现协议装配差异。

#### Scenario: Switch episode inside media library context
- **WHEN** 用户在播放器内从当前剧集切换到同一播放上下文中的另一集
- **THEN** 系统 SHALL 通过 source adapter service 解析新剧集的播放源，而不是在页面内重新拼装 WebDAV 或 SMB 规则

### Requirement: Stable source identity SHALL be preserved for cache-related flows
系统 MUST 为每次播放源解析提供稳定 source identity，用于字幕缓存、最近使用字幕与其他依赖稳定 key 的流程，且该 identity 不得因瞬时代理 URL 变化而改变。

#### Scenario: SMB proxy URL changes across sessions
- **WHEN** SMB 源在不同播放会话中生成不同的代理 URL
- **THEN** 系统 SHALL 仍使用相同的稳定 source identity 读写字幕缓存与最近使用字幕记录
