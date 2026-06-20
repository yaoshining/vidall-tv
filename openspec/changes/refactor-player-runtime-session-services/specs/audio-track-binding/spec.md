## MODIFIED Requirements

### Requirement: 音频轨道绑定恢复
系统 SHALL 在每次加载视频音轨完成后，查询该视频的音轨绑定，若绑定存在且 `displayName` 匹配当前轨道列表中的某条轨道，则自动切换到该轨道。该恢复决策 MUST 通过统一的 audio track routing service 计算，但绑定语义与用户可见结果保持兼容。

#### Scenario: 绑定命中时自动恢复
- **WHEN** `loadAudioTracks()` 完成轨道列表填充
- **AND** `AppPreferences` 中存在该视频的音轨绑定
- **AND** 绑定的 `displayName` 在当前 `audioTracks` 列表中存在精确匹配
- **THEN** 系统直接切换到该轨道，跳过 `findInitialAudioTrackIndex()` 默认选轨

#### Scenario: 绑定未命中时清除并回退默认
- **WHEN** `loadAudioTracks()` 完成轨道列表填充
- **AND** `AppPreferences` 中存在该视频的音轨绑定
- **AND** 绑定的 `displayName` 不在当前 `audioTracks` 列表中
- **THEN** 系统自动清除该绑定，并继续执行 `findInitialAudioTrackIndex()` 默认选轨

#### Scenario: 绑定恢复由 routing service 给出建议
- **WHEN** 当前播放会话需要根据历史音轨绑定决定初始选轨
- **THEN** 系统 SHALL 通过统一的 audio track routing service 解析目标轨道
- **AND** 实际 `selectTrack` 执行仍由当前播放会话完成
