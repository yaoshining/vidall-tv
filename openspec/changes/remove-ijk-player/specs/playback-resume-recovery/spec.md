## MODIFIED Requirements

### Requirement: 播放器 SHALL 在后端切换或重建实例时保留待恢复续播点
当 AVPlayer 与 MPV 之间发生 fallback、reloadSource、选集切换或其他导致播放器实例重建的路径时，系统 MUST 保留当前播放位置及恢复后是否自动播放的决策，并在新播放器实例 ready 后只消费一次该恢复决策；该自动播放决策 MUST 以当前播放会话的显式恢复意图为准，不能只依赖瞬时播放器状态推断。

#### Scenario: fallback 后恢复到切换前位置
- **WHEN** 播放过程中 AVPlayer fallback 到 MPV
- **AND** 旧播放器实例已有可用播放位置
- **THEN** 系统保存切换前的播放位置与自动播放决策
- **AND** MPV ready 后 seek 到该位置
- **AND** 系统只消费一次该恢复决策

#### Scenario: 切源重建后沿用新媒体的续播决策
- **WHEN** 用户触发切源、reloadSource 或选集切换
- **AND** 新媒体存在 startPositionMs 或已保存的续播进度
- **THEN** 系统使用新媒体对应的恢复决策初始化新播放会话
- **AND** 系统不得继续消费旧媒体遗留的续播状态

#### Scenario: 选集切换后在 seekDone 与 onPlay 之间 fallback 仍自动播放
- **WHEN** 用户切换剧集后系统已完成续播 seek
- **AND** 当前播放会话已进入 seekDone 后的自动起播阶段
- **AND** 回退发生时播放态尚未更新为播放中
- **THEN** 系统仍将该会话视为恢复后应自动播放
- **AND** MPV 在 ready 后恢复位置并自动开始播放
