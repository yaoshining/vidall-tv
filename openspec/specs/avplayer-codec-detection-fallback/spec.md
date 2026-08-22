# avplayer-codec-detection-fallback Specification

## Purpose
Route playback to AVPlayer or MPV before AVPlayer preparation based on real device audio decoding capability, and degrade dynamically with device/firmware corrections when AVPlayer explicitly fails on a codec it claimed to support.

## Requirements

### Requirement: 启动前能力路由与显式失败 fallback
系统 SHALL 在创建或 prepare AVPlayer 之前，依据设备真实解码能力（codec 支持 + 最大声道）判定当前媒体是否存在兼容音轨；不存在兼容音轨时 SHALL 直接选择 MPV 后端，不先 prepare AVPlayer。全局 codec 黑名单不再作为最终兼容性真值。AVPlayer 明确播放失败（unsupported format / 5400106 / 5400103）时，系统 MUST 动态降级到 MPV，并在释放旧实例前保留续播位置与恢复决策；该 fallback 编排 MUST 由统一的 playback backend service 执行。

#### Scenario: 无兼容音轨时直接选择 MPV
- **WHEN** 设备不支持媒体中的全部音频轨道（如全部为 eac3）
- **THEN** 系统 SHALL 在创建或 prepare AVPlayer 前选择 MPV
- **AND** 不进入 AVPlayer PREPARED 阶段的 fallback 判定

#### Scenario: 存在兼容音轨时选择 AVPlayer 并预选兼容轨
- **WHEN** 媒体中存在至少一条设备能力兼容的音轨（如混合 eac3 + AAC 中的 AAC）
- **THEN** 系统 SHALL 选择 AVPlayer 并正常进入 ready，不触发 fallback
- **AND** 系统 SHALL 预选兼容性最高且符合语言偏好的音轨

#### Scenario: 无音频轨道时不触发 fallback
- **WHEN** 文件中不存在任何音频轨道
- **THEN** 系统 SHALL 选择 AVPlayer 并正常进入 ready，不触发 fallback

#### Scenario: 能力查询异常时保守选择 MPV
- **WHEN** 设备能力查询异常或能力未知
- **THEN** 系统 SHALL 保守选择 MPV（不基于任何 codec 启发式假设兼容性）

#### Scenario: API 19 error 路径不受影响
- **WHEN** 设备运行在 API 19 环境，且不支持的音频文件在 `prepare()` 阶段触发 error 事件（5400106/5400103）
- **THEN** 原有 error handler 调用 `_onUnsupportedFormatCb` 触发动态降级
- **AND** 新增的启动前能力判定不参与此 error 路径

#### Scenario: error 回调 fallback 时保留续播位置
- **WHEN** AVPlayer 因格式不支持错误触发 fallback，且播放会话在切换前已有已知播放位置
- **THEN** 系统在释放 AVPlayer 前保存当前播放位置与恢复决策
- **AND** fallback 后端 ready 后按该恢复决策恢复位置与播放语义

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

### Requirement: AVPlayer 明确播放失败时动态降级并记录纠偏

当 AVPlayer 对某音轨明确报告格式不支持（如错误码 5400106 / 5400103 或 unsupported format 事件）时，系统 MUST 动态降级到 MPV，并记录该 codec 的设备/固件纠偏结果以供后续会话复用。

#### Scenario: AVPlayer 明确失败触发动态降级
- **WHEN** AVPlayer 报告当前媒体格式不支持（5400106 / 5400103）
- **THEN** 系统 SHALL 触发 MPV fallback
- **AND** 记录该 codec 的纠偏结果（`forceUnsupported`）

#### Scenario: 纠偏结果在后续会话优先于系统声明
- **WHEN** 后续播放会话读取到针对当前设备与 codec 的纠偏结果
- **THEN** 系统 SHALL 优先采用纠偏结果判该 codec 不兼容
- **AND** 不再仅依赖系统声明的解码能力

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
