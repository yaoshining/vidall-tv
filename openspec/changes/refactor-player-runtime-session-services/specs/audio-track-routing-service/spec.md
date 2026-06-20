## ADDED Requirements

### Requirement: Audio routing decisions SHALL be centralized
音频 codec 探测、声道能力判断、初始 backend route 与 fallback 建议，系统 MUST 由统一的 audio track routing service 计算。

#### Scenario: Determine backend route from audio probe
- **WHEN** 新播放会话提供 ffprobe 结果、预置音轨提示或其他音频探测输入
- **THEN** audio track routing service SHALL 返回推荐 backend、fallback 建议与目标声道策略

### Requirement: Initial audio selection SHALL remain deterministic
系统 MUST 由 audio track routing service 统一计算初始音轨恢复建议，覆盖预置音轨与运行时轨道枚举两条路径。

#### Scenario: Restore user audio preference on session start
- **WHEN** 当前视频存在用户历史音轨绑定且当前会话音轨列表已就绪
- **THEN** audio track routing service SHALL 返回与该绑定一致的恢复建议
- **AND** 系统 SHALL 在当前会话中选择对应音轨

### Requirement: Audio routing SHALL not directly own track execution
audio track routing service MUST 只负责建议与决策，不直接调用具体播放器 adapter 执行选轨。

#### Scenario: Apply routing result through playback session
- **WHEN** audio track routing service 返回 route 或音轨恢复建议
- **THEN** 后续实际 `selectTrack` 执行 SHALL 由当前播放会话或 backend 侧完成
- **AND** routing service SHALL 不依赖具体 adapter 实现
