# player-fallback-preference Specification

## Purpose

Define the behavior contract for user-configurable playback kernel fallback preference, including the settings UI, in-playback kernel switching, and dual-kernel failure fallback UX.

## Requirements

### Requirement: System SHALL persist user's fallback kernel preference
系统 MUST 在 `AppPreferences` 中持久化用户对 AVPlayer 失败时回退内核的选择，默认值为 `'ijkplayer'`。

#### Scenario: Default fallback preference
- **WHEN** 用户首次安装应用且未修改过回退内核设置
- **THEN** `AppPreferences.PLAYER_FALLBACK` SHALL 返回 `'ijkplayer'`
- **AND** 后端决策逻辑 SHALL 在 AVPlayer 失败时回退到 `ijkplayer`

#### Scenario: User selects mpv as fallback
- **WHEN** 用户在设置中选择 `mpv` 作为回退内核
- **THEN** `AppPreferences.PLAYER_FALLBACK` SHALL 持久化为 `'mpv'`
- **AND** 后续播放会话中 AVPlayer 失败时 SHALL 回退到 `mpv`

### Requirement: Settings page SHALL expose fallback kernel selection
设置页 MUST 新增"播放内核回退"分组，允许用户在 `ijkplayer` 与 `mpv` 之间单选，并标注当前选择。

#### Scenario: Settings UI displays current selection
- **WHEN** 用户进入设置页
- **THEN** "播放内核回退"分组 SHALL 显示当前选中的回退内核
- **AND** 选项 SHALL 包含 `'ijkplayer'` 与 `'mpv'` 两项

#### Scenario: User changes fallback in settings
- **WHEN** 用户在设置中切换回退内核选择
- **THEN** 选择 SHALL 立即持久化到 `AppPreferences`
- **AND** 新选择 SHALL 在下一次播放会话的 AVPlayer 失败回退中生效

### Requirement: Backend decision SHALL respect user fallback preference
`PlaybackBackendService.chooseBackend()` MUST 在 AVPlayer 无法播放时，读取用户偏好决定回退到 `ijkplayer` 还是 `mpv`。

#### Scenario: AVPlayer fails with ijkplayer preference
- **WHEN** AVPlayer 探测为无法播放且用户偏好为 `'ijkplayer'`
- **THEN** 后端决策 SHALL 返回 `'ijkplayer'`

#### Scenario: AVPlayer fails with mpv preference
- **WHEN** AVPlayer 探测为无法播放且用户偏好为 `'mpv'`
- **THEN** 后端决策 SHALL 返回 `'mpv'`

#### Scenario: AVPlayer succeeds regardless of preference
- **WHEN** AVPlayer 探测为可播放
- **THEN** 后端决策 SHALL 返回 `'avplayer'`
- **AND** 用户偏好 SHALL 不影响此决策

### Requirement: Playback menu SHALL provide kernel switch entry
播放中控制菜单 MUST 新增"内核切换"按钮，允许用户在 `ijkplayer` 与 `mpv` 之间强制切换，无需退出播放页。

#### Scenario: Kernel switch button visible during playback
- **WHEN** 当前后端为 `'ijkplayer'` 或 `'mpv'` 且播放控制菜单展开
- **THEN** 菜单 SHALL 显示"内核切换"按钮
- **AND** 按钮文案 SHALL 显示当前内核名称

#### Scenario: User switches kernel during playback
- **WHEN** 用户点击"内核切换"按钮
- **THEN** 系统 SHALL 保存当前播放位置
- **AND** 释放当前内核并初始化目标内核
- **AND** 目标内核 `onReady` 后 SHALL seek 到保存的位置
- **AND** 切换过程中 UI SHALL 显示 loading 状态并禁用控制按钮

#### Scenario: Kernel switch preserves playback position
- **WHEN** 内核切换完成
- **THEN** 播放位置 SHALL 与切换前位置偏差不超过 ±1 秒
- **AND** 播放状态（播放/暂停）SHALL 与切换前一致

### Requirement: Dual-kernel failure SHALL prompt user for final fallback
当用户当前选中的回退内核也播放失败时，系统 MUST 弹出确认对话框询问是否尝试另一内核，而非直接报错退出。

#### Scenario: mpv fails, prompt for ijkplayer
- **WHEN** 当前后端为 `'mpv'` 且播放失败
- **THEN** UI SHALL 弹出对话框："当前内核无法播放此视频，是否尝试使用 ijkplayer 播放？"
- **AND** 提供"确认"与"取消"两个选项

#### Scenario: User confirms final fallback
- **WHEN** 用户在双内核失败对话框中点击"确认"
- **THEN** 系统 SHALL 强制切换到另一内核并重新加载当前视频
- **AND** 播放位置 SHALL 保持为失败前的位置

#### Scenario: User cancels final fallback
- **WHEN** 用户在双内核失败对话框中点击"取消"
- **THEN** 系统 SHALL 退出播放页
- **AND** 不 SHALL 自动重试

### Requirement: mpv kernel SHALL be marked as real-device only in settings
设置页中的 `mpv` 选项 MUST 标注"仅支持真机"，以管理 x86_64 模拟器用户的预期。

#### Scenario: Settings display mpv limitation
- **WHEN** 用户查看"播放内核回退"设置
- **THEN** `mpv` 选项 SHALL 附带"仅支持真机"说明
- **AND** 在 x86_64 模拟器上选择 `mpv` 时 SHALL 提示"当前设备不支持 mpv 内核，已自动回退到 ijkplayer"