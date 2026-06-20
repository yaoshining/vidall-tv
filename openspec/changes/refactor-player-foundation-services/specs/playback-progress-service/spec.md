## ADDED Requirements

### Requirement: Playback resume decisions SHALL be centralized
播放器 prepared 后的续播决策，系统 MUST 通过统一的 playback progress service 计算，包括直接播放、直接 seek、弹续播框、清理已完播进度等分支。

#### Scenario: Saved progress requires direct seek
- **WHEN** 当前媒体存在有效已保存进度且不接近完播阈值
- **THEN** playback progress service SHALL 返回 seek 类型的续播决策与目标位置

#### Scenario: Saved progress is near end
- **WHEN** 当前媒体已保存进度满足 near-end 判定
- **THEN** playback progress service SHALL 返回清理已完播状态后直接播放的决策

### Requirement: Playback progress persistence SHALL be centralized
系统 MUST 通过统一的 playback progress service 协调 `play_progress` 与 `media_progress` 的写入时机，包括定时保存、切后台保存、退出保存与切集前保存。

#### Scenario: App goes to background during playback
- **WHEN** 应用在播放过程中切到后台
- **THEN** playback progress service SHALL 按当前媒体上下文立即保存必要的播放进度

#### Scenario: Episode switch persists current playback state
- **WHEN** 用户在播放器内切换到另一集
- **THEN** playback progress service SHALL 在切换前保存当前媒体的播放进度，并将下一集的续播决策建立在新媒体上下文上

### Requirement: Resume behavior SHALL remain compatible with current UI contracts
在引入 playback progress service 后，系统 MUST 保持当前 `PlayerPageParam`、续播弹窗触发条件与 prepared 后续播时机不变。

#### Scenario: Existing page param contract is reused
- **WHEN** 页面层仍以当前 `PlayerPageParam` 结构发起播放
- **THEN** 系统 SHALL 在不要求页面传入新增字段的情况下完成与现有一致的续播流程
