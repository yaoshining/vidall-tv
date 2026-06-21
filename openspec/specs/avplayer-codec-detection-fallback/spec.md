# avplayer-codec-detection-fallback Specification

## Purpose
TBD - created by archiving change fix-212-eac3-prepared-fallback. Update Purpose after archive.
## Requirements
### Requirement: AVPlayer 在 PREPARED 状态检测不支持的音频 codec 并主动触发 fallback

系统 SHALL 在 AVPlayer 进入 PREPARED 状态后，通过 `getTrackDescription()` 获取全部轨道信息，检查所有音频轨道（type=0）的 codec 字段；若所有音频轨道均属于不支持的软解格式列表（eac3、ac3、dts、truehd、mlp 等），系统 SHALL 调用 `_onUnsupportedFormatCb`，并且不调用 `_onReadyCb`，以触发播放器 fallback 链路。

#### Scenario: 所有音频轨道均为 eac3 时触发 fallback

- **WHEN** AVPlayer 进入 PREPARED 状态
- **AND** 所有音频轨道（type=0）的 codec 均属于不支持格式（如 audio/eac3）
- **THEN** 系统调用 `_onUnsupportedFormatCb` 触发 fallback
- **AND** 系统不调用 `_onReadyCb`

#### Scenario: 混合音轨场景（eac3 + AAC）不触发 fallback

- **WHEN** AVPlayer 进入 PREPARED 状态
- **AND** 音频轨道中至少有一条受支持格式（如 audio/mp4a-latm / audio/aac）
- **THEN** 系统正常调用 `_onReadyCb`，不触发 fallback

#### Scenario: 无音频轨道时不触发 fallback

- **WHEN** AVPlayer 进入 PREPARED 状态
- **AND** 文件中不存在任何音频轨道（type=0）
- **THEN** 系统正常调用 `_onReadyCb`，不触发 fallback

#### Scenario: API 19 行为不受影响

- **WHEN** 设备运行在 API 19 环境
- **AND** eac3 文件在 `prepare()` 阶段触发 error 事件（5400106/5400103）
- **THEN** 原有 error handler 调用 `_onUnsupportedFormatCb`，PREPARED handler 不执行
- **AND** 新增的 PREPARED 检测逻辑不参与此路径

### Requirement: AVPlayer codec fallback SHALL 保留并恢复当前续播位置

当 AVPlayer 因 PREPARED 阶段 codec 检测或 error 回调判定当前媒体不受支持并触发 fallback 时，系统 MUST 在释放旧播放器实例前捕获当前可用播放位置与恢复决策，并将该恢复决策透传给接手的后端；恢复决策 MUST 同时包含恢复位置与是否自动播放，且当 fallback 发生在 seek 已完成、自动起播已决策但播放态回调尚未到达的窗口内时，系统 MUST 保留该"待自动播放"意图，而不能仅依赖 `isPlaying` 或 `isSeeking` 的瞬时状态推断；新的后端 ready 后 MUST 按该决策恢复到对应位置并继续执行自动播放或暂停语义。该 fallback 编排 MUST 由统一的 playback backend service 执行，但恢复位置、自动播放意图与当前用户可见行为保持兼容。

#### Scenario: PREPARED 阶段主动 fallback 时保留续播位置

- **WHEN** AVPlayer 在 PREPARED 状态检测到所有音频轨道均为不支持 codec
- **AND** 系统准备切换到 fallback 后端
- **THEN** 系统在释放 AVPlayer 前保存当前可用播放位置与当前恢复决策
- **AND** fallback 后端 ready 后按该恢复决策恢复位置与播放语义

#### Scenario: error 回调 fallback 时保留续播位置

- **WHEN** AVPlayer 因格式不支持错误触发 `_onUnsupportedFormatCb`
- **AND** 播放会话在切换前已有已知播放位置
- **THEN** 系统将该位置与自动播放决策透传到 fallback 后端
- **AND** fallback 完成后继续按原决策恢复播放

