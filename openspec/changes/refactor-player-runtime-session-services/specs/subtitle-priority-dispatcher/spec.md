## MODIFIED Requirements

### Requirement: 系统 SHALL 在 prepared 后按固定优先级链自动选择字幕来源
视频进入 `prepared` 状态后，系统 SHALL 仍按既有优先级链裁决字幕来源：用户指定字幕、adapter 已加载的内置或同目录外置字幕、本地缓存、无字幕。该裁决流程 MUST 在统一的 subtitle session service 中执行，但优先级顺序与用户可见结果保持兼容。

#### Scenario: 字幕优先级裁决在会话初始化中执行
- **WHEN** 当前播放会话初始化字幕轨
- **THEN** 系统在 subtitle session service 中执行既有的字幕优先级裁决
- **AND** adapter 自动选轨结果仅在优先级更高的用户绑定或缓存命中时被覆盖

#### Scenario: 缓存字幕恢复使用当前会话的稳定视频标识
- **WHEN** 当前播放会话尝试恢复缓存字幕或最近使用字幕
- **THEN** 系统使用当前会话关联的稳定视频标识进行查询
- **AND** 命中的字幕结果通过 subtitle session service 应用到当前会话
