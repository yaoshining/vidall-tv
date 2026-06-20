# playback-resume-recovery Specification

## Purpose
TBD - created by syncing change fix-real-device-resume-playback. Update Purpose after archive.

## Requirements
### Requirement: 播放器 SHALL 在重新进入同一媒体时恢复上次进度
系统 MUST 在用户重新进入同一视频时读取该媒体对应的已保存进度；当进度存在且未达到完播阈值时，系统 MUST 在播放器准备完成后恢复到该位置，而不是从 0 开始播放；当进度已达到完播阈值时，系统 MUST 清除续播状态并从头开始播放。

#### Scenario: 重新进入视频时恢复已保存进度
- **WHEN** 用户重新进入同一视频
- **AND** 系统读到该视频存在有效续播进度
- **AND** 该进度未达到完播阈值
- **THEN** 系统在播放器准备完成后 seek 到该进度
- **AND** 系统按该播放会话的恢复决策继续播放

#### Scenario: 已接近完播时不恢复旧进度
- **WHEN** 用户重新进入同一视频
- **AND** 系统读到的续播进度已达到完播阈值
- **THEN** 系统清除该媒体的续播状态
- **AND** 系统从头开始播放

### Requirement: 播放器 SHALL 在后端切换或重建实例时保留待恢复续播点
当 AVPlayer、native player 或 ijkplayer 之间发生 fallback、reloadSource、选集切换或其他导致播放器实例重建的路径时，系统 MUST 保留当前播放位置及恢复后是否自动播放的决策，并在新播放器实例 ready 后只消费一次该恢复决策；该自动播放决策 MUST 以当前播放会话的显式恢复意图为准，不能只依赖 `isPlaying`、`isSeeking` 等瞬时播放器状态推断，因此当 seek 已完成且会话已经决定自动播放但播放态尚未落稳时，系统仍 MUST 在后端切换后继续自动播放。

#### Scenario: fallback 后恢复到切换前位置
- **WHEN** 播放过程中发生播放器后端 fallback
- **AND** 旧播放器实例已有可用播放位置
- **THEN** 系统保存切换前的播放位置与自动播放决策
- **AND** 新播放器实例 ready 后 seek 到该位置
- **AND** 系统只消费一次该恢复决策

#### Scenario: 切源重建后沿用新媒体的续播决策
- **WHEN** 用户触发切源、reloadSource 或选集切换
- **AND** 新媒体存在 `startPositionMs` 或已保存的续播进度
- **THEN** 系统使用新媒体对应的恢复决策初始化新播放会话
- **AND** 系统不得继续消费旧媒体遗留的续播状态

#### Scenario: 选集切换后在 seekDone 与 onPlay 之间 fallback 仍自动播放
- **WHEN** 用户切换剧集后系统已完成续播 seek
- **AND** 当前播放会话已进入 seekDone 后的自动起播阶段
- **AND** 回退发生时 `isPlaying` 尚未更新为播放中
- **THEN** 系统仍将该会话视为“恢复后应自动播放”
- **AND** 接手的后端在 ready 后恢复位置并自动开始播放

### Requirement: 系统 SHALL 输出续播恢复的结构化诊断日志
系统 MUST 在续播恢复链路的关键节点输出结构化日志，至少覆盖进度保存、进度读取、续播决策建立、fallback 捕获、fallback 消费、seek 触发、seek 完成或失败、自动播放决策执行八类事件；日志 MUST 包含能够关联当前播放会话的最小上下文，以及恢复决策来源、是否要求自动播放、是否处于 seekDone 后的自动起播窗口，以支持真实设备定位“位置恢复成功但自动播放意图丢失”的失败点。

#### Scenario: 恢复失败时能够定位自动播放意图丢失阶段
- **WHEN** 用户在真实设备上复现“切集后位置正确但未自动播放”的问题
- **THEN** 日志能够区分问题发生在恢复决策建立、fallback 捕获、fallback 消费或自动播放执行阶段

#### Scenario: 恢复成功时能够串联完整链路
- **WHEN** 用户在真实设备上成功恢复续播
- **THEN** 日志能够串联出保存进度、读取进度、建立恢复决策、fallback 透传、seek 完成与继续播放的完整顺序