#### Scenario: fallback 编排由 backend service 统一执行
- **WHEN** 当前播放会话进入 unsupported format fallback 路径
- **THEN** 系统 SHALL 通过统一的 playback backend service 执行 backend 切换、旧实例释放与新实例恢复
- **AND** `VideoPlayerController` 对 UI 暴露的 fallback 结果保持不变

#### Scenario: seek 完成后的自动起播窗口内 fallback 仍保留自动播放意图

- **WHEN** 用户切换剧集后系统已对新媒体执行续播 seek
- **AND** seek 已完成且当前播放会话已决策继续自动播放
- **AND** AVPlayer 在播放态回调到达前触发 unsupported format fallback
- **THEN** 系统保存的恢复决策仍标记该会话需要自动播放
- **AND** fallback 后端 ready 后在恢复位置后自动开始播放

### Requirement: AVPlayer 在混合音轨文件中恢复历史音轨偏好时必须避开不可播放 codec

系统 SHALL 在加载媒体音轨并尝试恢复历史音轨偏好时，依据目标轨的 `codecName` 判定该偏好轨是否可播放；若该偏好轨不可播放，系统 SHALL 不直接选中它，而是按“同语言可播放轨优先，其次任意可播放轨”的顺序选择候选；若不存在任何可播放音轨，系统 SHALL 保留现有失败或 fallback 策略。

#### Scenario: 历史偏好轨可播放时直接恢复

- **WHEN** 当前媒体存在历史偏好对应的音轨
- **AND** 该音轨的 `codecName` 属于当前设备可播放格式
- **THEN** 系统直接恢复该历史偏好轨
- **AND** 不触发降级选择

#### Scenario: 历史偏好轨不可播放但存在同语言可播放轨时同语言降级

- **WHEN** 当前媒体存在历史偏好对应的音轨
- **AND** 该偏好轨的 `codecName` 不可播放
- **AND** 当前媒体中存在另一条语言相同且 `codecName` 可播放的音轨
- **THEN** 系统选择该同语言可播放轨
- **AND** 不直接选中不可播放的历史偏好轨

#### Scenario: 历史偏好轨不可播放且无同语言候选时选择任意可播放轨

- **WHEN** 当前媒体存在历史偏好对应的音轨
- **AND** 该偏好轨的 `codecName` 不可播放
- **AND** 不存在同语言可播放轨
- **AND** 仍存在至少一条其他可播放音轨
- **THEN** 系统选择任意一条可播放音轨
- **AND** 不回退到不可播放的历史偏好轨

#### Scenario: 全部音轨都不可播放时沿用现有失败或 fallback 策略

- **WHEN** 当前媒体存在历史偏好对应的音轨
- **AND** 该偏好轨的 `codecName` 不可播放
- **AND** 当前媒体中不存在任何可播放音轨
- **THEN** 系统不强行选中不可播放音轨
- **AND** 系统继续沿用现有失败或 fallback 策略

### Requirement: AVPlayer 初始音轨选择不得无脑回退到索引 0

系统 SHALL 在没有可恢复的有效历史偏好时，基于可播放性选择初始音轨；当索引 0 音轨不可播放但存在其他可播放音轨时，系统 SHALL 选择可播放候选，而不是无条件选择索引 0。

#### Scenario: 无历史偏好且索引 0 不可播放时选择其他可播放轨

- **WHEN** 当前媒体不存在可恢复的有效历史偏好
- **AND** 索引 0 音轨的 `codecName` 不可播放
- **AND** 当前媒体存在另一条可播放音轨
- **THEN** 系统选择该可播放音轨作为初始音轨
- **AND** 不直接默认选中索引 0

#### Scenario: 无历史偏好且索引 0 可播放时保持当前首选顺序

- **WHEN** 当前媒体不存在可恢复的有效历史偏好
- **AND** 索引 0 音轨的 `codecName` 可播放
- **THEN** 系统可以按当前首选顺序选择该音轨
