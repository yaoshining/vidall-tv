## ADDED Requirements

### Requirement: Subtitle runtime session SHALL be centralized
一次播放会话中的字幕轨加载、激活状态、延迟调整与外置字幕追加，系统 MUST 由统一的 subtitle session service 管理。

#### Scenario: Initialize subtitle session for a playback session
- **WHEN** 播放器完成 ready 阶段并开始初始化字幕轨
- **THEN** subtitle session service SHALL 负责建立当前会话的字幕轨列表、当前激活轨与相关运行时状态

### Requirement: Subtitle switching semantics SHALL remain compatible
在迁移到 subtitle session service 后，系统 MUST 保持现有字幕切换语义，包括关闭字幕、切换内嵌字幕、切换外置字幕与追加下载字幕后的自动切换。

#### Scenario: Disable subtitle in current session
- **WHEN** 用户选择关闭字幕
- **THEN** subtitle session service SHALL 将当前会话字幕状态切换到关闭态
- **AND** 系统 SHALL 保持现有用户绑定清理语义

#### Scenario: Append and activate a downloaded subtitle
- **WHEN** 当前播放会话收到一个新下载完成的本地字幕文件
- **THEN** subtitle session service SHALL 将该字幕追加到当前会话轨道列表
- **AND** 系统 SHALL 支持后续将其切换为当前激活字幕

### Requirement: Subtitle delay SHALL be session state, not UI-local state
字幕延迟 MUST 作为当前播放会话的一部分统一存储和驱动，而不能仅由 UI 临时持有。

#### Scenario: Adjust subtitle delay during playback
- **WHEN** 用户在当前会话中调整字幕延迟
- **THEN** subtitle session service SHALL 更新当前会话的 delay 状态
- **AND** 字幕显示效果 SHALL 在现有时间尺度内反映该变化
