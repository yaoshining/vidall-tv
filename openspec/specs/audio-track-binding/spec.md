## ADDED Requirements

### Requirement: 音频轨道绑定持久化存储
系统 SHALL 在用户手动切换音轨后，将选择的音轨 `displayName` 与视频路径的哈希关联存储至 `AppPreferences`，key 格式为 `audio_binding_<sha256(videoPath).slice(0,12)>`。

#### Scenario: 用户手动切换音轨后保存绑定
- **WHEN** 用户通过播放器 UI 选择音轨（`userInitiated=true`）
- **THEN** 系统将该音轨的 `displayName` 存入 `AppPreferences`，与当前视频路径绑定

#### Scenario: 初始化自动选轨不触发保存
- **WHEN** 播放器在 `loadAudioTracks()` 初始化阶段自动调用 `switchAudioTrack()`（`userInitiated=false`）
- **THEN** 系统不写入任何绑定，`AppPreferences` 无变化

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

#### Scenario: 无绑定时使用默认选轨
- **WHEN** `loadAudioTracks()` 完成轨道列表填充
- **AND** `AppPreferences` 中不存在该视频的音轨绑定
- **THEN** 系统执行 `findInitialAudioTrackIndex()` 使用默认选轨逻辑，行为与原有一致

### Requirement: 音频轨道绑定清除
系统 SHALL 提供清除音轨绑定的能力，在 `displayName` 匹配失败时自动触发，并可通过 `AudioDispatcher.clearAudioBinding()` 编程调用。

#### Scenario: 绑定 displayName 不在轨道列表时自动清除
- **WHEN** `resolveAudioTrack()` 在轨道列表中未找到绑定的 `displayName`
- **THEN** 系统调用 `clearAudioBinding()` 清除该视频的音轨绑定

#### Scenario: 绑定恢复由 routing service 给出建议
- **WHEN** 当前播放会话需要根据历史音轨绑定决定初始选轨
- **THEN** 系统 SHALL 通过统一的 audio track routing service 解析目标轨道
- **AND** 实际 `selectTrack` 执行仍由当前播放会话完成
